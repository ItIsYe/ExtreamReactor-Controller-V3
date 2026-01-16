local BASE_DIR = "/xreactor"
local REPO_BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/main"
local MANIFEST_REMOTE = "xreactor/installer/manifest.lua"
local MANIFEST_LOCAL = BASE_DIR .. "/.manifest"
local BACKUP_BASE = "/xreactor_backup"
local NODE_ID_PATH = BASE_DIR .. "/data/node_id.txt"

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

local function ensure_dir(path)
  if path == "" then return end
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function trim(text)
  if not text then return "" end
  return text:match("^%s*(.-)%s*$")
end

local function read_file(path)
  if not fs.exists(path) then return nil end
  local file = fs.open(path, "r")
  if not file then return nil end
  local content = file.readAll()
  file.close()
  return content
end

local function write_atomic(path, content)
  ensure_dir(fs.getDir(path))
  local tmp = path .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then
    error("Unable to write file at " .. path)
  end
  file.write(content)
  file.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
end

local function copy_file(src, dst)
  local content = read_file(src)
  if content == nil then return false end
  write_atomic(dst, content)
  return true
end

local function checksum(content)
  local sum = 0
  for i = 1, #content do
    sum = (sum + string.byte(content, i)) % 1000000007
  end
  return tostring(sum) .. ":" .. tostring(#content)
end

local function file_checksum(path)
  local content = read_file(path)
  if not content then return nil end
  return checksum(content)
end

local function read_config(path, defaults)
  if not fs.exists(path) then
    return defaults or {}
  end
  local content = read_file(path)
  if not content then
    return defaults or {}
  end
  local loader = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      return data
    end
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return defaults or {}
end

local function read_config_from_content(content)
  if not content then return {} end
  local loader = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      return data
    end
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local function write_config_file(path, tbl)
  write_atomic(path, "return " .. textutils.serialize(tbl))
end

local function merge_defaults(target, defaults)
  local changed = false
  for key, value in pairs(defaults or {}) do
    if target[key] == nil then
      target[key] = value
      changed = true
    elseif type(target[key]) == "table" and type(value) == "table" then
      local inner_changed = merge_defaults(target[key], value)
      changed = changed or inner_changed
    end
  end
  return changed
end

local function download_content(remote_path)
  local url = string.format("%s/%s", REPO_BASE_URL, remote_path)
  local response = http.get(url)
  if not response then
    error("Failed to download " .. url)
  end
  local content = response.readAll()
  response.close()
  return content
end

local function download_manifest()
  local content = download_content(MANIFEST_REMOTE)
  local loader = load(content, "manifest", "t", {})
  if not loader then
    error("Manifest load failed")
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
    error("Manifest parse failed")
  end
  return content, data
end

local function ensure_base_dirs()
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
  ensure_dir(BASE_DIR .. "/data")
end

local function is_config_file(path)
  return path:match("/config%.lua$") ~= nil
end

local function prompt(msg, default)
  write(msg .. (default and (" [" .. default .. "]") or "") .. ": ")
  local input = read()
  if input == "" then return default end
  return input
end

local function confirm(prompt_text, default)
  local hint = default and "Y/n" or "y/N"
  local input = prompt(prompt_text .. " (" .. hint .. ")", default and "y" or "n")
  input = input:lower()
  if input == "" then return default end
  return input == "y" or input == "yes"
end

local last_detection = { reactors = {}, turbines = {}, modems = {} }

local function is_wireless_modem(name)
  local ok, result = pcall(peripheral.call, name, "isWireless")
  if ok then return result end
  return false
end

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

local function detect_modems()
  local wireless = {}
  local wired = {}
  for _, name in ipairs(scan_peripherals().modems) do
    if is_wireless_modem(name) then
      table.insert(wireless, name)
    else
      table.insert(wired, name)
    end
  end
  return { wireless = wireless, wired = wired }
end

local function select_primary_modem(modems)
  if #modems.wireless > 0 then
    return modems.wireless[1]
  end
  if #modems.wired > 0 then
    return modems.wired[1]
  end
  return nil
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
  write_atomic("/startup.lua", [[shell.run("/xreactor/]] .. target.path .. [[/main.lua")]])
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

local function write_config(role, wireless, wired, extras)
  local cfg_path = BASE_DIR .. "/" .. role_targets[role].config
  local defaults = read_config(cfg_path, {})
  defaults.role = role
  defaults.wireless_modem = wireless
  defaults.wired_modem = wired
  if defaults.node_id == nil then
    defaults.node_id = os.getComputerLabel() or os.getComputerID()
  end
  if role == roles.MASTER then
    defaults.monitor_auto = true
    defaults.ui_scale_default = extras.ui_scale_default or 0.5
  elseif role == roles.RT_NODE then
    defaults.reactors = extras.reactors
    defaults.turbines = extras.turbines
    defaults.modem = extras.modem
    if extras.node_id then
      defaults.node_id = extras.node_id
    end
  end
  write_config_file(cfg_path, defaults)
end

local function build_rt_node_id()
  local id_str = tostring(os.getComputerID())
  local suffix = id_str:sub(-4)
  return "RT-" .. suffix
end

local function find_existing_role()
  for role, target in pairs(role_targets) do
    local cfg_path = BASE_DIR .. "/" .. target.config
    if fs.exists(cfg_path) then
      local cfg = read_config(cfg_path, {})
      if cfg.role == role then
        return role, cfg_path, cfg
      end
    end
  end
  return nil, nil, nil
end

local function create_backup_dir()
  ensure_dir(BACKUP_BASE)
  local stamp = os.date("%Y%m%d_%H%M%S")
  local path = BACKUP_BASE .. "/" .. stamp
  ensure_dir(path)
  return path
end

local function backup_files(base_dir, paths)
  for _, path in ipairs(paths) do
    if fs.exists(path) then
      local target = base_dir .. path
      ensure_dir(fs.getDir(target))
      copy_file(path, target)
    end
  end
end

local function rollback_from_backup(base_dir, paths, created)
  for _, path in ipairs(paths) do
    local backup_path = base_dir .. path
    if fs.exists(backup_path) then
      ensure_dir(fs.getDir(path))
      copy_file(backup_path, path)
    end
  end
  for _, path in ipairs(created) do
    if fs.exists(path) then
      fs.delete(path)
    end
  end
end

local function update_files(manifest)
  local updates = {}
  for path, expected_hash in pairs(manifest.files) do
    if not is_config_file(path) then
      local local_hash = file_checksum("/" .. path)
      if local_hash ~= expected_hash then
        table.insert(updates, { path = path, hash = expected_hash })
      end
    end
  end
  table.sort(updates, function(a, b) return a.path < b.path end)
  return updates
end

local function migrate_config(role, cfg_path, manifest)
  local remote_path = "xreactor/" .. role_targets[role].config
  local expected_hash = manifest.files[remote_path]
  if not expected_hash then
    return false
  end
  local content = download_content(remote_path)
  if checksum(content) ~= expected_hash then
    error("Config checksum mismatch for " .. remote_path)
  end
  local defaults = read_config_from_content(content)
  local existing = read_config(cfg_path, {})
  local original = textutils.serialize(existing)
  merge_defaults(existing, defaults)
  if existing.role ~= role then
    existing.role = role
  end
  if existing.node_id == nil then
    existing.node_id = os.getComputerLabel() or os.getComputerID()
  end
  if textutils.serialize(existing) ~= original then
    write_config_file(cfg_path, existing)
    return true
  end
  return false
end

local function verify_integrity(manifest, role, cfg_path)
  local required = {
    "xreactor/core/network.lua",
    "xreactor/core/protocol.lua",
    "xreactor/shared/constants.lua",
    "xreactor/installer/installer.lua"
  }
  if role == roles.MASTER then
    table.insert(required, "xreactor/master/main.lua")
  else
    table.insert(required, "xreactor/nodes/rt/main.lua")
  end
  for _, path in ipairs(required) do
    if not fs.exists("/" .. path) then
      return false, "Missing " .. path
    end
  end
  if role and cfg_path and not fs.exists(cfg_path) then
    return false, "Missing config"
  end
  if not fs.exists(NODE_ID_PATH) then
    return false, "Missing node_id"
  end
  return true
end

local function safe_update()
  local role, cfg_path = find_existing_role()
  if not role then
    print("No existing role config found. Use FULL REINSTALL.")
    return
  end

  local manifest_content, manifest = download_manifest()
  ensure_base_dirs()

  local updates = update_files(manifest)
  local backup_dir = create_backup_dir()
  local protected = { cfg_path, NODE_ID_PATH, "/startup.lua", MANIFEST_LOCAL }
  local update_paths = {}
  local created = {}
  for _, entry in ipairs(updates) do
    table.insert(update_paths, "/" .. entry.path)
  end

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, protected)

  local changed = 0
  local ok = true
  local err
  for _, entry in ipairs(updates) do
    local target_path = "/" .. entry.path
    local content
    local success, result = pcall(download_content, entry.path)
    if success then
      content = result
    else
      ok = false
      err = result
      break
    end
    if checksum(content) ~= entry.hash then
      ok = false
      err = "Checksum mismatch for " .. entry.path
      break
    end
    if not fs.exists(target_path) then
      table.insert(created, target_path)
    end
    local write_ok, write_err = pcall(write_atomic, target_path, content)
    if not write_ok then
      ok = false
      err = write_err
      break
    end
    changed = changed + 1
  end

  local migrated = false
  if ok then
    local success, result = pcall(migrate_config, role, cfg_path, manifest)
    if success then
      migrated = result
    else
      ok = false
      err = result
    end
  end

  if ok then
    local success, result = pcall(write_atomic, MANIFEST_LOCAL, manifest_content)
    if not success then
      ok = false
      err = result
    end
  end

  if not ok then
    local rollback_paths = {}
    for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
    for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("SAFE UPDATE failed. Rolled back. Error: " .. tostring(err))
    print("Backup: " .. backup_dir)
    return
  end

  local integrity_ok, integrity_err = verify_integrity(manifest, role, cfg_path)
  if not integrity_ok then
    local rollback_paths = {}
    for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
    for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("Integrity check failed: " .. tostring(integrity_err))
    print("Rollback complete. Backup: " .. backup_dir)
    return
  end

  print("SAFE UPDATE complete.")
  print("Changed files: " .. tostring(changed))
  if migrated then
    print("Config migration: updated defaults")
  end
  print("Backup: " .. backup_dir)
  print("Next steps: reboot or run the role entrypoint.")
