-- Black Market phone app: manifest rules (LuaJIT). Run: luajit tests/phone_app_manifest_test.lua
-- These are the rules RLS's own scanner applies (overhaul/lib/phone/appDiscovery.lua, lib/ui/routeValidation.lua, lib/platform/catalog.lua):
-- the manifest id must equal the file name, the component must be /ui/ui-vue/mods/<mod>/...vue, route paths stay inside /overhaul/.
-- A manifest RLS rejects only gets a warning in the game log and the app silently does not show up, so check it here.
package.path = "tests/support/?.lua;" .. package.path
local json = require("json")
local root = "Resources/Client/RLS-Career-MP/"
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
local function read(path) local h = assert(io.open(path, "rb"), "missing " .. path) local s = h:read("*a") h:close() return s end

local file = "gameplay/overhaul/phone/apps/black-market.json"
local app = json.decode(read(root .. file))
check(type(app) == "table", "manifest is a JSON object")
check(app.id == "black-market" and file:match("([^/]+)%.json$") == app.id, "id matches the file name")
check(app.id:match("^[%w][%w%._%-]*$") ~= nil, "id characters")
check(type(app.name) == "string" and app.name ~= "", "has a name")
check(type(app.icon) == "string" and app.icon ~= "", "has an icon")
check(type(app.route) == "string" and app.route:sub(1, 1) == "/", "route starts with /")
check(type(app.uiRoutes) == "table" and #app.uiRoutes == 1, "one ui route")
local r = app.uiRoutes[1]
check(r.name:match("^[%w][%w%._%-]*$") ~= nil, "route name")
check(not r.path:find("..", 1, true) and not r.path:find("\\", 1, true) and (r.path:sub(1, 1) ~= "/" or r.path:sub(1, 10) == "/overhaul/"), "route path stays inside /overhaul/")
check(r.component:match("^/ui/ui%-vue/mods/[^/]+/.+%.vue$") ~= nil and not r.component:find("..", 1, true), "component path is a .vue under /ui/ui-vue/mods/<mod>/")
check(("/overhaul/" .. r.path) == app.route, "the app's route is the route row's path")
check(r.backTarget == "phone-main", "Back goes to the phone's home")
local vue = read(root .. r.component:gsub("^/", ""))
check(vue:find("<template>", 1, true) and vue:find("<script setup>", 1, true), "the component file exists with a template and script")
check(not vue:find("rls_career_overhaul", 1, true), "the view imports nothing from the RLS mod's own files")
check(vue:find("lua.rlsmp_market.uiGet", 1, true) and vue:find("lua.rlsmp_market.uiAct", 1, true), "the view calls the client extension's two functions")

-- the client extension really offers them
local market = read(root .. "lua/ge/extensions/rlsmp/market.lua")
check(market:find("function M.uiGet", 1, true) and market:find("function M.uiAct", 1, true), "rlsmp_market exports uiGet and uiAct")
-- and the mod boots rlsmp_market so the global exists
local boot = read(root .. "lua/ge/extensions/rlsmp/core.lua")
check(boot:find('"market"', 1, true), "core loads the market extension")
print("phone_app_manifest_test: " .. passed .. " checks passed")
