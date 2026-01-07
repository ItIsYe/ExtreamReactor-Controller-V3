local BASE_DIR = "/xreactor"
local REPO_BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/main"

local roles = {
  MASTER = "MASTER",
  RT_NODE = "RT-NODE",
  ENERGY_NODE = "ENERGY-NODE",
  FUEL_NODE = "FUEL-NODE",
  WATER_NODE = "WATER-NODE",
  REPROCESSOR_NODE = "REPROCESSOR-NODE"
}

local role_targets = {
  [roles.MASTER] = { path = "master", config = "master/config.lua" },
  [roles.RT_NODE] = { path = "nodes/rt", config = "nodes/rt/config.lua" },
  [roles.ENERGY_NODE] = { path = "nodes/energy", config = "nodes/energy/config.lua" },
  [roles.FUEL_NODE] = { path = "nodes/fuel", config = "nodes/fuel/config.lua" },
  [roles.WATER_NODE] = { path = "nodes/water", config = "nodes/water/config.lua" },
  [roles.REPROCESSOR_NODE] = { path = "nodes/reprocessor", config = "nodes/reprocessor/config.lua" }
}

local files_to_download = {
  "xreactor/core/network.lua",
  "xreactor/core/trends.lua",
  "xreactor/core/utils.lua",
  "xreactor/core/ui.lua",
  "xreactor/core/protocol.lua",
  "xreactor/core/safety.lua",
  "xreactor/core/state_machine.lua",
  "xreactor/nodes/rt/config.lua",
  "xreactor/nodes/rt/main.lua",
  "xreactor/nodes/reprocessor/config.lua",
  "xreactor/nodes/reprocessor/main.lua",
  "xreactor/nodes/water/config.lua",
  "xreactor/nodes/water/main.lua",
  "xreactor/nodes/fuel/config.lua",
  "xreactor/nodes/fuel/main.lua",
  "xreactor/nodes/energy/config.lua",
  "xreactor/nodes/energy/main.lua",
  "xreactor/master/config.lua",
  "xreactor/master/startup_sequencer.lua",
  "xreactor/master/profiles.lua",
  "xreactor/master/main.lua",
  "xreactor/master/ui/alarms.lua",
  "xreactor/master/ui/resources.lua",
  "xreactor/master/ui/rt_dashboard.lua",
  "xreactor/master/ui/overview.lua",
  "xreactor/master/ui/energy.lua",
  "xreactor/shared/colors.lua",
  "xreactor/shared/constants.lua",
  "xreactor/installer/installer.lua"
}

local function ensure_dir(path)
  if path == "" then return end
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function write_file(path, content)
  ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if not file then
    error("Unable to write file at " .. path)
  end
  file.write(content)
  file.close()
end

local function trim(text)
  if not text then return "" end
  return text:match("^%s*(.-)%s*$")
end

local function read_config(path, defaults)
  if not fs.exists(path) then
    return defaults or {}
  end
  local file = fs.open(path, "r")
  if not file then
    return defaults or {}
  end
  local content = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return defaults or {}
end

local function write_config_file(path, tbl)
  ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if not file then
    error("Unable to write config at " .. path)
  end
  file.write(textutils.serialize(tbl))
  file.close()
end

local function download_file(remote_path)
  local url = string.format("%s/%s", REPO_BASE_URL, remote_path)
  local response = http.get(url)
  if not response then
    error("Failed to download " .. url)
  end
  local content = response.readAll()
  response.close()
  write_file("/" .. remote_path, content)
end

local function install_files()
  ensure_dir(BASE_DIR)
  ensure_dir(BASE_DIR .. "/core")
  ensure_dir(BASE_DIR .. "/master")
  ensure_dir(BASE_DIR .. "/master/ui")
  ensure_dir(BASE_DIR .. "/nodes")
  ensure_dir(BASE_DIR .. "/nodes/rt")
  ensure_dir(BASE_DIR .. "/nodes/energy")
  ensure_dir(BASE_DIR .. "/nodes/fuel")
  ensure_dir(BASE_DIR .. "/nodes/water")
  ensure_dir(BASE_DIR .. "/nodes/reprocessor")
  ensure_dir(BASE_DIR .. "/shared")
  ensure_dir(BASE_DIR .. "/installer")

  for _, file in ipairs(files_to_download) do
    print("Downloading " .. file .. "...")
    download_file(file)
  end
end

local last_detection = { reactors = {}, turbines = {}, modems = {} }

