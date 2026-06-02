if type(package) == "table" and type(package.path) == "string" then
  local extra = ";/xreactor/?.lua;/xreactor/?/init.lua;/xreactor/?/main.lua"
  if not package.path:find("/xreactor/%?%.lua", 1, false) then
    package.path = package.path .. extra
  end
end

local ok_constants, constants = pcall(require, "shared.constants")
if not ok_constants or type(constants) ~= "table" then
  constants = { channels = { LOG = 6502 } }
end

local CHANNEL = constants.channels and constants.channels.LOG or 6502
local FALLBACK_ROOT = "/xreactor_collected_logs"
local MAX_LOG_BYTES = 8192
local ROTATE_KEEP = 3
local MIN_FREE_BYTES = 1024

local stats = {
  received = 0,
  written = 0,
  dropped = 0,
  rotated = 0,
  pruned = 0,
  disk_switches = 0,
  disks = {},
  disk_index = 1,
  last_node = "-",
  last_level = "-",
  last_error = nil,
  log_root = nil,
  modem = nil
}

local function ensure_dir(path)
  if fs.exists(path) then return fs.isDir(path) end
  local ok = pcall(fs.makeDir, path)
  return ok and fs.exists(path) and fs.isDir(path)
end

local function free_space(path)
  if not fs.getFreeSpace then return math.huge end
  local ok, value = pcall(fs.getFreeSpace, path or "/")
  if not ok then return 0 end
  if type(value) == "string" then
    if value == "unlimited" then return math.huge end
    value = tonumber(value) or 0
  end
  return tonumber(value) or 0
end

