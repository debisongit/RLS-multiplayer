-- Client plate reading test (LuaJIT). Run: luajit tests/plates_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end
local handlers, out = {}, {}
TriggerServerEvent = function(name, data) out[#out + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end
local messages = {}
function ui_message(text, ttl, cat) messages[#messages + 1] = {text = text, cat = cat} end

local mp, career, isCop, playerId = true, true, false, 1
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}
local inactive = {}
be = {getPlayerVehicleID = function() return playerId end, getObjectActive = function(_, id) return not inactive[id] end}
overhaul_career_police_playerDriving = {getPlayerIsCop = function() return isCop end}
overhaul_career_garage_inventory = {getInventoryIdFromVehicleId = function(id) return id == 1 and 7 or nil end}

-- the player's car object
local car = {jbeam = "etk800", plate = "AB 123", color = {x = 0.0, y = 0.0, z = 0.6}}
function car:getDynDataFieldbyName() return self.plate end
function getObjectByID(id) if id == 1 then return car end return nil end
core_vehicles = {getVehicleLicenseText = function(obj) return obj.plate end}
local paints = {{baseColor = {0.05, 0.1, 0.8, 1}}}
core_vehicle_manager = {getVehicleData = function(id) return id == 1 and {config = {paints = paints}} or nil end}

-- RLS traffic data: the player (with triggerOffense) and police units (validTargets.dist is SQUARED)
local offenses = {}
local player = {isAi = false, speed = 5, pursuit = {mode = 0}, queuedFuncs = {}}
function player:triggerOffense(data) offenses[#offenses + 1] = data end
local function cop(dsq, visible) return {isAi = true, role = {name = "police", state = "none", flags = {}, validTargets = {[1] = {dist = dsq, visible = visible}}}} end
local traffic = {[1] = player, [10] = cop(20 * 20, true)}
gameplay_traffic = {getTrafficData = function() return traffic end}
local pursuitCalls = {}
overhaul_integration_services_police = {
  setPursuitMode = function(level, target, copId) pursuitCalls[#pursuitCalls + 1] = {level, target, copId} end,
  getWalkHandoffVehId = function() return nil end,
}
local chased = false
rlsmp_police = {isPursuit = function() return chased end}

local plates = require("rlsmp/plates")
plates.onExtensionLoaded()
local passed = 0
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end passed = passed + 1 end
local randoms = {}
plates._setRandom(function() return table.remove(randoms, 1) or 0 end)
local function tick(n) for _ = 1, (n or 1) do plates.onUpdate(0.5, 0.5) end end
local function sentNamed(name) local r = {} for _, m in ipairs(out) do if m.name == name then r[#r + 1] = m.data end end return r end
local function lastMsg() return messages[#messages] and messages[#messages].text end
local function server(name, body) handlers[name](json.encode(body)) end

-- nothing before the server speaks / while disabled
plates.enable(true)
traffic[10] = cop(10 * 10, true)
tick(4)
check(plates.getReader().cop == nil and #messages == 0, "no config yet: nothing")
server("rlsmpPlateConfig", {enabled = true, rangeMeters = 15, maxSpeedKmh = 50, minSeconds = 3, maxSeconds = 6, readChance = 1,
  afterEscapeChance = 1, skipChance = 0.2, retriggerSeconds = 120, offenseScore = 400, encounterSeconds = 60, copCooldownSeconds = 300,
  afterEscapeSeconds = 1200})
check(plates.getConfig().enabled and saw("plates: config received enabled=true"), "config received")

-- out of range (20 m), then in range: read 3 s (randoms: encounter 0 -> reads, need 3 + 0 * 3)
traffic[10] = cop(20 * 20, true)
tick()
check(plates.getReader().cop == nil, "20 m away: no read (dist is squared: 400 > 225)")
traffic[10] = cop(14 * 14, true)
randoms = {0, 0}
tick()
check(plates.getReader().cop == 10 and lastMsg() == "Police reading your plate: __ ___" and messages[#messages].cat == "rlsmpPlateRead", "read starts with a masked plate")
tick(3)
check(lastMsg() == "Police reading your plate: AB ___", "letters revealed with progress (1.5 of 3 s)")

-- speeding up resets
player.speed = 60 / 3.6
tick()
check(plates.getReader().cop == nil and lastMsg() == "Plate read interrupted", "over 50 km/h resets the read")
player.speed = 5
tick()
check(plates.getReader().cop == 10 and plates.getReader().got == 0, "slow again: starts from zero (same encounter)")
-- leaving range resets
traffic[10] = cop(30 * 30, true)
tick()
check(plates.getReader().cop == nil, "leaving range resets")
traffic[10] = cop(14 * 14, true)
tick()
tick(6)
local looks = sentNamed("rlsmpPlateLookup")
check(#looks == 1 and looks[1].plate == "AB 123" and looks[1].model == "etk800" and looks[1].color == "blue", "finished read asks the server")
check(lastMsg() == "Police read your plate: AB 123", "done message")
tick(4)
check(#sentNamed("rlsmpPlateLookup") == 1, "one lookup per read")

-- clean answer: nothing happens
server("rlsmpPlateResult", {plate = "AB 123", model = "etk800", flagged = false})
check(#offenses == 0 and plates._pending() == nil, "clean plate: no chase")

-- flagged answer from another unit: instant chase via RLS's offense (random 0.5 >= skip 0.2)
traffic[11] = cop(8 * 8, true)
randoms = {0, 0}
tick(8)
check(#sentNamed("rlsmpPlateLookup") == 2, "the second unit reads too (the first one has its cooldown)")
randoms = {0.5}
server("rlsmpPlateResult", {plate = "ab 123", model = "etk800", flagged = true, reason = "escaped", matchedBy = "plate"})
check(#offenses == 1 and offenses[1].key == "wantedPlate" and offenses[1].score == 400 and offenses[1].value == "AB 123", "flagged: wantedPlate offense")
check(saw("plates: lookup AB 123 flagged=true matchedBy=plate reason=escaped -> CHASE"), "chase log line")
-- RLS did not start it within 1.5 s: our fallback calls setPursuitMode(1, car, unit)
tick(3)
check(#pursuitCalls == 1 and pursuitCalls[1][1] == 1 and pursuitCalls[1][2] == 1 and pursuitCalls[1][3] == 11, "fallback setPursuitMode(1, player, unit)")
player.pursuit.mode = 1
chased = true
tick(3)
check(saw("plates: chase running (stage 2)"), "fallback sees the chase")
-- no reads while chased
traffic[12] = cop(5 * 5, true)
randoms = {0, 0}
tick(20)
check(#sentNamed("rlsmpPlateLookup") == 2 and plates.getReader().cop == nil, "no reads during a pursuit")

-- the chase ends in an escape (RLS hook): reported with plate, model, colour
plates.onPursuitAction(1, "evade", {timers = {evade = 40}})
local esc = sentNamed("rlsmpPlateEscaped")
check(#esc == 1 and esc[1].plate == "AB 123" and esc[1].model == "etk800" and esc[1].color == "blue", "escape reported")
plates.onPursuitAction(1, "evade", {timers = {evade = 0}})
check(#sentNamed("rlsmpPlateEscaped") == 1 and saw("stalemate"), "stalemate end is not an escape")
plates.onPursuitAction(99, "evade", {timers = {evade = 40}})
plates.onPursuitAction(1, "arrest", {})
check(#sentNamed("rlsmpPlateEscaped") == 1, "other cars and arrests are not escapes")
player.pursuit.mode = 0
chased = false

-- right after the escape a flagged read does not re-chase (our own 120 s cooldown; RLS wiped its pursuit table)
randoms = {0, 0}
tick(8)
check(#sentNamed("rlsmpPlateLookup") == 3, "unit 12 reads after the chase")
randoms = {0.9}
server("rlsmpPlateResult", {plate = "AB 123", model = "etk800", flagged = true, reason = "escaped", matchedBy = "plate"})
check(#offenses == 1 and saw("-> cooldown"), "re-trigger cooldown holds")

-- a unit lets a flagged plate go 1 time in 5 (random 0.1 < 0.2)
for _ = 1, 260 do plates.onUpdate(0.5, 0.5) end   -- 130 s: past the cooldown
traffic = {[1] = player, [20] = cop(6 * 6, true)}
randoms = {0, 0}
tick(8)
check(#sentNamed("rlsmpPlateLookup") == 4, "a new unit reads")
randoms = {0.1}
server("rlsmpPlateResult", {plate = "AB 123", model = "etk800", flagged = true, matchedBy = "description"})
check(#offenses == 1 and saw("-> skipped"), "skip chance lets it go")

-- plate change and repaint of the garage car are reported (cleared on the server)
car.plate = "NEW 1"
tick()
local ch = sentNamed("rlsmpPlateChanged")
check(#ch == 1 and ch[1].oldPlate == "AB 123" and ch[1].plate == "NEW 1" and ch[1].model == "etk800", "plate change reported")
paints[1].baseColor = {0.8, 0.05, 0.05, 1}
tick()
ch = sentNamed("rlsmpPlateChanged")
check(#ch == 2 and ch[2].oldColor == "blue" and ch[2].color == "red", "repaint reported")
car.plate = ""
tick()
check(#sentNamed("rlsmpPlateChanged") == 2, "empty plate text (RLS refreshing it) is ignored")
car.plate = "NEW 1"

-- the live colour is used when the spawn config has none (linear -> sRGB)
paints[1] = nil
car.plate = "NEW 1"
tick()
check(#sentNamed("rlsmpPlateChanged") == 3 and sentNamed("rlsmpPlateChanged")[3].color == "blue", "obj.color fallback")

-- skipped: cop player, passenger, not MP, inactive unit
local function readsStartWith(setup, undo, msg)
  traffic = {[1] = player, [30 + passed] = cop(5 * 5, true)}
  setup()
  randoms = {0, 0}
  tick(2)
  check(plates.getReader().cop == nil, msg)
  undo()
end
traffic = {[1] = player, [29] = cop(5 * 5, true)}
randoms = {0, 0}
tick(2)
check(plates.getReader().cop == 29, "control: a fresh unit nearby does start a read")
traffic = {[1] = player}
tick()
readsStartWith(function() isCop = true end, function() isCop = false end, "playing as a cop: no reads")
readsStartWith(function() player.isAi = true end, function() player.isAi = false end, "AI car (taxi passenger): no reads")
readsStartWith(function() player.isPerson = true end, function() player.isPerson = nil end, "on foot (RLS person entry): no reads")
readsStartWith(function() car.jbeam = "unicycle" end, function() car.jbeam = "etk800" end, "on foot (unicycle): no reads")
readsStartWith(function() mp = false end, function() mp = true end, "single player: nothing")
readsStartWith(function() for id in pairs(traffic) do inactive[id] = true end end, function() inactive = {} end, "inactive unit object: no read")
readsStartWith(function() plates.enable(false) end, function() plates.enable(true) end, "career not active on the server: nothing")
server("rlsmpPlateConfig", {enabled = false})
readsStartWith(function() end, function() end, "server switched it off: nothing")

-- random encounter decision: a unit that rolled "no" does not read
server("rlsmpPlateConfig", {enabled = true, readChance = 0.3})
traffic = {[1] = player, [50] = cop(5 * 5, true)}
randoms = {0.6}
tick(10)
check(plates.getReader().cop == nil, "roll 0.6 >= 0.3: this unit ignores you")

-- a rate-limited answer is not "clean": the unit may read again
server("rlsmpPlateConfig", {enabled = true, readChance = 1})
traffic = {[1] = player, [60] = cop(5 * 5, true)}
randoms = {0, 0}
tick(8)
local nLook = #sentNamed("rlsmpPlateLookup")
server("rlsmpPlateResult", {plate = "NEW 1", model = "etk800", flagged = false, limited = true})
check(plates.getReader().copDone[60] == nil and plates._pending() == nil, "limited answer: unit cooldown cleared")
randoms = {0, 0}
tick(8)
check(#sentNamed("rlsmpPlateLookup") == nLook + 1, "the unit reads again")
server("rlsmpPlateResult", {plate = "NEW 1", model = "etk800", flagged = false})

print("plates_client_test: " .. passed .. " checks passed")
