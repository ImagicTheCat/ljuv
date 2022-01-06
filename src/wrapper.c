// https://github.com/ImagicTheCat/ljuv
// MIT license (see LICENSE or src/ljuv.lua)

#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>
#include <uv.h>

// Object reference counting.

typedef struct ljuv_object{
  uint32_t count;
  void (*destructor)(struct ljuv_object *obj);
  uv_mutex_t mutex;
} ljuv_object;

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
    free(obj);
  }
}

// Channel



// Expose wrapper functions.

typedef struct ljuv_wrapper{
  int (*object_init)(ljuv_object *obj, void (*destructor)(ljuv_object *obj));
  void (*object_retain)(ljuv_object *obj);
  void (*object_release)(ljuv_object *obj);
} ljuv_wrapper;

static ljuv_wrapper wrapper = {
  object_init,
  object_retain,
  object_release
};

int luaopen_ljuv_wrapper_c(lua_State *L)
{
  lua_pushlightuserdata(L, &wrapper);
  return 1;
}
