-- RLS-Career-MP client extension "rlsmp_market": shows black market drop spots (rules and money: server/market.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server says where a paid package will be (rlsmpMarketDrop) and when it was collected (rlsmpMarketClear).
-- This side only: a toast when an order is placed and when it is ready, a marker drawn at a ready spot when it is
-- near. Standing inside the 15 m circle collects the package by itself: we ask rlsmp_positions to report right away (fresh position for
-- the server), send the pickup (same server action as the phone app's button), and the answer opens a small popup (vanilla guihook
-- showConfirmationDialog, like rlsmp/garage.lua). The server checks the position and everything else. Retried every 10 s while inside.
-- The phone app (ui/ui-vue/mods/rls_career_mp/phone/PhoneBlackMarket.vue) calls M.uiGet() about every 1.5 s and M.uiAct(...) on a tap; both
-- only relay to the server (rlsmpMarketGet / rlsmpMarketAct) and hand back what the server last said. No rules here.
-- Scout tip: the server answers rlsmpMarketScout {marks = [{x, y, z}], seconds}; each mark is a small sphere (no text) over the car until
-- the time is up. We do not use core_groundMarkers for it either.
-- We do not use core_groundMarkers: RLS jobs (taxi, bus) own that route and would lose it.

local M = {}

local net = require("rlsmp/lib/net")

local NEAR = 15        -- meters (horizontal): "you are at the drop"
local RETRY = 10       -- seconds between automatic pickup tries while inside
local DRAW = 300       -- meters: draw the marker when closer than this
local CHECK = 1        -- seconds between checks

local enabled = false
local drops = {}       -- id -> {label, spot, x, y, z, readyAt, told, near}
local clock, checkTimer = 0, 0
local marks = {}       -- scout tip: {x, y, z, till}
local autoPending = false  -- an automatic pickup was sent and its answer has not come yet

local function toast(kind, msg)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Black market", msg = msg, config = {timeOut = 8000}}) end
end

function M.enable(on)
  enabled = on == true
  if not enabled then drops, marks = {}, {} end
end

local function num(v)
  v = tonumber(v)
  if v and v == v and v ~= math.huge and v ~= -math.huge then return v end
end

local function onDrop(d)
  if not enabled then return end
  local x, y, z = num(d.x), num(d.y), num(d.z)
  if d.id == nil or not (x and y and z) then return end
  local id = tostring(d.id)
  local readyIn = math.max(0, num(d.readyIn) or 0)
  local old = drops[id]
  local label = tostring(d.label or d.item or "Package"):sub(1, 60)
  local spot = tostring(d.spot or "the drop spot"):sub(1, 60)
  drops[id] = {label = label, spot = spot, x = x, y = y, z = z, readyAt = clock + readyIn,
               told = old ~= nil and old.told or readyIn == 0, near = false}
  if old then return end
  if readyIn > 0 then
    toast("info", string.format("%s will be at %s in about %d s.", label, spot, math.floor(readyIn)))
  else
    toast("info", label .. " is waiting at " .. spot .. ".")
  end
end

local function onClear(d)
  if d.id ~= nil then drops[tostring(d.id)] = nil end
end

local function playerPos()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  return veh and veh:getPosition() or nil
end

local function dist2d(p, d)
  local dx, dy = p.x - d.x, p.y - d.y
  return math.sqrt(dx * dx + dy * dy)
end

local function draw(d)
  if not (debugDrawer and vec3) then return end
  pcall(function()
    debugDrawer:drawSphere(vec3(d.x, d.y, d.z + 1), 1.5, ColorF(1, 0.3, 0.1, 0.6))
  end)
end

local function drawMark(m)
  if not (debugDrawer and vec3) then return end
  pcall(function() debugDrawer:drawSphere(vec3(m.x, m.y, m.z + 2.3), 0.4, ColorF(0.2, 0.9, 1, 0.8)) end)
end

local function onScout(d)
  if not enabled or type(d.marks) ~= "table" then return end
  local till = clock + math.max(10, math.min(3600, num(d.seconds) or 600))
  marks = {}
  for _, m in ipairs(d.marks) do
    local x, y, z = num(m.x), num(m.y), num(m.z)
    if x and y and z then marks[#marks + 1] = {x = x, y = y, z = z, till = till} end
  end
  toast("info", string.format("Scout tip: %d car(s) marked for about %d min.", #marks, math.floor((till - clock) / 60 + 0.5)))
end

function M.onUpdate(dtReal)
  if not enabled or (next(drops) == nil and #marks == 0) then return end
  dtReal = dtReal or 0
  clock, checkTimer = clock + dtReal, checkTimer + dtReal
  for i = #marks, 1, -1 do
    if marks[i].till <= clock then table.remove(marks, i) else drawMark(marks[i]) end
  end
  local p = playerPos()
  if p then
    for _, d in pairs(drops) do
      if d.readyAt <= clock and dist2d(p, d) < DRAW then draw(d) end
    end
  end
  if checkTimer < CHECK then return end
  checkTimer = 0
  for _, d in pairs(drops) do
    if d.readyAt <= clock then
      if not d.told then
        d.told = true
        toast("info", d.label .. " is waiting at " .. d.spot .. ".")
      end
      local inside = p ~= nil and dist2d(p, d) <= NEAR
      if inside and (not d.near or clock - (d.tried or -RETRY) >= RETRY) then
        if not d.near then toast("info", "You are at the drop. Collecting the package...") end
        d.tried = clock
        autoPending = true
        M.uiAct("pickup")
      end
      d.near = inside
    end
  end
end

-- Phone app bridge -------------------------------------------------------------------------------------
local appState, appResult, appResultSeq = nil, nil, 0
local askedAt = -math.huge
local ASK_EVERY = 1                     -- whole seconds between server requests while the app polls (os.time: real time, os.clock is CPU time)

local function now() return os.time() end

local function onState(d)
  if type(d) == "table" then appState = d end
end

local function popup(text)
  if guihooks then
    guihooks.trigger("showConfirmationDialog", {text = text, buttons = {{label = "OK", luaCallback = "", enabled = true}}, class = "recoveryPrompt"})
  end
end

local function onResult(d)
  if type(d) ~= "table" then return end
  appResultSeq = appResultSeq + 1
  appResult = {text = tostring(d.text or ""):sub(1, 300), seq = appResultSeq}
  if autoPending then            -- the answer to an automatic pickup: a popup when it worked, one small toast when not
    autoPending = false
    if appResult.text:find("^Picked up") then popup(appResult.text) else toast("warning", appResult.text) end
  end
end

-- What the app shows: {state = last rlsmpMarketState or nil, result = {text, seq} or nil, enabled}. Asks the server when the answer is stale.
local loggedApp = false
function M.uiGet()
  if not loggedApp then
    loggedApp = true
    log("I", "RLSMP-MARKET", "the phone app reached the market extension (enabled=" .. tostring(enabled) .. ")")
  end
  if not enabled then return {enabled = false} end
  if now() - askedAt >= ASK_EVERY then
    askedAt = now()
    net.send("rlsmpMarketGet", {})
  end
  return {enabled = true, state = appState, result = appResult}
end

-- action: "buy" (item, n) | "pickup" | "invite" (who) | "accept" | "scout" (sends the stealable parked cars this game sees near us) go to the server;
-- "fence" (mode) | "meetup" (stolen car) | "meetupCancel" are done by the other client extensions. The answer arrives as a result and a new state.
function M.uiAct(action, a, b)
  if not enabled then return false end
  if type(action) ~= "string" then return false end
  if action == "fence" then
    if rlsmp_theft and rlsmp_theft.fence then rlsmp_theft.fence(a) end
    return true
  elseif action == "meetup" then
    if rlsmp_meetup and rlsmp_meetup.startBlack then rlsmp_meetup.startBlack() end
    return true
  elseif action == "meetupCancel" then
    if rlsmp_meetup and rlsmp_meetup.cancel then rlsmp_meetup.cancel() end
    return true
  end
  local body = {a = action}
  if action == "buy" then body.item, body.n = tostring(a or ""), tonumber(b) or 1
  elseif action == "invite" then body.who = tostring(a or "")
  elseif action == "scout" then
    local r = appState and appState.scout and tonumber(appState.scout.radius) or 800
    body.cars = rlsmp_theft and rlsmp_theft.stealableNear and rlsmp_theft.stealableNear(r, 8) or {}
  end
  if action == "pickup" and rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
  net.send("rlsmpMarketAct", body)
  askedAt = -math.huge                -- the next poll refreshes at once
  return true
end

function M.onServerLeave() appState, appResult, askedAt, marks, autoPending = nil, nil, -math.huge, {}, false end

function M.onExtensionLoaded()
  net.on("rlsmpMarketDrop", onDrop)
  net.on("rlsmpMarketClear", onClear)
  net.on("rlsmpMarketState", onState)
  net.on("rlsmpMarketResult", onResult)
  net.on("rlsmpMarketScout", onScout)
end

M._drops = function() return drops end
M._marks = function() return marks end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
