-- Client anti-teleport police test (LuaJIT). Run: luajit tests/police_client_test.lua
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")

jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = tag .. "|" .. tostring(msg) end
local function saw(fragment) for _, l in ipairs(logged) do if l:find(fragment, 1, true) then return true end end return false end
function setExtensionUnloadMode() end
local handlers = {}
TriggerServerEvent = function() end
AddEventHandler = function(name, fn) handlers[name] = fn end

local mp, career, playerId = true, true, 1
MPCoreNetwork = {isMPSession = function() return mp end}
overhaul_career_career = {isActive = function() return career end}
be = {getPlayerVehicleID = function() return playerId end}

local function at(x) return {x = x, y = 0, z = 0} end
local function cop(id, x) return {id = id, role = {name = "police"}, enableRespawn = true, respawnCount = 0, pos = at(x or 100), respawn = {spawnDirBias = 0.5}} end
local traffic = {
  [1] = {role = {name = "none"}, pursuit = {mode = 0}, pos = at(0)},
  [2] = {role = {name = "none"}, pursuit = {mode = 0}, pos = at(0)}, -- a second car the player may switch to
  [10] = cop(10, 100), [11] = cop(11, 1000), -- 11 is far away and not in the pursuit data: left alone
  [12] = {role = {name = "civilian"}, enableRespawn = true, pursuit = {mode = 0}},
}
local teleports, roadblocks = 0, 0
gameplay_traffic = {
  getTrafficData = function() return traffic end,
  forceTeleport = function() teleports = teleports + 1 return true end,
}
overhaul_integration_services_police = {setupRoadblock = function() roadblocks = roadblocks + 1 return {vehIds = {}} end}

local police = require("rlsmp/police")
police.onExtensionLoaded()

local passed = 0
local function check(cond, msg)
  if not cond then error("FAIL: " .. msg, 2) end
  passed = passed + 1
end
local function tick() police.onUpdate(1) end

check(saw("RLSMP-P3|probe: RLS police service present = true"), "boot probes use the RLSMP-P3 tag")
check(saw("RLSMP-P3|rlsmp_police loaded"), "loaded line")

-- 1. No pursuit: a cop near the player is held already (before any chase), a far one is not
tick()
check(traffic[10].rlsmpHold ~= true and not police.isPursuit(), "default: with no chase a cop 100 m away is NOT held (it can be recycled)")
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true, holdNearBeforeChase = true}))
tick()
check(traffic[10].rlsmpHold == true and not police.isPursuit(), "holdNearBeforeChase on: the cop 100 m away is held before any chase")
check(traffic[11].rlsmpHold ~= true, "...the one 1000 m away is not")
check(traffic[10].respawn.spawnDirBias == -1 and traffic[11].respawn.spawnDirBias == -1, "police get spawnDirBias -1 (re-placed behind)")
check(traffic[12].respawn == nil and traffic[12].rlsmpHold ~= true, "civilians untouched")
check(not saw("FROZE police"), "a hold before a chase writes no FROZE line")
-- the cop was already fading out when the offence happened: it fades back in (per frame)
traffic[10].state, traffic[10].alpha = "fadeOut", 0.6
police.onUpdate(0.01)
check(traffic[10].state == "fadeIn" and saw("CANCELLED fade-out of held police id=10"), "fade-out of a held cop cancelled")
traffic[11].state, traffic[11].alpha = "fadeOut", 0.6
police.onUpdate(0.01)
check(traffic[11].state == "fadeOut", "an unheld far cop keeps fading")
traffic[11].state = nil
-- roadblock and teleport are refused even before the pursuit is noticed
check(overhaul_integration_services_police.setupRoadblock(1) == nil and roadblocks == 0, "roadblock against the player refused before the pursuit is seen")
check(overhaul_integration_services_police.setupRoadblock(77) ~= nil and roadblocks == 1, "roadblock against another car allowed outside a chase")
roadblocks = 0
check(gameplay_traffic.forceTeleport(10) == false and teleports == 0, "police teleport refused before the pursuit is seen")

-- 2. Player chased (found by polling, the hook is only a fast start)
traffic[1].pursuit.mode = 2
tick()
check(police.isPursuit(), "pursuit detected from traffic data")
check(traffic[10].rlsmpHold == true, "police unit within 300 m frozen")
check(traffic[11].rlsmpHold ~= true, "police unit 1000 m away and not in the pursuit data left alone")
check(saw("RLSMP-P3|probe: player position known = true"), "probe: player position known")
check(traffic[12].rlsmpHold ~= true, "civilians untouched")

