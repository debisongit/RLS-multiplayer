-- Police plate records: server (lua5.3) test. Run: lua5.3 tests/plate_records_test.lua <tmpdir>
local tmp = assert(arg[1], "pass a temp dir")
package.path = "tests/support/?.lua;Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local json = require("json")
local players, sent, timers = {}, {}, {}
MP = {
  RegisterEvent = function() end, CreateEventTimer = function(name, ms) timers[name] = ms end,
  TriggerClientEvent = function(pid, name, data) sent[#sent + 1] = {pid = pid, name = name, data = json.decode(data)} end,
  GetPlayerIdentifiers = function(pid) return players[pid].ids end,
  GetPlayerName = function(pid) return players[pid].name end,
  DropPlayer = function() end, SendChatMessage = function() end,
}
Util = {}
RLSMP_PLUGIN_ROOT = tmp .. "/"
dofile("Resources/Server/RLS-Career-MP/main.lua")
local util = require("rlsmp.server.util")
util.setJsonCodec(json)
local clock = 1000000
util.setClock(function() return clock end)
onInit()
local sessions = require("rlsmp.server.sessions")
local plates = require("rlsmp.server.plateRecords")
local cfg = RLSMP.config
local function fire(ev, ...) return _G["rlsmp_handler_" .. ev](...) end
local function client(ev, pid, body) return fire(ev, pid, json.encode(body)) end
local function join(pid, name)
  players[pid] = {name = name, ids = {beammp = tostring(1000 + pid)}}
  fire("onPlayerJoin", pid)
  fire("rlsmpHello", pid, json.encode({v = 1, build = require("rlsmp.shared.transfer").BUILD}))
  sessions.get(pid).stage = "loaded"
end
local function take(name)
  local out = {}
  for _, m in ipairs(sent) do if not name or m.name == name then out[#out + 1] = m end end
  sent = {}
  return out
end
local function chased(pid, on)
  client("rlsmpPos", pid, {x = 1, y = 2, z = 3, speed = 10, chased = on})
end
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end

-- defaults and wiring (main.lua runs modules.lua)
check(cfg.police.plateFlagSeconds == 7200 and cfg.police.descriptionSeconds == 1200, "record lifetimes")
check(cfg.police.plateReading.enabled == true and cfg.police.plateReading.skipChance == 0.2, "plateReading defaults")
check(timers.rlsmpPlateTick == 1000, "own timer event")
local merged = util.deepMerge(require("rlsmp.server.config").defaults, {police = {enabled = true, antiTeleport = false}})
check(merged.police.plateReading and merged.police.plateReading.rangeMeters == 15 and merged.police.antiTeleport == false,
  "old config.json gets the new keys")

join(1, "ann") join(2, "bob")
take()
fire("rlsmpPlateTick")
local cfgMsgs = take("rlsmpPlateConfig")
check(#cfgMsgs == 2 and cfgMsgs[1].data.enabled == true and cfgMsgs[1].data.rangeMeters == 15 and cfgMsgs[1].data.maxSeconds == 6,
  "config sent once to each loaded player")
fire("rlsmpPlateTick")
check(#take("rlsmpPlateConfig") == 0, "only once")

-- lookup of a clean plate
client("rlsmpPlateLookup", 1, {plate = " ab 123 ", model = "etk800", color = "blue"})
local res = take("rlsmpPlateResult")
check(#res == 1 and res[1].pid == 1 and res[1].data.flagged == false and res[1].data.plate == "AB 123" and res[1].data.model == "etk800",
  "clean plate, normalised echo")

-- escape without a chase seen: refused (griefing guard)
client("rlsmpPlateEscaped", 1, {plate = "AB 123", model = "etk800", color = "blue"})
check(plates.lookup("AB 123", "etk800").flagged == false, "escape with no chase seen is refused")

-- chased, then escaped (the chased flag may already be gone when the escape arrives)
chased(1, true)
fire("rlsmpPlateTick")
clock = clock + 5
chased(1, false)
fire("rlsmpPlateTick")
client("rlsmpPlateEscaped", 1, {plate = "AB 123", model = "etk800", color = "blue"})
check(plates.lookup("ab 123", "etk800").flagged == true, "escape after a chase flags the plate")
check(plates.lookup("AB 123", "pickup").flagged == false, "same plate, other model: not flagged")

-- other players' cops read it
clock = clock + 2
client("rlsmpPlateLookup", 2, {plate = "AB 123", model = "etk800", color = "red"})
res = take("rlsmpPlateResult")
check(res[1].pid == 2 and res[1].data.flagged == true and res[1].data.matchedBy == "plate" and res[1].data.reason == "escaped",
  "the record is shared by all cops")

-- description: same model + colour, other plate
local d = plates.lookup("ZZZ 9", "etk800", "blue")
check(d.flagged and d.matchedBy == "description", "model + colour remembered")
check(plates.lookup("ZZZ 9", "etk800", "red").flagged == false, "other colour: no match")

-- rate limits
client("rlsmpPlateLookup", 2, {plate = "AB 123", model = "etk800"})
res = take("rlsmpPlateResult")
check(#res == 1 and res[1].data.flagged == false and res[1].data.limited == true, "too many lookups: answered, not looked up")
client("rlsmpPlateEscaped", 1, {plate = "OTHER", model = "etk800", color = "blue"})
check(plates.lookup("OTHER", "etk800").flagged == false, "second escape within the cooldown ignored")
client("rlsmpPlateEscaped", 1, {plate = "", model = "etk800"})
client("rlsmpPlateEscaped", 1, {plate = "X", model = "bad model!"})
check(plates.lookup("X", "bad model!").flagged == false, "bad input ignored")
check(plates.flag("X", "bad model!") == false and plates.flag("", "etk800") == false and plates.flag(nil, "etk800") == false, "M.flag refuses bad input")

-- description expires after 20 min, flag stays 2 h
clock = clock + 1201
check(plates.lookup("ZZZ 9", "etk800", "blue").flagged == false, "description gone after descriptionSeconds")
check(plates.lookup("AB 123", "etk800", "blue").matchedBy == "plate", "flag still there")

-- repaint clears the description at once, plate change clears the flag at once
plates.flag("CAR 1", "vivace", "green", "stolen")
check(plates.lookup("NEW", "vivace", "green").matchedBy == "description", "M.flag for other modules (description)")
client("rlsmpPlateChanged", 2, {model = "vivace", oldPlate = "CAR 1", plate = "CAR 1", oldColor = "green", color = "black"})
check(plates.lookup("NEW", "vivace", "green").flagged == false, "repaint clears the description")
check(plates.lookup("CAR 1", "vivace", "black").matchedBy == "plate", "repaint keeps the plate flag")
clock = clock + 4
client("rlsmpPlateChanged", 2, {model = "vivace", oldPlate = "car 1", plate = "CAR 2", oldColor = "black", color = "black"})
check(plates.lookup("CAR 1", "vivace").flagged == false and plates.lookup("CAR 2", "vivace").flagged == false, "new plate text clears the flag")
plates.flag("CAR 3", "vivace", nil, "stolen")
client("rlsmpPlateChanged", 2, {model = "vivace", oldPlate = "CAR 3", plate = "CAR 4"})
check(plates.lookup("CAR 3", "vivace").flagged == true, "change reports are rate limited")

-- persisted
local saved = json.decode(io.open(tmp .. "/plates.json"):read("*a"))
check(saved.flags["AB 123|etk800"] and saved.flags["AB 123|etk800"].reason == "escaped", "saved to plates.json")

-- flag expiry after 2 h, prune removes it from disk
clock = clock + 7200
check(plates.lookup("AB 123", "etk800").flagged == false, "flag gone after plateFlagSeconds")
check(plates.prune() >= 1 and plates.records().flags["AB 123|etk800"] == nil, "prune drops it")

-- a new escape refreshes; master switch off: lookups answer clean, escapes ignored, config still sent
clock = clock + 100
cfg.police.plateReading.enabled = false
chased(2, true)
fire("rlsmpPlateTick")
client("rlsmpPlateEscaped", 2, {plate = "OFF 1", model = "etk800"})
check(plates.lookup("OFF 1", "etk800").flagged == false, "off: escapes ignored")
plates.flag("OFF 2", "etk800", nil, "x")
client("rlsmpPlateLookup", 2, {plate = "OFF 2", model = "etk800"})
res = take("rlsmpPlateResult")
check(#res == 1 and res[1].data.flagged == false, "off: lookups answer clean")
join(3, "cid")
fire("rlsmpPlateTick")
local m = take("rlsmpPlateConfig")
check(#m == 1 and m[1].pid == 3 and m[1].data.enabled == false, "off is sent too")

print("plate_records_test: " .. passed .. " checks passed")
