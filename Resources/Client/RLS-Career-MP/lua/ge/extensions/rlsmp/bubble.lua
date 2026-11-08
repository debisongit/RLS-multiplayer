-- RLS-Career-MP client extension "rlsmp_bubble": traffic never vanishes in front of another player.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS only looks at the LOCAL player when it decides to fade a traffic car out and reuse it (tryRespawn).
-- In multiplayer a car next to your friend could vanish because it is far from you. This wraps tryRespawn:
-- a car may only be recycled when it is more than BUBBLE metres from EVERY other player and none of them has a clear line to it.
-- Other players' own traffic cars (hidden name tags) do not count, only the players themselves.
--
-- Modes (server setting police.bubbleMode, default "original"):
--  * "original": RLS's own distances stay. A car is only kept while another player is closer than the car's OWN active radius
--    (what RLS would use for the local player) AND has a clear line to it. Nothing else changes where cars vanish or appear.
--  * "protect": the old strict rule: kept while within BUBBLE metres of another player, or a clear line up to SIGHT metres.
--  * "off": no protection (RLS decides alone).
-- Police units tied to a chase (rlsmpHold, set by rlsmp/police.lua) are never recycled in any mode.
-- M.stayFor (used by unjam and the model swap, our own recycling) always uses the strict rule.

local M = {}

local mp = require("rlsmp/lib/mp")
local p3 = require("rlsmp/lib/p3")
local G = require("rlsmp/lib/viewGate")
local W = require("rlsmp/lib/respawnWatch")

local BUBBLE = 450
local SIGHT = 1000
local DEFAULT_RADIUS = 200   -- used when a car has no active radius (should not happen)
local MODES = {original = true, protect = true, off = true}
local enabled = false
local mode = "original"

function M.enable(on) enabled = on == true end
function M.isEnabled() return enabled end
function M.setMode(m)
  if MODES[m] then mode = m end
end
function M.getMode() return mode end

