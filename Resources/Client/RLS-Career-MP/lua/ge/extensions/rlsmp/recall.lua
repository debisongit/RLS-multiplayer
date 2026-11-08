-- RLS-Career-MP client extension "rlsmp_recall": stolen cars survive leaving the game. Server side: server/recall.lua.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- A stolen car is a local car of ours, so it is gone after we disconnect. The server keeps what is needed to rebuild it.
--   * While a stolen car exists we report its place and rotation every REPORT_EVERY seconds (only when it moved; the server rate limits too).
--   * After the career started the server sends rlsmpStolenRestore {auto = true}: each car is created again at its last place
--     (rlsmp_theft.spawnStolen: the same safe spawn as the theft convert) when that place is free and no car with that plate exists.
--     A place that is invalid or farther than 5 km from us goes to the nearest drop spot, or beside us (lib/recall.lua).
--     A failed try is repeated a few times (TRIES), never more.
--   * The garage computer button and the Black Market app button call M.bringHere(): the server checks owner, record, cooldown and fee,
--     then answers rlsmpStolenRestore {auto = false}: the car is put beside us (an existing one is removed first, so there is only one).
-- Log: "stolen car restored: ...". Untested in-game.

local M = {}

local net = require("rlsmp/lib/net")
local R = require("rlsmp/lib/recall")
local T = require("rlsmp/lib/theft")

local TAG = "RLSMP-RECALL"
local REPORT_EVERY = 30   -- seconds between place reports
local REPORT_MOVE = 3     -- metres: report sooner only if the car moved this much
local REPORT_FORCE = 120  -- seconds: report even when it did not move
local FIRST_WAIT = 8      -- seconds after the message before the first try (the world and the parked cars settle)
local RETRY_WAIT = 15
local TRIES = 3

local enabled = false
local clock = 0
local queue = {}          -- plate -> {spec, auto, tries, at}
local spots = {}
local reported = {}       -- plate -> {x, y, z, t}

local function say(level, msg) log(level, TAG, msg) end
local function toast(kind, msg, ms)
  if guihooks then guihooks.trigger("toastrMsg", {type = kind, title = "Stolen car", msg = msg, config = {timeOut = ms or 5000}}) end
end

function M.enable(on)
  enabled = on == true
  if not enabled then queue, reported = {}, {} return end
  for _, q in pairs(queue) do if q.auto then q.at = clock + FIRST_WAIT end end   -- the message may have come before the career started
end

local function playerPos()
  local id = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  local o = id and id >= 0 and be:getObjectByID(id)
  local p = o and o:getPosition()
  return p and {x = p.x, y = p.y, z = p.z} or nil, id
end

-- Is another car (or the walker) standing at x, y?
local function taken(selfId)
  return function(x, y)
    for i = 0, (be.getObjectCount and be:getObjectCount() or 0) - 1 do
      local o = be:getObject(i)
      local p = o and o.getID and o:getID() ~= selfId and o:getPosition()
      if p and (p.x - x) ^ 2 + (p.y - y) ^ 2 < R.SPOT_FREE ^ 2 then return true end
    end
    return false
  end
end

local function done(plate) queue[plate] = nil end

-- One try for one queued car. Returns true when the queue entry is finished (restored or given up).
local function attempt(plate, q)
  local me, myId = playerPos()
  if not (me and rlsmp_theft and rlsmp_theft.spawnStolen and core_vehicles and core_vehicles.spawnNewVehicle) then return false end
  if q.auto and rlsmp_theft.liveByPlate(plate) then say("I", "stolen car restored: " .. plate .. " is already here, nothing to do") return true end
  if not q.auto then
    if rlsmp_theft.removeStolenByPlate then rlsmp_theft.removeStolenByPlate(plate) end   -- one live car per record
    local id = rlsmp_theft.liveByPlate(plate)
    local o = id and be:getObjectByID(id)
    if o then o:delete() end
  end
  local where = R.choose(q.spec, me, spots, taken(myId), not q.auto)
  local veh, why = rlsmp_theft.spawnStolen(q.spec, where, where.rot)
  if not veh then say("W", string.format("stolen car not restored (%s, try %d): %s", plate, q.tries, tostring(why))) return false end
  say("I", string.format("stolen car restored: %s %s at %.0f %.0f %.0f (%s)", plate, tostring(q.spec.model), where.x, where.y, where.z, where.how))
  if not q.auto then toast("success", "Your " .. tostring(q.spec.model) .. " " .. plate .. " is next to you.") end
  return true
end

local function placeReports()
  if not (rlsmp_theft and rlsmp_theft.stolenPlaces) then return end
  local cars = {}
  for _, c in ipairs(rlsmp_theft.stolenPlaces()) do
    if R.dueReport(reported[c.plate], c, clock, REPORT_EVERY, REPORT_MOVE, REPORT_FORCE) then
      reported[c.plate] = {x = c.x, y = c.y, z = c.z, t = clock}
      cars[#cars + 1] = c
    end
  end
  if #cars > 0 then net.send("rlsmpStolenPos", {cars = cars}) end
end

function M.onUpdate(dtReal)
  clock = clock + (dtReal or 0)
  if not enabled then return end
  for plate, q in pairs(queue) do
    if clock >= q.at then
      if attempt(plate, q) then
        done(plate)
      else
        q.tries = q.tries + 1
        q.at = clock + RETRY_WAIT
        if q.tries > TRIES then
          say("W", "stolen car " .. plate .. ": giving up after " .. TRIES .. " tries")
          if not q.auto then toast("warning", "The car could not be brought. Try again later.") end
          done(plate)
        end
      end
    end
  end
  placeReports()
end

-- The server sends the cars to put back.
local function onRestore(d)
  if type(d) ~= "table" or type(d.cars) ~= "table" then return end
  local auto = d.auto == true
  if auto then spots = type(d.spots) == "table" and d.spots or {} end
  for i, spec in ipairs(d.cars) do
    local plate = type(spec) == "table" and T.cleanPlate(tostring(spec.plate or "")) or nil
    if plate and type(spec.model) == "string" and i <= 8 and not (queue[plate] and not queue[plate].auto) then
      spec.plate = plate
      queue[plate] = {spec = spec, auto = auto, tries = 1, at = clock + (auto and FIRST_WAIT or 0)}
    end
  end
  say("I", string.format("stolen cars to put back: %d (%s)", #d.cars, auto and "after the join" or "button"))
end

local function onRefused(d)
  toast("warning", tostring(d and d.err or "The car could not be brought."), 6000)
end

-- Garage computer and Black Market app button: "Bring my stolen car here". Only asks; the server decides.
function M.bringHere(plate)
  if not enabled then return false end
  if rlsmp_positions and rlsmp_positions.reportNow then rlsmp_positions.reportNow() end
  net.send("rlsmpStolenRecall", {plate = type(plate) == "string" and plate or nil})
  return true
end

function M.onServerLeave()
  -- one last place report while the connection may still be open
  pcall(placeReports)
  queue, reported, spots = {}, {}, {}
end

function M.onExtensionLoaded()
  net.on("rlsmpStolenRestore", onRestore)
  net.on("rlsmpStolenRecallResult", onRefused)
end

M._queue = function() return queue end
M.onInit = function() setExtensionUnloadMode(M, "manual") end

require("rlsmp/lib/perf").wrap("recall", M)
return M
