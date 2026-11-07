-- Traffic menu client test (LuaJIT). Run: luajit tests/traffic_menu_client_test.lua
-- A fake ui_imgui: only the functions the game's ImGui really has are defined, so a misspelled widget makes the draw fail here.
package.path = "tests/support/?.lua;Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local json = require("json")
jsonEncode, jsonDecode = json.encode, json.decode
local logged = {}
function log(level, tag, msg) logged[#logged + 1] = level .. "|" .. tostring(msg) end
local function saw(f) for _, l in ipairs(logged) do if l:find(f, 1, true) then return true end end return false end
local handlers, sent = {}, {}
TriggerServerEvent = function(name, data) sent[#sent + 1] = {name = name, data = json.decode(data)} end
AddEventHandler = function(name, fn) handlers[name] = fn end
function setExtensionUnloadMode() end
local toasts = {}
guihooks = {trigger = function(n, d) toasts[#toasts + 1] = d.msg end}
core_vehicles = {getModelList = function() return {models = {
  etk800 = {Type = "Car", Brand = "ETK", Name = "800"}, pickup = {Type = "Truck", Brand = "Gavril", Name = "D-Series"}}} end}

local clicks, sliders, drawn = {}, {}, {}
local ui = {visible = true, toggles = 0}
local function rec(n) drawn[n] = (drawn[n] or 0) + 1 end
for _, n in ipairs({"Text", "TextWrapped", "TextColored", "Separator", "SameLine", "SetNextItemWidth", "EndChild", "End"}) do ui[n] = function() rec(n) end end
ui.Begin = function() rec("Begin") return true end
ui.BeginChild1 = function() rec("BeginChild1") return true end
ui.ImVec2 = function(x, y) return {x, y} end
ui.ImVec4 = function(...) return {...} end
ui.FloatPtr = function(v) return {[0] = v} end
ui.IntPtr = function(v) return {[0] = v} end
ui.BoolPtr = function(v) return {[0] = v} end
ui.ArrayChar = function() return {} end
ui.Button = function(label) rec("Button") local base = label:gsub("^> ", "") if clicks[base] then clicks[base] = nil return true end return false end
ui.Checkbox = function(label, ptr) rec("Checkbox") if clicks[label] then clicks[label] = nil ptr[0] = not ptr[0] return true end return false end
ui.SliderFloat = function(label, ptr) rec("SliderFloat") if sliders[label] ~= nil then ptr[0] = sliders[label] sliders[label] = nil return true end return false end
ui.InputInt = function(label, ptr) rec("InputInt") if sliders[label] ~= nil then ptr[0] = sliders[label] sliders[label] = nil return true end return false end
ui.InputText = function() rec("InputText") return false end
ui.isVisible = function() return ui.visible end
ui.toggleVisibility = function() ui.toggles = ui.toggles + 1 ui.visible = not ui.visible end
ui_imgui = ui

local M = require("rlsmp/trafficMenu")
M.onExtensionLoaded()
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function server(name, tbl) handlers[name](json.encode(tbl)) end
local SNAP = {trafficVariety = {typeWeights = {Truck = 0.5}, models = {}, mods = {}}, smartTraffic = {mix = {normal = 100}},
  weather = {force = "", mix = {}}, traffic = {}, police = {}}

-- 1. the key asks the server; a refusal opens nothing --------------------------------------------------------------------------
M.toggle()
check(#sent == 1 and sent[1].name == "rlsmpTrafficAdminGet", "the key asks the server")
M.onUpdate()
check(not M.isOpen() and not drawn.Begin, "nothing drawn before the server answers")
server("rlsmpTrafficAdminState", {ok = false})
check(not M.isOpen() and #toasts == 1, "refused: stays closed, tells the player")
M.onUpdate()
check(not drawn.Begin, "still nothing drawn")

-- 2. an admin gets the window ---------------------------------------------------------------------------------------------------
M.toggle()
server("rlsmpTrafficAdminState", {ok = true, cfg = SNAP})
check(M.isOpen() and saw("probe: ui_imgui functions"), "opened, ImGui probed")
ui.visible = false
M.close()
M.toggle()
server("rlsmpTrafficAdminState", {ok = true, cfg = SNAP})
check(ui.visible == true and ui.toggles == 1, "hidden ImGui made visible")
M.onUpdate()
check(drawn.Begin == 1 and drawn.SliderFloat and drawn.SliderFloat >= 3, "window and sliders drawn (Car/Truck types, models)")
check(not saw("draw failed"), "no draw error")

-- 3. every section draws without error --------------------------------------------------------------------------------------------
for _, s in ipairs({"Where & when", "Behaviour", "Amount", "Swapping", "Weather", "Police", "Cars"}) do
  clicks[s] = true
  M.onUpdate()
  M.onUpdate()
  check(not saw("draw failed"), "section " .. s .. " draws: " .. tostring(logged[#logged]))
end
check(M.getState().section == "cars", "section buttons switch")

-- 4. edit, apply -------------------------------------------------------------------------------------------------------------------
sliders["Truck (1)##trafficVariety.typeWeights.Truck"] = 3
M.onUpdate()
check(M.getState().pending["trafficVariety.typeWeights.Truck"].value == 3, "slider change is pending")
sent = {}
clicks["Apply"] = true
M.onUpdate()
check(#sent == 1 and sent[1].name == "rlsmpTrafficAdminSet" and #sent[1].data.set == 1 and sent[1].data.set[1].v == 3, "Apply sends the patch")
server("rlsmpTrafficAdminResult", {ok = true, applied = 1, rejected = {}, saved = true})
check(M.getState().status:find("applied and saved", 1, true) and next(M.getState().pending) == nil, "result clears pending")

-- 5. revert, reset, nothing to apply ------------------------------------------------------------------------------------------------
sliders["Truck (1)##trafficVariety.typeWeights.Truck"] = 4
M.onUpdate()
clicks["Revert"] = true
M.onUpdate()
check(next(M.getState().pending) == nil, "Revert drops edits")
sent = {}
clicks["Apply"] = true
M.onUpdate()
check(#sent == 0, "Apply with nothing pending sends nothing")

-- 6. close puts ImGui back; leaving the server closes --------------------------------------------------------------------------------
clicks["Close"] = true
M.onUpdate()
check(not M.isOpen() and ui.visible == false, "Close hides the window and restores ImGui")
M.toggle()
server("rlsmpTrafficAdminState", {ok = true, cfg = SNAP})
M.onServerLeave()
check(not M.isOpen() and M.getState().snap == nil, "leaving the server closes and forgets")

-- 7. the server's /trafficmenu push opens it ----------------------------------------------------------------------------------------
sent = {}
server("rlsmpTrafficAdminOpen", {})
check(#sent == 1, "server push asks for the state")
server("rlsmpTrafficAdminState", {ok = true, cfg = SNAP})
check(M.isOpen(), "opened by the chat command")

-- 8. a draw error closes the menu instead of spamming ---------------------------------------------------------------------------
ui.Text = function() error("boom") end
M.onUpdate()
check(not M.isOpen() and saw("draw failed"), "draw error: logged once, menu closed")

print(string.format("traffic_menu_client_test: %d checks passed", passed))
