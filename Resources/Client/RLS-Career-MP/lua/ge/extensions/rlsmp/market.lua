-- RLS-Career-MP client extension "rlsmp_market": shows black market drop spots (rules and money: server/market.lua).
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- The server says where a paid package will be (rlsmpMarketDrop) and when it was collected (rlsmpMarketClear).
-- This side only: a toast when an order is placed and when it is ready, a marker drawn at a ready spot when it is
-- near, and a "type /market pickup" toast inside 15 m (it also asks rlsmp_positions to report right away, so the
-- server's copy of our position is fresh). Pickup itself is the chat command; the server checks the position.
-- The phone app (ui/ui-vue/mods/rls_career_mp/phone/PhoneBlackMarket.vue) calls M.uiGet() about every 1.5 s and M.uiAct(...) on a tap; both
-- only relay to the server (rlsmpMarketGet / rlsmpMarketAct) and hand back what the server last said. No rules here.
-- We do not use core_groundMarkers: RLS jobs (taxi, bus) own that route and would lose it.

local M = {}

local net = require("rlsmp/lib/net")

local NEAR = 15        -- meters (horizontal): "you are at the drop"
local DRAW = 300       -- meters: draw the marker when closer than this
local CHECK = 1        -- seconds between checks

local enabled = false
local drops = {}       -- id -> {label, spot, x, y, z, readyAt, told, near}
local clock, checkTimer = 0, 0

local function toast(kind, msg)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Black market", msg = msg, config = {timeOut = 8000}}) end
end

function M.enable(on)
  enabled = on == true
  if not enabled then drops = {} end
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
    debugDrawer:drawTextAdvanced(vec3(d.x, d.y, d.z + 3.5), String("Drop: " .. d.label), ColorF(1, 1, 1, 1), true, false,
      ColorI(0, 0, 0, 192))
  end)
end

function M.onUpdate(dtReal)
  if not enabled or next(drops) == nil then return end
  dtReal = dtReal or 0
  clock, checkTimer = clock + dtReal, checkTimer + dtReal
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
      if inside and not d.near then
        toast("info", "You are at the drop. Type /market pickup in chat.")
        if rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
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

local function onResult(d)
  if type(d) ~= "table" then return end
  appResultSeq = appResultSeq + 1
  appResult = {text = tostring(d.text or ""):sub(1, 300), seq = appResultSeq}
end

-- What the app shows: {state = last rlsmpMarketState or nil, result = {text, seq} or nil, enabled}. Asks the server when the answer is stale.
function M.uiGet()
  if not enabled then return {enabled = false} end
  if now() - askedAt >= ASK_EVERY then
    askedAt = now()
    net.send("rlsmpMarketGet", {})
  end
  return {enabled = true, state = appState, result = appResult}
end

-- action: "buy" (item, n) | "pickup" | "invite" (who) | "accept". The answer arrives as a result and a new state.
function M.uiAct(action, a, b)
  if not enabled then return false end
  if type(action) ~= "string" then return false end
  local body = {a = action}
  if action == "buy" then body.item, body.n = tostring(a or ""), tonumber(b) or 1
  elseif action == "invite" then body.who = tostring(a or "") end
  if action == "pickup" and rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
  net.send("rlsmpMarketAct", body)
  askedAt = -math.huge                -- the next poll refreshes at once
  return true
end

function M.onServerLeave() appState, appResult, askedAt = nil, nil, -math.huge end

function M.onExtensionLoaded()
  net.on("rlsmpMarketDrop", onDrop)
  net.on("rlsmpMarketClear", onClear)
  net.on("rlsmpMarketState", onState)
  net.on("rlsmpMarketResult", onResult)
end

M._drops = function() return drops end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
