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
void ljuv_object_retain(ljuv_object *obj)
{
  uv_mutex_lock(&obj->mutex);
  obj->count++;
  uv_mutex_unlock(&obj->mutex);
}
void ljuv_object_release(ljuv_object *obj)
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
ljuv_shared_flag* ljuv_shared_flag_create(int flag)
{
  // object
  ljuv_shared_flag *shared_flag = malloc(sizeof(ljuv_shared_flag));
  if(!shared_flag) return NULL;
  int status = object_init((ljuv_object*)shared_flag, NULL);
  if(status < 0){ free(shared_flag); return NULL; }
  shared_flag->flag = flag;
  return shared_flag;
}
void ljuv_shared_flag_set(ljuv_shared_flag *self, int flag)
{
  object_lock((ljuv_object*)self);
  self->flag = flag;
  object_unlock((ljuv_object*)self);
}
int ljuv_shared_flag_get(ljuv_shared_flag *self)
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
ljuv_channel* ljuv_channel_create(void)
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
bool ljuv_channel_push(ljuv_channel *channel, const uint8_t *data, size_t size)
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
uint8_t* ljuv_channel_pull(ljuv_channel *channel, size_t *size)
{
  // wait
  uv_sem_wait(&channel->semaphore);
  return channel_dequeue(channel, size);
}

// Pull message data (non-blocking).
// Return non-NULL on success; the returned data must be freed with free().
uint8_t* ljuv_channel_try_pull(ljuv_channel *channel, size_t *size)
{
  // wait
  if(uv_sem_trywait(&channel->semaphore) == 0)
    return channel_dequeue(channel, size);
  else return NULL;
}

// Count the number of pending messages.
size_t ljuv_channel_count(ljuv_channel *channel)
{
  object_lock((ljuv_object*)channel);
  size_t count = channel->count;
  object_unlock((ljuv_object*)channel);
  return count;
}

// Thread

typedef struct ljuv_thread{
  uv_thread_t handle;
  lua_State *L;
  char *data;
  size_t data_size;
} ljuv_thread;

// Thread entry function.
void thread_run(void *arg)
{
  ljuv_thread *thread = arg;
  lua_State *L = thread->L;
  // init
  luaL_openlibs(L);
  // execute main
  lua_getglobal(thread->L, "ljuv_main");
  size_t main_size = 0;
  const char* main_ptr = lua_tolstring(thread->L, -1, &main_size);
  if(main_ptr){
    luaL_loadbuffer(L, main_ptr, main_size, "=[ljuv thread]");
    lua_call(L, 0, 0);
  }
  else
    luaL_error(L, "%s", "missing \"ljuv_main\" global");
}

// Create thread.
// return NULL on failure
ljuv_thread* ljuv_thread_create(const char *main, size_t main_size, const char *data, size_t size)
{
  ljuv_thread *thread = malloc(sizeof(ljuv_thread));
  if(!thread) return NULL;
  thread->data = NULL;
  thread->data_size = 0;
  // setup Lua state
  lua_State *L = luaL_newstate();
  if(!L){ free(thread); return NULL; }
  thread->L = L;
  // setup main and data globals
  lua_pushlstring(L, main, main_size);
  lua_setglobal(L, "ljuv_main");
  lua_pushlstring(L, data, size);
  lua_setglobal(L, "ljuv_data");
  // run
  if(uv_thread_create(&thread->handle, thread_run, thread) != 0){
    // release on failure
    lua_close(L);
    free(thread);
    return NULL;
  }
  return thread;
}

// Join thread.
// return true on success
//
// On success, thread data are released and data/size are filled.
// The data pointer, if not NULL, must be freed with free().
bool ljuv_thread_join(ljuv_thread *thread, char **data, size_t *size)
{
  if(uv_thread_join(&thread->handle) == 0){
    // process returned data
    lua_getglobal(thread->L, "ljuv_data");
    *size = 0;
    const char* data_ptr = lua_tolstring(thread->L, -1, size);
    if(data_ptr && *size > 0){
      // copy
      *data = malloc(*size);
      if(*data) memcpy(*data, data_ptr, *size);
    }
    // end thread state
    lua_close(thread->L);
    free(thread);
    return true;
  }
  else return false;
}

void ljuv_free(void *ptr){ free(ptr); }
