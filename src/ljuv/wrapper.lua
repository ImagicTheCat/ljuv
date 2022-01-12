-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)
local ffi = require("ffi")

ffi.cdef[[
typedef struct ljuv_object ljuv_object;
typedef struct ljuv_channel ljuv_channel;

typedef struct ljuv_wrapper{
  void (*object_retain)(ljuv_object *obj);
  void (*object_release)(ljuv_object *obj);
  ljuv_channel* (*channel_create)(void);
  bool (*channel_push)(ljuv_channel *channel, const uint8_t *data, size_t size);
  uint8_t* (*channel_pull)(ljuv_channel *channel, size_t *size);
  uint8_t* (*channel_try_pull)(ljuv_channel *channel, size_t *size);
  size_t (*channel_count)(ljuv_channel *channel);
  void (*channel_free_data)(uint8_t *data);
} ljuv_wrapper;
]]

return ffi.cast("ljuv_wrapper*", require("ljuv.wrapper_c"))[0]
