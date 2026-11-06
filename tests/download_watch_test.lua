-- Download stall watcher test (LuaJIT). Run: luajit tests/download_watch_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local watch = require("rlsmp/lib/downloadWatch")

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end

-- Run `seconds` of frames (dt each), with a fixed chunk count. Returns the first verdict, if any.
local function run(w, seconds, dt, got, phase)
  local verdict
  for _ = 1, math.floor(seconds / dt) do
    local v = watch.step(w, dt, got, phase)
    verdict = verdict or v
  end
  return verdict
end

-- 1. Server never answers the hello
local w = watch.new()
check(run(w, 59, 0.5, 0, "hello_sent") == nil, "no alarm before 60 s")
check(run(w, 3, 0.5, 0, "hello_sent") == "no_answer", "no_answer after 60 s of silence")

-- 2. Download keeps moving: never stalls, even over a long time
w = watch.new()
local verdict
for chunk = 1, 100 do verdict = verdict or watch.step(w, 20, chunk, "downloading") end
check(verdict == nil, "steady progress never stalls (20 s between chunks)")

-- 3. Download stops
w = watch.new()
run(w, 5, 0.5, 40, "downloading")
check(run(w, 25, 0.5, 40, "downloading") == nil, "no alarm at 30 s without progress")
check(run(w, 3, 0.5, 40, "downloading") == "stalled", "stalled after 30 s without progress")

-- 4. A loading hitch is not a stall (one 100 s frame counts as 5 s)
w = watch.new()
watch.step(w, 0.5, 10, "downloading")
check(watch.step(w, 100, 10, "downloading") == nil, "a single long frame does not trigger the alarm")
check(w.idle <= watch.MAX_STEP + 0.5, "long frame is capped")

-- 5. Progress logging: once per second, only while downloading
w = watch.new()
local logs = 0
for _ = 1, 20 do local _, l = watch.step(w, 0.25, 1, "downloading") if l then logs = logs + 1 end end
check(logs == 5, "5 s of downloading -> 5 progress lines, got " .. logs)
w = watch.new()
logs = 0
for _ = 1, 20 do local _, l = watch.step(w, 0.25, 0, "hello_sent") if l then logs = logs + 1 end end
check(logs == 0, "no progress lines while waiting for the server")

-- 6. Reset starts a fresh wait
w = watch.new()
run(w, 50, 0.5, 0, "hello_sent")
watch.reset(w)
check(run(w, 30, 0.5, 0, "hello_sent") == nil, "reset gives a full new wait")

print(string.format("download_watch_test: %d checks passed", passed))