check(saw("RLSMP-P3|probe: player vehicle in traffic data = true"), "probe: player in traffic data")
check(saw("RLSMP-P3|pursuit START mode=2 antiTeleport=true blockRoadblocks=true"), "pursuit START line")
check(saw("RLSMP-P3|patched setupRoadblock = true") and saw("RLSMP-P3|patched forceTeleport = true"), "patched lines")
check(saw("RLSMP-P3|FROZE police id=13") == false, "no line for a unit that is not there yet")
check(saw("RLSMP-P3|pursuit START"), "start line")

-- 3. Roadblocks and police teleports refused, others pass
check(overhaul_integration_services_police.setupRoadblock(1) == nil and roadblocks == 0, "roadblock refused")
check(saw("RLSMP-P3|BLOCKED setupRoadblock from tests/police_client_test.lua:"), "BLOCKED line names the caller")
check(gameplay_traffic.forceTeleport(10) == false and teleports == 0, "cop teleport refused")
check(gameplay_traffic.forceTeleport(12) == true and teleports == 1, "civilian teleport allowed")

-- 4. A new police unit appearing mid-chase is frozen too
traffic[13] = cop(13, 50)
tick()
check(traffic[13].rlsmpHold == true, "late police unit frozen")

-- 5. Respawn watch notices a unit that was re-placed anyway
traffic[10].respawnCount = 1
tick()
check(police.getLeaks() == 1, "re-placed unit counted")
check(saw("RLSMP-P3|LEAK police id=10") and saw("dist=100 ahead="), "LEAK line says how far and whether ahead")
tick()
check(police.getLeaks() == 1, "counted once")

-- 6. RLS resets pursuit.mode directly and never calls the hook with 0 -> still released
traffic[1].pursuit.mode = 0
traffic[13].pos = at(2000)    -- drove far away during the chase
tick()
check(not police.isPursuit(), "pursuit end seen through traffic data")
check(saw("RLSMP-P3|pursuit END after"), "pursuit END line")
check(traffic[10].rlsmpHold == true, "a cop still near you stays held after the chase")
check(traffic[13].rlsmpHold ~= true, "...a far one is released")
traffic[10].role.state = "disabled"   -- RLS parks cops in 'disabled' after a chase (or when wrecked)
tick()
check(traffic[10].rlsmpHold ~= true, "a disabled (wrecked / cooling down) cop is let go")
traffic[10].role.state = nil
check(overhaul_integration_services_police.setupRoadblock(1) == nil, "roadblocks stay refused for the player")

-- 7. Player switches vehicle mid-chase: the new player vehicle is chased, state follows
traffic[1].pursuit.mode = 1
police.onPursuitModeUpdate(1, {mode = 1}) -- hook gives a fast start
check(police.isPursuit() and traffic[10].rlsmpHold == true, "hook starts at once")
playerId = 2
traffic[1].pursuit.mode = 0
tick()
check(not police.isPursuit(), "switching away from the chased car ends it")
traffic[2].pursuit.mode = 3
tick()
check(police.isPursuit() and traffic[10].rlsmpHold == true, "new player vehicle chased -> frozen again")
traffic[2].pursuit.mode = 0
tick()
playerId = 1

-- 8. A unit that already had respawn off keeps its own setting; we only add and remove our hold flag
traffic[10].enableRespawn = false
traffic[1].pursuit.mode = 1
tick()
traffic[1].pursuit.mode = 0
traffic[10].pos = at(1000)
tick()
traffic[10].pos = at(100)
check(traffic[10].enableRespawn == false and traffic[10].rlsmpHold == nil, "a unit that already had respawn off keeps it off, and the hold flag is gone")
traffic[10].enableRespawn = true

-- 9. Server config
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = false}))
traffic[1].pursuit.mode = 2
tick()
check(traffic[10].rlsmpHold ~= true, "antiTeleport=false -> nothing frozen")
check(overhaul_integration_services_police.setupRoadblock() ~= nil, "antiTeleport=false -> roadblocks allowed")
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true, blockRoadblocks = false}))
tick()
check(overhaul_integration_services_police.setupRoadblock() ~= nil, "blockRoadblocks=false allows roadblocks")
check(traffic[10].rlsmpHold == true, "police frozen again")

