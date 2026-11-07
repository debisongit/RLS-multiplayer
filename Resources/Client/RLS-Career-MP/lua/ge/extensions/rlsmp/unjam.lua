-- RLS-Career-MP client extension "rlsmp_unjam": stuck traffic cars (standing still for 30 s, honking) are recycled one by one.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Uses RLS's own recycle: a car in state 'fadeOut' fades away and RLS puts it back somewhere else.
-- Never recycles a car a player can see (local camera) or that is near/visible to another player (rlsmp_bubble),
-- never police, job or pursuit cars (same skip rules as the personalities).

local M = {}

local U = require("rlsmp/lib/unjam")

local enabled = false
local tracker = U.new()
local clock, timer = 0, 0
local CHECK_EVERY = 1

function M.enable(on)
  enabled = on == true
  if not enabled then tracker = U.new() end
end

-- Extensions are found by their global name first (as core.lua does), then by module path.
local function personalities() return rawget(_G, "rlsmp_personalities") or package.loaded["rlsmp/personalities"] end
local function bubble() return rawget(_G, "rlsmp_bubble") or package.loaded["rlsmp/bubble"] end
local function personality() return package.loaded["rlsmp/lib/personality"] end

local function recycle(veh)
  if type(veh.queuedFuncs) == "table" then for k in pairs(veh.queuedFuncs) do veh.queuedFuncs[k] = nil end end
  local obj
  if getObjectByID then obj = getObjectByID(veh.id)
  elseif be and be.getObjectByID then obj = be:getObjectByID(veh.id) end
  if obj and obj.queueLuaCommand then obj:queueLuaCommand("electrics.horn(false)") end
  veh.state = "fadeOut"
end

-- One round. Returns the id that was recycled, if any (for tests and logs).
function M.check()
  if not (gameplay_traffic and gameplay_traffic.getTrafficData) then return nil end
  local P, ps = personality(), personalities()
  if not (P and ps and ps.context) then return nil end
  local ctx = ps.context()
  local b = bubble()
  local candidates = {}
  for id, veh in pairs(gameplay_traffic.getTrafficData()) do
    -- only cars RLS itself would recycle: respawn allowed (a car with respawn off would fade out and stay invisible)
    local respawnOk = veh.enableRespawn ~= false and (type(veh.respawn) ~= "table" or (tonumber(veh.respawn.spawnValue) or 1) > 0)
    if veh.pos and respawnOk and P.skipReason(id, veh, ctx) == nil then
      local stuck = U.seen(tracker, id, veh.pos.x, veh.pos.y, tonumber(veh.speed) or 0, clock)
      if stuck >= U.STUCK_SECONDS then
        local bubbleOff = b and b.isEnabled and not b.isEnabled()   -- without the bubble we do not know where the other players are
        local hidden = veh.camVisible ~= true and not bubbleOff and not (b and b.stayFor and b.stayFor(veh))
        candidates[#candidates + 1] = {id = id, stuck = stuck, hidden = hidden}
      end
    end
  end
  U.sweep(tracker, clock)
  local id = U.pick(tracker, candidates, clock)
  if id then
    recycle(gameplay_traffic.getTrafficData()[id])
    log("I", "RLS-Career-MP", "unjam: recycled stuck traffic car " .. tostring(id))
  end
  return id
end

function M.onUpdate(dtReal)
  if not enabled then return end
  dtReal = dtReal or 0
  clock, timer = clock + dtReal, timer + dtReal
  if timer >= CHECK_EVERY then
    timer = 0
    M.check()
  end
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
