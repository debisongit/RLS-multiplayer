-- RLS-Career-MP: Phase 3 field-test logging and census (shared by rlsmp_traffic and rlsmp_police).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Every line goes to the game log with the tag RLSMP-P3, so one search recovers the whole run.
-- `report()` prints counters and the top callers; call it from the game console:  rlsmp_police.report()

local M = {}

M.TAG = "RLSMP-P3"
local TOP = 15

local counters = {}      -- name -> number
local callers = {}       -- category -> {site -> number}
local seen = {}          -- once-only messages

function M.log(level, msg) log(level, M.TAG, msg) end

function M.probe(name, value) M.log("I", "probe: " .. name .. " = " .. tostring(value)) end

-- Log a line only the first time `key` is seen (or when its value changes).
function M.logOnChange(key, value, level, msg)
  if seen[key] == value then return end
  seen[key] = value
  M.log(level or "I", msg)
end

function M.count(name, n) counters[name] = (counters[name] or 0) + (n or 1) end
function M.get(name) return counters[name] or 0 end

-- "file:line" of whoever called the function that called caller(). Call it from inside a wrapper.
function M.caller()
  if not debug or not debug.getinfo then return "?" end
  local info = debug.getinfo(3, "Sl")
  if not info then return "?" end
  return tostring(info.short_src) .. ":" .. tostring(info.currentline)
end

function M.countCaller(category, site)
  callers[category] = callers[category] or {}
  callers[category][site] = (callers[category][site] or 0) + 1
end

local function sortedPairs(t)
  local list = {}
  for k, v in pairs(t) do list[#list + 1] = {k, v} end
  table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  return list
end

function M.report()
  local lines = {"census begin"}
  for _, kv in ipairs(sortedPairs(counters)) do
    lines[#lines + 1] = string.format("  %-34s: %d", kv[1], kv[2])
  end
  local cats = {}
  for category in pairs(callers) do cats[#cats + 1] = category end
  table.sort(cats)
  for _, category in ipairs(cats) do
    lines[#lines + 1] = string.format("  %s callers (top %d):", category, TOP)
    for i, kv in ipairs(sortedPairs(callers[category])) do
      if i > TOP then break end
      lines[#lines + 1] = string.format("    %5d  %s", kv[2], kv[1])
    end
  end
  lines[#lines + 1] = "census end"
  for _, line in ipairs(lines) do M.log("I", line) end
  return table.concat(lines, "\n")
end

function M.reset() counters, callers, seen = {}, {}, {} end

return M