-- 10. Leaving the server restores everything; outside multiplayer nothing happens
police.onServerLeave()
check(traffic[10].rlsmpHold ~= true and not police.isPursuit(), "leave restores")
mp = false
tick()
check(not police.isPursuit() and traffic[10].rlsmpHold ~= true, "not in multiplayer -> ignored")
mp = true
career = false
police.onOverhaulActive(false)
tick()
check(not police.isPursuit(), "career inactive -> ignored")

-- 11. Census
local report = police.report()
check(report:find("census begin", 1, true) and report:find("setupRoadblock BLOCKED", 1, true), "census lists blocked roadblocks")
check(report:find("setupRoadblock BLOCKED callers", 1, true) and report:find("police_client_test.lua:", 1, true), "census lists callers")
check(report:find("pursuits started", 1, true) and report:find("units frozen", 1, true), "census lists pursuits and freezes")

-- 12. Player car missing from traffic data: the RLS hook is the fallback (no position known: all frozen)
mp, career = true, true
traffic[1] = nil
logged = {}
police.onPursuitModeUpdate(1, {mode = 2})
check(police.isPursuit() and traffic[10].rlsmpHold == true, "hook fallback starts the pursuit")
check(traffic[11].rlsmpHold == true, "no player position -> every police unit frozen (safe side)")
check(saw("RLSMP-P3|probe: player position known = false"), "probe says the position is unknown")
check(saw("RLSMP-P3|probe: player vehicle in traffic data = false"), "probe says the player is not in traffic data")
tick()
check(police.isPursuit(), "fallback keeps the pursuit on")
police.onPursuitModeUpdate(1, {mode = 0})
check(not police.isPursuit() and traffic[10].rlsmpHold ~= true and traffic[11].rlsmpHold ~= true, "hook ends it")

-- 13. Only units tied to the chase: pursuit data ids, distance, release gap, vanished units
traffic[1] = {role = {name = "none"}, pursuit = {mode = 0, sight = {}, roadblockTargetId = 0}, pos = at(0)}
traffic[10].pos, traffic[11].pos, traffic[13].pos = at(100), at(1000), at(50)
traffic[14] = cop(14, 2000)
traffic[1].pursuit.mode = 2
traffic[1].pursuit.sight.policeId = 11      -- RLS's nearest visible unit, far away
traffic[1].pursuit.roadblockTargetId = 14   -- the roadblock unit, far away
tick()
check(police.isPursuit(), "pursuit on")
check(traffic[11].rlsmpHold == true, "sight.policeId unit frozen even when far")
check(traffic[14].rlsmpHold == true, "roadblockTargetId unit frozen even when far")
check(traffic[10].rlsmpHold == true and traffic[13].rlsmpHold == true, "near units frozen")
traffic[1].pursuit.sight.policeId = nil
traffic[1].pursuit.roadblockTargetId = 0
tick()
check(traffic[11].rlsmpHold ~= true and traffic[14].rlsmpHold ~= true, "units that leave the pursuit data and are far are released")
check(saw("RLSMP-P3|RELEASED police id=11"), "RELEASED line for a single unit")
traffic[10].pos = at(320)                   -- past 300 m but inside the 350 m release gap
tick()
check(traffic[10].rlsmpHold == true, "frozen unit inside the release gap stays frozen")
traffic[10].pos = at(400)
tick()
check(traffic[10].rlsmpHold ~= true and police.isPursuit(), "unit beyond 350 m released, pursuit goes on")
traffic[10].pos = at(320)
tick()
check(traffic[10].rlsmpHold ~= true, "released unit at 320 m is not frozen again (needs <= 300 m)")
traffic[10].pos = at(200)
tick()
check(traffic[10].rlsmpHold == true, "unit coming back within 300 m frozen again")
traffic[13] = nil                           -- a frozen unit leaves the traffic data
tick()
check(saw("RLSMP-P3|GONE police id=13"), "vanished unit forgotten")
traffic[1].pos = nil                        -- player position from map.objects instead
map = {objects = {[1] = {pos = at(1900)}}}
tick()
check(traffic[14].rlsmpHold == true and traffic[10].rlsmpHold ~= true, "map.objects position used when traffic data has none")
map = nil
traffic[1].pos = at(0)
traffic[1].pursuit.mode = 0
tick()
check(not police.isPursuit() and traffic[14].rlsmpHold ~= true and traffic[10].rlsmpHold == true, "far units released at the end, the one 200 m away stays held")
traffic[13] = cop(13, 50)

