-- nodes/log_collector/main.lua
-- XReactor LOG Collector — v2 Rewrite
-- Empfängt Logs von allen Nodes via Modem, schreibt auf externe Disketten.
-- Eine Diskette pro Rolle: /disk=RT, /disk1=MASTER, /disk2=ENERGY etc.
-- Bei voller Disk: alte Logs löschen und neu schreiben (kein PC-Fallback).

-- ── Abhängigkeiten ────────────────────────────────────────────────────────
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

-- ── Konfiguration ─────────────────────────────────────────────────────────
local CHANNEL             = constants.channels and constants.channels.LOG or 6502
local MAX_LOG_BYTES       = 819200   -- 800 KB: nutzt fast die gesamte 1 MB Diskette
local MIN_FREE_BYTES      = 4096     -- 4 KB Mindestschwelle vor prune
local DEDUPE_LIMIT        = 512      -- Max. gecachte Event-IDs
local MODEM_REFRESH_S     = 10       -- Sekunden zwischen Modem-Refreshes
local SELF_ROLE           = "LOG_COLLECTOR"
local MONITOR_CFG_FILE    = "/xreactor/config/log_monitor.txt"

-- Disketten-Reihenfolge: /disk=RT, /disk1=MASTER, /disk2=ENERGY ...
local ROLE_ORDER = { "RT", "MASTER", "ENERGY", "WATER", "FUEL", "REPROCESSING", "LOG" }

-- ── Zustand ───────────────────────────────────────────────────────────────
local stats = {
  received = 0, written = 0, dropped = 0, duplicates = 0,
  ack_sent = 0, paused_dropped = 0, wiped = 0,
  disks = {}, disk_index = 1,
  last_write_index = nil, last_write_mount = "-",
  last_write_path = "-", last_node = "-", last_level = "-",
  last_error = nil, log_root = nil,
  modem = nil, modems = {}, modem_refreshes = 0,
  next_modem_refresh = 0,
  display = nil, display_name = "term",
  paused = false, pause_button = nil, log_mode_buttons = {},
  seen = {}, seen_order = {},
}

