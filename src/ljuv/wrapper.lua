-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)
local ffi = require("ffi")

ffi.cdef[[
typedef struct ljuv_wrapper{
  int non_empty;
} ljuv_wrapper;
]]

return ffi.cast("ljuv_wrapper*", require("ljuv.wrapper_c"))[0]
