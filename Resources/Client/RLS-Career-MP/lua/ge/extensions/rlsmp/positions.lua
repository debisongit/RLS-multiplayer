-- RLS-Career-MP client extension "rlsmp_positions": tells the server where we are (groundwork for server-directed traffic).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Every 2 s while the career runs: rlsmpPos {x, y, z, speed, chased} for whatever the player controls (a car, or the
-- walking character, which is also a vehicle). Skipped while standing nearly still, but sent at least every 10 s,
-- and sent right away when a police chase starts or ends. Server side: server/positions.lua.

local M = {}

local net = require("rlsmp/lib/net")

local EVERY = 2          -- seconds between checks
local KEEPALIVE = 10     -- send at least this often, even when standing still
local MIN_MOVE = 5       -- meters that count as "moved"

local enabled = false
local timer, sinceSent = 0, math.huge
local last                -- {x, y, z, chased} of the last report

function M.enable(on)
  enabled = on == true
  timer, sinceSent, last = 0, math.huge, nil
end

-- Send a report on the next frame even when standing still (rlsmp_market calls this at a drop spot so the server's
-- copy of our position is fresh for the automatic pickup).
function M.reportNow()
  if enabled then timer, last = EVERY, nil end
end

local function chased()
  return rlsmp_police ~= nil and rlsmp_police.isPursuit ~= nil and rlsmp_police.isPursuit() == true
end

local function round(v) return math.floor(v * 10 + 0.5) / 10 end

local function report()
  local veh = getPlayerVehicle(0)
  local p = veh and veh:getPosition()
  if not p then return end
  local vel = veh.getVelocity and veh:getVelocity()
  local speed = vel and vel:length() or 0
  local c = chased()
  if last and sinceSent < KEEPALIVE - 0.1 and c == last.chased then   -- 0.1: frame times do not add up exactly
    local dx, dy, dz = p.x - last.x, p.y - last.y, p.z - last.z
    if dx * dx + dy * dy + dz * dz < MIN_MOVE * MIN_MOVE then return end
  end
  net.send("rlsmpPos", {x = round(p.x), y = round(p.y), z = round(p.z), speed = round(speed), chased = c})
  last, sinceSent = {x = p.x, y = p.y, z = p.z, chased = c}, 0
end

function M.onUpdate(dtReal)
  if not enabled then return end
  dtReal = dtReal or 0
  timer, sinceSent = timer + dtReal, sinceSent + dtReal
  -- A chase starting or ending goes out at once (but not within 1.5 s of the last report: the server drops reports under 1 s apart).
  if last and sinceSent >= 1.5 and chased() ~= last.chased then timer = EVERY end
  if timer < EVERY then return end
  timer = 0
  report()
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
