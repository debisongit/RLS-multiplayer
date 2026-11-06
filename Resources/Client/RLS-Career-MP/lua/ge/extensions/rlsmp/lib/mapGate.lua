-- RLS-Career-MP client: make BeamMP wait for RLS's generated map.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- RLS builds its map ("rls_west_coast") on this PC after RLS loads, while BeamMP announces the server map
-- ~3 s after mounting the server mods. BeamMP then checks core_levels.expandMissionFileName(map) and leaves the
-- server with "Map not found" if the level is not there yet.
--   1. expandMissionFileName: while the map is still being built, say "found" (BeamMP only tests for truthiness).
--   2. freeroam_freeroam.startFreeroam: hold the real level load until the map exists, then continue.
-- If the map never shows up (RLS error or timeout) the player is sent back out with a clear message.
-- After the first build RLS reuses its cache, so the wait is usually zero.

local mp = require("rlsmp/lib/mp")

local M = {}

M.GATED = {rls_west_coast = true}
M.TIMEOUT = 240

local wrapped = setmetatable({}, {__mode = "k"})  -- module tables we already wrapped (a reloaded module is a new table)
local clock = os.clock
function M.setClock(fn) clock = fn end

local function levelOf(path)
  return type(path) == "string" and path:match("^/?levels/([^/]+)/") or nil
end

local function ready(level)
  return FS:fileExists("/levels/" .. level .. "/info.json")
end

local function proxyFailed()
  local lp = overhaul_world_levelProxy
  local status = lp and lp.getStatus and lp.getStatus()
  return status and status.state == "error"
end

-- true while the level is one we wait for, is not there yet, and can still appear
local function waiting(level)
  return level ~= nil and M.GATED[level] == true and not ready(level) and not proxyFailed()
end

local function say(text)
  -- BeamMP's loading text starts with a type code; "l" = show as loading message
  if UI and UI.updateLoading then pcall(UI.updateLoading, "l" .. text) end
end

-- RLS builds the map when it loads. If that build is gone (RLS was unloaded and reloaded while joining), start it again.
-- Returns true when it asked for a build.
local function kickBuild(state)
  local lp = overhaul_world_levelProxy
  if not lp then
    if state.loadAsked or not extensions then return false end
    state.loadAsked = true
    log("W", "RLS-Career-MP", "map gate: RLS map builder not loaded, loading it")
    pcall(extensions.load, "overhaul_world_levelProxy")
    return true
  end
  local status = lp.getStatus and lp.getStatus()
  if status and status.state == "idle" and not state.regenAsked and lp.regenerate then
    state.regenAsked = true
    log("W", "RLS-Career-MP", "map gate: no map build running, starting one")
    pcall(lp.regenerate)
    return true
  end
  return false
end

local function timing(msg)
  log("I", "RLS-Career-MP", "[rlsmp-timing] " .. msg .. " t=" .. string.format("%.1f", clock()))
end

-- Safe to call every frame: wraps each module once, and again if the game reloads it.
function M.install()
  if not (core_levels and core_levels.expandMissionFileName and freeroam_freeroam and freeroam_freeroam.startFreeroam) then
    return false
  end
  if not wrapped[core_levels] then
    wrapped[core_levels] = true
    local expand = core_levels.expandMissionFileName
    core_levels.expandMissionFileName = function(path, ...)
      local result = expand(path, ...)
      if result then return result end
      if mp.isMPSession() and waiting(levelOf(path)) then return path end
      return result
    end
  end
  if wrapped[freeroam_freeroam] then return true end
  wrapped[freeroam_freeroam] = true

  local start = freeroam_freeroam.startFreeroam
  freeroam_freeroam.startFreeroam = function(path, ...)
    local level = levelOf(path)
    if not (mp.isMPSession() and waiting(level)) then return start(path, ...) end
    local n, args = select("#", ...), {...}
    timing("map gate: waiting for " .. level)
    core_jobsystem.create(function(job)
      local started = clock()
      local lastNote = -10
      local kick = {}
      while waiting(level) and clock() - started < M.TIMEOUT do
        if clock() - lastNote >= 2 then
          lastNote = clock()
          say(string.format("Preparing the RLS map... %ds", math.floor(clock() - started)))
        end
        if clock() - started > 4 then kickBuild(kick) end
        job.sleep(0.5)
      end
      if ready(level) then
        timing(string.format("map gate: %s ready after %.1fs", level, clock() - started))
        start(path, unpack(args, 1, n))
      else
        log("E", "RLS-Career-MP", "map gate: " .. level .. " never appeared")
        guihooks.trigger("toastrMsg", {type = "error", title = "RLS Career MP",
          msg = "The RLS map could not be prepared. Check that RLS Career Overhaul loaded correctly.", config = {timeOut = 10000}})
        if MPCoreNetwork and MPCoreNetwork.leaveServer then MPCoreNetwork.leaveServer() end
      end
    end)
  end
  return true
end

M._levelOf = levelOf
return M
