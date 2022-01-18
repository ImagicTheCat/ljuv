-- Test simple application.
package.path = "src/?.lua;"..package.path

local ljuv = require("ljuv")

local channel_in, channel_out = ljuv.new_channel(), ljuv.new_channel()
local tasks = {}
local async = ljuv.loop:async(function()
  local co = table.remove(tasks, 1)
  assert(coroutine.resume(co, channel_out:pull()))
end)

-- Worker thread.
local thread = ljuv.new_thread(function(channel_in, channel_out, async)
  local function fib(n) return n < 2 and n or fib(n-2)+fib(n-1) end
  repeat
    local n = channel_in:pull()
    if n then
      channel_out:push(fib(n))
      async() -- notify
    end
  until not n
end, channel_in, channel_out, async)

-- Thread watcher.
local timer = ljuv.loop:timer()
timer:start(0, 0.1, function() if not thread:running() then ljuv.loop:stop() end end)

local function async_fib(n)
  channel_in:push(n)
  table.insert(tasks, coroutine.running())
  return coroutine.yield()
end

coroutine.resume(coroutine.create(function()
  assert(async_fib(9) == 34)
  assert(async_fib(20) == 6765)
  assert(async_fib(30) == 832040)
  channel_in:push() -- end thread
end))

ljuv.loop:run()

assert(thread:join())
