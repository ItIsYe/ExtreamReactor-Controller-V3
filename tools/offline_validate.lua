local errors = {}
local function fail(x) errors[#errors+1] = tostring(x) end
local function exists(p) local f=io.open(p,"rb"); if f then f:close(); return true end return false end
local files = {
  "installer",
  "xreactor/start.lua",
  "xreactor/manifest.lua",
  "xreactor/release.lua",
  "xreactor/installer_main.lua"
}
for _,p in ipairs(files) do
  if not exists(p) then fail("missing