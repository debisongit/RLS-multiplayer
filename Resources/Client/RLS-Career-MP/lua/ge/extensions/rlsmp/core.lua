-- RLS-Career-MP client extension "rlsmp_core": the join handshake.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- 1. World is ready on a BeamMP server  -> send rlsmpHello
-- 2. Server streams our profile         -> saveBridge writes it to disk
-- 3. Lift RLS's "no BeamMP" block       -> start RLS career on the server's map
-- 4. RLS says career is active          -> tell the server (rlsmpLoaded), turn on uploads + wallet
--
-- No RLS or BeamMP file is edited. We wrap one RLS function at runtime (refuseCareerStart).

local M = {}

local net = require("rlsmp/lib/net")
local transfer = require("rlsmp/lib/transfer")

local START_TIMEOUT = 180     -- seconds to wait for RLS to report the career as active
local RLS_WAIT_TIMEOUT = 60   -- seconds to wait for RLS itself to finish loading

local state = "idle"          -- idle | waiting_rls | hello_sent | downloading | starting | active | failed
local stateTime = 0
local pending                 -- {profile, isNew, slot, opts}
local isNewCareer = false
local firstSaveTimer

local function setState(s) state = s stateTime = 0 end
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
  setState("failed")
  toast("error", userMsg or ("Could not start your career (" .. tostring(reason) .. ")"))
  net.send("rlsmpLoaded", {ok = false, err = tostring(reason)})
end

local function sendHello()
  setState("hello_sent")
  net.send("rlsmpHello", {v = transfer.PROTOCOL})
end

local function startCareer()
  patchRlsGate()
  local p = pending
  local opts = {}
  for k, v in pairs(p.opts or {}) do opts[k] = v end
  opts.startingMap = getCurrentLevelIdentifier()

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
  startCareer()
end

-- RLS hook: the career finished loading (or was closed).
function M.onOverhaulActive(active)
  if not isMP() then return end
  if active and state == "starting" then
    setState("active")
    rlsmp_saveBridge.enable(true)
    rlsmp_wallet.enable(true)
    net.send("rlsmpLoaded", {ok = true})
    -- New careers get saved right away so the server has a copy from minute one.
    if isNewCareer then firstSaveTimer = 10 end
  elseif not active and state == "active" then
    rlsmp_saveBridge.enable(false)
    rlsmp_wallet.enable(false)
    setState("idle")
  end
end

function M.onWorldReadyState(worldState)
  if worldState ~= 2 or not isMP() or state ~= "idle" then return end
  if rlsReady() then sendHello() else setState("waiting_rls") end
end

function M.onUpdate(dtReal)
  stateTime = stateTime + (dtReal or 0)
  if state == "waiting_rls" then
    if rlsReady() then
      sendHello()
    elseif stateTime > RLS_WAIT_TIMEOUT then
      fail("rls_missing", "RLS Career Overhaul is not installed or failed to load.")
    end
  elseif state == "hello_sent" then
    local got = net.incomingProgress()
    if got > 0 then setState("downloading") end
  elseif state == "starting" and stateTime > START_TIMEOUT then
    fail("start_timeout")
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
  rlsmp_saveBridge.enable(false)
  rlsmp_wallet.enable(false)
  net.reset()
  pending, firstSaveTimer = nil, nil
  setState("idle")
end

function M.onExtensionLoaded()
  net.init()
  net.onBig("profile", onProfile)
  net.on("rlsmpError", function(e) toast("error", tostring(e.msg or e.code)) end)
  extensions.load("rlsmp_saveBridge", "rlsmp_wallet")
  setExtensionUnloadMode("rlsmp_saveBridge", "manual")
  setExtensionUnloadMode("rlsmp_wallet", "manual")
  log("I", "RLS-Career-MP", "client loaded")
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