local function scan_peripherals()
  local reactors = {}
  local turbines = {}
  local modems = {}
  for _, name in ipairs(peripheral.getNames()) do
    local peripheral_type = peripheral.getType(name)
    if peripheral_type == "BigReactors-Reactor" then
      table.insert(reactors, name)
    elseif peripheral_type == "BigReactors-Turbine" then
      table.insert(turbines, name)
    elseif peripheral_type == "modem" then
      table.insert(modems, name)
    end
  end
  last_detection = { reactors = reactors, turbines = turbines, modems = modems }
  return last_detection
end

local function prompt(msg, default)
  scan_peripherals()
  write(msg .. (default and (" [" .. default .. "]") or "") .. ": ")
  local input = read()
  if input == "" then return default end
  return input
end

local function choose_role()
  print("Select role:")
  local list = {
    roles.MASTER,
    roles.RT_NODE,
    roles.ENERGY_NODE,
    roles.FUEL_NODE,
    roles.WATER_NODE,
    roles.REPROCESSOR_NODE
  }
  for i, r in ipairs(list) do
    print(string.format("%d) %s", i, r))
  end
  local choice = tonumber(prompt("Role number", 1)) or 1
  return list[choice] or roles.MASTER
end

local function write_startup(role)
  local target = role_targets[role]
  local file = fs.open("/startup.lua", "w")
  file.write([[shell.run("/xreactor/]] .. target.path .. [[/main.lua")]])
  file.close()
end

local function print_detected(label, items)
  print(label .. ":")
  if #items == 0 then
    print(" - (none)")
    return
  end
  for _, name in ipairs(items) do
    print(" - " .. name)
  end
end

local function prompt_use_detected()
  scan_peripherals()
  write("Use detected peripherals? [Y/n]: ")
  local input = read()
  input = input:lower()
  if input == "" then return true end
  return input == "y" or input == "yes"
end

local function confirm(prompt_text, default)
  local hint = default and "Y/n" or "y/N"
  local input = prompt(prompt_text .. " (" .. hint .. ")", default and "y" or "n")
  input = input:lower()
  if input == "" then return default end
  return input == "y" or input == "yes"
end

local function write_config(role, wireless, wired, extras)
  local cfg_path = BASE_DIR .. "/" .. role_targets[role].config
  if fs.exists(cfg_path) then
    local overwrite = confirm("Config exists at " .. cfg_path .. ". Overwrite?", false)
    if not overwrite then
      print("Keeping existing config: " .. cfg_path)
      return
    end
  end
  local defaults = read_config(cfg_path, {})
  defaults.role = role
  defaults.wireless_modem = wireless
  defaults.wired_modem = wired
  defaults.node_id = os.getComputerLabel() or os.getComputerID()
  if role == roles.MASTER then
    defaults.monitor_auto = true
    defaults.ui_scale_default = extras.ui_scale_default or 0.5
  elseif role == roles.RT_NODE then
    defaults.reactors = extras.reactors
    defaults.turbines = extras.turbines
    defaults.modem = extras.modem
  end
  write_config_file(cfg_path, defaults)
end

local function main()
  if not http then
    error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
  end
  print("=== XReactor Installer ===")
  install_files()
  local role = choose_role()
  local wireless = prompt("Wireless modem side", "right")
  local wired = prompt("Wired modem side", "left")
  local label = prompt("Node ID", os.getComputerLabel() or os.getComputerID())
  os.setComputerLabel(label)
  local extras = {}
  if role == roles.MASTER then
    extras.ui_scale_default = tonumber(prompt("UI scale (0.5/1)", "0.5")) or 0.5
  elseif role == roles.RT_NODE then
    local detected = scan_peripherals()
    extras.modem = detected.modems[1]
    local use_detected = #detected.reactors > 0
    if use_detected then
      print_detected("Detected Reactors", detected.reactors)
      print_detected("Detected Turbines", detected.turbines)
      print_detected("Detected Modems", detected.modems)
      use_detected = prompt_use_detected()
    else
      print("Warning: No reactors detected. Switching to manual entry.")
    end

    if use_detected then
      extras.reactors = detected.reactors
      extras.turbines = detected.turbines
      if #detected.turbines == 0 then
        print("No turbines detected. Reactor-only setup will be used.")
      end
    else
      local reactors = prompt("Reactor peripheral names (comma separated)", "")
      local turbines = prompt("Turbine peripheral names (comma separated)", "")
      extras.reactors = {}
      extras.turbines = {}
      for name in string.gmatch(reactors, "[^,]+") do table.insert(extras.reactors, trim(name)) end
      for name in string.gmatch(turbines, "[^,]+") do table.insert(extras.turbines, trim(name)) end
    end
  end
  write_config(role, wireless, wired, extras)
  write_startup(role)
  print("Installation complete. Rebooting into role " .. role)
  os.sleep(1)
  os.reboot()
end

main()
