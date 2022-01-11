-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)

local ffi = require("ffi")
local buffer = require("string.buffer")
local api = require("ljuv.api")
local wrapper = require("ljuv.wrapper")

local function ccheck(self) assert(self, "invalid cdata self") end

local M = {}

local Channel = {}
local Channel_mt = {__index = Channel}
local channels_data = setmetatable({}, {__mode = "k"})

local function Channel_gc(self)
  wrapper.object_release(ffi.cast("ljuv_object*", self))
end
function M.new_channel()
  return ffi.gc(wrapper.channel_create(), Channel_gc)
end

function Channel:push(...)
  ccheck(self)
  local buf = channels_data[self]
  if not buf then buf = buffer.new(); channels_data[self] = buf end
  buf:reset()
  buf:encode({n = select("#", ...), ...})
  wrapper.channel_push(self, buf:ref())
end

local decode_buf = buffer.new()
function Channel:pull()
  ccheck(self)
  local size = ffi.new("size_t[1]")
  local ptr = wrapper.channel_pull(self, size)
  decode_buf:set(ptr, size[0])
  local data = decode_buf:decode()
  wrapper.channel_free_data(ptr)
  return unpack(data, 1, data.n)
end

function Channel:count() ccheck(self); return tonumber(wrapper.channel_count(self)) end

ffi.metatype("ljuv_channel", Channel_mt)

return M