local function add_unique(list, seen, path)
  if type(path) ~= "string" or path == "" or seen[path] then return end
  seen[path] = true
  list[#list + 1] = path
end

local function detect_disk_mounts()
  local roots, seen = {}, {}
  if peripheral and disk and type(peripheral.getNames) == "function" and type(disk.getMountPath) == "function" then
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then
      for _, name in ipairs(names) do
        local is_drive = false
        if peripheral.hasType then
          local ok_type, result = pcall(peripheral.hasType, name, "drive")
          is_drive = ok_type and result == true
        else
          local ok_type, ptype = pcall(peripheral.getType, name)
          is_drive = ok_type and ptype == "drive"
        end
        if is_drive then
          local ok_mount, mount = pcall(disk.getMountPath, name)
          if ok_mount then add_unique(roots, seen, mount) end
        end
      end
    end
  end
  if fs and fs.list then
    local ok, entries = pcall(fs.list, "/")
    if ok and type(entries) == "table" then
      table.sort(entries)
      for _, entry in ipairs(entries) do
        if type(entry) == "string" and entry:match("^disk%d*$") then add_unique(roots, seen, "/" .. entry) end
      end
    end
  end
  return roots
end

local function write_probe(root)
  local dir = root .. "/xreactor_logs"
  if not ensure_dir(dir) then return false end
  local path = dir .. "/.collector_probe"
  local ok = pcall(function()
    local h = fs.open(path, "w")
    if not h then error("open failed") end
    h.write("probe")
    h.close()
    fs.delete(path)
  end)
  return ok
end

local function discover_log_disks()
  local disks = {}
  for _, mount in ipairs(detect_disk_mounts()) do
    if ensure_dir(mount) and write_probe(mount) then
      disks[#disks + 1] = { mount = mount, root = mount .. "/xreactor_logs" }
    end
  end
  if #disks == 0 then
    ensure_dir(FALLBACK_ROOT)
    disks[#disks + 1] = { mount = "/", root = FALLBACK_ROOT, fallback = true }
  end
  table.sort(disks, function(a, b) return tostring(a.mount) < tostring(b.mount) end)
  return disks
end

local function refresh_disks_if_needed(force)
  if force or #stats.disks == 0 or stats.received % 200 == 0 then
    local current_root = stats.log_root
    stats.disks = discover_log_disks()
    stats.disk_index = 1
    if current_root then
      for i, d in ipairs(stats.disks) do
        if d.root == current_root then stats.disk_index = i; break end
      end
    end
    stats.log_root = stats.disks[stats.disk_index] and stats.disks[stats.disk_index].root or FALLBACK_ROOT
  end
end

local function current_disk()
  refresh_disks_if_needed(false)
  return stats.disks[stats.disk_index]
end

local function switch_next_disk()
  refresh_disks_if_needed(true)
  if #stats.disks == 0 then return nil end
  stats.disk_index = stats.disk_index + 1
  if stats.disk_index > #stats.disks then stats.disk_index = 1 end
  stats.log_root = stats.disks[stats.disk_index].root
  stats.disk_switches = stats.disk_switches + 1
  return stats.disks[stats.disk_index]
end

local function sanitize(value)
  local text = tostring(value or "unknown"):lower()
  text = text:gsub("[^a-z0-9_%-]+", "_")
  text = text:gsub("^_+", ""):gsub("_+$", "")
  if text == "" then return "unknown" end
  return text
end

local function format_line(payload)
  local ts = payload.ts or (os.epoch and os.epoch("utc")) or "?"
  return string.format("[%s] %s | %s | %s | %s", tostring(ts), tostring(payload.role or "?"), tostring(payload.prefix or "LOG"), tostring(payload.level or "INFO"), tostring(payload.message or payload.line or ""))
end

local function safe_delete(path)
  if fs.exists(path) then pcall(fs.delete, path) end
end

local function safe_move(from_path, to_path)
  if not fs.exists(from_path) then return false end
  safe_delete(to_path)
  local ok = pcall(fs.move, from_path, to_path)
  return ok
end

local function rotate_file(path)
  if not fs.exists(path) then return false end
  local size = fs.getSize(path)
  if size < MAX_LOG_BYTES then return false end
  safe_delete(path .. "." .. tostring(ROTATE_KEEP))
  for i = ROTATE_KEEP - 1, 1, -1 do
    safe_move(path .. "." .. tostring(i), path .. "." .. tostring(i + 1))
  end
  safe_move(path, path .. ".1")
  stats.rotated = stats.rotated + 1
  return true
end

local function prune_any_logs(root, aggressive)
  local removed = 0
  local function scan(dir)
    if not fs.exists(dir) or not fs.isDir(dir) then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return end
    table.sort(entries)
    for _, name in ipairs(entries) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then
        scan(path)
      elseif name:match("%.log%.%d+$") or name:match("%.old$") or name:match("%.bak$") or (aggressive and name:match("%.log$")) then
        safe_delete(path)
        removed = removed + 1
        if not aggressive and free_space(root) >= MIN_FREE_BYTES then return end
      end
    end
  end
  scan(root)
  stats.pruned = stats.pruned + removed
  return removed
end

local function try_write_to_disk(disk_entry, payload, allow_aggressive_prune)
  if not disk_entry or not disk_entry.root then return false, "no disk" end
  local root = disk_entry.root
  stats.log_root = root
  local role = sanitize(payload.role or "unknown")
  local node_id = sanitize(payload.node_id or "unknown")
  local dir = root .. "/" .. role
  if not ensure_dir(dir) then return false, "mkdir failed" end
  local path = dir .. "/" .. node_id .. ".log"
  rotate_file(path)
  if free_space(root) < MIN_FREE_BYTES then prune_any_logs(root, false) end
  if free_space(root) < 256 and allow_aggressive_prune then prune_any_logs(root, true) end
  if free_space(root) < 256 then return false, "disk full" end
  local line = format_line(payload) .. "\n"
  local ok, err = pcall(function()
    local h = fs.open(path, "a")
    if not h then error("open failed") end
    h.write(line)
    h.close()
  end)
  if not ok and allow_aggressive_prune then
    prune_any_logs(root, true)
    ok, err = pcall(function()
      local h = fs.open(path, "a")
      if not h then error("open failed") end
      h.write(line)
      h.close()
    end)
  end
  if not ok then return false, tostring(err or "write failed") end
  return true
end

local function write_log(payload)
  refresh_disks_if_needed(false)
  local count = math.max(1, #stats.disks)
  local last_err = nil
  for attempt = 1, count do
    local disk_entry = current_disk()
    local ok, err = try_write_to_disk(disk_entry, payload, false)
    if ok then return true end
    last_err = err
    switch_next_disk()
  end
  local disk_entry = current_disk()
  local ok, err = try_write_to_disk(disk_entry, payload, true)
  if ok then return true end
  return false, tostring(err or last_err or "all disks full")
end

local function find_modem()
  if not peripheral or not peripheral.getNames then return nil, nil end
  local names = peripheral.getNames()
  local fallback_name, fallback_modem = nil, nil
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem then
        local wireless = false
        if type(modem.isWireless) == "function" then
          local ok, result = pcall(modem.isWireless)
          wireless = ok and result == true
        end
        if wireless then return name, modem end
        fallback_name, fallback_modem = fallback_name or name, fallback_modem or modem
      end
    end
  end
  return fallback_name, fallback_modem
end

local function draw()
  refresh_disks_if_needed(false)
  local disk_entry = current_disk() or {}
  term.clear()
  term.setCursorPos(1, 1)
  print("XReactor LOG COLLECTOR")
  print("Channel: " .. tostring(CHANNEL))
  print("Modem:   " .. tostring(stats.modem or "none"))
  print("Disk:    " .. tostring(stats.disk_index) .. "/" .. tostring(#stats.disks) .. " " .. tostring(disk_entry.mount or "n/a"))
  print("Root:    " .. tostring(stats.log_root or "n/a"))
  print("Free:    " .. tostring(free_space(stats.log_root or "/")))
  print("Recv:    " .. tostring(stats.received))
  print("Written: " .. tostring(stats.written))
  print("Dropped: " .. tostring(stats.dropped))
  print("Switch:  " .. tostring(stats.disk_switches))
  print("Rotated: " .. tostring(stats.rotated))
  print("Pruned:  " .. tostring(stats.pruned))
  print("Last:    " .. tostring(stats.last_node) .. " " .. tostring(stats.last_level))
  if stats.last_error then print("Error:   " .. tostring(stats.last_error)) end
end

local function run()
  refresh_disks_if_needed(true)
  local modem_name, modem = find_modem()
  stats.modem = modem_name
  if not modem then error("No modem found for LOG collector", 0) end
  modem.open(CHANNEL)
  draw()
  while true do
    local _, _, channel, _, message = os.pullEvent("modem_message")
    if channel == CHANNEL and type(message) == "table" and message.type == "LOG_EVENT" then
      stats.received = stats.received + 1
      stats.last_node = message.node_id or "?"
      stats.last_level = message.level or "?"
      local ok, err = write_log(message)
      if ok then stats.written = stats.written + 1; stats.last_error = nil else stats.dropped = stats.dropped + 1; stats.last_error = err end
      if stats.received % 5 == 0 or not ok then draw() end
    end
  end
end

run()
