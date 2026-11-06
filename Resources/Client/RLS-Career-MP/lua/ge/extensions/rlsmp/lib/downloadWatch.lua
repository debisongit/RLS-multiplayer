-- RLS-Career-MP: notices a save download that has stopped, so the player is never left silently
-- in plain BeamNG. Plain module (no game calls) so it can be unit tested.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Feed it the received/total chunk counts every frame. It says "stalled" when nothing new has
-- arrived for STALL seconds while downloading, or "no_answer" when the server has not started
-- sending within HELLO_WAIT seconds of our hello. A frame longer than MAX_STEP counts as MAX_STEP,
-- so a loading hitch (textures importing) cannot trigger a false alarm.

local M = {}

M.HELLO_WAIT = 60
M.STALL = 30
M.LOG_EVERY = 1
M.MAX_STEP = 5

function M.new() return {idle = 0, last = -1, logTimer = 0} end

function M.reset(w) w.idle, w.last, w.logTimer = 0, -1, 0 end

-- phase: "hello_sent" or "downloading". Returns verdict (nil | "no_answer" | "stalled"), logNow (bool).
function M.step(w, dt, got, phase)
  dt = math.min(dt or 0, M.MAX_STEP)
  if got ~= w.last then
    w.last = got
    w.idle = 0
  else
    w.idle = w.idle + dt
  end
  local logNow = false
  if phase == "downloading" then
    w.logTimer = w.logTimer + dt
    if w.logTimer >= M.LOG_EVERY then
      w.logTimer = 0
      logNow = true
    end
  end
  if phase == "hello_sent" and w.idle > M.HELLO_WAIT then return "no_answer", logNow end
  if phase == "downloading" and w.idle > M.STALL then return "stalled", logNow end
  return nil, logNow
end

return M
