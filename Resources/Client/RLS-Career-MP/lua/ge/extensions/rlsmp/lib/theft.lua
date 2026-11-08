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

-- Exact config of a parked car -------------------------------------------------------------------------------------------------------------
-- "vehicles/<model>/<key>.pc" from a config key (a path stays as it is).
function M.configPath(model, key)
  if type(model) ~= "string" or type(key) ~= "string" or key == "" then return nil end
  if key:find("/", 1, true) or key:match("%.pc$") then return key end
  return "vehicles/" .. model .. "/" .. key .. ".pc"
end

-- What a game object's partConfig is: "path" (a .pc file), "inline" (a JSON text of the whole part config, from a string or a table), or nil.
function M.configSpec(pc, encode)
  if type(pc) == "table" then
    if not encode then return nil end
    local ok, text = pcall(encode, pc)
    if ok and type(text) == "string" and #text > 0 then return "inline", text end
    return nil
  end
  if type(pc) ~= "string" or pc == "" then return nil end
  if pc:match("^%s*[%[{]") then return "inline", pc end
  return "path", pc
end

-- The exact real car behind a parked object, or nil when it cannot be told (a stand-in nobody remembered a pick for).
--   jbeam, partConfig: the object's. intended: {model, config} remembered at group time for a stand-in (or nil).
-- Returns {model, config (path or nil), inline (JSON text or nil), how = "full" | "map"}.
function M.exactOf(jbeam, partConfig, intended, encode)
  if type(jbeam) ~= "string" or jbeam == "" then return nil end
  if jbeam ~= "simple_traffic" then
    local kind, v = M.configSpec(partConfig, encode)
    return {model = jbeam, how = "full", config = kind == "path" and v or nil, inline = kind == "inline" and v or nil}
  end
  if type(intended) == "table" and intended.model and intended.config then
    return {model = intended.model, how = "map", config = M.configPath(intended.model, intended.config)}
  end
  return nil
end

-- Stand-ins our group picks made: stand-in config name -> FIFO of the real {model, config}. The spawned car is matched by its stand-in name
-- (two stand-ins with the same name look the same, so which of them gets which real config does not matter).
local pendingStand, boundStand = {}, {}
local STAND_TTL = 900
function M.noteIntended(stand, model, config, now)
  if type(stand) ~= "string" or type(model) ~= "string" or type(config) ~= "string" then return end
  local q = pendingStand[stand]
  if not q then q = {} pendingStand[stand] = q end
  q[#q + 1] = {model = model, config = config, at = tonumber(now) or 0}
end
-- A stand-in car appeared (vehicle id, its config key): bind the oldest unexpired pick of that name to it. Returns the pick or nil.
function M.bindSpawned(id, stand, now)
  if boundStand[id] then return boundStand[id] end
  local q = type(stand) == "string" and pendingStand[stand]
  now = tonumber(now) or 0
  while q and q[1] do
    local e = table.remove(q, 1)
    if now - e.at <= STAND_TTL then
      boundStand[id] = e
      return e
    end
  end
  return nil
end
function M.intendedFor(id) return boundStand[id] end
function M.forgetIntended(id) if id ~= nil then boundStand[id] = nil end end
function M.clearIntended() pendingStand, boundStand = {}, {} end

-- Colour word from linear 0-1 RGB. The same buckets as lib/plateRead.colorName of the plate-reading feature (police match
-- descriptions by model + colour word, so both must name a colour the same way); rlsmp/theft.lua prefers plateRead's when present.
function M.colorName(r, g, b)
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if not r or not g or not b then return nil end
  local function c01(x) return x < 0 and 0 or (x > 1 and 1 or x) end
  r, g, b = c01(r), c01(g), c01(b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local v, d = mx, mx - mn
  local s = mx == 0 and 0 or d / mx
  if v < 0.15 then return "black" end
  if s < 0.18 then
    if v > 0.85 then return "white" end
    if v > 0.55 then return "silver" end
    return "grey"
  end
  local h
  if mx == r then h = 60 * (((g - b) / d) % 6)
  elseif mx == g then h = 60 * ((b - r) / d + 2)
  else h = 60 * ((r - g) / d + 4) end
  if h < 15 or h >= 345 then return "red" end
  if h < 40 then return v < 0.6 and "brown" or "orange" end
  if h < 70 then return "yellow" end
  if h < 165 then return "green" end
  if h < 200 then return "teal" end
  if h < 255 then return "blue" end
  if h < 290 then return "purple" end
  return "pink"
end

-- Plate text cleaned like the server does (theft.cleanPlate / plateRecords.cleanPlate). nil when unusable.
function M.cleanPlate(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):upper()
  if #s == 0 or #s > 16 or s:find("[%c|]") then return nil end
  return s
end

function M.dist(a, b)
  if not (a and b) then return math.huge end
  local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return M
