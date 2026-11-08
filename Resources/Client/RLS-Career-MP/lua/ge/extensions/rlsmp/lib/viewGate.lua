-- RLS-Career-MP client: pure "is this car too close or in view" gate (no game calls, unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS's camVisible is only a ray from the car to the player: it says nothing about the camera direction, and a walking avatar has a
-- short sight line. Our own removing or replacing of a car (re-roll, swap, stuck recycling) must never happen close to a player
-- or in front of the camera, so this gate is strict: distance first, then a wide cone in front of the camera.

local M = {}

M.NEAR = 120          -- metres: never touch a car closer than this to any player
M.FRONT_RANGE = 500   -- metres: a car in front of the camera up to here counts as seen
M.FRONT_COS = 0.17    -- about 80 degrees to each side of the camera direction

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- pos, focus, camPos: {x,y,z}; camFwd: unit {x,y,z}; others: list of {x,y,z}.
-- Returns nil when the car is far and out of view, else "noFocus" | "near" | "nearOther" | "inView", and the distance to the local player.
function M.reason(pos, focus, camPos, camFwd, others)
  if not (pos and focus) then return "noFocus" end
  local d = len(pos.x - focus.x, pos.y - focus.y, pos.z - focus.z)
  if d < M.NEAR then return "near", d end
  for _, p in ipairs(others or {}) do
    if len(pos.x - p.x, pos.y - p.y, pos.z - p.z) < M.NEAR then return "nearOther", d end
  end
  if camPos and camFwd then
    local vx, vy, vz = pos.x - camPos.x, pos.y - camPos.y, pos.z - camPos.z
    local vd = len(vx, vy, vz)
    if vd < 1 then return "inView", d end
    if vd < M.FRONT_RANGE and (vx * camFwd.x + vy * camFwd.y + vz * camFwd.z) / vd > M.FRONT_COS then return "inView", d end
  end
  return nil, d
end

return M
