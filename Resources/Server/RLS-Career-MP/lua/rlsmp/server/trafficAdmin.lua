-- RLS-Career-MP server: the in-game traffic settings menu (Phase 3).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A few players (config `trafficAdmin`: BeamMP account names, optionally account ids) can change the AI traffic settings from a menu in the game
-- (client rlsmp_trafficMenu: the [ key, or /trafficmenu). THIS FILE is what protects it: the client only asks, the server checks every time.
--   * who: the sender's BeamMP name (not case sensitive) or account id must be listed, and guests never count;
--   * what: only settings on the allowlist below, each with a type and a range (anything else, or a value out of range, is rejected);
--   * how: a change is set INSIDE the existing section tables (the other modules keep references to them), the config.json is saved,
--     the modules are told to resend their settings to everybody, and every admin gets the fresh state.
-- Events: rlsmpTrafficAdminGet (C>S), rlsmpTrafficAdminSet {set = {{p = path, v = value}}, rm = {path}} (C>S),
--         rlsmpTrafficAdminState / rlsmpTrafficAdminResult / rlsmpTrafficAdminOpen (S>C). Settings that are read only once at startup
--         (timer intervals, the weather period length) are NOT editable here, because changing them live would do nothing.

local util = require("rlsmp.server.util")
local net = require("rlsmp.server.net")
local sessions = require("rlsmp.server.sessions")
local storage = require("rlsmp.server.storage")

local M = {}

local MAX_CHANGES = 64            -- changes per message
local MAX_PER_SECOND = 3          -- messages per second per player
local MAX_KEY = 64

local ZONES = {city = true, main = true, highway = true}
local PERSONALITIES = {"normal", "slow", "aggressive", "racer", "drunk"}
local CONDITIONS = {"clear", "partlyCloudy", "overcast", "drizzle", "rain", "storm"}

-- Rules: static settings by their dotted path. {kind, min, max, int}
local STATIC = {
  ["traffic.enabled"] = {"bool"},
  ["traffic.totalBudget"] = {"number", 0, 500, true},
  ["traffic.baseBudget"] = {"number", 0, 500, true},
  ["traffic.perPlayerBudget"] = {"number", 0, 100, true},
  ["traffic.minPerPlayer"] = {"number", 0, 50, true},
  ["traffic.maxPerPlayer"] = {"number", 1, 100, true},
  ["smartTraffic.enabled"] = {"bool"},
  ["smartTraffic.policeReact"] = {"bool"},
  ["trafficVariety.enabled"] = {"bool"},
  ["trafficVariety.applyToTraffic"] = {"bool"},
  ["trafficVariety.applyToParked"] = {"bool"},
  ["trafficVariety.maxShare"] = {"number", 0.05, 1},
  ["trafficVariety.oversample"] = {"number", 1, 4},
  ["trafficVariety.maxCandidates"] = {"number", 10, 300, true},
  ["trafficVariety.zoneSpeedLimits.city"] = {"number", 1, 100},
  ["trafficVariety.zoneSpeedLimits.main"] = {"number", 1, 200},
  ["trafficVariety.swap.enabled"] = {"bool"},
  ["trafficVariety.swap.live"] = {"bool"},
  ["trafficVariety.swap.perMinute"] = {"number", 0, 12, true},
  ["trafficVariety.swap.hiddenSeconds"] = {"number", 1, 120},
  ["trafficVariety.swap.minRatio"] = {"number", 1, 100},
  ["trafficVariety.swap.maxFailures"] = {"number", 1, 20, true},
  ["weather.enabled"] = {"bool"},
  ["weather.force"] = {"enum", values = {[""] = true, clear = true, partlyCloudy = true, overcast = true, drizzle = true, rain = true, storm = true}},
  ["police.antiTeleport"] = {"bool"},
  ["police.blockRoadblocks"] = {"bool"},
}
for _, name in ipairs(PERSONALITIES) do STATIC["smartTraffic.mix." .. name] = {"number", 0, 100} end
for _, name in ipairs(CONDITIONS) do STATIC["weather.mix." .. name] = {"number", 0, 100} end

-- Rules for maps with names chosen by the player (car Types and models): first segments -> rule, last segment is the name.
local DYNAMIC_WEIGHT = {"number", 0, 20}
local DYNAMIC = {
  ["trafficVariety.typeWeights"] = DYNAMIC_WEIGHT,
  ["trafficVariety.models"] = DYNAMIC_WEIGHT,
  ["trafficVariety.mods"] = DYNAMIC_WEIGHT,
  ["trafficVariety.day"] = DYNAMIC_WEIGHT,
  ["trafficVariety.night"] = DYNAMIC_WEIGHT,
}

local config, configPath
local adminCfg
local seen = {}        -- pid -> {second, count}

-- Names of Types, models and zones: short, plain characters.
local function goodKey(k)
  return type(k) == "string" and #k >= 1 and #k <= MAX_KEY and k:match("^[%w_%- ]+$") ~= nil
end

-- Returns the rule for a path (an array of strings), and whether the setting may be removed (dynamic entries only), or nil, reason.
local function ruleFor(path)
  if type(path) ~= "table" or #path < 2 or #path > 4 then return nil, "bad path" end
  for _, seg in ipairs(path) do if type(seg) ~= "string" then return nil, "bad path" end end
  local dotted = table.concat(path, ".")
  local rule = STATIC[dotted]
  if rule then return rule, false end
  local head = table.concat(path, ".", 1, #path - 1)
  if DYNAMIC[head] then
    if not goodKey(path[#path]) then return nil, "bad name" end
    return DYNAMIC[head], true
  end
  if #path == 4 and path[1] == "trafficVariety" and path[2] == "zones" and ZONES[path[3]] then
    if not goodKey(path[4]) then return nil, "bad name" end
    return DYNAMIC_WEIGHT, true
  end
  return nil, "not an editable setting"
end

local function checkValue(rule, v)
  local kind = rule[1]
  if kind == "bool" then
    if type(v) ~= "boolean" then return nil, "needs true or false" end
    return v
  elseif kind == "number" then
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil, "needs a number" end
    if v < rule[2] or v > rule[3] then return nil, string.format("out of range (%s to %s)", rule[2], rule[3]) end
    if rule[4] then v = math.floor(v + 0.5) end
    return v
  elseif kind == "enum" then
    if type(v) ~= "string" or not rule.values[v] then return nil, "not an allowed value" end
    return v
  end
  return nil, "bad rule"
end

-- The table that holds the last segment of `path`, creating only the small maps whose names the player chooses.
local function holder(path, create)
  local t = config
  for i = 1, #path - 1 do
    local seg = path[i]
    local nxt = t[seg]
    if type(nxt) ~= "table" then
      local isZoneMap = (i == 3 and path[2] == "zones")
      if create and isZoneMap then nxt = {} t[seg] = nxt else return nil end   -- never replace or invent a whole section
    end
    t = nxt
  end
  return t, path[#path]
end

local function describe(path, v) return table.concat(path, ".") .. (v ~= nil and ("=" .. tostring(v)) or " removed") end

-- Applies a patch {set = {{p = path, v = value}}, rm = {path}}. Returns applied count, list of {p, why}, list of descriptions.
function M.applyPatch(patch)
  local applied, rejected, done = 0, {}, {}
  local function reject(p, why) rejected[#rejected + 1] = {p = p, why = why} end
  local sets = type(patch.set) == "table" and patch.set or {}
  local rms = type(patch.rm) == "table" and patch.rm or {}
  if #sets + #rms > MAX_CHANGES then
    return 0, {{p = {}, why = "too many changes in one message (" .. MAX_CHANGES .. " at most)"}}, {}
  end
  for _, change in ipairs(sets) do
    local path = type(change) == "table" and change.p
    local rule, why = ruleFor(path)
    if not rule then reject(path, why)
    else
      local value, problem = checkValue(rule, change.v)
      if value == nil then reject(path, problem)
      else
        local t, key = holder(path, true)
        if not t then reject(path, "that section does not exist")
        else
          t[key] = value
          applied = applied + 1
          done[#done + 1] = describe(path, value)
        end
      end
    end
  end
  for _, path in ipairs(rms) do
    local rule, removable = ruleFor(path)
    if not rule then reject(path, removable)
    elseif not removable then reject(path, "this setting cannot be removed, only changed")
    else
      local t, key = holder(path, false)
      if t and t[key] ~= nil then
        t[key] = nil
        applied = applied + 1
        done[#done + 1] = describe(path, nil)
      end
    end
  end
  return applied, rejected, done
end

-- The editable parts of the config, for the menu.
local function copyMap(src)
  local out = {}
  if type(src) == "table" then for k, v in pairs(src) do out[k] = v end end
  return out
end
local function copyZones(src)
  local out = {}
  if type(src) == "table" then for zone, map in pairs(src) do out[zone] = copyMap(map) end end
  return out
end

function M.snapshot()
  local t, s, v, w, p = config.traffic or {}, config.smartTraffic or {}, config.trafficVariety or {}, config.weather or {}, config.police or {}
  local swap = type(v.swap) == "table" and v.swap or {}
  local limits = type(v.zoneSpeedLimits) == "table" and v.zoneSpeedLimits or {}
  return {
    traffic = {enabled = t.enabled, totalBudget = t.totalBudget, baseBudget = t.baseBudget, perPlayerBudget = t.perPlayerBudget,
      minPerPlayer = t.minPerPlayer, maxPerPlayer = t.maxPerPlayer},
    smartTraffic = {enabled = s.enabled, policeReact = s.policeReact, mix = copyMap(s.mix)},
    trafficVariety = {enabled = v.enabled, applyToTraffic = v.applyToTraffic, applyToParked = v.applyToParked,
      maxShare = v.maxShare, oversample = v.oversample, maxCandidates = v.maxCandidates,
      typeWeights = copyMap(v.typeWeights), models = copyMap(v.models), mods = copyMap(v.mods),
      zones = copyZones(v.zones), day = copyMap(v.day), night = copyMap(v.night),
      zoneSpeedLimits = {city = limits.city, main = limits.main},
      swap = {enabled = swap.enabled, live = swap.live, perMinute = swap.perMinute, hiddenSeconds = swap.hiddenSeconds,
        minRatio = swap.minRatio, maxFailures = swap.maxFailures}},
    weather = {enabled = w.enabled, force = w.force, mix = copyMap(w.mix), periodMinutes = w.periodMinutes},
    police = {antiTeleport = p.antiTeleport, blockRoadblocks = p.blockRoadblocks},
  }
end

-- Who -----------------------------------------------------------------------------------------------------------------------------------
-- Returns true plus the player's name and account id for logs.
function M.isAdmin(pid)
  local s = sessions.get(pid)
  if not s or s.guest == true then return false end
  local name = tostring((MP.GetPlayerName and MP.GetPlayerName(pid)) or s.name or ""):lower()
  if name ~= "" then
    for _, n in ipairs(adminCfg.names or {}) do
      if tostring(n):lower() == name then return true, name, s.accountId end
    end
  end
  if s.accountId ~= nil then
    for _, id in ipairs(adminCfg.accountIds or {}) do
      if tostring(id) == tostring(s.accountId) then return true, name, s.accountId end
    end
  end
  return false
end

local function say(pid, text) if MP.SendChatMessage then MP.SendChatMessage(pid, "[Traffic] " .. text) end end

local function tooFast(pid)
  local now = util.now()
  local e = seen[pid]
  if not e or e.second ~= now then e = {second = now, count = 0} seen[pid] = e end
  e.count = e.count + 1
  return e.count > MAX_PER_SECOND
end

local function modulesResend()
  for _, name in ipairs({"smartTraffic", "trafficVariety", "trafficPolice"}) do
    local ok, mod = pcall(require, "rlsmp.server." .. name)
    if ok and type(mod) == "table" and mod.resend then mod.resend() end
  end
end

local function sendState(pid)
  net.send(pid, "rlsmpTrafficAdminState", {ok = true, cfg = M.snapshot()})
end

local function sendStateToAdmins()
  for pid in pairs(sessions.all()) do
    if M.isAdmin(pid) then sendState(pid) end
  end
end

local function onGet(pid)
  if tooFast(pid) then return end
  local ok, name, account = M.isAdmin(pid)
  if not ok then
    util.warn(string.format("RLSMP-ADMIN refused the traffic menu to pid=%s (%s)", tostring(pid), tostring(MP.GetPlayerName and MP.GetPlayerName(pid))))
    net.send(pid, "rlsmpTrafficAdminState", {ok = false})
    say(pid, "You are not allowed to use the traffic menu.")
    return
  end
  sendState(pid)
end

local function onSet(pid, data)
  if tooFast(pid) then return end
  local ok, name, account = M.isAdmin(pid)
  if not ok then
    util.warn(string.format("RLSMP-ADMIN refused a settings change from pid=%s (%s)", tostring(pid), tostring(MP.GetPlayerName and MP.GetPlayerName(pid))))
    net.send(pid, "rlsmpTrafficAdminState", {ok = false})
    say(pid, "You are not allowed to change traffic settings.")
    return
  end
  local applied, rejected, done = M.applyPatch(data)
  local saved = true
  if applied > 0 then
    saved = storage.writeJson(configPath, config, true) == true
    modulesResend()
    local shown = {}
    for i = 1, math.min(#done, 8) do shown[i] = done[i] end
    util.info(string.format("RLSMP-ADMIN %s (pid %s, account %s) changed %d settings%s: %s%s", tostring(name), tostring(pid), tostring(account), applied,
      saved and "" or " (NOT SAVED to config.json)", table.concat(shown, ", "), #done > 8 and ", ..." or ""))
  end
  if #rejected > 0 then
    local first = rejected[1]
    util.warn(string.format("RLSMP-ADMIN %s: %d changes rejected, first: %s (%s)", tostring(name), #rejected, type(first.p) == "table" and table.concat(first.p, ".") or "?", tostring(first.why)))
  end
  net.send(pid, "rlsmpTrafficAdminResult", {ok = true, applied = applied, rejected = rejected, saved = saved})
  if applied > 0 then sendStateToAdmins() end
end

local function onMenuCommand(pid)
  if M.isAdmin(pid) then
    net.send(pid, "rlsmpTrafficAdminOpen", {})
  else
    say(pid, "You are not allowed to use the traffic menu.")
  end
end

function M.init(cfg, pluginRoot)
  config = cfg
  adminCfg = cfg.trafficAdmin or {}
  configPath = (pluginRoot or "") .. "config/config.json"
  seen = {}
  net.onClient("rlsmpTrafficAdminGet", onGet)
  net.onClient("rlsmpTrafficAdminSet", onSet)
  net.onChat("trafficmenu", onMenuCommand)
  util.info("Traffic menu: " .. #(adminCfg.names or {}) .. " admin name(s) allowed")
end

M._ruleFor = ruleFor
return M