-- 14. RLS (or vanilla) replaces a wrapped function: we wrap the new one, keep it as the original, once
local newTeleports, newRoadblocks = 0, 0
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true, blockRoadblocks = true}))
gameplay_traffic.forceTeleport = function() newTeleports = newTeleports + 1 return "new" end
overhaul_integration_services_police.setupRoadblock = function() newRoadblocks = newRoadblocks + 1 return {vehIds = {}, new = true} end
traffic[1].pursuit.mode = 2
tick()
check(saw("RLSMP-P3|rewrapped forceTeleport(police)") and saw("RLSMP-P3|rewrapped setupRoadblock"), "rewrapped lines")
check(gameplay_traffic.forceTeleport(10) == false and newTeleports == 0, "replaced forceTeleport is blocked again for police")
check(overhaul_integration_services_police.setupRoadblock() == nil and newRoadblocks == 0, "replaced setupRoadblock is blocked again")
local before = teleports
check(gameplay_traffic.forceTeleport(12) == "new" and newTeleports == 1 and teleports == before, "allowed call reaches the new function, not the old one")
logged = {}
tick()
tick()
check(not saw("rewrapped"), "no rewrap while our wrapper is still in place")
check(gameplay_traffic.forceTeleport(12) == "new" and newTeleports == 2, "wrapped once: one call, one count")
traffic[1].pursuit.mode = 0
tick()
check(overhaul_integration_services_police.setupRoadblock(77).new == true and newRoadblocks == 1, "after the chase the new roadblock function runs (another car as target)")

-- 15. The bubble mode comes with the police config; leaving restores the respawn direction
local gotMode
package.loaded["rlsmp/bubble"] = {setMode = function(m) gotMode = m end}
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true, bubbleMode = "protect"}))
check(gotMode == "protect" and saw("traffic bubble mode = protect"), "bubbleMode forwarded to the bubble")
check(traffic[10].respawn.spawnDirBias == -1, "bias is set before leaving")
police.onServerLeave()
check(traffic[10].respawn.spawnDirBias == 0.5, "leaving puts the original respawn direction back")


-- No fine in a stolen car ------------------------------------------------------------------------------------------------------------------
local paid, messages = {}, {}
overhaul_career_economy_payment = {pay = function(price, reason) paid[#paid + 1] = {price = price, label = type(reason) == "table" and reason.label or nil} return true end}
ui_message = function(msg) messages[#messages + 1] = msg end
local theftLib = require("rlsmp/lib/theft")
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true, blockRoadblocks = true}))
tick()
check(saw("patched finePay = true"), "the payment function is wrapped")
-- the player's own car (not stolen): the fine is charged as RLS wants
overhaul_career_economy_payment.pay({money = {amount = 300}}, {label = "Police fine", tags = {"fine"}})
ui_message("Citation fine: $300 (1 violations, pursuit score 40)")
check(#paid == 1 and paid[1].label == "Police fine" and messages[1]:find("^Citation fine"), "own car: the police fine is charged and the message stays")
-- the same call in a car we made from a parked car: not charged, the message says why
theftLib.markConverted(playerId)
paid, messages = {}, {}
local result = overhaul_career_economy_payment.pay({money = {amount = 300}}, {label = "Police fine", tags = {"fine"}})
check(#paid == 0 and result == true, "stolen car: the police fine is not charged")
ui_message("Arrest fine: $900 (3 violations, pursuit score 200)")
check(messages[1] == "Arrest: no fine, this car is not registered to you.", "...and the message that follows says so: " .. tostring(messages[1]))
ui_message("Citation fine: $5 (1 violations, pursuit score 1)")
check(messages[2]:find("^Citation fine"), "a later fine message (no skipped fine before it) is left alone")
-- other payments in a stolen car are untouched
overhaul_career_economy_payment.pay({money = {amount = 50}}, {label = "Fuel"})
check(#paid == 1 and paid[1].label == "Fuel", "other payments in a stolen car are charged normally")
-- switched off by the server: the fine is charged again
handlers["rlsmpPoliceConfig"](json.encode({noFineInStolenCar = false}))
paid = {}
overhaul_career_economy_payment.pay({money = {amount = 300}}, {label = "Police fine"})
check(#paid == 1, "noFineInStolenCar = false: the fine is charged in a stolen car too")
handlers["rlsmpPoliceConfig"](json.encode({noFineInStolenCar = true}))
-- works with antiTeleport off too, and not outside multiplayer / the career
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = false}))
paid = {}
overhaul_career_economy_payment.pay({money = {amount = 300}}, {label = "Police fine"})
check(#paid == 0, "antiTeleport = false does not switch the no-fine rule off")
mp = false
overhaul_career_economy_payment.pay({money = {amount = 300}}, {label = "Police fine"})
check(#paid == 1, "outside multiplayer the fine is charged")
mp = true
theftLib.forget(playerId)
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true}))

