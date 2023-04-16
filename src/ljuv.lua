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

local ffi = require "ffi"
local api = require "ljuv.api"
local thread = require "ljuv.thread"
local sbuffer = require "string.buffer"
local L = require "ljuv.libuv"
local C = ffi.C
local uv_assert, refkey = api.assert, api.refkey
local ccheck = api.ccheck

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
local loop_t = api.defineHandle("uv_loop_t")
local handles_refmap = {}
local handles_data = {}

local loop_walk_cb = ffi.cast("uv_walk_cb", function(handle)
  handle = handles_refmap[refkey(handle)]
  if handle then handle:close() end
end)

local function Loop_gc(self)
  -- Close all handles and free uv loop.
  L.uv_walk(self.handle, loop_walk_cb, nil)
  uv_assert(L.uv_run(self.handle, L.UV_RUN_DEFAULT))
  uv_assert(L.uv_loop_close(self.handle))
  C.free(self.handle)
  self.handle = nil
end

function ljuv.new_loop()
  local loop = loop_t(ffi.cast("uv_loop_t*", C.malloc(L.uv_loop_size())))
  assert(loop.handle ~= nil, "allocation failed")
  ffi.gc(loop, Loop_gc)
  -- init
  uv_assert(L.uv_loop_init(loop.handle))
  loops_refmap[refkey(loop.handle)] = loop
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
  local status = L.uv_run(self.handle, mode)
  uv_assert(status)
  -- propagate deferred errors (after iteration)
  if #data.errors > 0 then error(table.remove(data.errors, 1), 0) end
  return status > 0
end
jit.off(Loop.run)

function Loop:alive() ccheck(self); return L.uv_loop_alive(self.handle) > 0 end
function Loop:stop() ccheck(self); L.uv_stop(self.handle) end
function Loop:now() ccheck(self); return tonumber(L.uv_now(self.handle))*1e-3 end
function Loop:update_time() ccheck(self); L.uv_update_time(self.handle) end

ffi.metatype(loop_t, Loop_mt)

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
    init(loop.handle, handle, ...)
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
  if data and data.sflag.handle ~= nil then data.sflag:set(0) end -- mark released
  Handle.close(self)
end

Loop.async = handle_constructor("UV_ASYNC", "uv_async_t", Async_mt,
  function(loop_handle, handle, callback)
    local data = handles_data[handle]
    data.callback = callback
    data.sflag = ljuv.new_shared_flag(1, 0)
    uv_assert(L.uv_async_init(loop_handle, handle, async_cb))
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

-- Thread abstraction

-- Create a new system-thread and run a Lua function asynchronously.
--
-- The loop will not synchronously wait on running threads if garbage
-- collected; the application should asynchronously wait on the callback.
--
-- entry: Lua function or code, plain or bytecode
-- callback(ok, ...): called when terminated, common soft error handling interface
--- (false, err_trace): on error
--- (true, ...): on success, where ... are thread return values
-- ...: entry function arguments (must be encodable by string buffers)
function Loop:thread(entry, callback, ...)
  local entry_code = type(entry) == "string" and entry or string.dump(entry)
  local thread_handle
  local async = self:async(function(async)
    async:close()
    callback(thread_handle:join())
  end)
  thread_handle = thread.new_thread(async, entry_code, ...)
end

-- Thread-pool abstraction

-- Entry function of each threadpool thread.
local function threadpool_entry(async, cin, cout, interface_code)
  -- header
  local function pack(...) return {n = select("#", ...), ...} end
  local ljuv = require "ljuv"
  -- inputs
  async_send, cin, cout = ljuv.import(async), ljuv.import(cin), ljuv.import(cout)
  -- load interface
  local interface_loader, err = load(interface_code)
  assert(interface_loader, err)
  local interface = interface_loader()
  -- setup dispatch
  local function dispatch(id, op, ...)
    cout:push(pack(id, true, interface[op](...)))
  end
  local traceback
  local function error_handler(err) traceback = debug.traceback(err, 2) end
  -- task loop
  local msg = cin:pull()
  while msg and msg ~= "exit" do
    local ok = xpcall(dispatch, error_handler, unpack(msg, 1, msg.n))
    if not ok then cout:push(pack(msg[1], false, traceback)) end
    async_send() -- signal new result
    -- next
    msg = cin:pull()
  end
end
local threadpool_entry_bc = string.dump(threadpool_entry)

local threadpool = {}
local threadpool_mt = {__index = threadpool}

local function r_assert(ok, ...)
  if not ok then error(..., 0) else return ... end
end

local function pack(...) return {n = select("#", ...), ...} end

-- Handle the inter-thread communications (result of operations).
function threadpool_tick(self)
  local ok, msg = self.cout:try_pull()
  while ok do
    local id = msg[1]
    local callback = self.tasks[id]
    if type(callback) == "thread" then
      local ok, err = coroutine.resume(callback, unpack(msg, 2, msg.n))
      if not ok then error(debug.traceback(callback, err), 0) end
    else callback(unpack(msg, 2, msg.n)) end
    -- next
    ok, msg = self.cout:try_pull()
  end
end

-- Create a thread pool.
-- thread_count: number of threads in the pool
-- interface_loader: Lua function or code, plain or bytecode, which returns a
--   map of functions (called from worker threads)
function Loop:threadpool(thread_count, interface_loader)
  local interface_code = type(interface_loader) == "string" and
    interface_loader or string.dump(interface_loader)
  -- instantiate
  local o = setmetatable({}, threadpool_mt)
  o.thread_count = thread_count
  o.ids = 0
  o.tasks = {}
  -- build async interface (bind interface call functions)
  o.interface = setmetatable({}, {__index = function(t, k)
    -- build call handler
    local function handler(...)
      local co, main = coroutine.running()
      if not co or main then error("interface call from a non-coroutine thread") end
      o:call(k, co, ...)
      return r_assert(coroutine.yield())
    end
    t[k] = handler; return handler
  end})
  -- create channels and async handle
  o.cin, o.cout = thread.new_channel(), thread.new_channel()
  o.async = self:async(function() threadpool_tick(o) end)
  -- create threads
  local exit_count = 0
  local function thread_callback(ok, err)
    exit_count = exit_count+1
    if exit_count == thread_count then
      -- threadpool termination
      o.async:close()
    end
    -- propagate thread error
    assert(ok, err)
  end
  for i=1, thread_count do
    self:thread(threadpool_entry_bc, thread_callback,
      ljuv.export(o.async), ljuv.export(o.cin), ljuv.export(o.cout), interface_code)
  end
  return o
end

-- Call an operation on the thread pool interface.
-- The callback can be a coroutine (will call coroutine.resume with the same parameters).
--
-- op: key to an operation of the interface
-- callback(ok, ...): called on operation return, common soft error handling interface
--- ...: return values or the error traceback on failure
-- ...: call arguments
function threadpool:call(op, callback, ...)
  assert(not self.closed, "thread pool is closed")
  -- gen id
  self.ids = self.ids+1
  if self.ids >= 2^53 then self.ids = 0 end
  local id = self.ids
  -- send
  self.cin:push(pack(id, op, ...))
  -- setup task: done afterwards to prevent clutter on an eventual push error
  self.tasks[id] = callback
end

-- (idempotent)
-- Close the thread pool (send exit signal to all threads).
--
-- There are no mechanisms to directly wait on the termination of the
-- threadpool, because only the application knows the context of the work it
-- has to do. I.e. this method should be called when all work is done.
function threadpool:close()
  if self.closed then return end
  self.closed = true
  -- send exit signal
  for i=1, self.thread_count do self.cin:push("exit") end
end

return ljuv
