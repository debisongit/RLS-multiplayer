-- RLS-Career-MP client extension "rlsmp_core": the join handshake.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- 1. World is ready on a BeamMP server  -> send rlsmpHello
-- 2. Server streams our profile         -> saveBridge writes it to disk
-- 3. Lift RLS's "no BeamMP" block       -> start RLS career on the server's map
-- 4. RLS says career is active          -> tell the server (rlsmpLoaded), turn on uploads + wallet
--    (also when it comes after we gave up waiting, as long as the save had been downloaded)
--
-- No RLS or BeamMP file is edited. We wrap one RLS function at runtime (refuseCareerStart).

local M = {}

local net = require("rlsmp/lib/net")
local transfer = require("rlsmp/lib/transfer")
local removeGuard = require("rlsmp/lib/removeGuard")
local mapGate = require("rlsmp/lib/mapGate")
local downloadWatch = require("rlsmp/lib/downloadWatch")

-- Extensions that only run while the career is active on the server.
local MODULES = {"saveBridge", "wallet", "fleet", "vehicleGuard", "unstuck", "trafficLabels", "claims", "world", "duel", "clock", "bubble", "positions", "personalities", "unjam", "dedupe", "plates", "market", "theft", "recall", "meetup", "fakePlate", "garage"}
local function setModules(on)
  for _, name in ipairs(MODULES) do
    local ext = _G["rlsmp_" .. name]
    if ext then ext.enable(on) end
  end
end

local START_TIMEOUT = 180     -- seconds to wait for RLS to report the career as active
local RLS_WAIT_TIMEOUT = 60   -- seconds to wait for RLS itself to finish loading

local state = "idle"          -- idle | waiting_rls | hello_sent | downloading | starting | active | failed
local stateTime = 0
local pending                 -- {profile, isNew, slot, opts}
local isNewCareer = false
local firstSaveTimer
local resendTimer = 0
local heartbeatTimer = 0
local HEARTBEAT_EVERY = 1     -- seconds between download progress heartbeats (net.heartbeat)
local staleCars, staleTimer   -- cars the server says already left (crash recovery), removed shortly after the career starts
local watch = downloadWatch.new()   -- spots a download that stopped
local retries = 0                    -- times this join asked the server to send the save again (smaller and slower each time)
local helloRetries = 0
local HELLO_AGAIN_AFTER = 20
local RETRY_AFTER, MAX_RETRIES = 12, 3   -- seconds without a new chunk before asking again

-- Lines tagged [rlsmp-timing] show where join time goes (send them with the log if joining feels slow).
local function timing(what)
  log("I", "RLS-Career-MP", string.format("[rlsmp-timing] %s t=%.1f", what, os.clock()))
end

local function setState(s) timing("state " .. s) state = s stateTime = 0 end
function M.getState() return state end

local function isMP()
  return MPCoreNetwork ~= nil and MPCoreNetwork.isMPSession ~= nil and MPCoreNetwork.isMPSession()
end

local function toast(kind, msg)
  guihooks.trigger("toastrMsg", {type = kind, title = "RLS Career MP", msg = msg, config = {timeOut = 8000}})
end

local function rlsReady()
  return overhaul_shell_extensionManager ~= nil
    and (overhaul_shell_gameMode ~= nil or overhaul_career_career ~= nil)
end

-- RLS refuses to start while BeamMP is active. That is exactly what this mod fixes,
-- so inside a BeamMP session we answer "don't refuse". Outside of one, RLS's own logic runs.
local function patchRlsGate()
  local em = overhaul_shell_extensionManager
  if not em or em.__rlsmpPatched then return end
  local original = em.refuseCareerStart
  em.refuseCareerStart = function(...)
    if isMP() then return false end
    return original(...)
  end
  em.__rlsmpPatched = true
end

local function fail(reason, userMsg)
  log("E", "RLS-Career-MP", "Career start failed: " .. tostring(reason))
  removeGuard.enable(false)
  setState("failed")
  toast("error", userMsg or ("Could not start your career (" .. tostring(reason) .. ")"))
  net.send("rlsmpLoaded", {ok = false, err = tostring(reason)})
end

local function sendHello()
  downloadWatch.reset(watch)
  retries, helloRetries = 0, 0
  pending = nil   -- set again only when this attempt's profile download completes
  setState("hello_sent")
  net.send("rlsmpHello", {v = transfer.PROTOCOL, build = transfer.BUILD})
end

