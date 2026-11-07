-- RLS-Career-MP client extension "rlsmp_personalities": smart traffic driver personalities.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Each AI traffic car of THIS game gets one personality the first time it is seen active: normal (left
-- to RLS), slow, aggressive, racer or drunk, using the weights from the server (`rlsmpSmartTraffic`).
-- We only change the game's own AI settings (aggression, speed cap, lane keeping), never steer.
-- Settings are re-sent every ~20 s, at once after RLS re-spawns the car, when the road's speed limit
-- changes, and on every drunk "event" (weave, speed wobble, hard brake). No horn, lights or markers:
-- players have to spot bad drivers by how they drive. BeamMP syncs the result to the other players.
--
-- Left alone: police, suspects and any role but RLS's "standard" civilian, cars in a pursuit, the
-- player's car, other players' cars, parked cars, the player's own garage cars, cars RLS locks for a
-- job (vehicle policy "roleLocked") and cars that are not active. When a car stops being ours for a
-- reason other than a pursuit / role change (RLS then sets its AI itself), we put RLS's traffic
-- values back. Turning the feature off (or leaving the career / server) puts every car back.
--
-- Police reaction (policeReact): a racer or drunk that is fast or weaving within 80 m of an AI police
-- car gets an RLS pursuit, at most one per 60 s, never while the player is chased or another chase runs.
--
-- Active only in a multiplayer session, while the RLS career is active, after the server's config arrived.
-- Pure logic: lib/personality.lua (tests: tests/personalities_client_test.lua).

local M = {}

local net = require("rlsmp/lib/net")
local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")
local P = require("rlsmp/lib/personality")

local STEP = 0.5            -- seconds between checks

local enabled = false       -- core.lua: career is active on the server
local config                -- nil until the server speaks: {enabled, mix, policeReact}
local now, timer = 0, 0
local cars = {}             -- vehicle id -> cache entry (lib/personality newEntry)
local limiter = P.newLimiter()
local rnd = math.random
local policyModule          -- RLS overhaul/lib/vehicles/policy, if it can be loaded

-- Sends one AI command string to a vehicle (BeamNG obj:queueLuaCommand). Swapped out by tests.
local function defaultSend(id, cmd)
  local obj = (getObjectByID and getObjectByID(id)) or (be and be.getObjectByID and be:getObjectByID(id))
  if obj then obj:queueLuaCommand(cmd) return true end
  return false
end
local send = defaultSend

local function isMP() return mp.isMPSession() end
local function careerActive() return overhaul_career_career ~= nil and overhaul_career_career.isActive() end

local function active()
  return enabled and config ~= nil and config.enabled and isMP() and careerActive()
end

local function playerChased()
  return rlsmp_police ~= nil and rlsmp_police.isPursuit ~= nil and rlsmp_police.isPursuit() == true
end

local function trafficData()
  return gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData() or {}
end

local function baseAggression()
  local vars = gameplay_traffic and gameplay_traffic.getTrafficVars and gameplay_traffic.getTrafficVars()
  return vars and tonumber(vars.baseAggression) or nil
end

local function policy()
  if policyModule == nil then
    local ok, mod = pcall(require, "overhaul/lib/vehicles/policy")
    policyModule = (ok and type(mod) == "table" and type(mod.query) == "function") and mod or false
  end
  return policyModule or nil
end

-- The facts skipReason needs, gathered once per check.
local function context()
  local ctx = {remote = mp.remoteSet(), parked = {}}
  ctx.playerId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) or nil
  if gameplay_parking and gameplay_parking.getParkedCarsList then
    for _, id in ipairs(gameplay_parking.getParkedCarsList(true) or {}) do ctx.parked[id] = true end
  end
  if be and be.getObjectActive then ctx.objectActive = function(id) return be:getObjectActive(id) end end
  local inv = overhaul_career_garage_inventory
  if inv and inv.getInventoryIdFromVehicleId then
    ctx.owned = function(id) return inv.getInventoryIdFromVehicleId(id) ~= nil end
  end
  local pol = policy()
  if pol then
    ctx.locked = function(id, veh)
      local ok, locked = pcall(pol.query, "roleLocked", id, veh)
      if ok and locked then return true end
      ok, locked = pcall(pol.query, "pursuitImmune", id, veh)
      return ok and locked == true
    end
  end
  return ctx
