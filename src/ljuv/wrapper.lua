-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)
local ffi = require("ffi")

ffi.cdef[[
typedef struct ljuv_object ljuv_object;
typedef struct ljuv_shared_flag ljuv_shared_flag;
typedef struct ljuv_channel ljuv_channel;
typedef struct ljuv_thread ljuv_thread;

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
]]

return ffi.cast("ljuv_wrapper*", require("ljuv.wrapper_c"))[0]
