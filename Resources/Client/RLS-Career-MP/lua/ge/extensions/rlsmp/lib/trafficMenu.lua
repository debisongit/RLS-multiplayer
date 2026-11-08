-- RLS-Career-MP client: pure logic for the in-game traffic settings menu (no game calls, so it can be unit tested).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The menu edits a copy of the server's settings. Every edit is remembered as a "pending" change (path -> value) until Apply sends them as one
-- patch {set = {{p = path, v = value}}, rm = {path}}. The SERVER decides what may be changed and to what range (server/trafficAdmin.lua); this file only keeps
-- the menu tidy: values shown, changes counted, the patch built, the real car models and Types listed.

local M = {}

M.SECTIONS = {
  {id = "cars", label = "Cars"},
  {id = "where", label = "Where & when"},
  {id = "behaviour", label = "Behaviour"},
  {id = "amount", label = "Amount"},
  {id = "swap", label = "Swapping"},
  {id = "weather", label = "Weather"},
  {id = "police", label = "Police"},
  {id = "theft", label = "Theft"},
  {id = "fence", label = "Fence"},
  {id = "market", label = "Market"},
}
M.ZONES = {{id = "city", label = "City roads"}, {id = "main", label = "Main roads"}, {id = "highway", label = "Highways"}}
M.TIMES = {{id = "any", label = "Any time"}, {id = "day", label = "Day"}, {id = "night", label = "Night"}}
M.PERSONALITIES = {{"normal", "Normal drivers"}, {"slow", "Slow drivers"}, {"aggressive", "Aggressive drivers"}, {"racer", "Street racers"}, {"drunk", "Drunk drivers"}}
M.CONDITIONS = {{"clear", "Clear"}, {"partlyCloudy", "Partly cloudy"}, {"overcast", "Overcast"}, {"drizzle", "Drizzle"}, {"rain", "Rain"}, {"storm", "Storm"}}

local function key(path) return table.concat(path, ".") end

-- Same rule as the server: short names of plain characters (the server rejects anything else).
function M.goodName(name)
  return type(name) == "string" and #name >= 1 and #name <= 64 and name:match("^[%w_%- ]+$") ~= nil
end

function M.new()
  return {snap = nil, pending = {}, removed = {}, status = "", statusBad = false, section = "cars", zone = "city", time = "any", search = "", modName = ""}
end

local function lookup(snap, path)
  local v = snap
  for _, seg in ipairs(path) do
    if type(v) ~= "table" then return nil end
    v = v[seg]
  end
  return v
end

-- The settings sent by the server. Pending changes that now equal the server's values are dropped.
function M.setSnapshot(st, snap)
  st.snap = snap
  for k, p in pairs(st.pending) do
    if lookup(snap, p.path) == p.value then st.pending[k] = nil end
  end
  for k, path in pairs(st.removed) do
    if lookup(snap, path) == nil then st.removed[k] = nil end
  end
end

-- The value to show: the pending one, else the server's, else `default`. A pending removal shows the default.
function M.get(st, path, default)
  local k = key(path)
  if st.removed[k] then return default end
  local p = st.pending[k]
  if p then return p.value end
  local v = st.snap and lookup(st.snap, path)
  if v == nil then return default end
  return v
end

-- True when the server has an entry for this path (a weight someone set), whatever is pending.
function M.isSet(st, path)
  local k = key(path)
  if st.removed[k] then return false end
  if st.pending[k] then return true end
  return st.snap ~= nil and lookup(st.snap, path) ~= nil
end

function M.set(st, path, value)
  local k = key(path)
  st.removed[k] = nil
  if st.snap and lookup(st.snap, path) == value then
    st.pending[k] = nil
  else
    st.pending[k] = {path = path, value = value}
  end
end

-- Reset a weight to "not set" (default). Only meaningful when the server has an entry or one is pending.
function M.remove(st, path)
  local k = key(path)
  st.pending[k] = nil
  if st.snap and lookup(st.snap, path) ~= nil then st.removed[k] = path end
end

function M.dirty(st)
  local n = 0
  for _ in pairs(st.pending) do n = n + 1 end
  for _ in pairs(st.removed) do n = n + 1 end
  return n
end

function M.revert(st) st.pending, st.removed = {}, {} end