end

local function restore(id, e)
  if e.drunk then P.drunkSober(e.drunk) end
  if e.touched then
    send(id, P.restoreCommand(baseAggression()))
    p3.count("smart: cars restored")
  end
  e.touched, e.eligible = false, false
end

-- Put every car we changed back to RLS's traffic values (skips cars RLS has taken over meanwhile).
local function restoreAll()
  local traffic = trafficData()
  for id, e in pairs(cars) do
    local veh = traffic[id]
    if veh and e.touched then
      local reason = P.skipReason(id, veh, {})
      if not P.rlsTakesOver(reason) and veh.isAi == true then restore(id, e) end
    end
  end
  cars = {}
end

-- UNVERIFIED IN-GAME. Asks RLS to start a pursuit on an AI car, with ONE police unit, the same call shape
-- RLS's own police service uses when a pursuit starts (integration/services/police.lua onUpdate:
-- setPursuitMode(level, vehId, pursuit.sight.policeId)). Vanilla gameplay_police.setPursuitMode is forwarded
-- to RLS's by integration/ownedServices.lua. Returns true if a call was made.
function M.startPursuit(targetId, policeId)
  local svc = overhaul_integration_services_police
  local fn = svc and svc.setPursuitMode
  if type(fn) ~= "function" and gameplay_police and type(gameplay_police.setPursuitMode) == "function" then
    fn = gameplay_police.setPursuitMode
  end
  if type(fn) ~= "function" then return false end
  local ok, problem = pcall(fn, 1, targetId, policeId)
  if not ok then p3.log("W", "smart: setPursuitMode failed: " .. tostring(problem)) end
  return ok
end

local function vehicleSpeed(veh)
  if tonumber(veh.speed) then return veh.speed end
  local v = veh.vel
  if v and tonumber(v.x) then return math.sqrt(v.x * v.x + v.y * v.y + (v.z or 0) * (v.z or 0)) end
  return 0
end

