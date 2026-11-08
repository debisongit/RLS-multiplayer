-- Pure rules for rlsmp/trafficVariety.lua "focus": traffic cars use the SAME few configs (1 or 2) and the choice changes only every N minutes.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Owner's report: every new car with a different model/config has to load its parts and meshes (about 0.25 s each in the log) and the game lags.
-- Cars of a config that is already on the street are cheap. So for traffic (not parked cars, not police) we keep a small "focus": `configs` entries
-- chosen with the normal weights (road class, day or night, rarity), kept for `minutes`, then chosen again. Tests: tests/traffic_focus_lib_test.lua.

local M = {}

M.DEFAULTS = {enabled = true, configs = 2, minutes = 20}

local function number(v, default, lo, hi)
  v = tonumber(v)
  if v == nil or v ~= v then return default end
  return math.max(lo, math.min(hi, v))
end

function M.sanitize(src)
  src = type(src) == "table" and src or {}
  local d = M.DEFAULTS
  return {
    enabled = src.enabled ~= false,
    configs = math.floor(number(src.configs, d.configs, 1, 6)),
    minutes = number(src.minutes, d.minutes, 1, 600),
  }
end

function M.key(e) return tostring(e.model) .. "/" .. tostring(e.config) end

function M.newState() return {entries = nil, at = nil, rotations = 0} end

-- Is a new choice due? (nothing chosen yet, or the time is over)
function M.due(state, cfg, now)
  return state.entries == nil or state.at == nil or now - state.at >= cfg.minutes * 60
end

-- Remember `entries` (list of {model, config}, at most cfg.configs, distinct by model/config) as the focus from `now`.
function M.set(state, cfg, entries, now)
  local out, seen, models = {}, {}, {}
  -- different models first (two cars of one model are hardly "two configs"), then other configs of the same model
  for pass = 1, 2 do
    for _, e in ipairs(entries or {}) do
      local k = M.key(e)
      if not seen[k] and #out < cfg.configs and (pass == 2 or not models[e.model]) then
        seen[k], models[e.model] = true, true
        out[#out + 1] = {model = e.model, config = e.config}
      end
    end
  end
  if #out == 0 then state.entries, state.at = nil, nil return false end
  state.entries, state.at = out, now
  state.rotations = state.rotations + 1
  return true
end

-- The focus entries (copies), or nil when none is set / the feature is off.
function M.current(state, cfg)
  if not (cfg and cfg.enabled) or not state.entries then return nil end
  local out = {}
  for i, e in ipairs(state.entries) do out[i] = {model = e.model, config = e.config} end
  return out
end

-- `want` cars from the focus entries, round robin from a random start so two entries share the cars evenly.
function M.group(entries, want, rng)
  local out = {}
  if not entries or #entries == 0 then return out end
  local start = (rng and rng(#entries)) or 1
  for i = 1, want do
    local e = entries[(start + i - 2) % #entries + 1]
    out[i] = {model = e.model, config = e.config}
  end
  return out
end

return M
