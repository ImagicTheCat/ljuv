-- MIT license (see LICENSE or src/ljuv.lua)
-- Copyright (c) 2022 ImagicTheCat

-- Mid-level abstraction module for multi-threading.

local ffi = require("ffi")
local buffer = require("string.buffer")
local api = require("ljuv.api")
local W = require("ljuv.wrapper")

local function pack(...) return {n = select("#", ...), ...} end
local decode_buf = buffer.new()
local ccheck = api.ccheck

local M = {}

-- Shared flag
-- Set/get a value between threads.

local SharedFlag = {}
local SharedFlag_mt = {__index = SharedFlag}
local shared_flag_t = api.defineHandle("ljuv_shared_flag")

local function SharedFlag_gc(self)
  W.ljuv_object_release(ffi.cast("ljuv_object*", self.handle))
  self.handle = nil
end

-- flag: integer (C int)
-- final_flag: (optional) flag set at finalization (workaround about GC dependencies)
function M.new_shared_flag(flag, final_flag)
  local shared_flag = shared_flag_t(W.ljuv_shared_flag_create(flag))
  assert(shared_flag.handle ~= nil, "failed to create shared flag")
  if final_flag then
    return ffi.gc(shared_flag, function(self)
      W.ljuv_shared_flag_set(self.handle, final_flag)
      SharedFlag_gc(self)
    end)
  else
    return ffi.gc(shared_flag, SharedFlag_gc)
  end
end

-- flag: integer (C int)
function SharedFlag:set(flag) ccheck(self); W.ljuv_shared_flag_set(self.handle, flag) end
function SharedFlag:get() ccheck(self); return W.ljuv_shared_flag_get(self.handle) end

ffi.metatype(shared_flag_t, SharedFlag_mt)

-- Channel

local Channel = {}
local Channel_mt = {__index = Channel}
local channels_data = setmetatable({}, {__mode = "k"})
local channel_t = api.defineHandle("ljuv_channel")

local function Channel_gc(self)
  W.ljuv_object_release(ffi.cast("ljuv_object*", self.handle))
  self.handle = nil
end

function M.new_channel()
  local channel = channel_t(W.ljuv_channel_create())
  assert(channel.handle ~= nil, "failed to create channel")
  return ffi.gc(channel, Channel_gc)
end

-- Push a message.
-- ...: payload arguments
function Channel:push(...)
  ccheck(self)
  -- init buffer
  local buf = channels_data[self]
  if not buf then buf = buffer.new(); channels_data[self] = buf end
  -- encode
  buf:reset()
  buf:encode(pack(...))
  -- push
  assert(W.ljuv_channel_push(self.handle, buf:ref()), "failed to allocate channel data")
end

-- Pull a message (blocking).
-- return payload arguments
function Channel:pull()
  ccheck(self)
  -- pull
  local size = ffi.new("size_t[1]")
  local ptr = W.ljuv_channel_pull(self.handle, size)
  -- decode
  decode_buf:set(ptr, size[0])
  local data = decode_buf:decode()
  W.ljuv_free(ptr)
  return unpack(data, 1, data.n)
end

-- Pull a message (non-blocking).
-- return false or (true, payload arguments...)
function Channel:try_pull()
  ccheck(self)
  -- pull
  local size = ffi.new("size_t[1]")
  local ptr = W.ljuv_channel_try_pull(self.handle, size)
  -- decode
  if ptr ~= nil then
    decode_buf:set(ptr, size[0])
    local data = decode_buf:decode()
    W.ljuv_free(ptr)
    return true, unpack(data, 1, data.n)
  end
  return false
end

-- Count the number of pending messages.
function Channel:count() ccheck(self); return tonumber(W.ljuv_channel_count(self.handle)) end

ffi.metatype(channel_t, Channel_mt)

-- Thread

local Thread = {}
local Thread_mt = {__index = Thread}
local thread_t = api.defineHandle("ljuv_thread")

