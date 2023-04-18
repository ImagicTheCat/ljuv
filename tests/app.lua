-- Test simple application.
package.path = "src/?.lua;"..package.path

local ljuv = require("ljuv")

local pool = ljuv.loop:threadpool(2, function()
  local function fib(n) return n < 2 and n or fib(n-2)+fib(n-1) end
  return {fib = fib}
end)

-- Do some work.
coroutine.resume(coroutine.create(function()
  assert(pool.interface.fib(9) == 34)
  assert(pool.interface.fib(20) == 6765)
  assert(pool.interface.fib(30) == 832040)
  pool:close()
end))

ljuv.loop:run()
assert(pool.closed)
