// https://github.com/ImagicTheCat/ljuv
// MIT license (see LICENSE or src/ljuv.lua)

#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <uv.h>

// Object multi-threaded reference counting.

typedef struct ljuv_object{
  uint32_t count;
  void (*destructor)(struct ljuv_object *obj);
  uv_mutex_t mutex;
} ljuv_object;

// Init object (one reference by default).
// return < 0 on failure
int object_init(ljuv_object *obj, void (*destructor)(ljuv_object *obj))
{
  obj->count = 1;
  obj->destructor = destructor;
  return uv_mutex_init(&obj->mutex);
}
void object_retain(ljuv_object *obj)
{
  uv_mutex_lock(&obj->mutex);
  obj->count++;
  uv_mutex_unlock(&obj->mutex);
}
void object_release(ljuv_object *obj)
{
  uv_mutex_lock(&obj->mutex);
  uint32_t count = --obj->count;
  uv_mutex_unlock(&obj->mutex);
  if(count == 0){
    if(obj->destructor) obj->destructor(obj);
    uv_mutex_destroy(&obj->mutex);
    free(obj);
  }
}
void object_lock(ljuv_object *obj){ uv_mutex_lock(&obj->mutex); }
void object_unlock(ljuv_object *obj){ uv_mutex_unlock(&obj->mutex); }

// Shared flag

typedef struct ljuv_shared_flag{
  ljuv_object object; // inheritance
  int flag;
} ljuv_shared_flag;

// Create shared flag.
// return NULL on failure
ljuv_shared_flag* shared_flag_create(int flag)
{
  // object
  ljuv_shared_flag *shared_flag = malloc(sizeof(ljuv_shared_flag));
  if(!shared_flag) return NULL;
  int status = object_init((ljuv_object*)shared_flag, NULL);
  if(status < 0){ free(shared_flag); return NULL; }
  shared_flag->flag = flag;
  return shared_flag;
}
void shared_flag_set(ljuv_shared_flag *self, int flag)
{
  object_lock((ljuv_object*)self);
  self->flag = flag;
  object_unlock((ljuv_object*)self);
}
int shared_flag_get(ljuv_shared_flag *self)
{
  object_lock((ljuv_object*)self);
  int flag = self->flag;
  object_unlock((ljuv_object*)self);
  return flag;
}

// Channel

typedef struct channel_node{
  uint8_t *data;
  size_t size;
  struct channel_node *prev;
} channel_node;

typedef struct ljuv_channel{
  ljuv_object object; // inheritance
  channel_node *back, *front; // queue
  unsigned int count; // queue count, follows semaphore integer type
  uv_sem_t semaphore;
} ljuv_channel;

channel_node* channel_node_create(uint8_t *data, size_t size)
{
  channel_node *node = malloc(sizeof(channel_node));
  if(!node) return NULL;
  node->data = data;
  node->size = size;
  node->prev = NULL;
  return node;
}

void channel_destroy(ljuv_object *obj)
{
  ljuv_channel *channel = (ljuv_channel*)obj;
  // free nodes and data
  channel_node *node = channel->front;
  while(node){
    free(node->data);
    channel_node *next = node->prev;
    free(node);
    // next
    node = next;
  }
  uv_sem_destroy(&channel->semaphore);
}

// Create channel (object).
// return NULL on failure
ljuv_channel* channel_create(void)
{
  // object
  ljuv_channel *channel = malloc(sizeof(ljuv_channel));
  if(!channel) return NULL;
  int status = object_init((ljuv_object*)channel, channel_destroy);
  if(status < 0){ free(channel); return NULL; }
  // channel
  status = uv_sem_init(&channel->semaphore, 0);
  if(status < 0){ free(channel); return NULL; }
  channel->back = channel->front = NULL;
  channel->count = 0;
  return channel;
}

// Push message data (makes a copy).
// return false on allocation failure
bool channel_push(ljuv_channel *channel, const uint8_t *data, size_t size)
{
  // copy data
  uint8_t *copy = malloc(size);
  if(!copy) return false;
  memcpy(copy, data, size);
  // push to queue
  channel_node *node = channel_node_create(copy, size);
  if(!node){ free(copy); return false; }
  object_lock((ljuv_object*)channel);
  if(channel->back){
    channel->back->prev = node;
    channel->back = node;
  }
  else // first push
    channel->back = channel->front = node;
  channel->count++;
  object_unlock((ljuv_object*)channel);
  // post
  uv_sem_post(&channel->semaphore);
  return true;
}

// [private] Dequeue channel (no checks).
uint8_t* channel_dequeue(ljuv_channel *channel, size_t *size)
{
  object_lock((ljuv_object*)channel);
  channel_node *node = channel->front;
  channel->front = node->prev;
  if(!channel->front) channel->back = NULL; // last pop
  channel->count--;
  object_unlock((ljuv_object*)channel);
  // fill data
  *size = node->size;
  uint8_t *data = node->data;
  free(node);
  return data;
}

// Pull message data (blocks if empty).
// The returned data must be freed with free().
uint8_t* channel_pull(ljuv_channel *channel, size_t *size)
{
  // wait
  uv_sem_wait(&channel->semaphore);
  return channel_dequeue(channel, size);
}

