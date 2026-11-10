-- The fast checksum gives exactly the old per-byte result (the server and the client must agree). Run: luajit tests/transfer_checksum_test.lua
package.path = "Resources/Client/RLS-Career-MP/lua/ge/extensions/?.lua;" .. package.path
local T = require("rlsmp/lib/transfer")
local function reference(str)
  local sum1, sum2 = 0, 0
  for k = 1, #str do
    sum1 = (sum1 + str:byte(k)) % 65535
    sum2 = (sum2 + sum1) % 65535
  end
  return string.format("%04x%04x", sum2, sum1)
end
math.randomseed(5)
local passed = 0
local function check(c, m) if not c then error("FAIL: " .. m, 2) end passed = passed + 1 end
check(T.checksum("") == reference(""), "empty string")
for _, n in ipairs({1, 2, 255, 256, 4095, 4096, 4097, 8192, 20000, 70001}) do
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  local s = table.concat(t)
  check(T.checksum(s) == reference(s), "random data of " .. n .. " bytes")
end
local worst = string.rep("\255", 300000)
check(T.checksum(worst) == reference(worst), "all 255 bytes")
print(string.format("transfer_checksum_test: %d checks passed", passed))