-- No radar fine in a stolen car or with a fake plate -------------------------------------------------------------------------------------
local tickets = {}
overhaul_career_garage_inventory = {addTicket = function(inv) tickets[#tickets + 1] = inv end}
rlsmp_theft = {hasFakePlate = function(id) return id == 7 end}
handlers["rlsmpPoliceConfig"](json.encode({antiTeleport = true}))
tick()
check(saw("patched radarTicket = true"), "the ticket function is wrapped")
local SP, RL = {label = "ui.career.attributeLog.fineSpeeding", tags = {"fine"}}, {label = "ui.career.attributeLog.fineRedLight"}
local function flash(reason, msg)
  paid, messages, tickets = {}, {}, {}
  local r = overhaul_career_economy_payment.pay({money = {amount = 750}}, reason)
  ui_message(msg)
  overhaul_career_garage_inventory.addTicket(5)
  return r
end
flash(SP, "Traffic Violation (Speeding): \n - \"X\" | Fine 750$")
check(#paid == 1 and messages[1]:find("^Traffic Violation") and #tickets == 1, "own car: the radar fine, message and ticket stay")
theftLib.markConverted(playerId)
local r = flash(SP, "Traffic Violation (Speeding): \n - \"X\" | Fine 750$")
check(#paid == 0 and r == true and #tickets == 0 and messages[1] == "Radar flashed a car that is not yours: no fine.", "stolen car: no radar fine, no ticket, message says so")
check(saw("RLSMP-FINE refused (radar) id=1 reason=stolen"), "...and it is logged")
flash(RL, {txt = "ui.career.speedTrap.redLightMessage"})
check(#paid == 0 and messages[1] == "Radar flashed a car that is not yours: no fine.", "red-light camera too")
overhaul_career_economy_payment.pay({money = {amount = 50}}, {label = "Fuel"})
check(#paid == 1, "other payments are charged")
handlers["rlsmpPoliceConfig"](json.encode({noRadarFineIllegal = false}))
flash(SP, "Traffic Violation (Speeding): x")
check(#paid == 1 and #tickets == 1, "noRadarFineIllegal = false: charged")
handlers["rlsmpPoliceConfig"](json.encode({noRadarFineIllegal = true}))
theftLib.forget(playerId)
playerId = 7
flash(SP, "Traffic Violation (Speeding): x")
check(#paid == 0 and saw("reason=fakeplate"), "fake plate: no radar fine")
-- own car with a fake plate: the chase citation / arrest fine is not charged either (the chase itself is untouched)
paid, messages = {}, {}
local pr = overhaul_career_economy_payment.pay({money = {amount = 300}}, {label = "Police fine", tags = {"fine"}})
ui_message("Arrest fine: $900 (3 violations, pursuit score 200)")
check(#paid == 0 and pr == true and messages[1] == "Arrest: no fine, the plate on this car is not yours.", "fake plate: no chase fine, message says so: " .. tostring(messages[1]))
playerId = 1
paid = {}
overhaul_career_economy_payment.pay({money = {amount = 300}}, {label = "Police fine", tags = {"fine"}})
check(#paid == 1, "own car with the real plate: the chase fine is charged")
flash(SP, "Traffic Violation (Speeding): x")
check(#paid == 1, "back in an own car: charged")

print(string.format("police_client_test: %d checks passed", passed))