end

local function full_reinstall()
  local manifest_content, manifest = download_manifest()
  ensure_base_dirs()
  local updates = {}
  for path in pairs(manifest.files) do
    table.insert(updates, path)
  end
  table.sort(updates)
  for _, path in ipairs(updates) do
    local content = download_content(path)
    local expected = manifest.files[path]
    if checksum(content) ~= expected then
      error("Checksum mismatch for " .. path)
    end
    write_atomic("/" .. path, content)
  end

  local role = choose_role()
  local cfg_path = BASE_DIR .. "/" .. role_targets[role].config
  local modems = detect_modems()
  local wireless = select_primary_modem(modems)
  local wired = modems.wired[1]
  local extras = {}

  if not wireless then
    wireless = prompt("Primary modem side", nil)
  end
  if wireless and wired == wireless then
    wired = nil
  end

  if role == roles.RT_NODE then
    local label = build_rt_node_id()
    os.setComputerLabel(label)
  end

  if role == roles.MASTER then
    extras.ui_scale_default = tonumber(prompt("UI scale (0.5/1)", "0.5")) or 0.5
  elseif role == roles.RT_NODE then
    local detected = scan_peripherals()
    extras.modem = wireless
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
    if not wireless then
      extras.modem = prompt("Modem peripheral name", nil)
    end
  end

  if role == roles.RT_NODE then
    extras.node_id = build_rt_node_id()
  end
  write_config(role, wireless, wired, extras)
  write_startup(role)
  write_atomic(MANIFEST_LOCAL, manifest_content)

  print("FULL REINSTALL complete.")
  print("Next steps: reboot or run the role entrypoint.")
end

local function main()
  if not http then
    error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
  end
  print("=== XReactor Installer ===")
  if fs.exists(BASE_DIR) then
    print("Existing installation detected.")
    print("1) SAFE UPDATE")
    print("2) FULL REINSTALL")
    print("3) CANCEL")
    local choice = tonumber(prompt("Select option", "1")) or 1
    if choice == 1 then
      safe_update()
    elseif choice == 2 then
      full_reinstall()
    else
      print("Cancelled.")
    end
  else
    full_reinstall()
  end
end

main()
