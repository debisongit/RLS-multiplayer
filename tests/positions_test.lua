-- Player positions: server (lua5.3) test. Run: lua5.3 tests/positions_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, chat = {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end, TriggerClientEvent = function() end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function(pid, m) chat[#chat + 1] = {pid, m} end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local now = 1000
util.setClock(function() return now end)
onInit()
local sessions = require("rlsmp.server.sessions")
local pos = require("rlsmp.server.positions")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function join(pid, name, loaded)
  players[pid] = {name = name, ids = {beammp = tostring(1000 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  if loaded ~= false then sessions.get(pid).stage = "loaded" end
end
local function send(pid, t) fire("rlsmpPos", pid, json.encode(t)) end
local function last() return chat[#chat] and chat[#chat][2] end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

join(1, "ann") join(2, "bob") join(3, "cid", false)

fire("onChatMessage", 1, "ann", "/where")
check(last():find("No position from you yet"), "/where before any report")

send(1, {x = 10, y = 20, z = 5, speed = 12.5, chased = false})
local p = pos.get(1)
check(p and p.x == 10 and p.y == 20 and p.z == 5 and p.speed == 12.5 and p.chased == false and p.t == 1000, "report stored")
check(p.s == nil, "internal fields are not handed out")

send(3, {x = 0, y = 0, z = 0, speed = 0})
check(pos.get(3) == nil, "player still loading is refused")

-- rate limit: a second report in the same second is ignored
send(1, {x = 99, y = 99, z = 0, speed = 1})
check(pos.get(1).x == 10, "report under 1 s apart ignored")
now = 1001
send(1, {x = 30, y = 20, z = 5, speed = 3, chased = true})
check(pos.get(1).x == 30 and pos.get(1).t == 1001 and pos.isChased(1), "next second accepted, chased flag")

-- bad values go straight into the handler (JSON cannot carry inf / nan)
now = 1010
for _, bad in ipairs({
  {x = math.huge, y = 0, z = 0, speed = 0}, {x = 0, y = -math.huge, z = 0, speed = 0}, {x = 0 / 0, y = 0, z = 0, speed = 0},
  {x = 0, y = 0, z = 0, speed = 0 / 0}, {x = 200000, y = 0, z = 0, speed = 0}, {x = 0, y = 0, z = 50000, speed = 0},
  {x = 0, y = 0, z = 0, speed = -1}, {x = 0, y = 0, z = 0, speed = 5000}, {x = "5", y = 0, z = 0, speed = 0},
  {x = 0, y = 0, speed = 0}, {x = 0, y = 0, z = 0},
}) do
  check(pos._onPos(1, bad) == false, "bad report refused")
end
check(pos.get(1).x == 30 and pos.get(1).t == 1001, "bad reports leave the old one")
fire("rlsmpPos", 1, "not json")
check(pos.get(1).x == 30, "broken JSON ignored")

-- chased only when exactly true
check(pos._onPos(1, {x = 30, y = 20, z = 5, speed = 3, chased = "yes"}) and pos.isChased(1) == false, "chased must be true")

-- distances (horizontal only)
send(2, {x = 30, y = 60, z = 500, speed = 0})
check(pos.distance(1, 2) == 40, "horizontal distance ignores height")
check(pos.distance(1, 3) == nil and pos.distance(9, 1) == nil, "distance nil for unknown players")
join(4, "dan")
send(4, {x = 30, y = 120, z = 0, speed = 0})
local near = pos.near(1, 150)
check(#near == 2 and near[1] == 2 and near[2] == 4, "near: closest first, not self")
check(#pos.near(1, 50) == 1 and #pos.near(3, 1000) == 0, "near: radius and unknown player")
local who, d = pos.nearest(4)
check(who == 2 and d == 60, "nearest returns pid and distance")
local count = 0 for _ in pairs(pos.all()) do count = count + 1 end
check(count == 3, "all lists everyone with a report")
check(pos.all()[2].z == 500, "all gives the reports")

now = 1013
fire("onChatMessage", 1, "ann", "/where")
check(last():find("x 30, y 20, z 5, 11 km/h, 3s ago"), "/where shows the last position: " .. last())

-- leaving forgets the player; a new player on the same id starts empty
fire("onPlayerDisconnect", 2)
check(pos.get(2) == nil and pos.distance(1, 2) == nil, "left player forgotten")
fire("onPlayerDisconnect", 4)
join(4, "eve")
check(pos.get(4) == nil, "reused id does not inherit the old position")
check(pos.nearest(1) == nil, "nobody else left")
send(4, {x = 0, y = 0, z = 0, speed = 0})
check(pos.get(4) and pos.get(4).x == 0, "new player on the reused id can report")
fire("rlsmpPosTick")
check(pos.get(1) ~= nil, "prune tick keeps players still online")
print("positions_test: " .. passed .. " checks passed")
