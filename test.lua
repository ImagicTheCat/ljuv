#!/usr/bin/env luajit
-- or Lua 5.1

-- config
local envs = {"luajit"}
local tests = {
  "tests/thread.lua",
  "tests/loop.lua",
  "tests/app.lua"
}
-- test
local errors = 0
for _, env in ipairs(envs) do
  for _, test in ipairs(tests) do
    local status = os.execute(env.." "..test)
    if status ~= 0 then print(env, test, "FAILED"); errors = errors+1 end
  end
end
if errors > 0 then error(errors.." error(s)") end
