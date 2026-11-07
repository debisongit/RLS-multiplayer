-- RLS-Career-MP client extension "rlsmp_trafficMenu": the in-game menu for the AI traffic settings.
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- Opened with the [ key (action rlsmpTrafficMenu, see core/input/actions/rlsmp.json) or the chat command /trafficmenu. Anybody can press the key, but the SERVER
-- decides: it only sends the settings (and only accepts changes) when the player is on its list (config `trafficAdmin`, server/trafficAdmin.lua).
-- The menu is an ImGui window (the same kind RLS's own debug tools use): sections Cars, Where & when, Behaviour, Amount, Swapping, Weather, Police, Theft, Fence, Market.
-- Changes are collected and sent as one patch with the Apply button; the server answers with what it applied and the fresh settings.
-- Pure logic (pending changes, the patch, the car lists): lib/trafficMenu.lua. Draw code only uses ImGui calls RLS itself uses.

local M = {}

local net = require("rlsmp/lib/net")
local p3 = require("rlsmp/lib/p3")
local L = require("rlsmp/lib/trafficMenu")
local ffi = require("ffi")

local WIN = "RLS Traffic settings"
local MODEL_ROWS = 60              -- rows of single cars shown at once (use the search box)

local st = L.new()
local open, wantOpen = false, false
local modelList = nil              -- the game's car list, read when the menu opens
local toggledImgui = false         -- we made ImGui visible and must put it back
local probed = false
local drawFailed = false
local inChild = false             -- between BeginChild1 and EndChild: a draw error must close it too (ImGui asserts on a mismatched stack)
local searchBuf, modBuf            -- ImGui text buffers
local readText = function(buf) local ok, s = pcall(ffi.string, buf) return ok and s or "" end

local function im() return rawget(_G, "ui_imgui") end

local function toast(kind, msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger("toastrMsg", {type = kind, title = "RLS Career MP", msg = msg, config = {timeOut = 6000}})
  end
end

-- What ImGui offers for showing the window and for the mouse: logged once, so the first test shows what is possible.
local function probeImgui()
  if probed then return end
  probed = true
  local lib = im()
  if type(lib) ~= "table" then p3.log("W", "probe: ui_imgui is not available: the traffic menu cannot be drawn") return end
  local names = {}
  for k, v in pairs(lib) do
    if type(v) == "function" and type(k) == "string" and (k:find("isible") or k:find("oggle") or k:find("nable") or k:find("ouse") or k:find("ursor")) then
      names[#names + 1] = k
    end
  end
  table.sort(names)
  p3.log("I", "probe: ui_imgui functions about visibility, input and the mouse = " .. (#names > 0 and table.concat(names, ",") or "(none)"))
end

-- Make ImGui visible if the game offers a way to ask and to switch it (guarded: unknown API), and remember to put it back.
local function ensureVisible()
  local lib = im()
  if type(lib) ~= "table" or type(lib.isVisible) ~= "function" or type(lib.toggleVisibility) ~= "function" then return end
  local ok, visible = pcall(lib.isVisible)
  if ok and visible == false then
    if pcall(lib.toggleVisibility) then toggledImgui = true p3.log("I", "traffic menu: ImGui was hidden, made visible") end
  end
end

local function restoreVisible()
  if not toggledImgui then return end
  toggledImgui = false
  local lib = im()
  if type(lib) == "table" and type(lib.toggleVisibility) == "function" then pcall(lib.toggleVisibility) end
end

local function readModels()
  modelList = nil
  if core_vehicles and core_vehicles.getModelList then
    local ok, list = pcall(core_vehicles.getModelList)
    if ok and type(list) == "table" then modelList = list end
  end
end

local function ask() net.send("rlsmpTrafficAdminGet", {}) end

function M.isOpen() return open end
function M.getState() return st end

local function doOpen()
  readModels()
  probeImgui()
  ensureVisible()
  open, wantOpen, drawFailed = true, false, false
  p3.log("I", "traffic menu opened")
end

function M.close()
  if open then p3.log("I", "traffic menu closed") end
  open, wantOpen = false, false
  restoreVisible()
end

-- The [ key: close if open, else ask the server (it answers with the settings only for admins).
function M.toggle()
  if open then return M.close() end
  wantOpen = true
  ask()
end

-- /trafficmenu: the server already checked, it asks us to open.
function M.open()
  wantOpen = true
  ask()
end

local function onState(data)
  if type(data) ~= "table" then return end
  if data.ok == true and type(data.cfg) == "table" then
    L.setSnapshot(st, data.cfg)
    if wantOpen then doOpen() end
  else
    wantOpen = false
    if open then M.close() end
    st.snap = nil
    toast("warning", "You are not allowed to use the traffic menu.")
  end
end

local function onResult(data)
  if type(data) ~= "table" then return end
  L.applyResult(st, data)
  p3.log("I", "traffic menu: " .. st.status)
end

-- Drawing --------------------------------------------------------------------------------------------------------------------------------------------------------
local function colored(ui, r, g, b, text) ui.TextColored(ui.ImVec4(r, g, b, 1), text) end

local function weightSlider(ui, label, path, minV, maxV, default, fmt, noReset)
  local k = table.concat(path, ".")
  local value = tonumber(L.get(st, path, default)) or default
  local ptr = ui.FloatPtr(value)
  ui.SetNextItemWidth(240)
  if ui.SliderFloat(label .. "##" .. k, ptr, minV, maxV, fmt or "%.2f") then L.set(st, path, ptr[0]) end
  if not noReset and L.isSet(st, path) then
    ui.SameLine()
    if ui.Button("reset##" .. k) then L.remove(st, path) end
  end
end

local function checkbox(ui, label, path)
  local ptr = ui.BoolPtr(L.get(st, path, false) == true)
  if ui.Checkbox(label .. "##" .. table.concat(path, "."), ptr) then L.set(st, path, ptr[0] == true) end
end

local function intInput(ui, label, path, minV, maxV)
  local ptr = ui.IntPtr(math.floor(tonumber(L.get(st, path, 0)) or 0))
  ui.SetNextItemWidth(140)
  if ui.InputInt(label .. "##" .. table.concat(path, "."), ptr) then
    L.set(st, path, math.max(minV, math.min(maxV, ptr[0])))
  end
end

-- The effective weight of one model: its own entry, else its Type's, else 1.
local function effectiveModelWeight(modelKey, t)
  local own = L.get(st, {"trafficVariety", "models", modelKey}, nil)
  if own ~= nil then return own end
  return L.get(st, {"trafficVariety", "typeWeights", t or "?"}, 1)
end

local function searchBox(ui, id, hint)
  searchBuf = searchBuf or ui.ArrayChar(64)
  ui.Text(hint)
  ui.SetNextItemWidth(240)
  if ui.InputText("##search" .. id, searchBuf, 64) then st.search = readText(searchBuf) end
end

local function typeSliders(ui, basePath, maxV)
  for _, t in ipairs(L.types(modelList)) do
    weightSlider(ui, string.format("%s (%d)", t.type, t.count), L.child(basePath, t.type), 0, maxV, 1)
  end
end

local function modelSliders(ui, basePath, useEffective)
  local rows = L.models(modelList, st.search, MODEL_ROWS)
  for _, row in ipairs(rows) do
    local path = L.child(basePath, row.key)
    local default = useEffective and effectiveModelWeight(row.key, row.type) or 1
    weightSlider(ui, string.format("%s [%s]", row.label, tostring(row.type or "?")), path, 0, 5, default)
  end
  if #rows == MODEL_ROWS then ui.Text("(more cars match: type more of the name)") end
end

local function sectionCars(ui)
  ui.TextWrapped("A car keeps its model once it exists. Changes here apply to traffic and parked cars built from now on (and to cars swapped in, if Swapping is on).")
  ui.Text("Car types: 1 = normal, 0 = never, 2 = twice as common")
  typeSliders(ui, {"trafficVariety", "typeWeights"}, 5)
  ui.Separator()
  ui.Text("Single cars: a car's own number replaces the number of its type")
  searchBox(ui, "cars", "Search a car:")
  modelSliders(ui, {"trafficVariety", "models"}, true)
  ui.Separator()
  ui.Text("Cars from mods the server ships (a game without the mod skips them)")
  for name in pairs((st.snap and st.snap.trafficVariety and st.snap.trafficVariety.mods) or {}) do
    weightSlider(ui, name, {"trafficVariety", "mods", name}, 0, 20, 1)
  end
  modBuf = modBuf or ui.ArrayChar(64)
  ui.SetNextItemWidth(240)
  if ui.InputText("##modname", modBuf, 64) then st.modName = readText(modBuf) end
  ui.SameLine()
  if ui.Button("Add mod car") then
    if L.goodName(st.modName) then L.set(st, {"trafficVariety", "mods", st.modName}, 1) else st.status, st.statusBad = "Type the mod car's model name first", true end
  end
end

local function sectionWhere(ui)
  ui.TextWrapped("Multiplies how common a car is on a kind of road or at a time of day. 1 = no change, 0 = never there, 2 = twice as common. One kind of road or one time is edited at a time. Road classes need the game to know road speed limits (the game log says).")
  for _, z in ipairs(L.ZONES) do
    if ui.Button((st.time == "any" and st.zone == z.id and "> " or "") .. z.label) then st.zone, st.time = z.id, "any" end
    ui.SameLine()
  end
  ui.Text("")
  for _, t in ipairs(L.TIMES) do
    if t.id ~= "any" then
      if ui.Button((st.time == t.id and "> " or "") .. t.label) then st.time = t.id end
      ui.SameLine()
    end
  end
  ui.Text("")
  local base = L.whereMap(st)
  colored(ui, 0.6, 0.9, 1, "Editing: " .. (st.time == "any" and (st.zone .. " roads") or st.time))
  typeSliders(ui, base, 5)
  ui.Separator()
  searchBox(ui, "where", "Search a car:")
  modelSliders(ui, base, false)
end

local function sectionBehaviour(ui)
  checkbox(ui, "Driver personalities on", {"smartTraffic", "enabled"})
  checkbox(ui, "Police chase racers and drunk drivers", {"smartTraffic", "policeReact"})
  ui.TextWrapped("How the AI drives. The numbers are relative weights: the share each type gets is shown next to it.")
  local shares = L.shares(st)
  for _, p in ipairs(L.PERSONALITIES) do
    weightSlider(ui, p[2], {"smartTraffic", "mix", p[1]}, 0, 100, 0, "%.0f")
    ui.SameLine()
    ui.Text(string.format("= %.1f%%", shares[p[1]]))
  end
end

local function sectionAmount(ui)
  checkbox(ui, "Traffic director on", {"traffic", "enabled"})
  ui.TextWrapped("How many traffic cars each game may keep active. Total budget 0 = automatic (base + per player x players online).")
  intInput(ui, "Total budget (0 = automatic)", {"traffic", "totalBudget"}, 0, 500)
  intInput(ui, "Base budget", {"traffic", "baseBudget"}, 0, 500)
  intInput(ui, "Per player", {"traffic", "perPlayerBudget"}, 0, 100)
  intInput(ui, "Fewest per player", {"traffic", "minPerPlayer"}, 0, 50)
  intInput(ui, "Most per player", {"traffic", "maxPerPlayer"}, 1, 100)
  ui.Separator()
  ui.Text("Cars per group")
  weightSlider(ui, "Largest share of one model", {"trafficVariety", "maxShare"}, 0.05, 1, 0.25)
  checkbox(ui, "Vary moving traffic", {"trafficVariety", "applyToTraffic"})
  checkbox(ui, "Vary parked cars", {"trafficVariety", "applyToParked"})
  checkbox(ui, "Car variety on", {"trafficVariety", "enabled"})
end

local function sectionSwap(ui)
  ui.TextWrapped("Swap a traffic car that nobody can see for a model that suits the road and time better.")
  checkbox(ui, "Watch only: log what would be swapped", {"trafficVariety", "swap", "enabled"})
  checkbox(ui, "LIVE: really replace cars", {"trafficVariety", "swap", "live"})
  colored(ui, 1, 0.7, 0.2, "Live swapping has never been tried in the game. It stops itself after 3 failures.")
  intInput(ui, "Swaps per minute", {"trafficVariety", "swap", "perMinute"}, 0, 12)
  weightSlider(ui, "Seconds hidden first", {"trafficVariety", "swap", "hiddenSeconds"}, 1, 120, 5, "%.0f")
  weightSlider(ui, "Gain needed (x)", {"trafficVariety", "swap", "minRatio"}, 1, 10, 1.5)
end

local function sectionWeather(ui)
  checkbox(ui, "Shared weather on", {"weather", "enabled"})
  local force = L.get(st, {"weather", "force"}, "")
  ui.Text("Pin one condition for everybody:")
  if ui.Button((force == "" and "> " or "") .. "Server mix") then L.set(st, {"weather", "force"}, "") end
  for _, c in ipairs(L.CONDITIONS) do
    ui.SameLine()
    if ui.Button((force == c[1] and "> " or "") .. c[2]) then L.set(st, {"weather", "force"}, c[1]) end
  end
  ui.Separator()
  ui.TextWrapped("How common each condition is when the weather is not pinned (relative weights).")
  for _, c in ipairs(L.CONDITIONS) do
    weightSlider(ui, c[2], {"weather", "mix", c[1]}, 0, 100, 0, "%.0f")
  end
end

local function sectionPolice(ui)
  checkbox(ui, "Police cannot appear in front of a chased player", {"police", "antiTeleport"})
  checkbox(ui, "No roadblocks", {"police", "blockRoadblocks"})
end

-- A plain number setting (always there, cannot be reset or removed): a slider.
local function num(ui, label, path, minV, maxV, fmt)
  weightSlider(ui, label, path, minV, maxV, minV, fmt, true)
end

local function sectionTheft(ui)
  ui.TextWrapped("Car theft: stealing a parked car with the right tools, and when it gets reported. Switching it on or off works at once.")
  checkbox(ui, "Car theft on", {"theft", "enabled"})
  num(ui, "Stealable parked cars (per 1000)", {"theft", "perMille"}, 0, 1000, "%.0f")
  num(ui, "New picks every (seconds)", {"theft", "periodSeconds"}, 60, 7200, "%.0f")
  num(ui, "Reach of a car (m)", {"theft", "radius"}, 1, 10, "%.1f")
  num(ui, "Wait after a try (s)", {"theft", "retrySeconds"}, 0, 120, "%.0f")
  ui.Separator()
  ui.Text("Witnesses and reports")
  num(ui, "Base chance to be seen", {"theft", "baseWitnessChance"}, 0, 1)
  num(ui, "More per witness nearby", {"theft", "perWitness"}, 0, 0.5)
  num(ui, "More for a loud method", {"theft", "noiseWitness"}, 0, 1)
  num(ui, "Highest chance", {"theft", "maxWitnessChance"}, 0, 1)
  num(ui, "Witnesses counted", {"theft", "witnessCap"}, 0, 20, "%.0f")
  num(ui, "Seen: reported after, at least (s)", {"theft", "seenReportMin"}, 1, 600, "%.0f")
  num(ui, "Seen: reported after, at most (s)", {"theft", "seenReportMax"}, 1, 600, "%.0f")
  num(ui, "Not seen: reported after (s)", {"theft", "unseenReportSeconds"}, 1, 3600, "%.0f")
  num(ui, "GPS tracker reports after (s)", {"theft", "trackerReportSeconds"}, 1, 600, "%.0f")
  num(ui, "Records kept (hours)", {"theft", "keepHours"}, 1, 168, "%.0f")
  num(ui, "Jammer keeps this share of the alarm noise", {"theft", "jammerNoiseFactor"}, 0, 1)
  ui.Separator()
  ui.Text("Which cars need which method (by year and price)")
  intInput(ui, "Immobilizer era starts (year)", {"theft", "tiers", "immobilizerYear"}, 1900, 2100)
  intInput(ui, "Keyless era starts (year)", {"theft", "tiers", "keylessYear"}, 1900, 2100)
  intInput(ui, "Newest cars start (year)", {"theft", "tiers", "newestYear"}, 1900, 2100)
  intInput(ui, "Luxury from a price of", {"theft", "tiers", "luxuryValue"}, 0, 100000000)
  ui.Separator()
  ui.Text("The methods")
  for _, name in ipairs(L.names(st, "theft", "methods")) do
    ui.Text(name)
    checkbox(ui, "  on", {"theft", "methods", name, "enabled"})
    num(ui, "  seconds", {"theft", "methods", name, "seconds"}, 1, 120, "%.0f")
    num(ui, "  noise", {"theft", "methods", name, "noise"}, 0, 1)
    num(ui, "  chance it fails", {"theft", "methods", name, "failChance"}, 0, 1)
  end
end

local function sectionFence(ui)
  ui.TextWrapped("The fence turns stolen cars into money at the black market's drop spot. The shares are of the car's value.")
  checkbox(ui, "Fence open", {"fence", "enabled"})
  num(ui, "Strip pays", {"fence", "stripRate"}, 0, 1)
  num(ui, "Resell with all papers pays", {"fence", "resellRate"}, 0, 1)
  num(ui, "Gamble pays (one paper)", {"fence", "gambleBase"}, 0, 1)
  num(ui, "Gamble: more per extra paper", {"fence", "gamblePerPaper"}, 0, 0.5)
  num(ui, "Gamble uses at most (papers)", {"fence", "gambleMaxPapers"}, 1, 3, "%.0f")
  num(ui, "Gamble: chance of a trap", {"fence", "gambleBust"}, 0, 1)
  intInput(ui, "Value of a car with no price", {"fence", "minValue"}, 0, 1000000)
  intInput(ui, "Highest car value counted", {"fence", "maxValue"}, 0, 100000000)
  ui.Separator()
  ui.Text("Reputation for a good sale")
  for _, mode in ipairs({"strip", "sell", "resell", "gamble"}) do
    num(ui, "  " .. mode, {"fence", "rep", mode}, 0, 25, "%.0f")
  end
  ui.TextWrapped("\"Sell\" pays the black market's fence share (Market section).")
end

local function sectionMarket(ui)
  ui.TextWrapped("The black market: invites, reputation, prices. Drop spot places are in config.json (market.dropSpots).")
  checkbox(ui, "Black market open", {"market", "enabled"})
  num(ui, "Fence pays for a car", {"market", "fenceCarRate"}, 0, 1)
  num(ui, "Fence pays for parts", {"market", "fencePartRate"}, 0, 1)
  intInput(ui, "Reputation lost in a bust", {"market", "bustRep"}, 0, 100)
  checkbox(ui, "A bust takes papers", {"market", "bustTakesPapers"})
  checkbox(ui, "A bust takes tools too", {"market", "bustTakesTools"})
  ui.Separator()
  ui.Text("Orders and drop spots")
  num(ui, "Package ready after, at least (s)", {"market", "minDelaySeconds"}, 0, 600, "%.0f")
  num(ui, "Package ready after, at most (s)", {"market", "maxDelaySeconds"}, 0, 600, "%.0f")
  intInput(ui, "Open orders at once", {"market", "maxOpenOrders"}, 1, 10)
  num(ui, "Pick up within (m)", {"market", "pickupRadius"}, 5, 100, "%.0f")
  intInput(ui, "Drop spot changes every (minutes)", {"market", "rotateMinutes"}, 1, 1440)
  ui.Separator()
  ui.Text("Invites")
  intInput(ui, "Invites to start with", {"market", "baseInvites"}, 0, 20)
  intInput(ui, "One more invite per this much reputation", {"market", "repPerInvite"}, 1, 100)
  intInput(ui, "Most invites", {"market", "maxInvites"}, 0, 50)
  ui.Separator()
  ui.Text("Items for sale (price, reputation needed, off)")
  for _, name in ipairs(L.names(st, "market", "tiers")) do
    ui.Text(name)
    intInput(ui, "  price", {"market", "tiers", name, "price"}, 1, 100000000)
    intInput(ui, "  reputation needed", {"market", "tiers", name, "minRep"}, 0, 100)
    checkbox(ui, "  not for sale", {"market", "tiers", name, "off"})
  end
end

local SECTIONS = {cars = sectionCars, where = sectionWhere, behaviour = sectionBehaviour, amount = sectionAmount, swap = sectionSwap,
  weather = sectionWeather, police = sectionPolice, theft = sectionTheft, fence = sectionFence, market = sectionMarket}

local function drawWindow(ui)
  if ui.Begin(WIN) then
    local dirty = L.dirty(st)
    if st.status ~= "" then colored(ui, st.statusBad and 1 or 0.5, st.statusBad and 0.4 or 1, st.statusBad and 0.4 or 0.5, st.status) end
    ui.Text(dirty > 0 and ("Unsaved changes: " .. dirty) or "No unsaved changes")
    if ui.Button("Apply") and dirty > 0 then
      net.send("rlsmpTrafficAdminSet", L.patch(st))
      st.status, st.statusBad = "Sent to the server...", false
    end
    ui.SameLine()
    if ui.Button("Revert") then L.revert(st) end
    ui.SameLine()
    if ui.Button("Refresh") then ask() end
    ui.SameLine()
    if ui.Button("Close") then M.close() end
    ui.Separator()
    for i, s in ipairs(L.SECTIONS) do
      if ui.Button((st.section == s.id and "> " or "") .. s.label) then st.section = s.id end
      if i % 5 ~= 0 and i < #L.SECTIONS then ui.SameLine() end   -- five tabs to a row: ten in one row would run out of the window
    end
    ui.Separator()
    ui.BeginChild1("rlsmpTrafficBody", ui.ImVec2(0, 460), true)
    inChild = true
    local body = SECTIONS[st.section] or sectionCars
    body(ui)
    inChild = false
    ui.EndChild()
  end
  ui.End()
end

function M.onUpdate()
  if not open then return end
  local ui = im()
  if type(ui) ~= "table" then return end
  local ok, err = pcall(drawWindow, ui)
  if not ok and not drawFailed then
    drawFailed = true
    p3.log("E", "traffic menu draw failed: " .. tostring(err))
    if inChild then inChild = false pcall(ui.EndChild) end
    pcall(ui.End)
    M.close()
    toast("error", "The traffic menu could not be drawn (see the game log).")
  end
end

function M.onServerLeave()
  M.close()
  st = L.new()
  modelList = nil
end

function M.onExtensionLoaded()
  net.on("rlsmpTrafficAdminState", onState)
  net.on("rlsmpTrafficAdminResult", onResult)
  net.on("rlsmpTrafficAdminOpen", function() M.open() end)
  p3.log("I", "rlsmp_trafficMenu loaded")
end

function M._setReader(fn) readText = fn end
M._drawWindow = drawWindow
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
