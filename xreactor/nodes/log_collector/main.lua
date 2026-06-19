if type(package) == "table" and type(package.path) == "string" then
  local extra = ";/xreactor/?.lua;/xreactor/?/init.lua;/xreactor/?/main.lua"
  if not package.path:find("/xreactor/%?%.lua", 1, false) then
    package.path = package.path .. extra
  end
end

local ok_utils, utils = pcall(require, "core.utils")
if not ok_utils or type(utils) ~= "table" then utils = nil end

local ok_constants, constants = pcall(require, "shared.constants")
if not ok_constants or type(constants) ~= "table" then
  constants = { channels = { LOG = 6502 } }
end

local CHANNEL = constants.channels and constants.channels.LOG or 6502
local FALLBACK_ROOT = "/xreactor_collected_logs"
local MAX_LOG_BYTES = 2097152  -- 2 MB pro Log-Datei (auf externer Disk reichlich Platz)
local ROTATE_KEEP = 8  -- 8 Rotationen × 2 MB = max 16 MB pro Node
local MIN_FREE_BYTES = 262144  -- 256 KB freier Platz Mindest-Schwelle
local DEDUPE_LIMIT = 512
local MODEM_REFRESH_SECONDS = 10
local SELF_ROLE = "LOG_COLLECTOR"
local MONITOR_NAME_FILE = "/xreactor/config/log_monitor.txt"

local stats = {
  received = 0,
  written = 0,
  dropped = 0,
  duplicates = 0,
  ack_sent = 0,
  paused_dropped = 0,
  rotated = 0,
  pruned = 0,
  disk_switches = 0,
  disks = {},
  disk_diag = {},
  disk_index = 1,
  last_write_index = nil,
  last_write_mount = "-",
  last_write_root = "-",
  last_write_path = "-",
  last_node = "-",
  last_level = "-",
  last_error = nil,
  log_root = nil,
  modem = nil,
  modems = {},
  modem_refreshes = 0,
  next_modem_refresh_at = 0,
  display = nil,
  display_name = "term",
  paused = false,
  pause_button = nil,
  log_mode_buttons = {},
  seen = {},
  seen_order = {}
}

local function c(name)
  if not colors then return nil end
  return colors[name] or colors.white
end

local function set_fg(color)
  if term.setTextColor and color then term.setTextColor(color) end
end

local function set_bg(color)
  if term.setBackgroundColor and color then term.setBackgroundColor(color) end
end

local function now_ticks()
  if os and type(os.clock) == "function" then
    local ok, value = pcall(os.clock)
    if ok and type(value) == "number" then return value end
  end
  if os and type(os.epoch) == "function" then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then return math.floor(value / 1000) end
  end
  return 0
end

