-- Tests removeGuard (keep remote cars on career start) and mapGate (wait for RLS map). LuaJIT.
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
function log() end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- removeGuard ---------------------------------------------------------------------------------------------
local objects, deleted = {}, {}
local function obj(id) return {getID = function() return id end, delete = function() deleted[id] = true end} end
for _, id in ipairs({1, 2, 3, 4}) do objects[#objects + 1] = obj(id) end   -- 3 = remote player's car
be = {getObjectCount = function() return #objects end, getObject = function(_, i) return objects[i + 1] end}
MPVehicleGE = {getVehicles = function()
  return {["0-0"] = {gameVehicleID = 1, isLocal = true}, ["1-0"] = {gameVehicleID = 3, isLocal = false}}
end}
local originalCalls = 0
core_vehicles = {removeAll = function() originalCalls = originalCalls + 1 end}
local rg = require("rlsmp/lib/removeGuard")
check(rg.install() == true, "installed")
core_vehicles.removeAll()
check(originalCalls == 1 and not next(deleted), "disabled: original removeAll runs untouched")
rg.enable(true)
core_vehicles.removeAll()
check(deleted[1] and deleted[2] and deleted[4] and not deleted[3], "enabled: everything except the remote car is deleted")
check(originalCalls == 1, "original not called while protecting")
rg.enable(false)
check(rg.install() == true, "install twice is harmless")

-- mapGate ------------------------------------------------------------------------------------------------
local files = {}
FS = {fileExists = function(_, p) return files[p] == true end}
local clockNow = 0
local mg = require("rlsmp/lib/mapGate")
mg.setClock(function() return clockNow end)
MPCoreNetwork = {isMPSession = function() return true end, leaveServer = function() _G.left = true end}
local toasts = {}
guihooks = {trigger = function(_, d) toasts[#toasts + 1] = d.msg end}
local expandReal = function(p) return files[p:gsub("info.json$", "") .. "info.json"] and p or nil end
core_levels = {expandMissionFileName = function(p) local lvl = p:match("^/?levels/([^/]+)/") return files["/levels/" .. lvl .. "/info.json"] and p or nil end}
local started = {}
freeroam_freeroam = {startFreeroam = function(p) started[#started + 1] = p end}
-- fake job system: runs the function as a coroutine; job.sleep advances the fake clock
local pendingJobs = {}
core_jobsystem = {create = function(fn)
  local co = coroutine.create(function() fn({sleep = function(s) clockNow = clockNow + (s > 0 and s or 0) coroutine.yield() end}) end)
  pendingJobs[#pendingJobs + 1] = co
  coroutine.resume(co)
end}
local function tick() for _, co in ipairs(pendingJobs) do if coroutine.status(co) == "suspended" then coroutine.resume(co) end end end

check(mg.install() == true, "gate installed")
local map = "/levels/rls_west_coast/info.json"
check(core_levels.expandMissionFileName(map) == map, "BeamMP is told the building map exists")
check(core_levels.expandMissionFileName("/levels/nowhere/info.json") == nil, "unknown maps are still reported missing")
files["/levels/west_coast_usa/info.json"] = true
check(core_levels.expandMissionFileName("/levels/west_coast_usa/info.json") ~= nil, "normal maps untouched")

freeroam_freeroam.startFreeroam("/levels/west_coast_usa/info.json")
check(started[1] == "/levels/west_coast_usa/info.json", "normal map loads immediately")

freeroam_freeroam.startFreeroam(map)
check(#started == 1, "gated map load is held")
for _ = 1, 10 do tick() end
check(#started == 1, "still waiting while the map is missing")
files[map] = true
tick()
check(started[2] == map, "map loads as soon as RLS has built it")

-- timeout leaves the server with a message
files[map] = nil
mg.TIMEOUT = 5
freeroam_freeroam.startFreeroam(map)
for _ = 1, 40 do tick() end
check(#started == 2 and _G.left == true and #toasts == 1, "timeout -> player leaves with a message")

-- RLS fails while we wait -> stop waiting immediately instead of running into the timeout
_G.left = nil
mg.TIMEOUT = 240
freeroam_freeroam.startFreeroam(map)
for _ = 1, 3 do tick() end
check(_G.left == nil, "still waiting while RLS is busy")
overhaul_world_levelProxy = {getStatus = function() return {state = "error"} end}
tick()
check(_G.left == true, "proxy error mid-wait: give up without waiting for the timeout")
-- build kick: nothing is building the map (RLS was unloaded and reloaded) -> start one, once
_G.left = nil
files[map] = nil
local regen, loaded, loadingText = 0, 0, nil
overhaul_world_levelProxy = {getStatus = function() return {state = "idle"} end, regenerate = function() regen = regen + 1 end}
UI = {updateLoading = function(t) loadingText = t end}
freeroam_freeroam.startFreeroam(map)
for _ = 1, 30 do tick() end
check(regen == 1, "idle map builder is restarted exactly once")
check(loadingText and loadingText:sub(1, 1) == "l" and loadingText:find("RLS map"), "loading text uses BeamMP's 'l' code")
files[map] = true
tick()
check(started[#started] == map, "map loads after the restarted build finishes")
files[map] = nil

-- builder module missing entirely -> ask the game to load it once
overhaul_world_levelProxy = nil
extensions = {load = function(name) loaded = loaded + 1 end}
freeroam_freeroam.startFreeroam(map)
for _ = 1, 30 do tick() end
check(loaded == 1, "missing map builder is loaded once")
overhaul_world_levelProxy = {getStatus = function() return {state = "error"} end}
for _ = 1, 600 do tick() end   -- let the old job end

-- wrappers survive the game reloading its modules
local before = core_levels.expandMissionFileName
mg.install()
check(core_levels.expandMissionFileName == before, "install twice does not stack wrappers")
local freshExpand = function() return nil end
core_levels = {expandMissionFileName = freshExpand}
freeroam_freeroam = {startFreeroam = function() end}
check(mg.install() == true and core_levels.expandMissionFileName ~= freshExpand, "reloaded core_levels is wrapped again")
overhaul_world_levelProxy = nil
core_vehicles = {removeAll = function() end}
local oldRemoveAll = core_vehicles.removeAll
rg.install()
check(core_vehicles.removeAll ~= oldRemoveAll, "reloaded core_vehicles is wrapped again")

print(string.format("join_protect_test: %d checks passed", passed))
