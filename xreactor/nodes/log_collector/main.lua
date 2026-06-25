-- nodes/log_collector/main.lua
-- XReactor LOG Collector — completed v2 rewrite
-- Receives LOG_EVENT packets via modem and writes them to external disks.
-- One disk slot per role: /disk=RT, /disk1=MASTER, /disk2=ENERGY, ...
-- No PC fallback for collected logs: if no writable disk exists, logs are dropped.
-- UI is incremental: only changed render segments are written to the terminal/monitor.

-- ── Dependencies ────────────────────────────────────────────────────────────
if type(package) == "table" and type(package.path) == "string" then
  local extra = ";/xreactor/?.lua;/xreactor/?/init.lua;/xreactor/?/main.lua"
  if not package.path:find("/xreactor/%?%.lua", 1, false) then
    package.path = package.path .. extra
  end
end

local ok_utils, utils = pcall(require, "core.utils")
if not ok_utils or type(utils) ~= "table" then utils = nil end

local ok_const, constants = pcall(require, "shared.constants")
if not ok_const or type(constants) ~= "table" then
  constants = { channels = { LOG = 6502 } }
end

-- ── Configuration ───────────────────────────────────────────────────────────
local CHANNEL          = constants.channels and constants.channels.LOG or 6502
local MAX_LOG_BYTES    = 524288   -- 512 KB per active log file; leaves headroom on 1 MB CC disk
local MIN_FREE_BYTES   = 8192    -- 8 KB; triggers wipe before disk fills completely
local DEDUPE_LIMIT     = 512
local MODEM_REFRESH_S  = 10
local DISK_REFRESH_S   = 30
local DRAW_INTERVAL_S  = 5
local SELF_ROLE        = "LOG_COLLECTOR"
local MONITOR_CFG_FILE = "/xreactor/config/log_monitor.txt"
local ROLE_ORDER       = { "RT", "MASTER", "ENERGY", "WATER", "FUEL", "REPROCESSING", "LOG" }

-- ── Runtime state ───────────────────────────────────────────────────────────
local stats = {
  received = 0,
  written = 0,
  dropped = 0,
  duplicates = 0,
  ack_sent = 0,
  paused_dropped = 0,
  wiped = 0,
  disks = {},
  disk_index = 1,
  last_write_index = nil,
  last_write_mount = "-",
  last_write_path = "-",
  last_node = "-",
  last_role = "-",
  last_level = "-",
  last_error = nil,
  log_root = nil,
  modem = "",
  modems = {},
  modem_refreshes = 0,
  disk_refreshes = 0,
  next_modem_refresh = 0,
  next_disk_refresh = 0,
  display = nil,
  display_name = "term",
  paused = false,
  pause_button = nil,
  log_mode_buttons = {},
  seen = {},
  seen_order = {},
  last_draw_s = 0,
}

local live_diag = {}

-- ── Generic helpers ─────────────────────────────────────────────────────────
local function color(name, fallback)
  if colors and colors[name] then return colors[name] end
  return fallback or 1
end

