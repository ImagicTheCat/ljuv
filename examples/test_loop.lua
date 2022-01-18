-- Test loop and handles.
package.path = "src/?.lua;"..package.path

local ljuv = require("ljuv")

do -- Test timer basics.
  local loop = ljuv.new_loop()
  assert(not loop:alive())
  local timer = loop:timer()
  local count = 0
  timer:start(1e-3, 0, function(timer) count = count+1 end)
  assert(timer:is_active())
  loop:run()
  assert(not timer:is_active())
  assert(count == 1)
  timer:start(1e-3, 1e-3, function(timer) count = count+1 end)
  assert(timer:is_active())
  loop:run("once")
  assert(timer:is_active())
  assert(count == 2)
  -- interruption
  timer:start(1e-3, 1e-3, function(timer) timer:stop() end)
  loop:run()
  timer:start(1e-3, 1e-3, function(timer) timer:get_loop():stop() end)
  loop:run()
  timer:start(1e-3, 1e-3, function(timer) timer:close() end)
  loop:run()
end
do -- Test async and cdata identity.
  local loop = ljuv.new_loop()
  local t = {}
  local async = loop:async(function(async) t[async] = true; async:close() end)
  async:send()
  loop:run()
  assert(t[async])
end
do -- Test async export.
  local loop = ljuv.new_loop()
  local async = loop:async(function(async) ok = true; async:close() end)
  local async_send = ljuv.import(ljuv.export(async))
  async_send()
  loop:run()
end
