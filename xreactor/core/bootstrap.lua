-- Centralized bootstrap for module loading (package.path).
local bootstrap = {}

local CONFIG = {
  BASE_DIR = "/xreactor",
  PATH_SUFFIX = ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
}

local function has_path(path, needle)
  return path:find(needle, 1, true) ~= nil
end

function bootstrap.setup()
  local current = package.path or ""
  if not has_path(current, CONFIG.BASE_DIR .. "/?.lua") then
    package.path = current .. CONFIG.PATH_SUFFIX
  end
end

function bootstrap.require(module_name)
  bootstrap.setup()
  return require(module_name)
end

return bootstrap