local function startCareer()
  patchRlsGate()
  local p = pending
  local opts = {}
  for k, v in pairs(p.opts or {}) do opts[k] = v end
  opts.startingMap = getCurrentLevelIdentifier()

  -- RLS activation deletes every vehicle in the scene; keep the other players' cars.
  removeGuard.install()
  removeGuard.enable(true)

  local ok, result, problem
  if overhaul_shell_gameMode and overhaul_shell_gameMode.start then
    ok, result, problem = pcall(overhaul_shell_gameMode.start, p.profile, p.slot, opts)
  else
    ok, result = pcall(overhaul_career_career.createOrLoadCareerAndStart, p.profile, p.slot, opts)
  end
  if not ok then return fail(result) end
  if result == false then return fail(problem or "rls_refused_start") end
  setState("starting")
end

local function onProfile(text, extra, problem)
  if state ~= "hello_sent" and state ~= "downloading" then return end
  if not text then return fail(problem or "download_failed", "Your save could not be downloaded. Please rejoin.") end
  local data = jsonDecode(text)
  if type(data) ~= "table" then return fail("bad_profile") end
  extra = type(extra) == "table" and extra or {}
  if type(extra.profile) ~= "string" or not extra.profile:match("^[a-z0-9]+$") then return fail("bad_profile_name") end

  local files = type(data.files) == "table" and data.files or {}
  local slot = rlsmp_saveBridge.writeProfile(extra.profile, files, getCurrentLevelIdentifier())
  isNewCareer = extra.isNew == true or slot == nil
  pending = {profile = extra.profile, slot = slot, opts = extra.startingOptions}
  staleCars = type(extra.drop) == "table" and extra.drop or nil
  startCareer()
end

-- RLS hook: the career finished loading (or was closed).
local function activate()
  setState("active")
  setModules(true)
  net.send("rlsmpLoaded", {ok = true})
  -- New careers get saved right away so the server has a copy from minute one.
  if isNewCareer then firstSaveTimer = 10 end
  if staleCars and #staleCars > 0 then staleTimer = 8 end
end

function M.onOverhaulActive(active)
  if not isMP() then return end
  if active and state == "starting" then
    activate()
  elseif active and state == "failed" and pending ~= nil then
    -- We gave up waiting (start timeout) but RLS did start our downloaded career after all: carry on as normal,
    -- otherwise the player would play with no save uploads and no wallet sync.
    log("I", "RLS-Career-MP", "career became active after the start failed: recovering")
    removeGuard.install()
    removeGuard.enable(true)
    activate()
  elseif not active and state == "active" then
    setModules(false)
    removeGuard.enable(false)
    setState("idle")
  end
end

local lostFor = 0       -- seconds without a multiplayer connection while a join was waiting
local started = false   -- a join attempt was made since we last left a server

local function begin()
  started = true
  if rlsReady() then sendHello() else setState("waiting_rls") end
end

-- Any state but "a join is running or done" restarts on a fresh world: a failed or stuck earlier attempt must not block the next join.
function M.onWorldReadyState(worldState)
  if worldState ~= 2 or not isMP() then return end
  if state == "starting" or state == "active" then return end
  if state == "hello_sent" or state == "downloading" then
    -- A second world-ready signal while a join is still waiting means the game reconnected on its own (a log showed the launcher link
    -- breaking 7 s after the hello): the old hello is dead, so ask again instead of waiting 60 s for an answer that never comes.
    if stateTime < 5 then return end
    log("W", "RLS-Career-MP", "the game joined again while the old join was waiting: starting the join again")
    net.reset()
  end
  begin()
end

