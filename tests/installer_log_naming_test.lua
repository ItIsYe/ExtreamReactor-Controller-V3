local function read(path)
  local file = assert(io.open(path, "r"))
  local content = file:read("*a")
  file:close()
  return content
end

local main = read("xreactor/installer_main.lua")
local storage = read("xreactor/installer_storage.lua")

local main_checks = {
  "function ctx.set_log_target(role_label)",
  "installer_%s.log",
  "ctx.set_log_target(role.label)",
  "ctx.set_log_target(role_label)",
  "ctx.info(\"Installer log target: \" .. tostring(ctx.constants.LOG_PATH))"
}

for _, snippet in ipairs(main_checks) do
  if not main:find(snippet, 1, true) then
    error("installer log naming missing snippet: " .. snippet)
  end
end

if not storage:find("name:match(\"^installer(?:_[a-z0-9_%%-]+)?%%.log%%.%d+$\")", 1, true) then
  error("installer storage rotation guard missing installer role log pattern")
end

local install_target_pos = main:find("ctx.set_log_target(role.label)", 1, true)
local install_action_pos = main:find("ctx.info(\"Selected action: Neuinstallation\")", 1, true)
if not install_target_pos or not install_action_pos or install_target_pos > install_action_pos then
  error("installer install action log must happen after role log target is set")
end

local update_target_pos = main:find("ctx.set_log_target(role_label)", 1, true)
local update_action_pos = main:find("ctx.info(\"Selected action: Update\")", 1, true)
if not update_target_pos or not update_action_pos or update_target_pos > update_action_pos then
  error("installer update action log must happen after role log target is set")
end

print("installer_log_naming_test.lua: ok")