local function diag(message)
  live_diag[#live_diag + 1] = tostring(message or "")
  while #live_diag > 12 do table.remove(live_diag, 1) end
end

local function now_s()
  if os and type(os.epoch) == "function" then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then return math.floor(value / 1000) end
  end
  if os and type(os.clock) == "function" then
    local ok, value = pcall(os.clock)
    if ok and type(value) == "number" then return math.floor(value) end
  end
  return 0
end

local function now_ms()
  if os and type(os.epoch) == "function" then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then return value end
  end
  return now_s() * 1000
end

local function computer_node_id()
  if os and type(os.getComputerID) == "function" then
    return "pc-" .. tostring(os.getComputerID())
  end
  return "log-collector"
end

local function fit(text, width)
  local s = tostring(text or ""):gsub("[\r\n]", " ")
  local w = math.max(1, tonumber(width) or #s)
  if #s <= w then return s end
  if w <= 1 then return s:sub(1, 1) end
  return s:sub(1, w - 1) .. "~"
end

local function trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function safe_read(path)
  if not (fs and fs.exists and fs.open) then return nil end
  if not fs.exists(path) then return nil end
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local data = handle.readAll()
  handle.close()
  return data
end

local function safe_delete(path)
  if fs and fs.exists and fs.delete and fs.exists(path) then
    pcall(fs.delete, path)
  end
end

local function ensure_dir(path)
  if not (fs and fs.exists and fs.isDir and fs.makeDir) then return false end
  if fs.exists(path) then return fs.isDir(path) end
  local ok = pcall(fs.makeDir, path)
  return ok and fs.exists(path) and fs.isDir(path)
end

local function free_space(path)
  if not (fs and type(fs.getFreeSpace) == "function") then return 0 end
  local ok, value = pcall(fs.getFreeSpace, path or "/")
  if not ok then return 0 end
  if value == "unlimited" then return math.huge end
  return tonumber(value) or 0
end

local function sanitize(value)
  local s = tostring(value or "unknown"):lower():gsub("[^a-z0-9_%-]+", "_")
  s = s:gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or "unknown"
end

local function role_index(role)
  local wanted = tostring(role or ""):upper()
  for i, name in ipairs(ROLE_ORDER) do
    if name == wanted then return i end
  end
  return nil
end

-- ── Disk handling ───────────────────────────────────────────────────────────
local function wipe_disk(root)
  local wiped = 0
  if not (fs and fs.exists and fs.isDir and fs.list) then return 0 end

  local function sweep(dir)
    if not fs.exists(dir) or not fs.isDir(dir) then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return end
    for _, name in ipairs(entries) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then
        sweep(path)
      else
        safe_delete(path)
        wiped = wiped + 1
      end
    end
  end

  sweep(root)
  stats.wiped = stats.wiped + wiped
  return wiped
end

local function find_disk_mounts()
  local mounts = {}
  if not (fs and fs.list) then return mounts end
  local ok, entries = pcall(fs.list, "/")
  if not ok or type(entries) ~= "table" then return mounts end
  table.sort(entries)
  for _, entry in ipairs(entries) do
    if type(entry) == "string" and entry:match("^disk%d*$") then
      mounts[#mounts + 1] = "/" .. entry
    end
  end
  return mounts
end

local function probe_disk(mount)
  local root = mount .. "/xreactor_logs"
  if not ensure_dir(root) then return false end
  local probe = root .. "/.probe"

  local function write_probe()
    local handle = fs.open(probe, "w")
    if not handle then error("fs.open returned nil") end
    handle.write("ok")
    handle.close()
    fs.delete(probe)
  end

  local ok = pcall(write_probe)
  if ok then return true end

  wipe_disk(root)
  return pcall(write_probe)
end

local function discover_disks()
  local disks = {}
  local seen_mounts = {}
  local mounts = find_disk_mounts()
  for index, mount in ipairs(mounts) do
    -- Dedup: gleichen Mount nicht zweimal eintragen
    if seen_mounts[mount] then
      diag("duplicate mount skipped: " .. tostring(mount))
    elseif probe_disk(mount) then
      seen_mounts[mount] = true
      local role = ROLE_ORDER[index] or ("DISK" .. tostring(index))
      local root = mount .. "/xreactor_logs"
      disks[#disks + 1] = { id = index, mount = mount, root = root, role = role }
      diag("disk ok: " .. tostring(mount) .. " role=" .. tostring(role))
    else
      diag("disk probe failed: " .. tostring(mount))
    end
  end
  if #disks == 0 then
    diag("no writable disk found; collected logs will be dropped")
  else
    diag(tostring(#disks) .. " disk(s) ready")
  end
  return disks
end

local function refresh_disks(force)
  local ts = now_s()
  if not force and ts < stats.next_disk_refresh then return end
  stats.next_disk_refresh = ts + DISK_REFRESH_S
  stats.disks = discover_disks()
  stats.disk_refreshes = stats.disk_refreshes + 1
  stats.log_root = stats.disks[1] and stats.disks[1].root or nil
end

local function disk_for_role(role)
  if #stats.disks == 0 then return nil end
  local idx = role_index(role)
  if idx then
    for _, disk in ipairs(stats.disks) do
      if disk.id == idx or disk.role == tostring(role or ""):upper() then
        return disk
      end
    end
  end
  return stats.disks[stats.disk_index] or stats.disks[1]
end

local function format_log_line(payload)
  local ts = payload.ts or now_ms()
  return string.format("[%s] %s | %s | %s | %s",
    tostring(ts),
    tostring(payload.role or "?"),
    tostring(payload.prefix or "LOG"),
    tostring(payload.level or "INFO"),
    tostring(payload.message or payload.line or ""))
end

local function write_log(payload)
  if stats.paused then
    stats.paused_dropped = stats.paused_dropped + 1
    return false, "paused"
  end

  refresh_disks(false)
  if #stats.disks == 0 then
    stats.dropped = stats.dropped + 1
    return false, "no disk"
  end

  local disk = disk_for_role(payload.role)
  if not disk then
    stats.dropped = stats.dropped + 1
    return false, "no disk for role"
  end

  local role_dir = disk.root .. "/" .. sanitize(payload.role or "unknown")
  if not ensure_dir(role_dir) then
    stats.dropped = stats.dropped + 1
    return false, "mkdir failed"
  end

  local path = role_dir .. "/" .. sanitize(payload.node_id or "unknown") .. ".log"
  if fs.exists(path) and fs.getSize(path) >= MAX_LOG_BYTES then
    safe_delete(path)
  end

  if free_space(disk.mount) < MIN_FREE_BYTES then
    local wiped = wipe_disk(disk.root)
    diag("disk full: wiped " .. tostring(wiped) .. " file(s) on " .. tostring(disk.mount))
  end

  local line = format_log_line(payload) .. "\n"
  local ok, err = pcall(function()
    local handle = fs.open(path, "a")
    if not handle then error("fs.open returned nil") end
    handle.write(line)
    handle.close()
  end)

  if not ok then
    local message = tostring(err or "write failed")
    local lower = message:lower()
    if lower:find("out of space", 1, true) or lower:find("no space", 1, true) then
      local wiped = wipe_disk(disk.root)
      diag("write out-of-space: wiped " .. tostring(wiped) .. " file(s), retry")
      ok, err = pcall(function()
        local handle = fs.open(path, "a")
        if not handle then error("fs.open returned nil after wipe") end
        handle.write(line)
        handle.close()
      end)
    end
  end

  if not ok then
    stats.last_error = tostring(err or "write failed"):sub(1, 90)
    stats.dropped = stats.dropped + 1
    return false, stats.last_error
  end

  stats.last_write_index = disk.id
  stats.last_write_mount = disk.mount
  stats.last_write_path = path
  stats.log_root = disk.root
  stats.last_error = nil
  return true
end

-- ── Dedupe ─────────────────────────────────────────────────────────────────
local function seen(event_id)
  return type(event_id) == "string" and event_id ~= "" and stats.seen[event_id] == true
end

local function remember(event_id)
  if type(event_id) ~= "string" or event_id == "" or stats.seen[event_id] then return end
  stats.seen[event_id] = true
  stats.seen_order[#stats.seen_order + 1] = event_id
  while #stats.seen_order > DEDUPE_LIMIT do
    local old = table.remove(stats.seen_order, 1)
    if old then stats.seen[old] = nil end
  end
end

-- ── Modem handling ──────────────────────────────────────────────────────────
local function is_modem_name(name)
  if not peripheral or type(peripheral.getType) ~= "function" then return false end
  local ok, ptype = pcall(peripheral.getType, name)
  if not ok then return false end
  if ptype == "modem" then return true end
  if type(ptype) == "table" then
    for _, item in pairs(ptype) do if item == "modem" then return true end end
  end
  return tostring(ptype or ""):lower():find("modem", 1, true) ~= nil
end

local function refresh_modems(force)
  local ts = now_s()
  if not force and ts < stats.next_modem_refresh then return end
  stats.next_modem_refresh = ts + MODEM_REFRESH_S
  stats.modems = {}

  local names = {}
  if peripheral and type(peripheral.getNames) == "function" then
    local ok, perifs = pcall(peripheral.getNames)
    if ok and type(perifs) == "table" then
      table.sort(perifs)
      for _, name in ipairs(perifs) do
        if is_modem_name(name) then
          local ok_wrap, modem = pcall(peripheral.wrap, name)
          if ok_wrap and modem and type(modem.open) == "function" then
            pcall(modem.open, CHANNEL)
            stats.modems[#stats.modems + 1] = modem
            names[#names + 1] = name
          end
        end
      end
    end
  end

  stats.modem = table.concat(names, ",")
  stats.modem_refreshes = stats.modem_refreshes + 1
end

local function send_ack(payload, status)
  if not payload.ack or not payload.event_id then return end
  local ack = {
    type = "LOG_ACK",
    proto = "xreactor-log-v2",
    event_id = payload.event_id,
    to_node = payload.node_id,
    collector_node = computer_node_id(),
    status = status or "written",
    ts = now_ms(),
  }
  for _, modem in ipairs(stats.modems or {}) do
    if type(modem.transmit) == "function" then
      local ok = pcall(modem.transmit, CHANNEL, CHANNEL, ack)
      if ok then stats.ack_sent = stats.ack_sent + 1 end
    end
  end
end

-- ── Self log ────────────────────────────────────────────────────────────────
local function self_log(message, level)
  local event_id = computer_node_id() .. ":self:" .. tostring(now_ms())
  local payload = {
    type = "LOG_EVENT",
    proto = "xreactor-log-v2",
    node_id = computer_node_id(),
    role = SELF_ROLE,
    prefix = "LOG",
    level = level or "INFO",
    message = tostring(message or ""),
    event_id = event_id,
    ts = now_ms(),
  }
  local ok, err = write_log(payload)
  if ok then remember(event_id) elseif err ~= "paused" then stats.last_error = err end
end

-- ── Incremental UI renderer ─────────────────────────────────────────────────
local ui_buffer = {
  prev = {},
  current = {},
  force = true,
  last_w = nil,
  last_h = nil,
}

local function display_size()
  if not term or type(term.getSize) ~= "function" then return 40, 20 end
  local ok, w, h = pcall(term.getSize)
  if ok then return tonumber(w) or 40, tonumber(h) or 20 end
  return 40, 20
end

local function begin_frame()
  local w, h = display_size()
  ui_buffer.current = {}
  if ui_buffer.last_w ~= w or ui_buffer.last_h ~= h then
    ui_buffer.force = true
    ui_buffer.last_w = w
    ui_buffer.last_h = h
  end
  return w, h
end

local function segment_key(x, y, text)
  return tostring(y) .. ":" .. tostring(x) .. ":" .. tostring(#tostring(text or ""))
end

local function queue_segment(x, y, text, fg, bg)
  text = tostring(text or "")
  if text == "" then return end
  local key = segment_key(x, y, text)
  ui_buffer.current[key] = {
    x = x,
    y = y,
    text = text,
    fg = fg or color("white", 1),
    bg = bg or color("black", 32768),
  }
end

local function write_segment(seg)
  if not term or not seg then return end
  pcall(term.setCursorPos, seg.x, seg.y)
  if term.setBackgroundColor then pcall(term.setBackgroundColor, seg.bg) end
  if term.setTextColor then pcall(term.setTextColor, seg.fg) end
  if term.write then pcall(term.write, seg.text) end
  if term.setTextColor then pcall(term.setTextColor, color("white", 1)) end
  if term.setBackgroundColor then pcall(term.setBackgroundColor, color("black", 32768)) end
end

local function same_segment(a, b)
  return a and b
    and a.x == b.x and a.y == b.y
    and a.text == b.text and a.fg == b.fg and a.bg == b.bg
end

local function erase_segment(seg)
  if not seg then return end
  write_segment({
    x = seg.x,
    y = seg.y,
    text = string.rep(" ", #tostring(seg.text or "")),
    fg = color("white", 1),
    bg = color("black", 32768),
  })
end

local function flush_ui()
  if ui_buffer.force then
    if term and term.setBackgroundColor then term.setBackgroundColor(color("black", 32768)) end
    if term and term.setTextColor then term.setTextColor(color("white", 1)) end
    if term and term.clear then term.clear() end
    ui_buffer.prev = {}
  end

  for key, old in pairs(ui_buffer.prev) do
    if not ui_buffer.current[key] then
      erase_segment(old)
    end
  end

  for key, seg in pairs(ui_buffer.current) do
    if ui_buffer.force or not same_segment(seg, ui_buffer.prev[key]) then
      write_segment(seg)
    end
  end

  ui_buffer.prev = ui_buffer.current
  ui_buffer.current = {}
  ui_buffer.force = false
end

local function line_ui(x, y, text, fg, bg)
  local w = ({ display_size() })[1]
  queue_segment(x, y, fit(text, math.max(1, w - x + 1)), fg, bg)
end

local function fill_line(y, fg, bg)
  local w = ({ display_size() })[1]
  queue_segment(1, y, string.rep(" ", w), fg or color("white", 1), bg or color("black", 32768))
end

local function badge_ui(x, y, label, status)
  local bg = color("gray", 128)
  if status == "OK" then bg = color("lime", 32)
  elseif status == "WARN" then bg = color("yellow", 16)
  elseif status == "ERR" then bg = color("red", 16384)
  elseif status == "INFO" then bg = color("cyan", 2048) end
  local text = " " .. fit(label, 10) .. " "
  queue_segment(x, y, text, color("black", 32768), bg)
  return #text
end

local function progress_ui(x, y, width, pct, good)
  local p = math.max(0, math.min(1, tonumber(pct) or 0))
  local fill = math.floor(width * p)
  local bar = string.rep("|", fill) .. string.rep(" ", math.max(0, width - fill))
  queue_segment(x, y, bar, good and color("lime", 32) or color("yellow", 16), color("gray", 128))
end

local function draw_pause_button(x, y)
  local label = stats.paused and " RESUME DISK WRITES " or " PAUSE DISK WRITES "
  stats.pause_button = { x = x, y = y, w = #label, h = 1 }
  queue_segment(x, y, label, color("black", 32768), stats.paused and color("lime", 32) or color("yellow", 16))
end

local function draw_log_mode_buttons(x, y)
  stats.log_mode_buttons = {}
  if not utils then return end
  local mode = utils.get_log_mode and utils.get_log_mode() or "all"
  local modes = { "all", "disk", "remote", "terminal", "none" }
  local labels = { all = "All ", disk = "Disk", remote = "Rmt ", terminal = "Term", none = "Off " }
  line_ui(x, y, "Log:", color("gray", 128), color("black", 32768))
  local cx = x + 4
  for _, item in ipairs(modes) do
    local selected = mode == item
    local label = labels[item] or item
    queue_segment(cx, y, label,
      selected and color("black", 32768) or color("white", 1),
      selected and color("lime", 32) or color("gray", 128))
    stats.log_mode_buttons[#stats.log_mode_buttons + 1] = { x = cx, y = y, w = #label, h = 1, mode = item }
    cx = cx + #label
  end
end

local function button_hit(button, x, y)
  return button and x >= button.x and x < button.x + button.w and y >= button.y and y < button.y + button.h
end

local function draw()
  refresh_disks(false)
  refresh_modems(false)

  local w, h = begin_frame()

  local title = " XReactor LOG Collector v2 "
  line_ui(1, 1, title .. string.rep(" ", math.max(0, w - #title)),
    color("black", 32768), color("gray", 128))

  local status = "OK"
  if stats.last_error then status = "WARN" end
  if #stats.modems == 0 or #stats.disks == 0 then status = "ERR" end
  if stats.paused then status = "WARN" end

  local bx = 2
  bx = bx + badge_ui(bx, 2, stats.paused and "PAUSED" or status, status) + 1
  bx = bx + badge_ui(bx, 2, "CH " .. tostring(CHANNEL), "INFO") + 1
  bx = bx + badge_ui(bx, 2, stats.modem ~= "" and stats.modem or "NO-MODEM", stats.modem ~= "" and "OK" or "ERR") + 1
  badge_ui(bx, 2, "DISKS " .. tostring(#stats.disks), #stats.disks > 0 and "OK" or "ERR")

  line_ui(2, 3, "Display: " .. tostring(stats.display_name or "term"), color("lightGray", 256))
  draw_pause_button(2, 4)
  draw_log_mode_buttons(2, 5)

  line_ui(2, 6, "Disk Ring (/disk=RT, /disk1=MASTER, /disk2=ENERGY, ...)", color("cyan", 2048))
  local dx = 2
  for _, disk in ipairs(stats.disks) do
    local free = free_space(disk.mount)
    local disk_status = free < MIN_FREE_BYTES and "WARN" or "OK"
    local label = (disk.id == stats.last_write_index and "*" or "") .. tostring(disk.id) .. ":" .. tostring(disk.role):sub(1, 3)
    dx = dx + badge_ui(dx, 7, label, disk_status)
    if dx > w - 4 then break end
  end

  local current = stats.disks[stats.last_write_index or 1] or stats.disks[1]
  if current then
    line_ui(2, 8, string.format("Last disk: %s role=%s", tostring(current.mount), tostring(current.role)), color("lightGray", 256))
    line_ui(2, 9, "Path: " .. fit(stats.last_write_path or "-", w - 8), color("lightGray", 256))
    local free = free_space(current.mount)
    local free_ok = free > MIN_FREE_BYTES * 4
    line_ui(2, 10, "Free: " .. tostring(free) .. " bytes", free_ok and color("lime", 32) or color("yellow", 16))
    progress_ui(2, 11, math.max(8, w - 3), free == math.huge and 1 or math.min(1, free / math.max(MIN_FREE_BYTES * 8, 1)), free_ok)
  else
    line_ui(2, 8, "No writable disk. Logs are dropped until a disk is attached.", color("red", 16384))
  end

  line_ui(2, 13, "Traffic", color("cyan", 2048))
  line_ui(2, 14, string.format("Recv %-6s Write %-6s Drop %-6s Dup %-6s", stats.received, stats.written, stats.dropped, stats.duplicates), color("white", 1))
  line_ui(2, 15, string.format("ACK %-7s Wiped %-5s PauseDrop %-5s", stats.ack_sent, stats.wiped, stats.paused_dropped), color("lightGray", 256))
  line_ui(2, 16, string.format("Refresh modem=%s disk=%s", stats.modem_refreshes, stats.disk_refreshes), color("lightGray", 256))
  line_ui(2, 18, "Last: " .. fit(tostring(stats.last_role) .. "/" .. tostring(stats.last_node) .. " " .. tostring(stats.last_level), w - 8), color("white", 1))

  if stats.last_error and h >= 20 then
    line_ui(2, 20, "Error: " .. fit(stats.last_error, w - 9), color("red", 16384))
  elseif stats.paused and h >= 20 then
    line_ui(2, 20, "PAUSED: incoming logs are acknowledged only when written/duplicate; paused logs are dropped.", color("yellow", 16))
  elseif h >= 20 then
    line_ui(2, 20, "Status OK", color("lime", 32))
  end

  if #live_diag > 0 and h >= 23 then
    line_ui(2, 22, "Diagnostics:", color("cyan", 2048))
    local rows = math.min(#live_diag, h - 22)
    for i = 1, rows do
      local entry = live_diag[#live_diag - rows + i]
      line_ui(2, 22 + i, fit(entry, w - 3), color("lightGray", 256))
    end
  end

  flush_ui()
  stats.last_draw_s = now_s()
end

-- ── Display selection ───────────────────────────────────────────────────────
local function find_display()
  local configured = trim(safe_read(MONITOR_CFG_FILE) or "")
  if configured ~= "" and peripheral and peripheral.wrap then
    local ok, monitor = pcall(peripheral.wrap, configured)
    if ok and monitor then return configured, monitor end
  end

  if peripheral and type(peripheral.getNames) == "function" then
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then
      table.sort(names)
      for _, name in ipairs(names) do
        local ok_type, ptype = pcall(peripheral.getType, name)
        if ok_type and tostring(ptype or ""):lower():find("monitor", 1, true) then
          local ok_wrap, monitor = pcall(peripheral.wrap, name)
          if ok_wrap and monitor then return name, monitor end
        end
      end
    end
  end

  return "term", term
end

-- ── Packet handling ─────────────────────────────────────────────────────────
local function valid_log_event(message)
  return type(message) == "table" and message.type == "LOG_EVENT"
end

local function handle_log_event(message)
  stats.received = stats.received + 1
  stats.last_node = message.node_id or "?"
  stats.last_role = message.role or "?"
  stats.last_level = message.level or "?"

  if seen(message.event_id) then
    stats.duplicates = stats.duplicates + 1
    send_ack(message, "duplicate")
    return
  end

  local ok, err = write_log(message)
  if ok then
    stats.written = stats.written + 1
    remember(message.event_id)
    send_ack(message, "written")
  else
    if err ~= "paused" then stats.last_error = err end
  end
end

local function toggle_pause()
  stats.paused = not stats.paused
  stats.last_error = nil
  self_log(stats.paused and "Disk writes paused" or "Disk writes resumed", "INFO")
  draw()
end

local function handle_touch(x, y)
  if button_hit(stats.pause_button, x, y) then
    toggle_pause()
    return
  end
  if utils and utils.set_log_mode then
    for _, button in ipairs(stats.log_mode_buttons or {}) do
      if button_hit(button, x, y) then
        utils.set_log_mode(button.mode)
        draw()
        return
      end
    end
  end
end

-- ── Main loop ───────────────────────────────────────────────────────────────
local function run()
  local display_name, display = find_display()
  stats.display_name = display_name
  stats.display = display

  if display and display ~= term and term and term.redirect then
    if type(display.setTextScale) == "function" then pcall(display.setTextScale, 0.5) end
    pcall(term.redirect, display)
  end

  refresh_disks(true)
  refresh_modems(true)
  self_log("LOG Collector started; disks=" .. tostring(#stats.disks) .. " modem=" .. tostring(stats.modem), "INFO")
  draw()

  local timer = os.startTimer and os.startTimer(1)
  while true do
    local event = { os.pullEvent() }
    local name = event[1]

    if name == "modem_message" then
      local channel = event[3]
      local message = event[5]
      if channel == CHANNEL and valid_log_event(message) then
        local ok, err = pcall(handle_log_event, message)
        if not ok then
          stats.dropped = stats.dropped + 1
          stats.last_error = "handle crashed: " .. tostring(err):sub(1, 70)
          diag(stats.last_error)
        end
        if stats.received % 20 == 0 or not ok then draw() end
      end
    elseif name == "monitor_touch" then
      handle_touch(event[3], event[4])
    elseif name == "mouse_click" then
      handle_touch(event[3], event[4])
    elseif name == "key" then
      if keys and (event[2] == keys.p or event[2] == keys.space) then toggle_pause() end
    elseif name == "disk" or name == "disk_eject" or name == "peripheral" or name == "peripheral_detach" then
      refresh_disks(true)
      refresh_modems(true)
      draw()
    elseif name == "timer" and event[2] == timer then
      refresh_disks(false)
      refresh_modems(false)
      if now_s() - stats.last_draw_s >= DRAW_INTERVAL_S then draw() end
      timer = os.startTimer and os.startTimer(1)
    end
  end
end

-- ── Crash screen ────────────────────────────────────────────────────────────
local ok, err = xpcall(run, function(e) return e end)
if ok then return end
if tostring(err or ""):lower():find("terminate", 1, true) then return end

if term then
  if term.setBackgroundColor then term.setBackgroundColor(color("black", 32768)) end
  if term.setTextColor then term.setTextColor(color("red", 16384)) end
  if term.clear then term.clear() end
  if term.setCursorPos then term.setCursorPos(1, 1) end
  print("=== LOG COLLECTOR CRASH ===")
  if term.setTextColor then term.setTextColor(color("white", 1)) end
  print("")
  print(tostring(err))
  print("")
  print("recv=" .. tostring(stats.received) .. " write=" .. tostring(stats.written) .. " drop=" .. tostring(stats.dropped))
  if term.setTextColor then term.setTextColor(color("yellow", 16)) end
  print("Taste druecken um neu zu starten...")
end
pcall(os.pullEvent, "key")
if os and os.reboot then os.reboot() end
