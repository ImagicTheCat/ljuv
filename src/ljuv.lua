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
ffi.cdef[[
void* malloc(size_t);
void free(void*);
]]

local C = ffi.C
local L = require("ljuv.libuv")
local wrapper = require("ljuv.wrapper")

-- Shallow table cloning.
local function clone(t)
  local nt = {}; for k,v in pairs(t) do nt[k] = v end; return nt
end

-- Lazy main loop creation.
local ljuv_mt = {__index = function(self, k)
  if k == "loop" then
    self.loop = self.newLoop()
    return self.loop
  end
end}
local ljuv = setmetatable({}, ljuv_mt)

local function uv_assert(code)
  if code < 0 then error(ffi.string(libuv.uv_strerror(code)), 2) end
end

-- Cdata to Lua reference mapping.
local refmap = {}

local ptr_s = ffi.new("struct{ void *ptr; }")
-- Convert cdata pointer to keyable value.
local function refkey(cdata)
  local key = ffi.cast("uintptr_t", cdata)
  if key <= 2^53LL then return tonumber(key) -- number key
  else -- fallback to string key
    ptr_s.ptr = cdata
    return ffi.string(ptr_s, ffi.sizeof(ptr_s))
  end
end

local Loop = {}
local Loop_mt = {__index = Loop}

function ljuv.newLoop()
  local handle = ffi.cast("uv_loop_t*", C.malloc(L.uv_loop_size()))
  assert(handle ~= nil, "allocation failed")
  ffi.gc(handle, function(handle)
    -- Close all handles and free uv loop.
    local loop = refmap[refkey(handle)]
    for handle in pairs(loop.handles) do handle:close() end
    loop:run()
    uv_assert(L.uv_loop_close(handle))
    refmap[refkey(handle)] = nil
    C.free(handle)
  end)
  -- init
  uv_assert(L.uv_loop_init(handle))
  local loop = setmetatable({handle = handle, handles = {}, errors = {}}, Loop_mt)
  refmap[refkey(handle)] = loop
  return loop
end

function Loop:run(mode)
  mode = mode or "default"
  if mode == "default" then mode = L.UV_RUN_DEFAULT
  elseif mode == "once" then mode = L.UV_RUN_ONCE
  elseif mode == "nowait" then mode = L.UV_RUN_NOWAIT
  else error("invalid mode \""..mode.."\"") end
  -- propagate deferred errors (before iteration)
  if #self.errors > 0 then error(table.remove(self.errors, 1), 0) end
  -- run
  local status = L.uv_run(self.handle, mode)
  uv_assert(status)
  -- propagate deferred errors (after iteration)
  if #self.errors > 0 then error(table.remove(self.errors, 1), 0) end
  return status > 0
end
jit.off(Loop.run)

function Loop:alive() return L.uv_loop_alive(self.handle) > 0 end
function Loop:stop() L.uv_stop(self.handle) end
function Loop:now() return tonumber(L.uv_now(self.handle))*1e-3 end
function Loop:update_time() L.uv_update_time(self.handle) end

local Handle = {}
local Handle_mt = {__index = Handle}

local handle_close_cb = ffi.cast("uv_close_cb", C.free)

local function check_handle(self)
  assert(not self.closed, "attempt to use a closed handle")
end

function Handle:is_active()
  check_handle(self)
  return L.uv_is_active(self.handle) > 0
end
function Handle:is_closing()
  check_handle(self)
  return L.uv_is_closing(self.handle) > 0
end
function Handle:get_loop()
  check_handle(self)
  return refmap[refkey(L.uv_handle_get_loop(self.handle))]
end
function Handle:get_type()
  check_handle(self)
  return ffi.string(L.uv_handle_type_name(L.uv_handle_get_type(self.handle)))
end
-- (idempotent)
function Handle:close()
  if self.closed then return end
  local loop = self:get_loop()
  if loop then loop.handles[self] = nil end
  L.uv_close(self.handle, handle_close_cb)
  self.closed = true
end

-- Create constructor function for a specific handle type.
local function handle_constructor(enum_type, ptype, metatable, init_func)
  return function(loop)
    local handle = ffi.cast(ptype, C.malloc(L.uv_handle_size(L[enum_type])))
    assert(handle ~= nil, "allocation failed")
    ffi.gc(handle, function(handle)
      local obj = refmap[refkey(handle)]
      obj:close()
      refmap[refkey(handle)] = nil
    end)
    uv_assert(L[init_func](loop.handle, handle))
    local obj = setmetatable({terminal = handle}, metatable)
    obj.handle = ffi.cast("uv_handle_t*", handle)
    refmap[refkey(handle)] = obj
    loop.handles[obj] = true
    return obj
  end
end

local Timer = clone(Handle)
local Timer_mt = {__index = Timer}

-- Timer callback handling.
-- Defers error propagation to loop:run() with loop:stop().
local last_traceback
local function timer_error_handler(err)
  last_traceback = debug.traceback(err, 2)
end
local timer_cb = ffi.cast("uv_timer_cb", function(handle)
  local timer = refmap[refkey(handle)]
  local ok = xpcall(timer.callback, timer_error_handler, timer)
  if not ok then
    -- Even if the callback called timer:close(), the memory is valid until the
    -- the next loop iteration.
    local loop = refmap[refkey(L.uv_handle_get_loop(timer.handle))]
    table.insert(loop.errors, last_traceback)
    loop:stop()
  end
end)

function Timer:start(timeout, t_repeat, callback)
  check_handle(self)
  timeout = math.floor(timeout*1e3+0.5)
  if t_repeat > 0 then t_repeat = math.max(1, math.floor(t_repeat*1e3+0.5)) end
  self.callback = callback
  uv_assert(L.uv_timer_start(self.terminal, timer_cb, timeout, t_repeat))
end
function Timer:stop()
  check_handle(self)
  uv_assert(L.uv_timer_stop(self.terminal))
end
function Timer:again()
  check_handle(self)
  uv_assert(L.uv_timer_again(self.terminal))
end
function Timer:set_repeat(t_repeat)
  check_handle(self)
  if t_repeat > 0 then t_repeat = math.max(1, math.floor(t_repeat*1e3+0.5)) end
  uv_assert(L.uv_timer_set_repeat(self.terminal, t_repeat))
end
function Timer:get_repeat()
  check_handle(self)
  return tonumber(L.uv_timer_get_repeat(self.terminal))*1e-3
end
function Timer:get_due_in()
  check_handle(self)
  return tonumber(L.uv_timer_get_due_in(self.terminal))*1e-3
end

Loop.timer = handle_constructor("UV_TIMER", "uv_timer_t*", Timer_mt, "uv_timer_init")

return ljuv
