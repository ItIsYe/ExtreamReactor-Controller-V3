package.path = (package.path or "") .. ";/xreactor/?.lua;/xreactor/?/?.lua;/xreactor/?/init.lua"
local utils = require("core.utils")
local constants = require("shared.constants")

local roles = {
  MASTER = { path = "master", config = "master/config.lua" },
  [constants.roles.RT_NODE] = { path = "nodes/rt", config = "nodes/rt/config.lua" },
  [constants.roles.ENERGY_NODE] = { path = "nodes/energy", config = "nodes/energy/config.lua" },
  [constants.roles.FUEL_NODE] = { path = "nodes/fuel", config = "nodes/fuel/config.lua" },
  [constants.roles.WATER_NODE] = { path = "nodes/water", config = "nodes/water/config.lua" },
  [constants.roles.REPROCESSOR_NODE] = { path = "nodes/reprocessor", config = "nodes/reprocessor/config.lua" }
}

local function prompt(msg, default)
  write(msg .. (default and (" [" .. default .. "]") or "") .. ": ")
  local input = read()
  if input == "" then return default end
  return input
end

local function choose_role()
  print("Select role:")
  local list = {
    constants.roles.MASTER,
    constants.roles.RT_NODE,
    constants.roles.ENERGY_NODE,
    constants.roles.FUEL_NODE,
    constants.roles.WATER_NODE,
    constants.roles.REPROCESSOR_NODE
  }
  for i, r in ipairs(list) do
    print(string.format("%d) %s", i, r))
  end
  local choice = tonumber(prompt("Role number", 1)) or 1
  return list[choice] or constants.roles.MASTER
end

local function write_startup(role)
  local target = roles[role]
  local file = fs.open("startup.lua", "w")
  file.write([[shell.run("/xreactor/]] .. target.path .. [[/main.lua")]])
  file.close()
end

local function scan_peripherals()
  local list = {}
  for _, name in ipairs(peripheral.getNames()) do
    table.insert(list, string.format("%s (%s)", name, peripheral.getType(name)))
  end
  print("Peripherals detected:")
  for _, line in ipairs(list) do print(" - " .. line) end
end

local function write_config(role, wireless, wired, extras)
  local cfg_path = "xreactor/" .. roles[role].config
  local defaults = utils.read_config(cfg_path, {})
  defaults.role = role
  defaults.wireless_modem = wireless
  defaults.wired_modem = wired
  defaults.node_id = os.getComputerLabel() or os.getComputerID()
  if role == constants.roles.MASTER then
    defaults.monitor_auto = true
    defaults.ui_scale_default = extras.ui_scale_default or 0.5
  elseif role == constants.roles.RT_NODE then
    defaults.reactors = extras.reactors
    defaults.turbines = extras.turbines
  end
  utils.write_config(cfg_path, defaults)
end

local function main()
  print("=== XReactor Installer ===")
  local role = choose_role()
  local wireless = prompt("Wireless modem side", "right")
  local wired = prompt("Wired modem side", "left")
  local label = prompt("Node ID", os.getComputerLabel() or os.getComputerID())
  os.setComputerLabel(label)
  local extras = {}
  if role == constants.roles.MASTER then
    extras.ui_scale_default = tonumber(prompt("UI scale (0.5/1)", "0.5")) or 0.5
  elseif role == constants.roles.RT_NODE then
    scan_peripherals()
    local reactors = prompt("Reactor peripheral names (comma separated)", "")
    local turbines = prompt("Turbine peripheral names (comma separated)", "")
    extras.reactors = {}
    extras.turbines = {}
    for name in string.gmatch(reactors, "[^,]+") do table.insert(extras.reactors, utils.trim(name)) end
    for name in string.gmatch(turbines, "[^,]+") do table.insert(extras.turbines, utils.trim(name)) end
  end
  write_config(role, wireless, wired, extras)
  write_startup(role)
  print("Installation complete. Rebooting into role " .. role)
  os.sleep(1)
  os.reboot()
end

main()
