local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local bootstrap = read("installer")
local main = read("xreactor/installer_main.lua")

local bootstrap_checks = {
  "BASE_URL = \"https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/\"",
  "Installer source fixed to beta branch",
}

for _, snippet in ipairs(bootstrap_checks) do
  if not bootstrap:find(snippet, 1, true) then
    error("installer bootstrap release consistency snippet missing: " .. snippet)
  end
end

local main_checks = {
  "release metadata commit pin is not allowed in beta install strategy",
  "release metadata source_ref is not allowed in beta install strategy",
  "Installer source fixed to beta branch",
  "Manifest source_ref must be beta during normal install/update",
}

for _, snippet in ipairs(main_checks) do
  if not main:find(snippet, 1, true) then
    error("installer main release consistency snippet missing: " .. snippet)
  end
end

print("installer_release_pin_consistency_test.lua: ok")
