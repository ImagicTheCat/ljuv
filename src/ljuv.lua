-- https://github.com/ImagicTheCat/ljuv
-- MIT license (see LICENSE or src/ljuv.lua)
--[[
MIT License

Copyright (c) 2021 ImagicTheCat

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local ffi = require("ffi")

local api = require("ljuv.api")
local thread = require("ljuv.thread")
local L = require("ljuv.libuv")
local C = ffi.C
local uv_assert, refkey = api.assert, api.refkey

local function ccheck(self) assert(self, "invalid cdata self") end

-- Lazy main loop creation.
local ljuv_mt = {__index = function(self, k)
  if k == "loop" then
    self.loop = self.new_loop()
    return self.loop
  end
end}
local ljuv = setmetatable({}, ljuv_mt)

ljuv.assert = uv_assert
ljuv.new_shared_flag = thread.new_shared_flag
ljuv.new_channel = thread.new_channel
ljuv.new_thread = thread.new_thread
ljuv.import, ljuv.export = thread.import, thread.export

-- Loop

local Loop = {}
local Loop_mt = {__index = Loop}
local loops_refmap = setmetatable({}, {__mode = "v"})
local loops_data = setmetatable({}, {__mode = "k"})
local handles_refmap = {}
local handles_data = {}

local loop_walk_cb = ffi.cast("uv_walk_cb", function(handle)
  handle = handles_refmap[refkey(handle)]
  if handle then handle:close() end
end)

local function Loop_gc(self)
  -- Close all handles and free uv loop.
  L.uv_walk(self, loop_walk_cb, nil)
  uv_assert(L.uv_run(self, L.UV_RUN_DEFAULT))
  uv_assert(L.uv_loop_close(self))
  C.free(self)
end

function ljuv.new_loop()
  local loop = ffi.cast("uv_loop_t*", C.malloc(L.uv_loop_size()))
  assert(loop ~= nil, "allocation failed")
  ffi.gc(loop, Loop_gc)
  -- init
  uv_assert(L.uv_loop_init(loop))
  loops_refmap[refkey(loop)] = loop
  loops_data[loop] = {errors = {}}
  return loop
end

-- mode: (optional) "default", "once", "nowait"
function Loop:run(mode)
  ccheck(self)
  mode = mode or "default"
  if mode == "default" then mode = L.UV_RUN_DEFAULT
  elseif mode == "once" then mode = L.UV_RUN_ONCE
  elseif mode == "nowait" then mode = L.UV_RUN_NOWAIT
  else error("invalid mode \""..mode.."\"") end
  local data = loops_data[self]
  -- propagate deferred errors (before iteration)
  if #data.errors > 0 then error(table.remove(data.errors, 1), 0) end
  -- run
  local status = L.uv_run(self, mode)
  uv_assert(status)
  -- propagate deferred errors (after iteration)
  if #data.errors > 0 then error(table.remove(data.errors, 1), 0) end
  return status > 0
end
jit.off(Loop.run)

function Loop:alive() ccheck(self); return L.uv_loop_alive(self) > 0 end
function Loop:stop() ccheck(self); L.uv_stop(self) end
function Loop:now() ccheck(self); return tonumber(L.uv_now(self))*1e-3 end
function Loop:update_time() ccheck(self); L.uv_update_time(self) end

ffi.metatype("uv_loop_t", Loop_mt)

-- Handle

local Handle = {}
local handle_close_cb = ffi.cast("uv_close_cb", C.free)
local uv_handle_t = ffi.typeof("uv_handle_t*")

local function check_handle(self)
  assert(handles_data[self], "attempt to use an invalid/closed handle")
end
local function cast_handle(self) return ffi.cast(uv_handle_t, self) end

function Handle:is_active()
  check_handle(self)
  return L.uv_is_active(cast_handle(self)) > 0
end
function Handle:is_closing()
  check_handle(self)
  return L.uv_is_closing(cast_handle(self)) > 0
end
function Handle:get_loop()
  check_handle(self)
  return loops_refmap[refkey(L.uv_handle_get_loop(cast_handle(self)))]
end
function Handle:get_type()
  check_handle(self)
  return ffi.string(L.uv_handle_type_name(L.uv_handle_get_type(cast_handle(self))))
end
-- (idempotent)
function Handle:close()
  if not handles_data[self] then return end
  handles_refmap[refkey(self)], handles_data[self] = nil, nil
  L.uv_close(cast_handle(self), handle_close_cb)
end

-- Create constructor function for a specific handle type.
local function handle_constructor(enum_type, handle_type, metatable, init_func)
  ffi.metatype(handle_type, metatable)
  local ptype = ffi.typeof(handle_type.."*")
  -- set init function
  local init
  if type(init_func) == "string" then -- basic passthrough
    init = function(...) uv_assert(L[init_func](...)) end
  else init = init_func end -- custom init function
  -- generate constructor
  return function(loop, ...)
    local handle = ffi.cast(ptype, C.malloc(L.uv_handle_size(L[enum_type])))
    assert(handle ~= nil, "allocation failed")
    handles_refmap[refkey(handle)] = handle
    handles_data[handle] = {}
    init(loop, handle, ...)
    return handle
  end
end

-- Loop callback handling.
-- Defers error propagation to loop:run() by using loop:stop().
local last_traceback
local function callback_error_handler(err)
  last_traceback = debug.traceback(err, 2)
end
local function handle_callback(raw_handle, ...)
  local handle = handles_refmap[refkey(raw_handle)]
  local data = handles_data[handle]
  if data and data.callback then
    local ok = xpcall(data.callback, callback_error_handler, handle, ...)
    if not ok then
      -- Even if the callback called handle:close(), the memory is valid until the
      -- the next loop iteration.
      local loop = loops_refmap[refkey(L.uv_handle_get_loop(cast_handle(handle)))]
      table.insert(loops_data[loop].errors, last_traceback)
      loop:stop()
    end
  end
end

-- Timer

local Timer = api.clone(Handle)
local Timer_mt = {__index = Timer}
local timer_cb = ffi.cast("uv_timer_cb", handle_callback)

function Timer:start(timeout, t_repeat, callback)
  check_handle(self)
  timeout = math.floor(timeout*1e3+0.5)
  if t_repeat > 0 then t_repeat = math.max(1, math.floor(t_repeat*1e3+0.5)) end
  handles_data[self].callback = callback
  uv_assert(L.uv_timer_start(self, timer_cb, timeout, t_repeat))
end
function Timer:stop()
  check_handle(self)
  uv_assert(L.uv_timer_stop(self))
end
function Timer:again()
  check_handle(self)
  uv_assert(L.uv_timer_again(self))
end
function Timer:set_repeat(t_repeat)
  check_handle(self)
  if t_repeat > 0 then t_repeat = math.max(1, math.floor(t_repeat*1e3+0.5)) end
  uv_assert(L.uv_timer_set_repeat(self, t_repeat))
end
function Timer:get_repeat()
  check_handle(self)
  return tonumber(L.uv_timer_get_repeat(self))*1e-3
end
function Timer:get_due_in()
  check_handle(self)
  return tonumber(L.uv_timer_get_due_in(self))*1e-3
end

Loop.timer = handle_constructor("UV_TIMER", "uv_timer_t", Timer_mt, "uv_timer_init")

-- Async

local Async = api.clone(Handle)
local Async_mt = {__index = Async}
local async_cb = ffi.cast("uv_async_cb", handle_callback)

function Async:send()
  check_handle(self)
  uv_assert(L.uv_async_send(self))
end

-- override
function Async:close()
  local data = handles_data[self]
  if data then data.sflag:set(0) end -- mark invalid
  Handle.close(self)
end

Loop.async = handle_constructor("UV_ASYNC", "uv_async_t", Async_mt,
  function(loop, handle, callback)
    local data = handles_data[handle]
    data.callback = callback
    data.sflag = ljuv.new_shared_flag(1)
    uv_assert(L.uv_async_init(loop, handle, async_cb))
  end
)

-- Signal

local Signal = api.clone(Handle)
local Signal_mt = {__index = Signal}
local signal_cb = ffi.cast("uv_signal_cb", handle_callback)

function Signal:start(signum, callback)
  check_handle(self)
  handles_data[self].callback = callback
  uv_assert(L.uv_signal_start(self, signal_cb, signum))
end
function Signal:start_oneshot(signum, callback)
  check_handle(self)
  handles_data[self].callback = callback
  uv_assert(L.uv_signal_start_oneshot(self, signal_cb, signum))
end
function Signal:stop()
  check_handle(self)
  uv_assert(L.uv_signal_stop(self))
end

Loop.signal = handle_constructor("UV_SIGNAL", "uv_signal_t", Signal_mt, "uv_signal_init")

-- Export / Import for handles

function thread.export_handle(o)
  if ffi.istype("uv_async_t*", o) then
    check_handle(o)
    return {
      type = "async",
      ptr = ffi.cast("uintptr_t", ffi.cast("void*", o)),
      sflag = ljuv.export(handles_data[o].sflag)
    }
  end
end

function thread.import_handle(payload)
  if payload.type == "async" then
    -- Return a function which checks the validity of the async handle before
    -- using uv_async_send().
    local sflag = ljuv.import(payload.sflag)
    local async = ffi.cast("uv_async_t*", ffi.cast("void*", payload.ptr))
    return function()
      assert(sflag:get() == 1, "async handle is invalid/closed")
      L.uv_async_send(async)
    end
  end
end

return ljuv
