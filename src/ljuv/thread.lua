-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)

local ffi = require("ffi")
local buffer = require("string.buffer")
local api = require("ljuv.api")
local wrapper = require("ljuv.wrapper")

local function pack(...) return {n = select("#", ...), ...} end
local function ccheck(self) assert(self, "invalid cdata self") end
local decode_buf = buffer.new()

local M = {}

-- Channel

local Channel = {}
local Channel_mt = {__index = Channel}
local channels_data = setmetatable({}, {__mode = "k"})

local function Channel_gc(self)
  wrapper.object_release(ffi.cast("ljuv_object*", self))
end
function M.new_channel()
  local channel = wrapper.channel_create()
  assert(channel ~= nil, "failed to create channel")
  return ffi.gc(channel, Channel_gc)
end

function Channel:push(...)
  ccheck(self)
  local buf = channels_data[self]
  if not buf then buf = buffer.new(); channels_data[self] = buf end
  buf:reset()
  buf:encode(pack(...))
  assert(wrapper.channel_push(self, buf:ref()), "failed to allocate channel data")
end

function Channel:pull()
  ccheck(self)
  local size = ffi.new("size_t[1]")
  local ptr = wrapper.channel_pull(self, size)
  decode_buf:set(ptr, size[0])
  local data = decode_buf:decode()
  wrapper.free(ptr)
  return unpack(data, 1, data.n)
end
function Channel:try_pull()
  ccheck(self)
  local size = ffi.new("size_t[1]")
  local ptr = wrapper.channel_try_pull(self, size)
  if ptr ~= nil then
    decode_buf:set(ptr, size[0])
    local data = decode_buf:decode()
    wrapper.free(ptr)
    return true, unpack(data, 1, data.n)
  end
  return false
end

function Channel:count() ccheck(self); return tonumber(wrapper.channel_count(self)) end

ffi.metatype("ljuv_channel", Channel_mt)

-- Thread

local Thread = {}
local Thread_mt = {__index = Thread}
local threads_data = setmetatable({}, {__mode = "k"})

function M.new_thread(func, ...)
  func = string.dump(func)
  local data = buffer.encode({
    path = package.path, cpath = package.cpath,
    func = func, args = pack(...)
  })
  local thread = wrapper.thread_create(data, #data)
  assert(thread ~= nil, "failed to create thread")
  threads_data[thread] = true -- mark active
  return thread
end

function Thread:join()
  local size = ffi.new("size_t[1]")
  local data = ffi.new("char*[1]")
  assert(threads_data[self], "thread already joined")
  assert(wrapper.thread_join(self, data, size), "failed to join thread")
  assert(data[0] ~= nil, "missing thread join data")
  local str = ffi.string(data[0], size[0])
  wrapper.free(data[0])
  threads_data[self] = nil -- mark joined/released
  local ldata = buffer.decode(str)
  return unpack(ldata, 1, ldata.n)
end

ffi.metatype("ljuv_thread", Thread_mt)

return M
