-- RLS-Career-MP client extension "rlsmp_unstuck": "/unstuck" teleports you to the nearest road.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The car keeps its damage (a plain teleport would repair it).
-- Works for whatever you are controlling: a car, or the walking character (a "unicycle" vehicle).
-- Cars land on the road node; walkers land next to the road (up to 3 m toward where they were),
-- so nobody is dropped into a traffic lane on foot.
-- The server only enforces the cooldown. Refused here during police pursuits and while moving fast.

local M = {}

local enabled = false
local MAX_SPEED = 6        -- m/s: this is for being stuck, not for skipping a chase
local WALKER_OFFSET = 3    -- meters

function M.enable(on) enabled = on == true end

local function toast(kind, msg)
  guihooks.trigger("toastrMsg", {type = kind, title = "Unstuck", msg = msg, config = {timeOut = 4000}})
end

local function pursuitActive()
  local pd = overhaul_career_police_playerDriving
  return pd and pd.playerPursuitActive and pd.playerPursuitActive() or false
end

-- Position of the road node nearest to `pos`, or nil.
local function nearestRoadPos(pos)
  local roadName, nodeIdx = map.findClosestRoad(pos)
  if not (roadName and nodeIdx) then return nil end
  local mapData = map.getMap()
  local node = mapData and mapData.nodes and mapData.nodes[nodeIdx]
  return node and node.pos and vec3(node.pos) or nil
end

local function onUnstuck()
  if not enabled then return end
  local veh = getPlayerVehicle(0)
  if not veh then return toast("warning", "Nothing to move.") end
  if pursuitActive() then return toast("warning", "Not available during a police chase.") end
  if veh:getVelocity():length() > MAX_SPEED then return toast("warning", "Slow down first.") end

  local from = veh:getPosition()
  local road = nearestRoadPos(from)
  if not road then return toast("warning", "No road found nearby.") end

  local target = road
  if veh.jbeam == "unicycle" then
    local away = from - road
    local len = away:length()
    if len > 0.01 then target = road + away * (math.min(WALKER_OFFSET, len) / len) end
  end

  local dir = veh:getDirectionVector()
  local rot = quatFromDir(vec3(dir.x, dir.y, 0), vec3(0, 0, 1))
  -- Police must not see this jump as speeding or a crash.
  local police = overhaul_integration_services_police
  if police and police.ignoreSpeedingAfterTeleport then pcall(police.ignoreSpeedingAfterTeleport, 5) end
  -- Arguments: vehicle, position, rotation, checkOnlyStatics, visibilityPoint, removeTraffic, centeredPosition, resetVehicle.
  -- resetVehicle must be an explicit false: when left out the game resets (repairs) the car, which would make /unstuck a free repair.
  local ok, result = pcall(spawn.safeTeleport, veh, target, rot, nil, nil, nil, true, false)
  if not ok or result == false then return toast("error", "Teleport failed.") end
  toast("info", "Moved to the nearest road.")
end

function M.onExtensionLoaded()
  require("rlsmp/lib/net").on("rlsmpUnstuck", onUnstuck)
end

M._onUnstuck = onUnstuck
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
