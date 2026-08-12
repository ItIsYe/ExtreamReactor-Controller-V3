local f=assert(io.open("installer","r")); local src=f:read("*a"); f:close()
-- Installerstruktur: muss Lua-Code sein (syntaktisch)
local fn, err = load(src)
if not fn then error("installer is not valid Lua: " .. tostring(err)) end
-- Muss mindestens eine Funktion oder return-Statement enthalten
assert(src:find("function ", 1, true) ~= nil or src:find("return", 1, true) ~= nil,
  "installer must define functions or return a table")
print("installer_standalone_bootstrap_test.lua: ok")