// Pull message data (non-blocking).
// Return non-NULL on success; the returned data must be freed with free().
uint8_t* channel_try_pull(ljuv_channel *channel, size_t *size)
{
  // wait
  if(uv_sem_trywait(&channel->semaphore) == 0)
    return channel_dequeue(channel, size);
  else return NULL;
}

// Count the number of pending messages.
size_t channel_count(ljuv_channel *channel)
{
  object_lock((ljuv_object*)channel);
  size_t count = channel->count;
  object_unlock((ljuv_object*)channel);
  return count;
}

// Thread

typedef struct ljuv_thread{
  uv_thread_t handle;
  uv_mutex_t mutex;
  lua_State *L;
  bool running;
} ljuv_thread;

static const char thread_lua[] =
  "local function pack(...) return {n = select('#', ...), ...} end\n\
  local buffer = require('string.buffer')\n\
  local errtrace\n\
  local function error_handler(err) errtrace = debug.traceback(err, 2) end\n\
  -- execute\n\
  local ok, data = xpcall(function()\n\
    local data = buffer.decode(ljuv_data)\n\
    ljuv_data = nil\n\
    package.path, package.cpath = data.path, data.cpath\n\
    local func, err = load(data.func)\n\
    assert(func, err)\n\
    local rets = pack(true, func(unpack(data.args, 1, data.args.n)))\n\
    return buffer.encode(rets)\n\
  end, error_handler)\n\
  if ok then ljuv_data = data\n\
  else ljuv_data = buffer.encode(pack(false, errtrace)) end\n";

// Thread entry function.
void thread_run(void *arg)
{
  ljuv_thread *thread = arg;
  lua_State *L = thread->L;
  luaL_openlibs(L);
  luaL_loadbuffer(L, thread_lua, strlen(thread_lua), "=[ljuv thread]");
  lua_call(L, 0, 0);
  // end
  uv_mutex_lock(&thread->mutex);
  thread->running = false;
  uv_mutex_unlock(&thread->mutex);
}

// Create thread.
// return NULL on failure
ljuv_thread* thread_create(const char *data, size_t size)
{
  ljuv_thread *thread = malloc(sizeof(ljuv_thread));
  if(!thread) return NULL;
  // init mutex
  if(uv_mutex_init(&thread->mutex) < 0){ free(thread); return NULL; }
  // setup Lua state
  lua_State *L = luaL_newstate();
  if(!L){ uv_mutex_destroy(&thread->mutex); free(thread); return NULL; }
  thread->L = L;
  thread->running = true;
  lua_pushlstring(L, data, size);
  lua_setglobal(L, "ljuv_data");
  // run
  if(uv_thread_create(&thread->handle, thread_run, thread) != 0){
    lua_close(L);
    uv_mutex_destroy(&thread->mutex);
    free(thread);
    return NULL;
  }
  return thread;
}

// Check if the thread is running.
bool thread_running(ljuv_thread *thread)
{
  uv_mutex_lock(&thread->mutex);
  bool running = thread->running;
  uv_mutex_unlock(&thread->mutex);
  return running;
}

// Join thread.
// return true on success
//
// On success, thread data are released and data/size are filled.
// The data pointer, if not NULL, must be freed with free().
bool thread_join(ljuv_thread *thread, char **data, size_t *size)
{
  if(uv_thread_join(&thread->handle) == 0){
    lua_getglobal(thread->L, "ljuv_data");
    const char* data_ptr = lua_tolstring(thread->L, -1, size);
    *data = NULL;
    if(data_ptr && *size > 0){
      *data = malloc(*size);
      if(*data) memcpy(*data, data_ptr, *size);
    }
    lua_close(thread->L);
    uv_mutex_destroy(&thread->mutex);
    free(thread);
    return true;
  }
  else return false;
}

// Wrapper (expose functions)

typedef struct ljuv_wrapper{
  void (*free)(void *data);
  void (*object_retain)(ljuv_object *obj);
  void (*object_release)(ljuv_object *obj);
  ljuv_shared_flag* (*shared_flag_create)(int flag);
  int (*shared_flag_get)(ljuv_shared_flag *self);
  void (*shared_flag_set)(ljuv_shared_flag *self, int flag);
  ljuv_channel* (*channel_create)(void);
  bool (*channel_push)(ljuv_channel *channel, const uint8_t *data, size_t size);
  uint8_t* (*channel_pull)(ljuv_channel *channel, size_t *size);
  uint8_t* (*channel_try_pull)(ljuv_channel *channel, size_t *size);
  size_t (*channel_count)(ljuv_channel *channel);
  ljuv_thread* (*thread_create)(const char *data, size_t size);
  bool (*thread_running)(ljuv_thread *thread);
  bool (*thread_join)(ljuv_thread *thread, char **data, size_t *size);
} ljuv_wrapper;

static ljuv_wrapper wrapper = {
  free,
  object_retain,
  object_release,
  shared_flag_create,
  shared_flag_get,
  shared_flag_set,
  channel_create,
  channel_push,
  channel_pull,
  channel_try_pull,
  channel_count,
  thread_create,
  thread_running,
  thread_join
};

int luaopen_ljuv_wrapper_c(lua_State *L)
{
  lua_pushlightuserdata(L, &wrapper);
  return 1;
}
