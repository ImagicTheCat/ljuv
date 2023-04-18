-- Test threading features.
package.path = "src/?.lua;"..package.path

local ljuv = require("ljuv")

do -- Test shared flag.
  local sflag = ljuv.new_shared_flag(5)
  local sflag_bis = ljuv.import(ljuv.export(sflag))
  assert(sflag:get() == 5)
  assert(sflag_bis:get() == 5)
  sflag:set(42)
  assert(sflag_bis:get() == 42)
end
do -- Test channel.
  local channel = ljuv.new_channel()
  local channel_bis = ljuv.import(ljuv.export(channel))
  assert(channel:count() == 0)
  channel:push("a", 1, 0.5)
  assert(channel:count() == 1)
  local a, b, c = channel:pull()
  assert(a == "a" and b == 1 and c == 0.5 and channel:count() == 0)
  assert(not channel:try_pull())
  channel:push(nil)
  channel:push(nil, 1)
  assert(channel_bis:count() == 2)
  local ok, a = channel_bis:try_pull()
  assert(ok and a == nil)
  local ok, a, b = channel_bis:try_pull()
  assert(ok and a == nil and b == 1)
  assert(channel_bis:count() == 0)
end
-- Test thread: basic.
do -- function
  local loop = ljuv.new_loop()
  loop:thread(function(a, b) return a*b end,
    function(ok, r) assert(ok and r == 42) end,
    6, 7)
  loop:run()
end
do -- string
  local loop = ljuv.new_loop()
  loop:thread("local a,b = ...; return a*b",
    function(ok, r) assert(ok and r == 42) end,
    6, 7)
  loop:run()
end
do -- error
  local loop = ljuv.new_loop()
  loop:thread(function(a, b) return a*b end,
    function(ok, err) assert(not ok and err:find("attempt to perform arithmetic")) end,
    6, nil)
  loop:run()
end
do -- Test thread: export.
  local channel = ljuv.new_channel()
  ljuv.loop:thread(
    function(channel)
      local ljuv = require "ljuv"
      channel = ljuv.import(channel)
      local a,b = channel:pull()
      channel:push(a*b)
    end,
    function(ok, err)
      assert(ok and channel:pull() == 42)
    end,
    ljuv.export(channel)
  )
  channel:push(6, 7)
  ljuv.loop:run()
end
