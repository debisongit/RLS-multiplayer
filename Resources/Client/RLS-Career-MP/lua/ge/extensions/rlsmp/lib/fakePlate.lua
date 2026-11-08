-- RLS-Career-MP client: fake plates on own cars, pure rules (no game calls; the extension is rlsmp/fakePlate.lua, the server side server/fakePlates.lua).
-- SPDX-License-Identifier: AGPL-3.0-only

local M = {}

-- Same cleaning as the server's plateRecords.cleanPlate (upper case, single spaces, 1 to 16 characters).
function M.clean(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):upper()
  if #s == 0 or #s > 16 or s:find("[%c|]") then return nil end
  return s
end

-- What to do with one fake plate record. rec = {fake, real}; invPlate = the plate text RLS keeps for the car (nil = no such car in the garage);
-- livePlate = the plate text on the spawned car (nil = not spawned or empty while RLS refreshes it).
--   "ok"      nothing to do
--   "reapply" RLS (or a respawn) put another plate back: write the fake plate again (record and car)
--   "drop"    the car is gone or the player changed the plate another way (RLS plate shop): forget the record
function M.decide(rec, invPlate, livePlate)
  local fake, real = M.clean(rec.fake), M.clean(rec.real)
  local inv, live = M.clean(invPlate), M.clean(livePlate)
  if not inv then return "drop" end
  if inv == fake then
    if live == nil or live == fake then return "ok" end
    return "reapply"
  end
  if inv == real then return "reapply" end
  return "drop"
end

return M
