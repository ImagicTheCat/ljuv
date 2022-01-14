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

-- Shared flag

local SharedFlag = {}
local SharedFlag_mt = {__index = SharedFlag}

local function SharedFlag_gc(self)
  wrapper.object_release(ffi.cast("ljuv_object*", self))
end
function M.new_shared_flag(flag)
  local shared_flag = wrapper.shared_flag_create(flag)
  assert(shared_flag ~= nil, "failed to create shared flag")
  return ffi.gc(shared_flag, SharedFlag_gc)
end
function SharedFlag:set(flag) ccheck(self); wrapper.shared_flag_set(self, flag) end
function SharedFlag:get() ccheck(self); return wrapper.shared_flag_get(self) end

ffi.metatype("ljuv_shared_flag", SharedFlag_mt)

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

-- Create thread.
-- The arguments must be encodable by string buffers
-- It will try to export each argument first, i.e. it's possible to pass a
-- channel without manual calls to export/import.
--
-- func: thread entry, a Lua function or a string of Lua code/bytecode
-- ...: arguments passed to the function
function M.new_thread(func, ...)
  func = type(func) == "string" and func or string.dump(func)
  -- try to export arguments
  local args = pack(...)
  for i, arg in ipairs(args) do args[i] = M.export(arg, true) or arg end
  -- encode data
  local data = buffer.encode({
    path = package.path, cpath = package.cpath,
    func = func, args = args
  })
  -- create thread
  local thread = wrapper.thread_create(data, #data)
  assert(thread ~= nil, "failed to create thread")
  threads_data[thread] = true -- mark active
  return thread
end
function Thread:running()
  if not threads_data[self] then return false end
  return wrapper.thread_running(self)
end
function Thread:join()
  local size = ffi.new("size_t[1]")
  local data = ffi.new("char*[1]")
  assert(threads_data[self], "thread already joined")
  assert(wrapper.thread_join(self, data, size), "failed to join thread")
  threads_data[self] = nil -- mark joined/released
  assert(data[0] ~= nil, "missing thread join data")
  local str = ffi.string(data[0], size[0])
  wrapper.free(data[0])
  local ldata = buffer.decode(str)
  return unpack(ldata, 1, ldata.n)
end

ffi.metatype("ljuv_thread", Thread_mt)

-- Export / Import

local EXPORT_KEY = "ljuv-export-a9c0f255c"

-- Export an object to be passed to another thread.
-- The returned payload must be imported exactly once to prevent memory leak
-- and invalid memory accesses.
-- An async handle is imported as a function which safely calls async:send().
--
-- o: object
-- soft: truthy to no throw errors on invalid object (returns nothing)
-- return a payload encodable by string buffers
function M.export(o, soft)
  local payload
  if ffi.istype("ljuv_shared_flag*", o) then
    wrapper.object_retain(ffi.cast("ljuv_object*", o))
    payload = {type = "shared_flag", ptr = ffi.cast("uintptr_t", ffi.cast("void*", o))}
  elseif ffi.istype("ljuv_channel*", o) then
    wrapper.object_retain(ffi.cast("ljuv_object*", o))
    payload = {type = "channel", ptr = ffi.cast("uintptr_t", ffi.cast("void*", o))}
  else payload = M.export_handle(o) end -- defined in ljuv.lua
  -- return payload
  if payload then return {[EXPORT_KEY] = payload} end
  assert(soft, "no defined export for the given object")
end

-- Import an object payload.
-- soft: truthy to no throw errors on invalid payload (returns nothing)
-- return imported object
function M.import(payload, soft)
  if type(payload) == "table" and payload[EXPORT_KEY] then
    payload = payload[EXPORT_KEY]
    if payload.type == "shared_flag" then
      local sflag = ffi.cast("ljuv_shared_flag*", ffi.cast("void*", payload.ptr))
      return ffi.gc(sflag, SharedFlag_gc)
    elseif payload.type == "channel" then
      local channel = ffi.cast("ljuv_channel*", ffi.cast("void*", payload.ptr))
      return ffi.gc(channel, Channel_gc)
    else
      local o = M.import_handle(payload) -- defined in ljuv.lua
      if o then return o end
    end
  end
  assert(soft, "no defined import for the given payload")
end

return M