local function fit(text, width)
  local raw = tostring(text or ""):gsub("\n", " "):gsub("\r", " ")
  local w = math.max(1, tonumber(width) or #raw)
  if #raw <= w then return raw end
  if w <= 2 then return raw:sub(1, w) end
  return raw:sub(1, w - 1) .. "~"
end

local function trim_text(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function read_small_file(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local content = f.readAll()
  f.close()
  return content
end

local function line(x, y, text, fg, bg)
  local w = ({ term.getSize() })[1] or 40
  term.setCursorPos(x, y)
  set_fg(fg or c("white"))
  set_bg(bg or c("black"))
  term.write(fit(text, math.max(1, w - x + 1)))
end

local function badge(x, y, text, status)
  local fg = c("black")
  local bg = c("gray")
  if status == "OK" then bg = c("lime") elseif status == "WARN" then bg = c("yellow") elseif status == "ERR" then bg = c("red") elseif status == "INFO" then bg = c("cyan") end
  term.setCursorPos(x, y)
  set_fg(fg); set_bg(bg)
  local label = " " .. fit(text, 10) .. " "
  term.write(label)
  set_fg(c("white")); set_bg(c("black"))
  return #label
end

local function progress(x, y, width, pct, status)
  local p = tonumber(pct) or 0
  p = math.max(0, math.min(1, p))
  local fill = math.floor(width * p)
  local bg = c("gray")
  local fg = c("lime")
  if status == "WARN" then fg = c("yellow") elseif status == "ERR" then fg = c("red") end
  term.setCursorPos(x, y)
  for i = 1, width do
    set_bg(i <= fill and fg or bg)
    term.write(" ")
  end
  set_bg(c("black")); set_fg(c("white"))
end

local function draw_log_mode_buttons(x, y)
  -- LOG_COLLECTOR's own logging is independent of the log_collector channel
  -- it receives (this controls THIS node's local utils.log() output).
  -- Uses c() helper (already defined in this file) for color lookup.
  if not utils then return end
  local mode = utils.get_log_mode and utils.get_log_mode() or "all"
  local modes  = { "all", "disk", "remote", "terminal", "none" }
  local labels = { all = "All ", disk = "Disk", remote = "Rmt ", terminal = "Term", none = "Off " }
  term.setCursorPos(x, y)
  set_bg(c("black")); set_fg(c("gray"))
  term.write("Log:")
  local cx = x + 4
  stats.log_mode_buttons = {}
  for _, m in ipairs(modes) do
    term.setCursorPos(cx, y)
    set_bg(mode == m and c("lime") or c("gray"))
    set_fg(mode == m and c("black") or c("white"))
    term.write(labels[m] or m)
    stats.log_mode_buttons[#stats.log_mode_buttons + 1] = { x = cx, y = y, w = 4, h = 1, mode = m }
    cx = cx + 4
  end
  set_bg(c("black")); set_fg(c("white"))
end

local function draw_pause_button(x, y)
  local label = stats.paused and " RESUME DISK WRITES " or " PAUSE DISK WRITES "
  stats.pause_button = { x = x, y = y, w = #label, h = 1 }
  term.setCursorPos(x, y)
  set_fg(c("black"))
  set_bg(stats.paused and c("lime") or c("yellow"))
  term.write(label)
  set_fg(c("white")); set_bg(c("black"))
end

local function button_hit(button, x, y)
  return button and x >= button.x and x < button.x + button.w and y >= button.y and y < button.y + button.h
end

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
  local diag = {}  -- Diagnose-Zeilen: was wurde pro Peripheral gefunden/versucht
  if peripheral and type(peripheral.getNames) == "function" then
    local ok, names = pcall(peripheral.getNames)
    diag[#diag+1] = "getNames ok=" .. tostring(ok) .. " count=" .. tostring(type(names)=="table" and #names or "n/a")
    if ok and type(names) == "table" then
      for _, name in ipairs(names) do
        local ok_type, ptype = pcall(peripheral.getType, name)
        local is_drive = false
        if peripheral.hasType then
          local ok_ht, result = pcall(peripheral.hasType, name, "drive")
          is_drive = ok_ht and result == true
        else
          is_drive = ok_type and ptype == "drive"
        end
        diag[#diag+1] = string.format("  %s type=%s is_drive=%s", tostring(name), tostring(ptype), tostring(is_drive))
        if is_drive then
          local mount = nil
          local ok_wrap, drv = pcall(peripheral.wrap, name)
          diag[#diag+1] = string.format("    wrap ok=%s has_getMountPath=%s",
            tostring(ok_wrap), tostring(ok_wrap and drv and type(drv.getMountPath)=="function"))
          if ok_wrap and drv and type(drv.getMountPath) == "function" then
            local ok_mount, m = pcall(drv.getMountPath)
            diag[#diag+1] = string.format("    drv.getMountPath() ok=%s value=%s", tostring(ok_mount), tostring(m))
            if ok_mount and type(m) == "string" and m ~= "" then mount = m end
          end
          if not mount and ok_wrap and drv and type(drv.isDiskPresent) == "function" then
            local ok_p, present = pcall(drv.isDiskPresent)
            diag[#diag+1] = string.format("    drv.isDiskPresent() ok=%s value=%s", tostring(ok_p), tostring(present))
          end
          if not mount and disk and type(disk.getMountPath) == "function" then
            local ok_mount2, m2 = pcall(disk.getMountPath, name)
            diag[#diag+1] = string.format("    disk.getMountPath(name) ok=%s value=%s", tostring(ok_mount2), tostring(m2))
            if ok_mount2 and type(m2) == "string" and m2 ~= "" then mount = m2 end
          end
          if mount then
            add_unique(roots, seen, mount)
            diag[#diag+1] = "    => MOUNT FOUND: " .. tostring(mount)
          else
            diag[#diag+1] = "    => NO MOUNT FOUND"
          end
        end
      end
    end
  end
  stats.disk_diag = diag
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
  for i, disk_entry in ipairs(disks) do disk_entry.id = i end
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

local function advance_disk_after_write()
  if #stats.disks <= 1 then return end
  stats.disk_index = stats.disk_index + 1
  if stats.disk_index > #stats.disks then stats.disk_index = 1 end
  stats.log_root = stats.disks[stats.disk_index] and stats.disks[stats.disk_index].root or stats.log_root
  stats.disk_switches = stats.disk_switches + 1
end

local function switch_next_disk()
  refresh_disks_if_needed(true)
  if #stats.disks == 0 then return nil end
  advance_disk_after_write()
  return stats.disks[stats.disk_index]
end

local function sanitize(value)
  local text = tostring(value or "unknown"):lower()
  text = text:gsub("[^a-z0-9_%-]+", "_")
  text = text:gsub("^_+", ""):gsub("_+$", "")
  if text == "" then return "unknown" end
  return text
end

local function node_id()
  if os and type(os.getComputerID) == "function" then return "pc-" .. tostring(os.getComputerID()) end
  return "log-collector"
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
  for i = ROTATE_KEEP - 1, 1, -1 do safe_move(path .. "." .. tostring(i), path .. "." .. tostring(i + 1)) end
  safe_move(path, path .. ".1")
  stats.rotated = stats.rotated + 1
  return true
end

local function prune_any_logs(root)
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
      elseif name:match("%.log%.%d+$") or name:match("%.old$") or name:match("%.bak$") then
        safe_delete(path)
        removed = removed + 1
        if free_space(root) >= MIN_FREE_BYTES then return end
      end
    end
  end
  scan(root)
  stats.pruned = stats.pruned + removed
  return removed
end

local function try_write_to_disk(disk_entry, payload)
  if not disk_entry or not disk_entry.root then return false, "no disk" end
  local root = disk_entry.root
  stats.log_root = root
  local role = sanitize(payload.role or "unknown")
  local id = sanitize(payload.node_id or "unknown")
  local dir = root .. "/" .. role
  if not ensure_dir(dir) then return false, "mkdir failed" end
  local path = dir .. "/" .. id .. ".log"
  rotate_file(path)
  if free_space(root) < MIN_FREE_BYTES then prune_any_logs(root) end
  if free_space(root) < 256 then return false, "disk full" end
  local line_text = format_line(payload) .. "\n"
  local ok, err = pcall(function()
    local h = fs.open(path, "a")
    if not h then error("open failed") end
    h.write(line_text)
    h.close()
  end)
  if not ok then return false, tostring(err or "write failed") end
  stats.last_write_index = disk_entry.id or stats.disk_index
  stats.last_write_mount = disk_entry.mount or "?"
  stats.last_write_root = root
  stats.last_write_path = path
  return true
end

-- Wipe ALL log files in a root directory to reclaim space (fresh start).
local function wipe_logs(root)
  local wiped = 0
  local function wipe_dir(dir)
    if not fs.exists(dir) or not fs.isDir(dir) then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return end
    for _, name in ipairs(entries) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then
        wipe_dir(path)
      else
        safe_delete(path)
        wiped = wiped + 1
      end
    end
  end
  wipe_dir(root)
  return wiped
end

local function write_log(payload)
  if stats.paused then
    stats.paused_dropped = stats.paused_dropped + 1
    return false, "paused"
  end
  refresh_disks_if_needed(false)
  local count = math.max(1, #stats.disks)
  local last_err = nil
  for attempt = 1, count do
    local disk_entry = current_disk()
    local ok, err = try_write_to_disk(disk_entry, payload)
    if ok then
      -- Stay on this disk; only switch when it's full.
      return true
    end
    last_err = err
    -- Current disk is full. Move to next disk.
    local prev_index = stats.disk_index
    switch_next_disk()
    -- If we wrapped around (back to first disk), wipe it to start fresh.
    if attempt == count and stats.disk_index == 1 then
      local disk_entry_wipe = current_disk()
      if disk_entry_wipe then
        local wiped = wipe_logs(disk_entry_wipe.root)
        stats.disk_switches = stats.disk_switches + 1
        stats.last_error = string.format("all disks full, wiped disk[1] (%d files)", wiped)
      end
    end
  end
  return false, tostring(last_err or "all disks full")
end

local function remember_event(event_id)
  if type(event_id) ~= "string" or event_id == "" or stats.seen[event_id] then return end
  stats.seen[event_id] = true
  stats.seen_order[#stats.seen_order + 1] = event_id
  while #stats.seen_order > DEDUPE_LIMIT do
    local old = table.remove(stats.seen_order, 1)
    if old then stats.seen[old] = nil end
  end
end

local function has_seen(event_id)
  return type(event_id) == "string" and event_id ~= "" and stats.seen[event_id] == true
end

local function find_modems()
  local found = {}
  if not peripheral or not peripheral.getNames then return found end
  local names = peripheral.getNames()
  table.sort(names)
  local wireless, wired = {}, {}
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem and type(modem.open) == "function" then
        local is_wireless = false
        if type(modem.isWireless) == "function" then
          local ok, result = pcall(modem.isWireless)
          is_wireless = ok and result == true
        end
        local entry = { name = name, modem = modem, wireless = is_wireless }
        if is_wireless then wireless[#wireless + 1] = entry else wired[#wired + 1] = entry end
      end
    end
  end
  for _, entry in ipairs(wireless) do found[#found + 1] = entry end
  for _, entry in ipairs(wired) do found[#found + 1] = entry end
  return found
end

local function refresh_collector_modems(force)
  local now = now_ticks()
  if not force and #stats.modems > 0 and now < (stats.next_modem_refresh_at or 0) then return end
  stats.next_modem_refresh_at = now + MODEM_REFRESH_SECONDS
  local modems = find_modems()
  local modem_names = {}
  stats.modems = {}
  for _, entry in ipairs(modems) do
    local ok = pcall(entry.modem.open, CHANNEL)
    if ok then
      modem_names[#modem_names + 1] = entry.name
      stats.modems[#stats.modems + 1] = entry
    end
  end
  stats.modem = table.concat(modem_names, ",")
  stats.modem_refreshes = stats.modem_refreshes + 1
end

local function send_ack(payload, status)
  if type(payload) ~= "table" or not payload.ack or not payload.event_id or not payload.node_id then return end
  refresh_collector_modems(false)
  local ack = {
    type = "LOG_ACK",
    proto = "xreactor-log-v2",
    event_id = payload.event_id,
    to_node = payload.node_id,
    collector_node = node_id(),
    status = status or "written",
    ts = os and os.epoch and os.epoch("utc") or nil
  }
  for _, entry in ipairs(stats.modems or {}) do
    if entry.modem and type(entry.modem.transmit) == "function" then
      local ok = pcall(entry.modem.transmit, CHANNEL, CHANNEL, ack)
      if ok then stats.ack_sent = stats.ack_sent + 1 end
    end
  end
end

local function self_log(message, level)
  local payload = {
    type = "LOG_EVENT",
    proto = "xreactor-log-v2",
    node_id = node_id(),
    role = SELF_ROLE,
    prefix = "LOG",
    level = level or "INFO",
    message = message,
    event_id = node_id() .. ":self:" .. tostring(os and os.epoch and os.epoch("utc") or math.random(1, 999999)),
    ts = os and os.epoch and os.epoch("utc") or nil
  }
  local ok, err = write_log(payload)
  if ok then remember_event(payload.event_id) elseif err ~= "paused" then stats.last_error = err end
  return ok
end

local draw

local function toggle_pause()
  if stats.paused then
    stats.paused = false
    stats.last_error = nil
    self_log("Collector disk writes resumed by operator", "INFO")
  else
    self_log("Collector disk writes paused by operator", "WARN")
    stats.paused = true
    stats.last_error = nil
  end
  if draw then draw() end
end

local REMOTE_MONITOR_METHODS = {
  "write", "blit", "clear", "clearLine", "getSize", "setCursorPos", "getCursorPos",
  "setCursorBlink", "getCursorBlink", "setTextColor", "setTextColour", "getTextColor", "getTextColour",
  "setBackgroundColor", "setBackgroundColour", "getBackgroundColor", "getBackgroundColour",
  "isColor", "isColour", "scroll", "setTextScale", "getTextScale"
}

local function make_remote_monitor(modem, remote_name)
  if not modem or type(modem.callRemote) ~= "function" then return nil end
  local proxy = {}
  for _, method in ipairs(REMOTE_MONITOR_METHODS) do
    proxy[method] = function(...)
      return modem.callRemote(remote_name, method, ...)
    end
  end
  return proxy
end

local function is_remote_monitor(modem, remote_name)
  if type(modem.getTypeRemote) == "function" then
    local ok, ptype = pcall(modem.getTypeRemote, remote_name)
    if ok and ptype == "monitor" then return true end
  end
  if type(modem.hasTypeRemote) == "function" then
    local ok, result = pcall(modem.hasTypeRemote, remote_name, "monitor")
    if ok and result == true then return true end
  end
  return false
end

local function configured_display_name()
  local candidates = {}
  if settings and type(settings.get) == "function" then
    candidates[#candidates + 1] = settings.get("xreactor.log_monitor")
    candidates[#candidates + 1] = settings.get("xreactor.log.monitor")
    candidates[#candidates + 1] = settings.get("xreactor.monitor.log")
  end
  candidates[#candidates + 1] = read_small_file(MONITOR_NAME_FILE)
  for _, value in ipairs(candidates) do
    local text = trim_text(value or "")
    if text ~= "" then return text end
  end
  return nil
end

local function split_display_spec(spec)
  local text = trim_text(spec or "")
  if text == "" then return nil, nil end
  local remote, modem = text:match("^([^@]+)@(.+)$")
  if remote and modem then return trim_text(remote), trim_text(modem) end
  return text, nil
end

local function try_local_monitor(name)
  if not name or not peripheral or type(peripheral.getType) ~= "function" then return nil end
  if peripheral.getType(name) == "monitor" then
    local ok, mon = pcall(peripheral.wrap, name)
    if ok and mon then return name, mon end
  end
  return nil
end

local function try_remote_monitor(target_name, target_modem)
  if not peripheral or type(peripheral.getNames) ~= "function" then return nil end
  local names = peripheral.getNames() or {}
  table.sort(names)
  for _, modem_name in ipairs(names) do
    if (not target_modem or tostring(modem_name) == tostring(target_modem)) and peripheral.getType(modem_name) == "modem" then
      local ok_wrap, modem = pcall(peripheral.wrap, modem_name)
      if ok_wrap and modem and type(modem.getNamesRemote) == "function" and type(modem.callRemote) == "function" then
        local ok, remotes = pcall(modem.getNamesRemote)
        if ok and type(remotes) == "table" then
          table.sort(remotes)
          for _, remote_name in ipairs(remotes) do
            if (not target_name or tostring(remote_name) == tostring(target_name)) and is_remote_monitor(modem, remote_name) then
              local mon = make_remote_monitor(modem, remote_name)
              if mon then return remote_name .. "@" .. modem_name, mon end
            end
          end
        end
      end
    end
  end
  return nil
end

local function find_display()
  local configured = configured_display_name()
  if configured then
    local requested_name, requested_modem = split_display_spec(configured)
    local local_name, local_mon = try_local_monitor(requested_name)
    if local_mon then return local_name, local_mon end
    local remote_name, remote_mon = try_remote_monitor(requested_name, requested_modem)
    if remote_mon then return remote_name, remote_mon end
    stats.last_error = "configured monitor not found: " .. tostring(configured)
  end
  if peripheral and type(peripheral.getNames) == "function" then
    local names = peripheral.getNames() or {}
    table.sort(names)
    for _, name in ipairs(names) do
      local local_name, local_mon = try_local_monitor(name)
      if local_mon then return local_name, local_mon end
    end
  end
  local remote_name, remote_mon = try_remote_monitor(nil, nil)
  if remote_mon then return remote_name, remote_mon end
  return "term", term
end

local function draw_disk_bar(y)
  local w = ({ term.getSize() })[1] or 40
  local disks = math.max(1, #stats.disks)
  local x = 2
  local max_width = math.max(8, w - 3)
  local per = math.max(3, math.floor(max_width / disks))
  for i = 1, disks do
    local d = stats.disks[i]
    local free = free_space(d and d.root or "/")
    local status = (i == stats.last_write_index) and "INFO" or (free < MIN_FREE_BYTES and "WARN" or "OK")
    local label = tostring(i)
    if disks <= 8 then label = tostring(i) .. ":" .. tostring(d and d.mount or "?"):gsub("/disk", "d") end
    if i == stats.last_write_index then label = "*" .. label end
    x = x + badge(x, y, fit(label, per - 2), status)
    if x > max_width then break end
  end
end

draw = function()
  refresh_disks_if_needed(false)
  refresh_collector_modems(false)
  local disk_entry = current_disk() or {}
  local w, h = term.getSize()
  term.clear()
  set_bg(c("black")); set_fg(c("white"))
  line(1, 1, string.rep(" ", w), c("black"), c("gray"))
  line(2, 1, " XReactor LOG ", c("black"), c("gray"))
  local status = stats.paused and "WARN" or (stats.last_error and "WARN" or "OK")
  local x = 2
  x = x + badge(x, 2, stats.paused and "PAUSED" or (stats.last_error and "WARN" or "OK"), status) + 1
  x = x + badge(x, 2, "CH " .. tostring(CHANNEL), "INFO") + 1
  x = x + badge(x, 2, tostring(stats.modem or "NO-MODEM"), stats.modem ~= "" and "OK" or "ERR")
  line(2, 3, fit("Display " .. tostring(stats.display_name or "term"), w - 2), c("lightGray"))
  draw_pause_button(2, 4)
  draw_log_mode_buttons(2, 5)
  line(2, 6, "Disk Ring (* = last write target)", c("cyan"))
  draw_disk_bar(7)
  local is_fallback = disk_entry and disk_entry.fallback
  line(2, 8, string.format("Next    Disk #%s/%s  %s%s", tostring(stats.disk_index), tostring(#stats.disks), tostring(disk_entry.mount or "n/a"), is_fallback and "  [FALLBACK - keine externe Disk gefunden!]" or ""), is_fallback and c("red") or c("lightGray"))
  line(2, 9, string.format("Writing Disk #%s  %s", tostring(stats.last_write_index or "-"), tostring(stats.last_write_mount or "-")), stats.paused and c("yellow") or c("lime"))
  line(2, 10, fit("Path " .. tostring(stats.last_write_path or "-"), w - 2), c("lightGray"))
  local free = free_space(stats.log_root or "/")
  line(2, 11, "Free " .. tostring(free) .. " bytes at " .. tostring(stats.log_root or "n/a"), free < MIN_FREE_BYTES and c("yellow") or c("lime"))
  progress(2, 12, math.max(8, w - 3), free == math.huge and 1 or math.min(1, free / math.max(MIN_FREE_BYTES * 8, 1)), free < MIN_FREE_BYTES and "WARN" or "OK")
  line(2, 14, "Traffic", c("cyan"))
  line(2, 15, string.format("Recv %-6s Write %-6s Drop %-5s Dup %-5s", tostring(stats.received), tostring(stats.written), tostring(stats.dropped), tostring(stats.duplicates)), c("white"))
  line(2, 16, string.format("ACK %-7s PausedDrop %-5s", tostring(stats.ack_sent), tostring(stats.paused_dropped)), c("lightGray"))
  line(2, 17, string.format("Switch %-5s Rotate %-5s Prune %-5s", tostring(stats.disk_switches), tostring(stats.rotated), tostring(stats.pruned)), c("lightGray"))
  line(2, 18, string.format("ModemRefresh %-5s", tostring(stats.modem_refreshes)), c("lightGray"))
  line(2, 20, "Last", c("cyan"))
  line(2, 21, fit(tostring(stats.last_node) .. "  " .. tostring(stats.last_level), w - 3), c("white"))
  if stats.last_error and h >= 23 then
    line(2, 23, "Error", c("red"))
    line(2, 24, fit(tostring(stats.last_error), w - 3), c("red"))
  elseif stats.paused and h >= 23 then
    line(2, 23, "Disk writes paused; ACKs withheld so senders retry", c("yellow"))
  elseif h >= 23 then
    line(2, 23, "Status stable", c("lime"))
  end
  set_fg(c("white")); set_bg(c("black"))
end

local function redirect_display()
  local name, display = find_display()
  stats.display_name = name or "term"
  stats.display = display or term
  if display and display ~= term and term.redirect then
    if type(display.setTextScale) == "function" then pcall(display.setTextScale, 0.5) end
    local ok, err = pcall(term.redirect, display)
    if not ok then
      stats.last_error = "display redirect failed: " .. tostring(err)
      stats.display_name = "term"
      stats.display = term
    end
  end
end

local function handle_log_event(message)
  stats.received = stats.received + 1
  stats.last_node = message.node_id or "?"
  stats.last_level = message.level or "?"
  if has_seen(message.event_id) then
    stats.duplicates = stats.duplicates + 1
    send_ack(message, "duplicate")
    return true, "duplicate"
  end
  local ok, err = write_log(message)
  if ok then
    stats.written = stats.written + 1
    stats.last_error = nil
    if message.event_id then remember_event(message.event_id) end
    send_ack(message, "written")
    return true
  end
  stats.dropped = stats.dropped + 1
  if err ~= "paused" then stats.last_error = err end
  return false, err
end

local function is_terminate(err)
  return tostring(err or ""):lower():find("terminate", 1, true) ~= nil
end

local function crash_screen(err)
  if term and term.setBackgroundColor and colors then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== LOG COLLECTOR CRASH ===")
    term.setTextColor(colors.white)
    print("")
    print(tostring(err))
    print("")
    print("received=" .. tostring(stats.received) .. " written=" .. tostring(stats.written)
      .. " dropped=" .. tostring(stats.dropped))
    print("")
    term.setTextColor(colors.yellow)
    print("Druecke eine Taste um neu zu starten...")
    term.setTextColor(colors.white)
  else
    print("CRASH: " .. tostring(err))
  end
  pcall(os.pullEvent, "key")
  if os.reboot then os.reboot() end
end

local function run_loop()
  refresh_disks_if_needed(true)
  redirect_display()
  refresh_collector_modems(true)
  -- Beim Start alle alten Logs auf allen Disks löschen damit
  -- immer frische, vollständige Logs vorhanden sind.
  local total_wiped = 0
  for _, d in ipairs(stats.disks) do
    if not d.fallback then
      local wiped = wipe_logs(d.root)
      total_wiped = total_wiped + wiped
    end
  end
  if total_wiped > 0 then
    self_log("LOG collector startup: wiped " .. tostring(total_wiped) .. " old log files", "INFO")
  end
  self_log("LOG collector startup display=" .. tostring(stats.display_name) .. " disks=" .. tostring(#stats.disks), "INFO")
  -- Diagnose: detaillierter Disk-Erkennungs-Trace ins Log schreiben, damit bei
  -- Problemen mit der Disk-Erkennung sofort sichtbar ist was gefunden/nicht
  -- gefunden wurde, ohne dass jemand vor Ort am Monitor stehen muss.
  for _, diag_line in ipairs(stats.disk_diag or {}) do
    self_log("DiskDiag: " .. diag_line, "INFO")
  end
  if #stats.modems == 0 then self_log("No modem found for LOG collector", "ERROR"); error("No modem found for LOG collector", 0) end
  self_log("Listening on log channel " .. tostring(CHANNEL) .. " modems=" .. tostring(stats.modem), "INFO")
  draw()
  local status_timer = os.startTimer and os.startTimer(30) or nil
  while true do
    local event = { os.pullEvent() }
    if event[1] == "modem_message" then
      local channel = event[3]
      local message = event[5]
      if channel == CHANNEL and type(message) == "table" and message.type == "LOG_EVENT" then
        -- pcall: ein einzelner kaputter LOG_EVENT darf nicht den gesamten
        -- Collector zum Absturz bringen (sonst gehen alle Logs danach verloren).
        local call_ok, ok = pcall(handle_log_event, message)
        if not call_ok then
          stats.dropped = stats.dropped + 1
          stats.last_error = "handle_log_event crashed: " .. tostring(ok)
        end
        if stats.received % 5 == 0 or not call_ok or not ok then draw() end
      end
    elseif event[1] == "monitor_touch" then
      local x_pos, y_pos = event[3], event[4]
      if button_hit(stats.pause_button, x_pos, y_pos) then toggle_pause() end
      for _, b in ipairs(stats.log_mode_buttons or {}) do
        if button_hit(b, x_pos, y_pos) and utils and utils.set_log_mode then
          utils.set_log_mode(b.mode); draw()
        end
      end
    elseif event[1] == "mouse_click" then
      local x_pos, y_pos = event[3], event[4]
      if button_hit(stats.pause_button, x_pos, y_pos) then toggle_pause() end
      for _, b in ipairs(stats.log_mode_buttons or {}) do
        if button_hit(b, x_pos, y_pos) and utils and utils.set_log_mode then
          utils.set_log_mode(b.mode); draw()
        end
      end
    elseif event[1] == "key" then
      local key_code = event[2]
      if keys and (key_code == keys.p or key_code == keys.space) then toggle_pause() end
    elseif event[1] == "timer" and event[2] == status_timer then
      refresh_collector_modems(false)
      if not stats.paused then
        self_log("Collector status received=" .. tostring(stats.received) .. " written=" .. tostring(stats.written) .. " dropped=" .. tostring(stats.dropped) .. " dup=" .. tostring(stats.duplicates) .. " ack=" .. tostring(stats.ack_sent), "DEBUG")
      end
      draw()
      status_timer = os.startTimer and os.startTimer(30) or nil
    end
  end
end

local function run()
  local ok, err = xpcall(run_loop, function(e) return e end)
  if ok then return end
  if is_terminate(err) then return end
  crash_screen(err)
end

run()