function M.onUpdate(dtReal)
  -- The game may reload core_levels / freeroam / core_vehicles while mods change; wrap the fresh copies.
  mapGate.install()
  removeGuard.install()
  stateTime = stateTime + (dtReal or 0)
  -- Any download in progress (the save, or a fleet / duel car later): keep the server's send window open.
  heartbeatTimer = heartbeatTimer + (dtReal or 0)
  if heartbeatTimer >= HEARTBEAT_EVERY then
    heartbeatTimer = 0
    net.heartbeat()
  end
  if state == "waiting_rls" then
    if rlsReady() then
      sendHello()
    elseif stateTime > RLS_WAIT_TIMEOUT then
      fail("rls_missing", "RLS Career Overhaul is not installed or failed to load.")
    end
  elseif state == "hello_sent" or state == "downloading" then
    -- The connection to the server is gone (the game fell back to a plain world): forget this join so the next world-ready starts a new one.
    if isMP() then lostFor = 0 else
      lostFor = lostFor + (dtReal or 0)
      if lostFor > 5 then
        log("W", "RLS-Career-MP", "the connection to the server was lost during the join")
        lostFor, started = 0, false
        net.reset()
        setState("idle")
        return
      end
    end
    local got, total = net.incomingProgress()
    if state == "hello_sent" and got > 0 then setState("downloading") end
    local verdict, logNow = downloadWatch.step(watch, dtReal, got, state)
    -- Chunks that went missing: ask for them again every 4 s, while there are gaps (even if new chunks still
    -- trickle in, which keeps watch.idle low) or after 4 s of silence (the last chunks were lost).
    if state == "downloading" and (watch.idle >= 4 or net.hasHoles()) then
      resendTimer = resendTimer + (dtReal or 0)
      if resendTimer >= 4 then
        resendTimer = 0
        timing("asked the server to resend " .. net.requestMissing() .. " chunks")
      end
    else
      resendTimer = 0
    end
    if logNow then timing(string.format("download %d/%d chunks", got, total)) end
    -- No answer to the hello (a friend's log: the launcher link broke right after it): say hello again, the server then sends (again) with smaller chunks.
    if state == "hello_sent" and watch.idle >= HELLO_AGAIN_AFTER and helloRetries < 2 then
      helloRetries = helloRetries + 1
      timing(string.format("no answer to the hello for %d s: saying hello again (%d of 2)", HELLO_AGAIN_AFTER, helloRetries))
      downloadWatch.reset(watch)
      net.send("rlsmpHello", {v = transfer.PROTOCOL, build = transfer.BUILD, again = helloRetries})
      return
    end
    -- The server stopped sending (seen in two logs: 29 of 191 pieces, then nothing, not even to the resend requests): ask for the whole
    -- save again. The server sends it with smaller chunks, a bit slower each time (server/net.lua setPace).
    if state == "downloading" and watch.idle >= RETRY_AFTER and retries < MAX_RETRIES and not (total > 0 and got >= total) then
      retries = retries + 1
      timing(string.format("download stalled at %d/%d chunks: asking the server to send the save again (attempt %d of %d)", got, total, retries, MAX_RETRIES))
      net.dropIncoming()
      downloadWatch.reset(watch)
      resendTimer = 0
      net.send("rlsmpRetry", {attempt = retries})
      return
    end
    if verdict == "stalled" then
      log("E", "RLS-Career-MP", string.format("Save download stalled at %d/%d chunks", got, total))
      fail("download_stalled", "Your save stopped downloading. Please leave and rejoin the server.")
    elseif verdict == "no_answer" then
      fail("no_answer", "The server did not send your save. Please leave and rejoin the server.")
    end
  elseif state == "starting" and stateTime > START_TIMEOUT then
    fail("start_timeout")
  end
  -- Safety net: if the world-ready signal never reached us (mod mounted late after an update), start anyway.
  if state == "idle" and not started and stateTime > 10 and isMP() and getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    log("I", "RLS-Career-MP", "world-ready signal missed, starting the join anyway")
    begin()
  end
  if staleTimer then
    staleTimer = staleTimer - (dtReal or 0)
    if staleTimer <= 0 then
      staleTimer = nil
      rlsmp_fleet.dropStale(staleCars)
      staleCars = nil
    end
  end
  if firstSaveTimer then
    firstSaveTimer = firstSaveTimer - (dtReal or 0)
    if firstSaveTimer <= 0 then
      firstSaveTimer = nil
      rlsmp_saveBridge.requestSave("rlsmp_first")
    end
  end
end

function M.onServerLeave()
  removeGuard.enable(false)
  setModules(false)
  net.reset()
  pending, firstSaveTimer, staleCars, staleTimer = nil, nil, nil, nil
  started = false
  setState("idle")
end

function M.onExtensionLoaded()
  mapGate.install()
  removeGuard.install()
  net.init()
  net.onBig("profile", onProfile)
  net.on("rlsmpError", function(e) toast("error", tostring(e.msg or e.code)) end)
  for _, name in ipairs(MODULES) do
    -- After leaving a server and joining again the game may still hold an old copy without handlers: start fresh.
    if extensions.isExtensionLoaded and extensions.unload and extensions.isExtensionLoaded("rlsmp_" .. name) then
      pcall(extensions.unload, "rlsmp_" .. name)
    end
    extensions.load("rlsmp_" .. name)
    setExtensionUnloadMode("rlsmp_" .. name, "manual")
  end
  log("I", "RLS-Career-MP", "client loaded, build " .. transfer.BUILD)
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("core", M)
return M