-- init globals:
--- ljuv_main: main Lua code
--- ljuv_data: passed data from new_thread()
local function thread_main()
  ljuv_main = nil -- remove main code
  require "ffi" -- fix buffer cdata decoding
  local function pack(...) return {n = select('#', ...), ...} end
  local buffer = require "string.buffer"
  local errtrace
  local function error_handler(err) errtrace = debug.traceback(err, 2) end
  -- decode data
  local data = buffer.decode(ljuv_data); ljuv_data = nil
  package.path, package.cpath = data.path, data.cpath
  local ljuv = require "ljuv"
  local async_send = ljuv.import(data.async)
  -- execute
  local ok, data = xpcall(function()
    -- execute entry function
    local func, err = load(data.entry_code)
    assert(func, err)
    local rets = pack(true, func(unpack(data.args, 1, data.args.n)))
    return buffer.encode(rets)
  end, error_handler)
  -- setup return data
  if ok then ljuv_data = data
  else ljuv_data = buffer.encode(pack(false, errtrace)) end
  async_send() -- signal correct thread termination
end
local thread_main_code = string.dump(thread_main)

-- Create thread.
-- The arguments must be encodable by string buffers.
--
-- async: async handle to signal the termination
-- entry_code: thread entry code (plain or bytecode)
-- ...: arguments passed to the function
function M.new_thread(async, entry_code, ...)
  -- encode data
  local data = buffer.encode({
    path = package.path, cpath = package.cpath,
    async = M.export(async),
    entry_code = entry_code, args = pack(...)
  })
  -- create thread
  local thread = thread_t(W.ljuv_thread_create(thread_main_code, #thread_main_code, data, #data))
  assert(thread.handle ~= nil, "failed to create thread")
  return thread
end

-- Join thread.
-- return (false, errtrace) on thread error or (true, return values...)
function Thread:join()
  ccheck(self)
  -- join
  local size = ffi.new("size_t[1]")
  local data = ffi.new("char*[1]")
  assert(W.ljuv_thread_join(self.handle, data, size), "failed to join thread")
  self.handle = nil -- mark released
  assert(data[0] ~= nil, "missing thread join data")
  -- decode return values
  local str = ffi.string(data[0], size[0])
  W.ljuv_free(data[0])
  local ldata = buffer.decode(str)
  return unpack(ldata, 1, ldata.n)
end

ffi.metatype(thread_t, Thread_mt)

-- Export / Import

local EXPORT_KEY = "ljuv-export-a9c0f255c"

-- Export an object to be passed to another thread.
-- The returned payload must be imported exactly once to prevent memory leak
-- and invalid memory accesses.
-- An async handle is imported as a function which safely calls async:send().
--
-- Exportables:
-- - channel
-- - shared flag
-- - async handle
--
-- o: object
-- soft: truthy to not throw errors on invalid object (returns nothing)
-- return a payload encodable by string buffers
function M.export(o, soft)
  local payload
  if ffi.istype(shared_flag_t, o) then
    W.ljuv_object_retain(ffi.cast("ljuv_object*", o.handle))
    payload = {type = "shared_flag", ptr = ffi.cast("uintptr_t", ffi.cast("void*", o.handle))}
  elseif ffi.istype(channel_t, o) then
    W.ljuv_object_retain(ffi.cast("ljuv_object*", o.handle))
    payload = {type = "channel", ptr = ffi.cast("uintptr_t", ffi.cast("void*", o.handle))}
  else payload = M.export_handle(o) end -- defined in ljuv.lua
  -- return payload
  if payload then return {[EXPORT_KEY] = payload} end
  assert(soft, "no defined export for the given object")
end

-- Import an object payload.
-- soft: truthy to not throw errors on invalid payload (returns nothing)
-- return imported object
function M.import(payload, soft)
  if type(payload) == "table" and payload[EXPORT_KEY] then
    payload = payload[EXPORT_KEY]
    if payload.type == "shared_flag" then
      local sflag = shared_flag_t(ffi.cast("ljuv_shared_flag*", ffi.cast("void*", payload.ptr)))
      return ffi.gc(sflag, SharedFlag_gc)
    elseif payload.type == "channel" then
      local channel = channel_t(ffi.cast("ljuv_channel*", ffi.cast("void*", payload.ptr)))
      return ffi.gc(channel, Channel_gc)
    else
      local o = M.import_handle(payload) -- defined in ljuv.lua
      if o then return o end
    end
  end
  assert(soft, "no defined import for the given payload")
end

return M