-- AI police that could react (not the player's own police car, not disabled, not busy with a target).
local function policeUnits(traffic, ctx)
  local units = {}
  for id, veh in pairs(traffic) do
    if type(veh) == "table" and type(veh.role) == "table" and veh.role.name == "police" then
      local usable = veh.isAi == true and id ~= ctx.playerId and veh.role.state ~= "disabled"
        and (veh.role.targetId == nil or veh.role.targetId == 0)
        and (not ctx.objectActive or ctx.objectActive(id))
      units[#units + 1] = {id = id, pos = veh.pos, usable = usable}
    end
  end
  return units
end

local function anyPursuit(traffic)
  for _, veh in pairs(traffic) do
    if type(veh) == "table" then
      if type(veh.pursuit) == "table" and (tonumber(veh.pursuit.mode) or 0) ~= 0 then return true end
      if type(veh.queuedFuncs) == "table" and veh.queuedFuncs.pursuitStart then return true end
    end
  end
  return false
end

local function policeReact(traffic, ctx, suspects)
  if #suspects == 0 then return end
  local ok, why = P.mayStart(limiter, now, {playerChased = playerChased(), anyPursuit = anyPursuit(traffic)})
  if not ok then p3.count("smart: police reaction held (" .. why .. ")") return end
  local units = policeUnits(traffic, ctx)
  for _, s in ipairs(suspects) do
    local veh = traffic[s.id]
    local policeId, dist = P.nearestPolice(veh.pos, units, P.POLICE.radius)
    if policeId then
      P.noteStart(limiter, now)
      local called = M.startPursuit(s.id, policeId)
      p3.count(called and "smart: AI pursuits started" or "smart: AI pursuits detected (no API)")
      p3.log("I", string.format("smart: %s id=%s seen by police id=%s at %.0fm speed=%.1f -> pursuit %s",
        s.name, tostring(s.id), tostring(policeId), dist, vehicleSpeed(veh), called and "requested" or "NOT started (no API)"))
      cars[s.id].hits = 0
      return
    end
  end
end

local function step()
  if not active() then
    if next(cars) then restoreAll() end
    return
  end
  local traffic = trafficData()
  local ctx = context()
  for id, e in pairs(cars) do
    if traffic[id] == nil then cars[id] = nil end   -- car is gone
  end
  local suspects = {}
  for id, veh in pairs(traffic) do
    local reason = P.skipReason(id, veh, ctx)
    local e = cars[id]
    if reason then
      if e and e.eligible then
        if P.rlsTakesOver(reason) then
          if e.drunk then P.drunkSober(e.drunk) end
          e.eligible, e.touched = false, false
        else
          restore(id, e)
        end
        p3.count("smart: handed back (" .. reason .. ")")
      end
    else
      if not e then
        e = P.newEntry(P.pick(config.mix, rnd()), now, rnd)
        cars[id] = e
        p3.count("smart: assigned " .. e.name)
        if e.name ~= "normal" then p3.log("I", string.format("smart: car id=%s is %s", tostring(id), e.name)) end
      end
      local cmd = P.schedule(e, veh, now, rnd)
      if cmd then
        send(id, cmd)
        p3.count("smart: commands sent")
      end
      if config.policeReact and (e.name == "racer" or e.name == "drunk") then
        local limit = type(veh.tracking) == "table" and tonumber(veh.tracking.speedLimit) or nil
        if P.suspicious(e, vehicleSpeed(veh), limit, now) then e.hits = e.hits + 1 else e.hits = 0 end
        if e.hits >= P.POLICE.hits and veh.pos then suspects[#suspects + 1] = {id = id, name = e.name} end
      end
    end
  end
  if config.policeReact then policeReact(traffic, ctx, suspects) end
end

function M.onUpdate(dtReal, dtSim)
  local dt = tonumber(dtSim) or tonumber(dtReal) or 0
  now = now + dt
  timer = timer + dt
  if timer < STEP then return end
  timer = 0
  step()
end

-- core.lua: career active on the server (true) / closed or left (false).
function M.enable(on)
  enabled = on == true
  if not enabled then restoreAll() end
end

-- RLS hook (extensions.hook from trafficVehicle:setRole): a car got a new role. Re-check it at the next step;
-- if it is a standard civilian again its settings are sent at once.
function M.onTrafficAction(id, action)
  if action == "changeRole" and cars[id] then
    cars[id].eligible = false
    if cars[id].drunk then P.drunkSober(cars[id].drunk) end
  end
end

local function onConfig(data)
  local was = config and config.enabled
  config = {
    enabled = data.enabled == true,
    mix = P.sanitizeMix(data.mix),
    policeReact = data.policeReact == true,
  }
  local m = config.mix
  p3.log("I", string.format("smart: config received enabled=%s policeReact=%s mix normal=%s slow=%s aggressive=%s racer=%s drunk=%s",
    tostring(config.enabled), tostring(config.policeReact), m.normal, m.slow, m.aggressive, m.racer, m.drunk))
  if was and not config.enabled then restoreAll() end
end

function M.onServerLeave()
  restoreAll()
  config, enabled, now, timer = nil, false, 0, 0
  limiter = P.newLimiter()
end

function M.getConfig() return config end
function M.getCars() return cars end
function M.report() return p3.report() end
-- Console helper: how many cars have each personality right now.
function M.census()
  local n = {}
  for _, e in pairs(cars) do n[e.name] = (n[e.name] or 0) + 1 end
  local parts = {}
  for _, name in ipairs(P.ORDER) do parts[#parts + 1] = name .. "=" .. tostring(n[name] or 0) end
  local line = "smart: personalities now " .. table.concat(parts, " ")
  p3.log("I", line)
  return line
end

function M.onExtensionLoaded()
  net.on("rlsmpSmartTraffic", onConfig)
  p3.log("I", "rlsmp_personalities loaded")
  p3.probe("smart: RLS police setPursuitMode is a function",
    overhaul_integration_services_police ~= nil and type(overhaul_integration_services_police.setPursuitMode) == "function")
  p3.probe("smart: RLS vehicle policy loadable", policy() ~= nil)
end

-- Test hooks.
M._onConfig = onConfig
M._step = step
M._setSend = function(fn) send = fn or defaultSend end
M._setRandom = function(fn) rnd = fn or math.random end
M._now = function() return now end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
