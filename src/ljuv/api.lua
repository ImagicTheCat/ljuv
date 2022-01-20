-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)

-- API helper

local ffi = require("ffi")
ffi.cdef[[
void* malloc(size_t);
void free(void*);
]]
local libuv = require("ljuv.libuv")

local M = {}

-- uv assert
function M.assert(code)
  if code < 0 then error(ffi.string(libuv.uv_strerror(code)), 2) end
end

local ptr_s = ffi.new("struct{ void *ptr; }")
-- Convert cdata pointer to keyable value (type independent, address only).
function M.refkey(cdata)
  local key = ffi.cast("uintptr_t", cdata)
  if key <= 2^53LL then return tonumber(key) -- number key
  else -- fallback to string key
    ptr_s.ptr = cdata
    return ffi.string(ptr_s, ffi.sizeof(ptr_s))
  end
end

-- Shallow table cloning.
function M.clone(t)
  local nt = {}; for k,v in pairs(t) do nt[k] = v end; return nt
end

-- Define handle struct "<ptr_type>_h" with handle pointer.
-- return ctype
function M.defineHandle(ptr_type)
  ffi.cdef("typedef struct ${ $ *handle; } $;", ptr_type.."_h", ffi.typeof(ptr_type), ptr_type.."h")
  return ffi.typeof(ptr_type.."h")
end

return M