-- Live-Diagnose: nur im RAM, rendert direkt im UI (unabhängig von Disk-IO)
local live_diag = {}
local function diag(msg)
  live_diag[#live_diag + 1] = tostring(msg)
  if #live_diag > 12 then table.remove(live_diag, 1) end
end

-- ── Hilfsfunktionen ───────────────────────────────────────────────────────
local function c(name)
  return colors and colors[name] or nil
end

local function fit(text, w)
  local s = tostring(text or ""):gsub("[\n\r]", " ")
  w = math.max(1, tonumber(w) or #s)
  if #s <= w then return s end
  return s:sub(1, w - 1) .. "~"
end

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function safe_read(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll(); f.close(); return s
end

local function now_s()
  if os and type(os.epoch) == "function" then
    local ok, v = pcall(os.epoch, "utc")
    if ok and type(v) == "number" then return math.floor(v / 1000) end
  end
  return 0
end

local function free_space(path)
  if type(fs.getFreeSpace) ~= "function" then return 0 end
  local ok, v = pcall(fs.getFreeSpace, path or "/")
  if not ok then return 0 end
  if v == "unlimited" then return math.huge end
  return tonumber(v) or 0
end

local function ensure_dir(path)
  if fs.exists(path) then return fs.isDir(path) end
  local ok = pcall(fs.makeDir, path)
  return ok and fs.exists(path) and fs.isDir(path)
end

local function safe_del(path)
  if fs.exists(path) then pcall(fs.delete, path) end
end

local function sanitize(v)
  local s = tostring(v or "unknown"):lower():gsub("[^a-z0-9_%-]+", "_")
  s = s:gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or "unknown"
end

local function node_id()
  if os and type(os.getComputerID) == "function" then
    return "pc-" .. tostring(os.getComputerID())
  end
  return "log-collector"
end

-- ── Disk-Management ───────────────────────────────────────────────────────
-- Alle Log-Dateien auf einer Disk löschen (bei voller Disk)
local function wipe_disk(root)
  local wiped = 0
  local function sweep(dir)
    if not fs.exists(dir) or not fs.isDir(dir) then return end
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return end
    for _, name in ipairs(entries) do
      local p = fs.combine(dir, name)
      if fs.isDir(p) then sweep(p)
      else safe_del(p); wiped = wiped + 1 end
    end
  end
  sweep(root)
  stats.wiped = (stats.wiped or 0) + wiped
  return wiped
end

-- Findet alle externen Disketten über fs.list("/")
-- Gibt alphabetisch sortierte Liste zurück: /disk, /disk1, /disk2 ...
local function find_disk_mounts()
  local mounts = {}
  diag("--- disk scan ---")
  if not (fs and fs.list) then return mounts end
  local ok, entries = pcall(fs.list, "/")
  if not ok or type(entries) ~= "table" then return mounts end
  table.sort(entries)
  for _, entry in ipairs(entries) do
    if type(entry) == "string" and entry:match("^disk%d*$") then
      mounts[#mounts + 1] = "/" .. entry
    end
  end
  diag("mounts: " .. (#mounts > 0 and table.concat(mounts, ", ") or "keine"))
  return mounts
end

-- Probe-Schreib-Test: kann auf diese Disk geschrieben werden?
local function probe_disk(root)
  local dir = root .. "/xreactor_logs"
  if not ensure_dir(dir) then return false end
  local path = dir .. "/.probe"
  local ok = pcall(function()
    local h = fs.open(path, "w")
    if not h then error("fs.open nil") end
    h.write("x"); h.close()
    fs.delete(path)
  end)
  if not ok then
    -- Disk voll: leeren und nochmal
    wipe_disk(dir)
    ok = pcall(function()
      local h = fs.open(path, "w")
      if not h then error("fs.open nil after wipe") end
      h.write("x"); h.close()
      fs.delete(path)
    end)
  end
  return ok
end

local refreshing = false

local function discover_disks()
  local mounts = find_disk_mounts()
  local disks = {}
  for idx, mount in ipairs(mounts) do
    local root = mount .. "/xreactor_logs"
    if probe_disk(mount) then
      local role = ROLE_ORDER[idx] or ("DISK" .. idx)
      diag(mount .. " → " .. role)
      disks[#disks + 1] = { mount = mount, root = root, role = role, id = idx }
    else
      diag(mount .. " → probe FAILED")
    end
  end
  if #disks == 0 then
    diag("KEINE Disk verfügbar — Logs werden verworfen")
  else
    diag(tostring(#disks) .. " Disk(s) bereit")
  end
  return disks
end

local function refresh_disks(force)
  if refreshing then return end
  if not force and #stats.disks > 0 and stats.received % 200 ~= 0 then return end
  refreshing = true
  stats.disks = discover_disks()
  stats.disk_index = 1
  stats.log_root = stats.disks[1] and stats.disks[1].root or nil
  refreshing = false
end

-- Gibt die Disk für eine Rolle zurück (nach ROLE_ORDER Index)
local function disk_for_role(role)
  if not role then return stats.disks[stats.disk_index] end
  local r = tostring(role):upper()
  for _, d in ipairs(stats.disks) do
    if d.role == r then return d end
  end
  return stats.disks[stats.disk_index]
end

-- ── Log schreiben ─────────────────────────────────────────────────────────
local function format_line(payload)
  local ts = payload.ts or (os.epoch and os.epoch("utc")) or "?"
  return string.format("[%s] %s | %s | %s | %s",
    tostring(ts), tostring(payload.role or "?"),
    tostring(payload.prefix or "LOG"), tostring(payload.level or "INFO"),
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
  if not disk then return false, "no disk" end

  local role_dir = disk.root .. "/" .. sanitize(payload.role or "unknown")
  if not ensure_dir(role_dir) then return false, "mkdir failed" end

  local path = role_dir .. "/" .. sanitize(payload.node_id or "unknown") .. ".log"

  -- Datei rotieren wenn zu groß
  if fs.exists(path) and fs.getSize(path) >= MAX_LOG_BYTES then
    safe_del(path)
  end

  -- Platz prüfen
  local free = free_space(disk.mount)
  if free < MIN_FREE_BYTES then
    -- Disk leeren und neu starten
    local wiped = wipe_disk(disk.root)
    diag("disk full: wiped " .. tostring(wiped) .. " files on " .. disk.mount)
    free = free_space(disk.mount)
  end

  local line_text = format_line(payload) .. "\n"
  local ok, err = pcall(function()
    local h = fs.open(path, "a")
    if not h then error("fs.open nil") end
    h.write(line_text); h.close()
  end)

  if not ok then
    local es = tostring(err or "write failed")
    diag("write failed: " .. es:sub(1, 60))
    -- Bei "Out of space": Disk leeren und nochmal
    if es:lower():find("out of space", 1, true) or es:lower():find("no space", 1, true) then
      local wiped = wipe_disk(disk.root)
      diag("out of space: wiped " .. tostring(wiped) .. " files, retry")
      ok, err = pcall(function()
        local h = fs.open(path, "a")
        if not h then error("fs.open nil after wipe") end
        h.write(line_text); h.close()
      end)
      if ok then
        stats.last_write_index = disk.id
        stats.last_write_mount = disk.mount
        stats.last_write_path  = path
        stats.last_error = nil
        return true
      end
    end
    stats.last_error = tostring(err or "write failed"):sub(1, 80)
    return false, stats.last_error
  end

  stats.last_write_index = disk.id
  stats.last_write_mount = disk.mount
  stats.last_write_path  = path
  stats.log_root         = disk.root
  stats.last_error = nil
  return true
end

-- ── Deduplizierung ────────────────────────────────────────────────────────
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

-- ── Modem ─────────────────────────────────────────────────────────────────
local function refresh_modems(force)
  local now = now_s()
  if not force and now < stats.next_modem_refresh then return end
  stats.next_modem_refresh = now + MODEM_REFRESH_S
  stats.modems = {}
  local names = {}
  if not (peripheral and peripheral.getNames) then return end
  local ok, perifs = pcall(peripheral.getNames)
  if not ok then return end
  for _, name in ipairs(perifs) do
    if peripheral.getType(name) == "modem" then
      local ok2, m = pcall(peripheral.wrap, name)
      if ok2 and m and type(m.open) == "function" then
        pcall(m.open, CHANNEL)
        stats.modems[#stats.modems + 1] = m
        names[#names + 1] = name
      end
    end
  end
  stats.modem = table.concat(names, ",")
  stats.modem_refreshes = stats.modem_refreshes + 1
end

local function send_ack(payload, status)
  if not payload.ack or not payload.event_id then return end
  local ack = {
    type = "LOG_ACK", proto = "xreactor-log-v2",
    event_id = payload.event_id, to_node = payload.node_id,
    collector_node = node_id(), status = status or "written",
    ts = os.epoch and os.epoch("utc") or nil
  }
  for _, m in ipairs(stats.modems or {}) do
    if type(m.transmit) == "function" then
      local ok = pcall(m.transmit, CHANNEL, CHANNEL, ack)
      if ok then stats.ack_sent = stats.ack_sent + 1 end
    end
  end
end

-- ── Self-Log ──────────────────────────────────────────────────────────────
local function self_log(msg, level)
  local payload = {
    type = "LOG_EVENT", proto = "xreactor-log-v2",
    node_id = node_id(), role = SELF_ROLE, prefix = "LOG",
    level = level or "INFO", message = msg,
    event_id = node_id() .. ":self:" .. tostring(now_s()),
    ts = os.epoch and os.epoch("utc") or nil
  }
  local ok, err = write_log(payload)
  if ok then remember(payload.event_id)
  elseif err ~= "paused" then stats.last_error = err end
end

-- ── Display / UI ──────────────────────────────────────────────────────────
local function line_ui(x, y, text, fg, bg)
  local w = ({ term.getSize() })[1] or 40
  term.setCursorPos(x, y)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
  term.write(fit(text, math.max(1, w - x + 1)))
  term.setTextColor(c("white") or 1)
  term.setBackgroundColor(c("black") or 32768)
end

local function badge_ui(x, y, text, status)
  local bg = status == "OK" and c("lime") or status == "WARN" and c("yellow")
    or status == "ERR" and c("red") or status == "INFO" and c("cyan") or c("gray")
  local label = " " .. fit(text, 10) .. " "
  buf_line(x, y, label, c("black") or 1, bg or c("gray"))
  return #label
end

local function progress_ui(x, y, w, pct, ok)
  local p = math.max(0, math.min(1, tonumber(pct) or 0))
  local fill = math.floor(w * p)
  local fg = ok and c("lime") or c("yellow")
  local bar = string.rep("|", fill) .. string.rep(" ", w - fill)
  buf_line(x, y, bar, fg, c("gray"))
end

local function draw_pause_btn(x, y)
  local label = stats.paused and " RESUME DISK WRITES " or " PAUSE DISK WRITES "
  stats.pause_button = { x=x, y=y, w=#label, h=1 }
  buf_line(x, y, label, c("black") or 1, stats.paused and c("lime") or c("yellow"))
end

local function draw_logmode_btns(x, y)
  if not utils then return end
  local mode = utils.get_log_mode and utils.get_log_mode() or "all"
  local modes = { "all", "disk", "remote", "terminal", "none" }
  local labels = { all="All ", disk="Disk", remote="Rmt ", terminal="Term", none="Off " }
  buf_line(x, y, "Log:", c("gray"), c("black"))
  local cx = x + 4
  stats.log_mode_buttons = {}
  for _, m in ipairs(modes) do
    local lbl = labels[m] or m
    buf_line(cx, y, lbl,
      mode == m and c("black") or c("white"),
      mode == m and c("lime") or c("gray"))
    stats.log_mode_buttons[#stats.log_mode_buttons+1] = { x=cx, y=y, w=4, h=1, mode=m }
    cx = cx + 4
  end
end

local function btn_hit(btn, x, y)
  return btn and x >= btn.x and x < btn.x+btn.w and y >= btn.y and y < btn.y+btn.h
end

local draw
draw = function()
  refresh_disks(false)
  refresh_modems(false)
  local w, h = term.getSize()
  term.clear()
  term.setTextColor(c("white") or 1)
  term.setBackgroundColor(c("black") or 32768)

  -- Zeile 1: Header
  line_ui(1, 1, string.rep(" ", w), c("black"), c("gray"))
  line_ui(2, 1, " XReactor LOG ", c("black"), c("gray"))

  -- Zeile 2: Status-Badges
  local status = stats.paused and "WARN" or (stats.last_error and "WARN" or "OK")
  local bx = 2
  bx = bx + badge_ui(bx, 2, stats.paused and "PAUSED" or status, status) + 1
  bx = bx + badge_ui(bx, 2, "CH " .. tostring(CHANNEL), "INFO") + 1
  bx = bx + badge_ui(bx, 2, tostring(stats.modem ~= "" and stats.modem or "NO-MODEM"),
    stats.modem and stats.modem ~= "" and "OK" or "ERR")

  -- Zeile 3-5: Buttons
  line_ui(2, 3, fit("Display " .. tostring(stats.display_name or "term"), w-2), c("lightGray"))
  draw_pause_btn(2, 4)
  draw_logmode_btns(2, 5)

  -- Zeile 6-7: Disk-Ring
  line_ui(2, 6, "Disk Ring (* = aktive Disk)", c("cyan"))
  local dx = 2
  for i, d in ipairs(stats.disks) do
    local free = free_space(d.mount)
    local st = i == stats.last_write_index and "INFO"
      or (free < MIN_FREE_BYTES and "WARN" or "OK")
    local label = (i == stats.last_write_index and "*" or "") .. tostring(i) .. ":" .. d.role:sub(1,3)
    dx = dx + badge_ui(dx, 7, label, st)
    if dx > w - 4 then break end
  -- Nur geänderte Zeilen auf Monitor schreiben
  flush_buf()
  end

  -- Zeile 8-12: Disk-Status
  local cur = stats.disks[stats.last_write_index or 1] or {}
  line_ui(2, 8, string.format("Disk %s/%s  %s  → %s",
    tostring(stats.last_write_index or "-"), tostring(#stats.disks),
    tostring(cur.mount or "-"), tostring(cur.role or "-")), c("lightGray"))
  line_ui(2, 9, "Path " .. fit(tostring(stats.last_write_path or "-"), w-7), c("lightGray"))
  local free = free_space(cur.mount or "/")
  local free_ok = free > MIN_FREE_BYTES * 4
  line_ui(2, 10, "Free " .. tostring(free) .. " bytes", free_ok and c("lime") or c("yellow"))
  progress_ui(2, 11, math.max(8, w-3),
    free == math.huge and 1 or math.min(1, free / math.max(MIN_FREE_BYTES * 8, 1)), free_ok)

  -- Zeile 13-18: Traffic
  line_ui(2, 13, "Traffic", c("cyan"))
  line_ui(2, 14, string.format("Recv %-6s Write %-6s Drop %-5s Dup %-5s",
    stats.received, stats.written, stats.dropped, stats.duplicates), c("white"))
  line_ui(2, 15, string.format("ACK %-7s Wiped %-5s Paused %-5s",
    stats.ack_sent, stats.wiped or 0, stats.paused_dropped), c("lightGray"))
  line_ui(2, 16, string.format("Modem-Refreshes %-3s", stats.modem_refreshes), c("lightGray"))
  line_ui(2, 18, "Last: " .. fit(tostring(stats.last_node) .. " " .. tostring(stats.last_level), w-8), c("white"))

  -- Zeile 20+: Fehler oder Status
  if stats.last_error and h >= 20 then
    line_ui(2, 20, "Error", c("red"))
    line_ui(2, 21, fit(tostring(stats.last_error), w-3), c("red"))
  elseif stats.paused and h >= 20 then
    line_ui(2, 20, "PAUSED — Logs werden verworfen", c("yellow"))
  elseif h >= 20 then
    line_ui(2, 20, "Status OK", c("lime"))
  end

  -- Zeile 23+: Live-Diagnose
  if #live_diag > 0 and h >= 23 then
    line_ui(2, 22, "Disk Diagnose:", c("cyan"))
    local max_lines = math.min(#live_diag, h - 23)
    for i = 1, max_lines do
      local entry = live_diag[#live_diag - max_lines + i]
      line_ui(2, 22 + i, fit(tostring(entry), w-3), c("lightGray"))
    end
  end
end

-- ── Display-Erkennung ─────────────────────────────────────────────────────
local function find_display()
  local cfg = trim(safe_read(MONITOR_CFG_FILE) or "")
  if cfg ~= "" then
    local ok, mon = pcall(peripheral.wrap, cfg)
    if ok and mon then return cfg, mon end
  end
  if peripheral and peripheral.getNames then
    local ok, names = pcall(peripheral.getNames)
    if ok and names then
      table.sort(names)
      for _, name in ipairs(names) do
        if peripheral.getType(name) == "monitor" then
          local ok2, mon = pcall(peripheral.wrap, name)
          if ok2 and mon then return name, mon end
        end
      end
    end
  end
  return "term", term
end

-- ── Hauptschleife ─────────────────────────────────────────────────────────
local function handle_event(message)
  stats.received = stats.received + 1
  stats.last_node  = message.node_id or "?"
  stats.last_level = message.level or "?"

  if seen(message.event_id) then
    stats.duplicates = stats.duplicates + 1
    send_ack(message, "duplicate")
    return
  end

  local ok, err = write_log(message)
  if ok then
    stats.written = stats.written + 1
    stats.last_error = nil
    remember(message.event_id)
    send_ack(message, "written")
  else
    stats.dropped = stats.dropped + 1
    if err ~= "paused" then stats.last_error = err end
  end
end

local function toggle_pause()
  stats.paused = not stats.paused
  stats.last_error = nil
  self_log(stats.paused and "Disk writes paused" or "Disk writes resumed", "INFO")
  draw()
end

local function run()
  -- Display einrichten
  local dname, dmon = find_display()
  stats.display_name = dname
  stats.display = dmon
  if dmon and dmon ~= term and term.redirect then
    if type(dmon.setTextScale) == "function" then pcall(dmon.setTextScale, 0.5) end
    pcall(term.redirect, dmon)
  end

  -- Disks und Modems initialisieren
  refresh_disks(true)
  refresh_modems(true)

  if #stats.modems == 0 then
    term.clear(); term.setCursorPos(1,1)
    print("FEHLER: Kein Modem gefunden!")
    print("Bitte Modem anschliessen und neu starten.")
    os.pullEvent("key")
    return
  end

  self_log("LOG Collector gestartet — disks=" .. tostring(#stats.disks)
    .. " modem=" .. tostring(stats.modem), "INFO")
  draw()

  local timer = os.startTimer and os.startTimer(30)

  while true do
    local ev = { os.pullEvent() }
    local name = ev[1]

    if name == "modem_message" then
      local channel, msg = ev[3], ev[5]
      if channel == CHANNEL and type(msg) == "table" and msg.type == "LOG_EVENT" then
        local ok, err = pcall(handle_event, msg)
        if not ok then
          stats.dropped = stats.dropped + 1
          stats.last_error = "handle crashed: " .. tostring(err):sub(1,60)
        end
        if stats.received % 20 == 0 or not ok then draw() end
      end

    elseif name == "monitor_touch" or name == "mouse_click" then
      local x, y = ev[3], ev[4]
      if btn_hit(stats.pause_button, x, y) then toggle_pause() end
      for _, b in ipairs(stats.log_mode_buttons or {}) do
        if btn_hit(b, x, y) and utils and utils.set_log_mode then
          utils.set_log_mode(b.mode); draw()
        end
      end

    elseif name == "key" then
      if keys and (ev[2] == keys.p or ev[2] == keys.space) then toggle_pause() end

    elseif name == "timer" and ev[2] == timer then
      refresh_modems(false)
      self_log(string.format("Status recv=%d write=%d drop=%d dup=%d",
        stats.received, stats.written, stats.dropped, stats.duplicates), "DEBUG")
      draw()
      timer = os.startTimer and os.startTimer(30)
    end
  end
end

-- ── Start ─────────────────────────────────────────────────────────────────
local ok, err = xpcall(run, function(e) return e end)
if ok then return end
if tostring(err or ""):lower():find("terminate") then return end

-- Crash-Screen
if term then
  term.setBackgroundColor(colors and colors.black or 32768)
  term.setTextColor(colors and colors.red or 16384)
  term.clear(); term.setCursorPos(1,1)
  print("=== LOG COLLECTOR CRASH ===")
  term.setTextColor(colors and colors.white or 1)
  print(tostring(err))
  print("recv=" .. stats.received .. " write=" .. stats.written .. " drop=" .. stats.dropped)
  term.setTextColor(colors and colors.yellow or 16)
  print("Taste druecken um neu zu starten...")
end
pcall(os.pullEvent, "key")
if os.reboot then os.reboot() end
