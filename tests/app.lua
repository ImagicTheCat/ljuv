-- Test simple application.
package.path = "src/?.lua;"..package.path

local ljuv = require("ljuv")

local pool = ljuv.loop:threadpool(2, function(init)
  assert(init == 42)
  local function fib(n) return n < 2 and n or fib(n-2)+fib(n-1) end
  return {fib = fib, __exit = function() print("interface exit") end}
end, 42)

-- Do some work.
local exited = false
coroutine.resume(coroutine.create(function()
  assert(pool.interface.fib(9) == 34)
  assert(pool.interface.fib(20) == 6765)
  assert(pool.interface.fib(30) == 832040)
  pool:close()
  exited = true
end))

ljuv.loop:run()
assert(exited)
