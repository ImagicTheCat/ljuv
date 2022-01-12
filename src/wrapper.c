// https://github.com/ImagicTheCat/ljuv
// MIT license (see LICENSE or src/ljuv.lua)

#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
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

// Pull message data (blocks if empty).
// The returned data must be freed with channel_free_data().
uint8_t* channel_pull(ljuv_channel *channel, size_t *size)
{
  // wait
  uv_sem_wait(&channel->semaphore);
  // pop from queue
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

// Count the number of pending messages.
size_t channel_count(ljuv_channel *channel)
{
  object_lock((ljuv_object*)channel);
  size_t count = channel->count;
  object_unlock((ljuv_object*)channel);
  return count;
}
void channel_free_data(uint8_t *data){ free(data); }

// Wrapper (expose functions)

typedef struct ljuv_wrapper{
  void (*object_retain)(ljuv_object *obj);
  void (*object_release)(ljuv_object *obj);
  ljuv_channel* (*channel_create)(void);
  bool (*channel_push)(ljuv_channel *channel, const uint8_t *data, size_t size);
  uint8_t* (*channel_pull)(ljuv_channel *channel, size_t *size);
  size_t (*channel_count)(ljuv_channel *channel);
  void (*channel_free_data)(uint8_t *data);
} ljuv_wrapper;

static ljuv_wrapper wrapper = {
  object_retain,
  object_release,
  channel_create,
  channel_push,
  channel_pull,
  channel_count,
  channel_free_data
};

int luaopen_ljuv_wrapper_c(lua_State *L)
{
  lua_pushlightuserdata(L, &wrapper);
  return 1;
}
