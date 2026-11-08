-- The stealing mechanic must never tell the player to type a chat command. Run: lua5.3 tests/no_chat_hints_test.lua
-- Scans the player-facing code for quoted text with /steal /inspect /fence /market /meetup /items (comments are fine).
local files = {
  "Resources/Server/RLS-Career-MP/lua/rlsmp/server/theft.lua", "Resources/Server/RLS-Career-MP/lua/rlsmp/server/fence.lua",
  "Resources/Server/RLS-Career-MP/lua/rlsmp/server/market.lua", "Resources/Server/RLS-Career-MP/lua/rlsmp/server/meetup.lua",
  "Resources/Server/RLS-Career-MP/lua/rlsmp/server/items.lua",
  "Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/theft.lua", "Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/garage.lua",
  "Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/market.lua", "Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/meetup.lua",
  "Resources/Client/RLS-Career-MP/lua/ge/extensions/rlsmp/trafficMenu.lua",
  "Resources/Client/RLS-Career-MP/ui/ui-vue/mods/rls_career_mp/phone/PhoneBlackMarket.vue",
}
local words = {"steal", "inspect", "fence", "market", "meetup", "items"}
local bad, n = 0, 0
for _, path in ipairs(files) do
  local f = assert(io.open(path), path)
  local lineNo = 0
  for line in f:lines() do
    lineNo = lineNo + 1
    local code = line:gsub("%-%-.*$", "")                       -- Lua comments
    for _, w in ipairs(words) do
      if code:find('["\'%s(]/' .. w .. '%f[%A]') or code:find("[Tt]ype /") then
        -- net.onChat("market", ...) has no slash; anything with a slash inside text is a hint
        print("FAIL " .. path .. ":" .. lineNo .. ": " .. line)
        bad = bad + 1
      end
    end
  end
  f:close()
  n = n + 1
end
if bad > 0 then error(bad .. " chat command hint(s) left", 0) end
package.path = "Resources/Server/RLS-Career-MP/lua/?.lua;" .. package.path
local defaults = require("rlsmp.server.config").defaults
assert(defaults.ui and defaults.ui.chatCommands == false, "config ui.chatCommands must default to false")
print("no_chat_hints_test: " .. n .. " files clean")
