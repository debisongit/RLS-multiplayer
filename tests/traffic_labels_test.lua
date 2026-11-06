-- Traffic name-tag relay: server (lua5.3) test. Run: lua5.3 tests/traffic_labels_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
local players, sent = {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function() end,
  TriggerClientEvent = function(pid, name, data) sent[pid] = sent[pid] or {} table.insert(sent[pid], {name = name, data = json.decode(data)}) end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function() end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
require("rlsmp.server.util").setJsonCodec(json)
onInit()
local sessions = require("rlsmp.server.sessions")
local labels = require("rlsmp.server.trafficLabels")
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function join(pid, name)
  players[pid] = {name = name, ids = {beammp = tostring(1000 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  sessions.get(pid).stage = "loaded"
end
local function got(pid) local out = {} for _, m in ipairs(sent[pid] or {}) do if m.name == "rlsmpTrafficIdsRx" then out[#out + 1] = m.data end end return out end

local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

join(0, "alice") join(1, "bob")
fire("rlsmpTrafficIds", 0, json.encode({ids = {"0-3", "0-5", "1-9", "bad", 5}}))
local rx = got(1)
check(#rx == 1 and rx[1].from == 0, "bob receives alice's list")
check(#rx[1].ids == 2 and rx[1].ids[1] == "0-3" and rx[1].ids[2] == "0-5", "only ids that belong to the sender are relayed")
check(#got(0) == 0, "the sender does not get their own list back")

fire("rlsmpTrafficIds", 0, json.encode({ids = {}}))
check(#got(1) == 2 and #got(1)[2].ids == 0, "an empty list is relayed (tags come back)")

join(2, "carol")
labels.tick()
local late = got(2)
check(#late == 1 and late[1].from == 0, "a player who joins later gets the existing lists")
labels.tick()
check(#got(2) == 1, "they are only greeted once")

local before = #got(1)
fire("rlsmpTrafficIds", 5, json.encode({ids = {"5-1"}}))   -- not a loaded player
check(#got(1) == before, "lists from players who are not in career are ignored")

fire("onPlayerDisconnect", 0)
labels.tick()
join(3, "dave")
labels.tick()
check(#got(3) == 0, "a player who left is forgotten")
print(string.format("traffic_labels_test: %d checks passed", passed))
