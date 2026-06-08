local errors = {}

local function fail(msg)
  errors[#errors + 1] = tostring(msg)
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local required = {
  "installer",
  "xreactor/start.lua",
  "xreactor/manifest.lua",
  "xreactor/release.lua",
  "xreactor/installer_main.lua",
  "xreactor/installer_manifest.lua",
  "xreactor/installer_stage.lua",
  "xreactor/installer_start