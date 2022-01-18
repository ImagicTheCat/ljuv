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
do -- Test thread: basic.
  -- function
  local thread = ljuv.new_thread(function(a, b) return a*b end, 6, 7)
  local ok, r = thread:join()
  assert(ok and r == 42)
  -- string
  local thread = ljuv.new_thread("local a,b = ...; return a*b", 6, 7)
  local ok, r = thread:join()
  assert(ok and r == 42)
  -- error
  local thread = ljuv.new_thread(function(a, b) return a*b end, 6, nil)
  local ok, err = thread:join()
  assert(not ok and err:find("attempt to perform arithmetic"))
end
do -- Test thread: export.
  local channel = ljuv.new_channel()
  local thread = ljuv.new_thread(function(channel)
    local a,b = channel:pull()
    channel:push(a*b)
  end, channel)
  assert(thread:running())
  channel:push(6, 7)
  thread:join()
  assert(not thread:running())
  assert(channel:pull() == 42)
end