-- The patch for the server, in a steady order.
function M.patch(st)
  local set, rm, keys = {}, {}, {}
  for k in pairs(st.pending) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do set[#set + 1] = {p = st.pending[k].path, v = st.pending[k].value} end
  keys = {}
  for k in pairs(st.removed) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do rm[#rm + 1] = st.removed[k] end
  return {set = set, rm = rm}
end

-- The server's answer to an Apply: {applied, rejected = {{p, why}}, saved}. Applied changes leave the pending list, rejected ones stay.
function M.applyResult(st, res)
  res = type(res) == "table" and res or {}
  local rejected = {}
  for _, r in ipairs(res.rejected or {}) do
    if type(r.p) == "table" then rejected[key(r.p)] = true end
  end
  local kept = 0
  for k in pairs(st.pending) do
    if rejected[k] then kept = kept + 1 else st.pending[k] = nil end
  end
  for k in pairs(st.removed) do
    if rejected[k] then kept = kept + 1 else st.removed[k] = nil end
  end
  local bad = #(res.rejected or {})
  if bad > 0 then
    local first = res.rejected[1]
    st.status = string.format("%d applied, %d refused (%s: %s)", tonumber(res.applied) or 0, bad,
      type(first.p) == "table" and key(first.p) or "?", tostring(first.why))
    st.statusBad = true
  elseif res.saved == false then
    st.status = string.format("%d applied but NOT saved to config.json (check the server log)", tonumber(res.applied) or 0)
    st.statusBad = true
  else
    st.status = string.format("%d setting%s applied and saved", tonumber(res.applied) or 0, (tonumber(res.applied) or 0) == 1 and "" or "s")
    st.statusBad = false
  end
  return kept
end

-- The game's cars ------------------------------------------------------------------------------------------------------------------------------------------
local function isVehicle(info)
  local t = string.lower(tostring(info.Type or info.type or ""))
  if t:find("prop", 1, true) or t:find("trailer", 1, true) or t:find("device", 1, true) then return false end
  return true
end

-- All car Types of the model list, with how many models each has: {{type = "Car", count = 40}, ...} sorted by name.
function M.types(modelList)
  local counts = {}
  for name, info in pairs(type(modelList) == "table" and modelList.models or {}) do
    if type(info) == "table" and isVehicle(info) then
      local t = info.Type or info.type
      if type(t) == "string" and M.goodName(t) then counts[t] = (counts[t] or 0) + 1 end
    end
  end
  local out = {}
  for t, n in pairs(counts) do out[#out + 1] = {type = t, count = n} end
  table.sort(out, function(a, b) return a.type < b.type end)
  return out
end

-- Models whose name or label contains `filter` (not case sensitive), sorted by label: {{key = "pickup", label = "Gavril D-Series", type = "Truck"}}.
-- Names the server would refuse are left out. At most `limit` rows.
function M.models(modelList, filter, limit)
  filter = string.lower(tostring(filter or ""))
  limit = limit or 200
  local out = {}
  for name, info in pairs(type(modelList) == "table" and modelList.models or {}) do
    if type(info) == "table" and isVehicle(info) and M.goodName(name) then
      local brand, label = tostring(info.Brand or info.brand or ""), tostring(info.Name or info.name or name)
      local full = (brand ~= "" and (brand .. " ") or "") .. label
      if filter == "" or string.lower(name):find(filter, 1, true) or string.lower(full):find(filter, 1, true) then
        out[#out + 1] = {key = name, label = full, type = info.Type or info.type}
      end
    end
  end
  table.sort(out, function(a, b) if a.label ~= b.label then return a.label < b.label end return a.key < b.key end)
  if #out > limit then for i = #out, limit + 1, -1 do out[i] = nil end end
  return out
end

-- Share of each personality in percent, for display (the weights are relative).
function M.shares(st)
  local total, weights = 0, {}
  for _, p in ipairs(M.PERSONALITIES) do
    local w = tonumber(M.get(st, {"smartTraffic", "mix", p[1]}, 0)) or 0
    weights[p[1]] = w
    total = total + w
  end
  local out = {}
  for _, p in ipairs(M.PERSONALITIES) do out[p[1]] = total > 0 and weights[p[1]] / total * 100 or 0 end
  return out
end

-- Share of each personality at night in percent (the day weights times the night multipliers), for display.
function M.nightShares(st)
  local total, weights = 0, {}
  for _, p in ipairs(M.PERSONALITIES) do
    local w = tonumber(M.get(st, {"smartTraffic", "mix", p[1]}, 0)) or 0
    local m = tonumber(M.get(st, {"smartTraffic", "nightMult", p[1]}, 1)) or 1
    weights[p[1]] = w * m
    total = total + w * m
  end
  local out = {}
  for _, p in ipairs(M.PERSONALITIES) do out[p[1]] = total > 0 and weights[p[1]] / total * 100 or 0 end
  return out
end

-- The map a "Where & when" edit goes to: zones[zone] when a road class is chosen with "any time", else day/night.
-- (A weight for a road class AND a time of day is the product of the two maps, so one of them is chosen at a time.)
function M.whereMap(st)
  if st.time == "day" then return {"trafficVariety", "day"} end
  if st.time == "night" then return {"trafficVariety", "night"} end
  return {"trafficVariety", "zones", st.zone}
end

-- The names under snap[a][b] (theft methods, market items), sorted. Empty when the server did not send them.
function M.names(st, a, b)
  local out = {}
  local t = st.snap and type(st.snap[a]) == "table" and st.snap[a][b]
  if type(t) == "table" then for name in pairs(t) do out[#out + 1] = name end end
  table.sort(out)
  return out
end

function M.child(path, name)
  local out = {}
  for i, seg in ipairs(path) do out[i] = seg end
  out[#out + 1] = name
  return out
end

return M
