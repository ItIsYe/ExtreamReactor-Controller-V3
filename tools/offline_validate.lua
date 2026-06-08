-- Offline validator for GitHub Actions.
-- Runs outside Minecraft/CC:Tweaked and therefore only performs static checks.

local ROOT = "."
local errors = {}
local warnings = {}

local function fail(message)
  errors[#errors + 1] = tostring(message)
end

local function warn(message)
  warnings[#warnings + 1] = tostring(message)
end

local function path_join(a, b)
  if a == "." or a == "" then return b end
  return a .. "/" .. b
end
