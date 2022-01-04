// https://github.com/ImagicTheCat/ljuv
// MIT license (see LICENSE or src/ljuv.lua)

#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>
#include <uv.h>

typedef struct ljuv_wrapper{
  int non_empty;
} ljuv_wrapper;

static ljuv_wrapper wrapper;

int luaopen_ljuv_wrapper_c(lua_State *L)
{
  lua_pushlightuserdata(L, &wrapper);
  return 1;
}
