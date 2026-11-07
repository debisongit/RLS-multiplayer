-- RLS-Career-MP client: car theft helpers (plain module, no game calls; see rlsmp/theft.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- * stealable(seed, period, perMille, pos): the same answer in every game for a car at the same spot (the server hands out
--   seed and period; position is rounded to a CELL metre grid, x and y only, because z moves with the suspension).
-- * the converted set: game vehicle ids of parked cars WE turned into driveable cars. vehicleGuard lets the player into
--   exactly these (and nothing else it would refuse). Ids are removed when the car is destroyed (the game reuses ids).
-- * realModel(model, partConfig): RLS's simplified traffic cars (jbeam simple_traffic) carry the real model in their
--   config file name (RLS trafficVehicle.lua reads it the same way).
-- * colorName(r, g, b): a plain colour word for police descriptions (plateRecords wants letters only).

local M = {}

local bit = bit or require("bit")

M.CELL = 4

-- FNV-1a, 32 bit, exact in LuaJIT doubles (h * prime is split so it never passes 2^53).
local function fnv(str)
  local h = 2166136261
  for i = 1, #str do
    h = bit.bxor(h, str:byte(i))
    h = bit.tobit(bit.lshift(h, 24) + (h % 4294967296) * 403)
  end
  return h % 4294967296
end
M.hash = fnv

function M.cellOf(pos)
  if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then return nil end
  return math.floor(pos.x / M.CELL), math.floor(pos.y / M.CELL)
end

-- A key that changes when the car moves to another spot (RLS re-parks its pool cars) or the period changes.
function M.spotKey(period, pos)
  local cx, cy = M.cellOf(pos)
  if not cx then return nil end
  return string.format("%d:%d:%d", math.floor(tonumber(period) or 0), cx, cy)
end

function M.stealable(seed, period, perMille, pos)
  local cx, cy = M.cellOf(pos)
  if not cx or type(seed) ~= "number" or type(perMille) ~= "number" or perMille <= 0 then return false end
  local h = fnv(string.format("%d|%d|%d|%d", math.floor(seed), math.floor(tonumber(period) or 0), cx, cy))
  return h % 1000 < perMille
end

-- Converted cars ------------------------------------------------------------------------------------
local converted = {}
function M.markConverted(id) if type(id) == "number" then converted[id] = true end end
function M.isConverted(id) return id ~= nil and converted[id] == true end
function M.forget(id) if id ~= nil then converted[id] = nil end end
function M.clearConverted() converted = {} end
function M.convertedIds()
  local out = {}
  for id in pairs(converted) do out[#out + 1] = id end
  table.sort(out)
  return out
end

-- "vehicles/etk800/854t_A.pc" -> "854t_A"
function M.configKey(partConfig)
  if type(partConfig) ~= "string" then return nil end
  return partConfig:match("([^/\\]+)%.pc$")
end

-- The model and config to spawn for a parked car. Simplified cars: model from the config name, config left to the game
-- (configKey stays nil unless the rest of the name is a real config the caller can check).
function M.realModel(model, partConfig)
  if model ~= "simple_traffic" then return model, partConfig, M.configKey(partConfig) end
  local key = M.configKey(partConfig)
  local real = key and key:match("^(%w+)")
  if not real or real == "" then return nil end
  local rest = key:match("^%w+_(.+)$")
  return real, nil, rest
end

-- Colour word from linear 0-1 (or 0-255) RGB.
function M.colorName(r, g, b)
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if not (r and g and b) then return nil end
  if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local l = (mx + mn) / 2
  local d = mx - mn
  if d < 0.08 then
    if l > 0.8 then return "white" elseif l > 0.45 then return "silver" elseif l > 0.18 then return "grey" else return "black" end
  end
  local h
  if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
  h = h * 60
  if l < 0.12 then return "black" end
  if h < 15 or h >= 345 then return (l < 0.3) and "maroon" or "red" end
  if h < 40 then return (l < 0.35) and "brown" or "orange" end
  if h < 70 then return "yellow" end
  if h < 165 then return "green" end
  if h < 200 then return "teal" end
  if h < 255 then return "blue" end
  if h < 290 then return "purple" end
  return "pink"
end

function M.dist(a, b)
  if not (a and b) then return math.huge end
  local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return M
