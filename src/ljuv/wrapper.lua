-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)
local ffi = require("ffi")

ffi.cdef[[
typedef struct ljuv_object ljuv_object;
typedef struct ljuv_shared_flag ljuv_shared_flag;
typedef struct ljuv_channel ljuv_channel;
typedef struct ljuv_thread ljuv_thread;

void ljuv_object_retain(ljuv_object *obj);
void ljuv_object_release(ljuv_object *obj);
ljuv_shared_flag* ljuv_shared_flag_create(int flag);
void ljuv_shared_flag_set(ljuv_shared_flag *self, int flag);
int ljuv_shared_flag_get(ljuv_shared_flag *self);
ljuv_channel* ljuv_channel_create(void);
bool ljuv_channel_push(ljuv_channel *channel, const uint8_t *data, size_t size);
uint8_t* ljuv_channel_pull(ljuv_channel *channel, size_t *size);
uint8_t* ljuv_channel_try_pull(ljuv_channel *channel, size_t *size);
size_t ljuv_channel_count(ljuv_channel *channel);
ljuv_thread* ljuv_thread_create(const char *data, size_t size);
bool ljuv_thread_running(ljuv_thread *thread);
bool ljuv_thread_join(ljuv_thread *thread, char **data, size_t *size);
void ljuv_free(void *ptr);
]]

return ffi.load(package.searchpath("ljuv.wrapper_c", package.cpath))