-- Positions of the other players' cars (and walking characters).
local function playerPositions()
  local list = {}
  if not (MPVehicleGE and MPVehicleGE.getVehicles and map and map.objects) then return list end
  for _, v in pairs(MPVehicleGE.getVehicles()) do
    local id = v.gameVehicleID
    if v.isLocal ~= true and id and id ~= -1 and v.hideNametag ~= true then
      local obj = map.objects[id]
      if obj and obj.pos then list[#list + 1] = obj.pos end
    end
  end
  return list
end

-- true = keep this car where it is. `canSee(a, b)` is true when nothing static is between the points.
function M.mustStay(carPos, players, canSee)
  local limit = BUBBLE * BUBBLE
  for _, p in ipairs(players) do
    if carPos:squaredDistance(p) < limit then return true end
    -- line of sight only matters up to about a kilometre (a ray cast per player is not free)
    if canSee and carPos:squaredDistance(p) < SIGHT * SIGHT and canSee(p, carPos) then return true end
  end
  return false
end

-- "original" mode: keep the car only if another player is inside its own active radius and has a clear line to it.
function M.mustStayOriginal(carPos, radius, players, canSee)
  local limit = (tonumber(radius) or DEFAULT_RADIUS) ^ 2
  for _, p in ipairs(players) do
    if carPos:squaredDistance(p) < limit and (not canSee or canSee(p, carPos)) then return true end
  end
  return false
end

-- For other modules: should this traffic car stay where it is because another player is near or can see it?
function M.stayFor(car)
  if not enabled or not mp.isMPSession() or not car or not car.pos then return false end
  local players = playerPositions()
  if #players == 0 then return false end
  return M.mustStay(car.pos, players, car.checkRayCast and function(a, b) return car:checkRayCast(a, b) end or nil)
end

local function xyz(v) return v and v.x and {x = v.x, y = v.y, z = v.z} or nil end

-- Where the local player is (the walking avatar or the car), for the strict gate and the distance log.
local function focusPos(veh)
  local pv = be and be.getPlayerVehicle and be:getPlayerVehicle(0)
  local p = pv and pv.getPosition and pv:getPosition()
  return xyz(p) or (veh and veh.focus and xyz(veh.focus.pos))
end

-- For our own recyclers (re-roll, swap, unjam): nil = the car is far from every player and out of the camera's view; else why not.
-- Also writes one line to the log with the distance when it says no for a reason other than "near".
function M.viewReason(veh)
  if not veh or not veh.pos then return "noPos" end
  local cam, fwd
  if core_camera and core_camera.getPosition and core_camera.getForward then
    local ok1, c = pcall(core_camera.getPosition)
    local ok2, f = pcall(core_camera.getForward)
    cam, fwd = ok1 and xyz(c) or nil, ok2 and xyz(f) or nil
  end
  local others = {}
  for _, p in ipairs(playerPositions()) do others[#others + 1] = xyz(p) end
  local why, d = G.reason(xyz(veh.pos), focusPos(veh), cam, fwd, others)
  if why then p3.count("view gate: " .. why) end
  return why, d
end

local wrappers = setmetatable({}, {__mode = "k"})   -- class -> the wrapper we installed

local function anyTrafficClass()
  if not (gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  for _, veh in pairs(gameplay_traffic.getTrafficData()) do
    local class = getmetatable(veh)
    if type(class) == "table" then return class end
  end
end

-- Runs every frame: RLS may replace the method when its services restart, then we wrap the new one.
function M.install()
  local class = anyTrafficClass()
  if not class or type(class.tryRespawn) ~= "function" then return false end
  if wrappers[class] and class.tryRespawn == wrappers[class] then return true end
  local original = class.tryRespawn
  local wrapper
  wrapper = function(self, ...)
    if enabled and self.rlsmpHold then p3.count("bubble: police held") return end   -- a police unit tied to the player's chase (rlsmp/police.lua) must not be recycled
    -- RLS's own cheap gates first: nothing to decide unless RLS is about to recycle this car
    local aboutToGo = self.enableRespawn and type(self.respawn) == "table" and self.focusDist and (tonumber(self.respawn.finalRadius) or math.huge) < self.focusDist
    if enabled and aboutToGo and mode ~= "off" and mp.isMPSession() and self.pos then
      local players = playerPositions()
      if #players > 0 then
        local canSee = self.checkRayCast and function(a, b) return self:checkRayCast(a, b) end or nil
        local keep
        if mode == "protect" then keep = M.mustStay(self.pos, players, canSee)
        else keep = M.mustStayOriginal(self.pos, self.respawn.finalRadius, players, canSee) end
        if keep then p3.count("bubble: kept for another player") return end
      end
    end
    p3.count("bubble: passed to RLS")
    return original(self, ...)
  end
  wrappers[class] = wrapper
  class.tryRespawn = wrapper
  return true
end

-- Respawn / fade-out census for the "distance:" log (every 30 s). Read only.
local watch = W.new()
local clock, logTimer = 0, 0
function M.onUpdate(dtReal)
  M.install()
  dtReal = dtReal or 0
  clock, logTimer = clock + dtReal, logTimer + dtReal
  if not (gameplay_traffic and gameplay_traffic.getTrafficData and mp.isMPSession()) then return end
  local data = gameplay_traffic.getTrafficData()
  local fp = focusPos(nil)
  local cam, fwd
  if core_camera and core_camera.getPosition and core_camera.getForward then
    local ok1, c = pcall(core_camera.getPosition)
    local ok2, f = pcall(core_camera.getForward)
    cam, fwd = ok1 and xyz(c) or nil, ok2 and xyz(f) or nil
  end
  local alive, amount, radius = {}, 0, nil
  for id, veh in pairs(data) do
    alive[id] = true
    if veh.isAi and veh.state ~= "queued" then amount = amount + 1 end
    local vp = xyz(veh.pos)
    local dist = vp and fp and math.sqrt((vp.x - fp.x) ^ 2 + (vp.y - fp.y) ^ 2 + (vp.z - fp.z) ^ 2) or nil
    local fr = type(veh.respawn) == "table" and tonumber(veh.respawn.finalRadius) or nil
    if fr and fr < 1e5 and (not radius or fr > radius) then radius = fr end
    local ev = W.observe(watch, id, veh.respawnCount, veh.state, dist, clock)
    if ev then
      local why = vp and fp and G.reason(vp, fp, cam, fwd, nil)
      local line = string.format("%s car %s dist=%s camVisible=%s view=%s radius=%s walking=%s", ev, tostring(id), dist and string.format("%.0f", dist) or "?",
        tostring(veh.camVisible), tostring(why or "out"), fr and string.format("%.0f", fr) or "?", tostring(gameplay_walk ~= nil and gameplay_walk.isWalking and gameplay_walk.isWalking() or false))
      p3.count("respawn watch: " .. ev)
      if ev == "fadeout" and dist and dist < G.NEAR then p3.log("W", "despawn near player: " .. line) else p3.log("D", line) end
    end
  end
  W.forget(watch, alive)
  if logTimer >= 30 then
    logTimer = 0
    local vars = gameplay_traffic.getTrafficVars and gameplay_traffic.getTrafficVars() or {}
    local n, nearest = W.summary(watch, clock)
    p3.log("I", string.format("distance: walking=%s radius=%s activeAmount=%s cars=%d respawns/min=%d nearestRespawn=%s spawnValue=%s bubble=%s",
      tostring(gameplay_walk ~= nil and gameplay_walk.isWalking and gameplay_walk.isWalking() or false), radius and string.format("%.0f", radius) or "?",
      tostring(vars.activeAmount), amount, n, nearest and string.format("%.0f", nearest) or "none", tostring(vars.spawnValue), mode))
  end
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
