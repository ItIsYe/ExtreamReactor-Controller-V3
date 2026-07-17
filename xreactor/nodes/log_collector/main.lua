-- nodes/log_collector/main.lua
-- XReactor LOG Collector — completed v2 rewrite
-- Receives LOG_EVENT packets via modem and writes them to external disks.
-- 4 disk slots per role. Disks are auto-labeled on first detection with a
-- persistent "XR-<ROLE>-<slot>" label (drive.setDiskLabel) — role/slot then
-- comes from the label, not from plug order. Unlabeled disks get the next
-- free slot of the first role that still has room (see DISKS_PER_ROLE/ROLE_ORDER).
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
  -- Fix (2026-06-30): Fallback war 6502, muss zu shared.constants.channels.LOG
  -- (6503) passen, sonst driftet der Fallback-Pfad vom Normalfall ab.
  constants = { channels = { LOG = 6503 } }
end

-- ── Configuration ───────────────────────────────────────────────────────────
local CHANNEL          = constants.channels and constants.channels.LOG or 6503
local MAX_LOG_BYTES    = 524288   -- 512 KB per active log file; leaves headroom on 1 MB CC disk
local MIN_FREE_BYTES   = 8192    -- 8 KB; triggers wipe before disk fills completely
local DEDUPE_LIMIT     = 512
local MODEM_REFRESH_S  = 10
local DISK_REFRESH_S   = 30
local DRAW_INTERVAL_S  = 5
local ACTIVE_DRAW_MIN_INTERVAL_S = 1  -- Fix (2026-07-13): LOG-P1.2
local SELF_ROLE        = "LOG_COLLECTOR"
local MONITOR_CFG_FILE = "/xreactor/config/log_monitor.txt"
-- Fix (2026-07-07): vorher exakt 1 Disk pro Rolle (positionsbasiert via
-- ROLE_ORDER[index]). User hat pro Rolle 3 weitere Disks ingame ergänzt
-- (jetzt 4 pro Rolle) — DISKS_PER_ROLE gruppiert die sortierten Mounts in
-- Blöcken zu je 4 statt 1:1 auf eine Rolle zu mappen. Feste physische
-- Steckreihenfolge vorausgesetzt: die ersten 4 Disks = RT, die naechsten 4 =
-- MASTER usw. (Variante B, siehe disk_for_role() fuer die Rotation
-- innerhalb einer Rollen-Gruppe).
local DISKS_PER_ROLE   = 4
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

-- Feature (2026-07-11): Crash-Loop-Schutz. Der bestehende Absturz-
-- Bildschirm (siehe Dateiende) wartet bereits nur begrenzt (30s) und
-- rebootet dann automatisch -- das verhindert bereits "haengt fuer immer
-- fest ohne physische Anwesenheit". Was noch fehlte: wenn der Computer
-- bei JEDEM Neustart sofort wieder abstuerzt (z.B. durch einen dauerhaft
-- kaputten Zustand), wuerde er sich in einer Endlos-Neustart-Schleife
-- verfangen -- alle 30s ein Reboot, ohne dass sich je etwas bessert, und
-- ohne dass das irgendwo sichtbar wird. Persistente Absturz-Historie
-- (einfache Datei mit Zeitstempeln, ueberlebt Reboots) erkennt dieses
-- Muster und verlaengert die Wartezeit deutlich, statt den Server mit
-- Reboots im Sekundentakt zu belasten.
local CRASH_HISTORY_PATH = "/xreactor_crash_history.txt"
local CRASH_LOOP_WINDOW_S = 120   -- Beobachtungsfenster: letzte 2 Minuten
local CRASH_LOOP_THRESHOLD = 3    -- ab 3 Abstuerzen in diesem Fenster gilt es als Loop
local CRASH_LOOP_WAIT_S = 300     -- bei erkannter Schleife: 5 statt 30 Sekunden warten

local function read_crash_history()
  if not (fs and fs.exists and fs.exists(CRASH_HISTORY_PATH)) then return {} end
  local ok, handle = pcall(fs.open, CRASH_HISTORY_PATH, "r")
  if not ok or not handle then return {} end
  local content = handle.readAll() or ""
  handle.close()
  local out = {}
  for line in content:gmatch("[^\n]+") do
    local n = tonumber(line)
    if n then out[#out + 1] = n end
  end
  return out
end

local function record_crash_and_check_loop()
  local now = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  local history = read_crash_history()
  -- Nur Eintraege innerhalb des Beobachtungsfensters behalten (alte
  -- Abstuerze sollen nicht ewig mitzaehlen).
  local recent = {}
  for _, ts in ipairs(history) do
    if now - ts <= CRASH_LOOP_WINDOW_S then recent[#recent + 1] = ts end
  end
  recent[#recent + 1] = now
  pcall(function()
    local handle = fs.open(CRASH_HISTORY_PATH, "w")
    if handle then
      handle.write(table.concat(recent, "\n") .. "\n")
      handle.close()
    end
  end)
  return #recent >= CRASH_LOOP_THRESHOLD, #recent
end

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

-- Perf (2026-07-07): free_space() wird ueber disk_for_role() bei JEDEM
-- eingehenden Log-Event aufgerufen (im Betrieb alle paar hundert ms), und
-- die Rotation prueft dabei bis zu DISKS_PER_ROLE (4) Mounts pro Aufruf.
-- fs.getFreeSpace() ist kein Gratis-Tabellenzugriff — bei dieser Frequenz
-- unnoetig oft aufgerufen, obwohl sich freier Speicher innerhalb weniger
-- Sekunden praktisch nie relevant aendert. Kurzer TTL-Cache (2s) pro Mount,
-- ohne das eigentliche Verhalten (Rotation bei Platzmangel) zu aendern —
-- nur die Abfragehaeufigkeit sinkt.
local free_space_cache = {}
local FREE_SPACE_CACHE_TTL = 2
local function free_space(path)
  if not (fs and type(fs.getFreeSpace) == "function") then return 0 end
  local key = path or "/"
  local now = os.clock and os.clock() or 0
  local cached = free_space_cache[key]
  if cached and (now - cached.at) < FREE_SPACE_CACHE_TTL then
    return cached.value
  end
  local ok, value = pcall(fs.getFreeSpace, key)
  local result = 0
  if ok then
    if value == "unlimited" then
      result = math.huge
    else
      result = tonumber(value) or 0
    end
  end
  free_space_cache[key] = { value = result, at = now }
  return result
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
-- Fix (2026-07-16): CRITICAL. INSTALL/LOG-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 16). Die
-- vorherige "wipe_disk()" loeschte bei JEDEM Platzmangel-Ereignis (und bei
-- jedem einzelnen fehlgeschlagenen probe_disk()-Aufruf, siehe dort) den
-- KOMPLETTEN Rollen-Logordner in einem Schritt -- ein voruebergehender
-- Full-/Mount-/Race-Fehler konnte so sämtliche bereits gesammelten Logs
-- einer Rolle vollstaendig vernichten. Ersetzt durch eine gezielte,
-- ausschliesslich alters-basierte Teilbereinigung: die JEWEILS aeltesten
-- Dateien (nach Aenderungszeitstempel) werden nacheinander entfernt, bis
-- genug Platz frei ist ODER nichts mehr zum Entfernen uebrig ist -- niemals
-- der gesamte Ordner auf einmal.
local function list_files_recursive(dir, out)
  out = out or {}
  if not (fs and fs.exists and fs.isDir and fs.list) then return out end
  if not fs.exists(dir) or not fs.isDir(dir) then return out end
  local ok, entries = pcall(fs.list, dir)
  if not ok or type(entries) ~= "table" then return out end
  for _, name in ipairs(entries) do
    local path = fs.combine(dir, name)
    if fs.isDir(path) then
      list_files_recursive(path, out)
    else
      out[#out + 1] = path
    end
  end
  return out
end

local function file_mtime(path)
  if type(fs.attributes) == "function" then
    local ok, attr = pcall(fs.attributes, path)
    if ok and type(attr) == "table" and type(attr.modified) == "number" then
      return attr.modified
    end
  end
  return 0
end

-- Bewusst grosszuegigeres Ziel als der reine MIN_FREE_BYTES-Schwellwert,
-- damit nicht sofort beim naechsten Log-Event erneut aufgeraeumt werden
-- muss (dieselbe Marge, die disk_for_role() bereits als "gesund" ansieht).
local RECLAIM_TARGET_BYTES = MIN_FREE_BYTES * 4

-- Fix (2026-07-17): CRITICAL (LOG-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 22). free_space() cached ihren
-- Rueckgabewert pro Mount fuer FREE_SPACE_CACHE_TTL (2s, siehe dortiger
-- Kommentar). Diese Schleife prueft vor JEDER Loeschung denselben
-- gecachten Wert, ohne ihn nach einer erfolgreichen Loeschung zu
-- invalidieren -- laeuft der gesamte Reclaim-Lauf (mehrere synchron
-- aufeinanderfolgende Loeschungen) innerhalb der Cache-TTL ab (in der
-- Praxis praktisch immer, da hier keine echte I/O-Wartezeit zwischen den
-- Loeschungen liegt), sieht die Schleife bei JEDER Iteration weiterhin
-- den ALTEN, niedrigen Free-Space-Wert und loescht munter weiter, obwohl
-- nach der ersten Loeschung bereits genug Platz frei sein kann. Die
-- vorherige pauschale Komplettloeschung wurde zwar entfernt (siehe
-- wipe_disk()-Fix-Kommentar oben), aber im Extremfall konnte diese
-- Schleife trotzdem ALLE aufgelisteten Dateien entfernen. Jetzt wird der
-- Cache-Eintrag fuer "mount" nach jeder Loeschung explizit invalidiert,
-- damit die naechste free_space()-Abfrage tatsaechlich neu misst.
-- Zusaetzlich: "exclude_path" schuetzt die gerade tatsaechlich offene
-- Zieldatei (der Log-Collector darf nie die Datei loeschen, die er im
-- selben Schreibversuch gerade befuellen will) und ein hartes Limit pro
-- Lauf begrenzt den maximalen Schaden, selbst wenn die Free-Space-Messung
-- aus einem anderen Grund weiterhin falsch waere.
local RECLAIM_MAX_FILES_PER_RUN = 64

local function reclaim_oldest(root, mount, needed, exclude_path)
  local files = list_files_recursive(root)
  table.sort(files, function(a, b) return file_mtime(a) < file_mtime(b) end)
  local removed = 0
  for _, path in ipairs(files) do
    if free_space(mount) >= needed then break end
    if removed >= RECLAIM_MAX_FILES_PER_RUN then break end
    if path ~= exclude_path then
      safe_delete(path)
      free_space_cache[mount] = nil
      removed = removed + 1
    end
  end
  stats.wiped = stats.wiped + removed
  return removed
end

local function is_drive_name(name)
  if not peripheral or type(peripheral.getType) ~= "function" then return false end
  local ok, ptype = pcall(peripheral.getType, name)
  if not ok then return false end
  if ptype == "drive" then return true end
  if type(ptype) == "table" then
    for _, item in pairs(ptype) do if item == "drive" then return true end end
  end
  return tostring(ptype or ""):lower():find("drive", 1, true) ~= nil
end

-- Fix (2026-07-07): echtes Disk-Labeling statt reiner Steckreihenfolge.
-- LOG_LABEL_PATTERN erkennt persistente Rollen-Labels der Form
-- "XR-<ROLE>-<slot>" (z.B. "XR-RT-1"), geschrieben via drive.setDiskLabel().
-- Eine bereits so gelabelte Disk behält ihre Rolle/ihren Slot dauerhaft —
-- unabhängig von Steckposition, Neustart oder Umstecken. Nur eine frische,
-- unbeschriftete Disk bekommt beim allerersten Erkennen ein neues Label
-- zugewiesen (nächster freier Slot der am wenigsten befüllten Rolle).
local LOG_LABEL_PATTERN = "^XR%-([%u_]+)%-(%d+)$"

local function make_label(role, slot)
  return "XR-" .. tostring(role):upper() .. "-" .. tostring(slot)
end

local function parse_label(label)
  if type(label) ~= "string" then return nil, nil end
  local role, slot = label:match(LOG_LABEL_PATTERN)
  if not role or not slot then return nil, nil end
  slot = tonumber(slot)
  for _, name in ipairs(ROLE_ORDER) do
    if name == role then return role, slot end
  end
  return nil, nil
end

-- Findet alle Disk-Laufwerke (peripheral-Typ "drive") mit eingelegter Disk.
-- Gibt eine Liste { name=peripheral_name, wrapped=..., mount=..., label=... }
-- zurück, sortiert nach Mount-Pfad (numerisch) für eine stabile, deterministische
-- Reihenfolge bei der Neuzuweisung unbeschrifteter Disks.
local function find_drives()
  local found = {}
  if not (peripheral and type(peripheral.getNames) == "function") then return found end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return found end
  for _, name in ipairs(names) do
    if is_drive_name(name) then
      local ok_wrap, drv = pcall(peripheral.wrap, name)
      if ok_wrap and drv then
        local present = type(drv.isDiskPresent) == "function" and (pcall(drv.isDiskPresent) and drv.isDiskPresent()) or false
        if present then
          local ok_mp, mount_path = pcall(drv.getMountPath)
          if ok_mp and type(mount_path) == "string" and mount_path ~= "" then
            local ok_lbl, label = pcall(drv.getDiskLabel)
            found[#found + 1] = {
              name = name, wrapped = drv, mount = "/" .. mount_path,
              label = (ok_lbl and label) or nil,
              n = tonumber(mount_path:match("^disk(%d*)$")) or 0,
            }
          end
        end
      end
    end
  end
  table.sort(found, function(a, b) return a.n < b.n end)
  return found
end

-- Fix (2026-07-16): CRITICAL. INSTALL/LOG-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 16).
-- Ein einzelner fehlgeschlagener Schreibversuch (z.B. voruebergehender
-- Mount-/IO-Fehler oder Race mit einer anderen Disk-Operation) loeschte
-- bisher den GESAMTEN Rollen-Logordner der Disk, bevor ueberhaupt ein
-- zweiter Versuch unternommen wurde -- die "Reparatur" vernichtete dabei
-- saemtliche bereits gesammelten Logs dieser Rolle. Ein fehlgeschlagener
-- Probe darf niemals mehr als die eigene ".probe"-Testdatei anfassen; bei
-- einem Fehlschlag wird die Disk fuer diesen Zyklus einfach als nicht
-- schreibbar gemeldet (discover_disks() ueberspringt sie dann) und beim
-- naechsten regulaeren DISK_REFRESH_S-Zyklus erneut probiert -- kein
-- destruktiver "Reparaturversuch".
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
  if not ok then
    -- Nur die eigene, evtl. haengengebliebene Probe-Datei aufraeumen --
    -- sonst nichts anfassen.
    pcall(function() if fs.exists(probe) then fs.delete(probe) end end)
  end
  return ok
end

local function discover_disks()
  local disks = {}
  local drives = find_drives()

  -- Slot-Belegung pro Rolle aus bereits gültig gelabelten Disks ermitteln,
  -- damit Neuzuweisungen keine bestehenden Slots doppelt vergeben.
  local used_slots = {}
  for _, name in ipairs(ROLE_ORDER) do used_slots[name] = {} end
  for _, d in ipairs(drives) do
    local role, slot = parse_label(d.label)
    if role and slot and slot >= 1 and slot <= DISKS_PER_ROLE and not used_slots[role][slot] then
      used_slots[role][slot] = true
    end
  end

  local function next_free_slot(role)
    for slot = 1, DISKS_PER_ROLE do
      if not used_slots[role][slot] then return slot end
    end
    return nil
  end

  local function next_role_with_space()
    for _, role in ipairs(ROLE_ORDER) do
      if next_free_slot(role) then return role end
    end
    return nil
  end

  for _, d in ipairs(drives) do
    if not probe_disk(d.mount) then
      diag("disk probe failed: " .. tostring(d.mount))
    else
      local role, slot = parse_label(d.label)
      local newly_labeled = false

      if not role then
        -- Unbeschriftete (oder fremd-beschriftete) Disk: naechste freie
        -- Rolle/Slot zuweisen und dauerhaft auf die Disk schreiben.
        role = next_role_with_space()
        if role then
          slot = next_free_slot(role)
          used_slots[role][slot] = true
          local new_label = make_label(role, slot)
          local ok_set = pcall(d.wrapped.setDiskLabel, new_label)
          if ok_set then
            newly_labeled = true
            diag("disk gelabelt: " .. tostring(d.mount) .. " -> " .. new_label)
          else
            diag("Label setzen fehlgeschlagen fuer " .. tostring(d.mount) .. " (" .. new_label .. ")")
          end
        else
          diag("keine freie Rolle/Slot mehr fuer unbeschriftete Disk " .. tostring(d.mount) .. " (alle Rollen voll)")
        end
      end

      if role and slot then
        local root = d.mount .. "/xreactor_logs"
        disks[#disks + 1] = {
          id = #disks + 1, mount = d.mount, root = root, role = role,
          role_group = role_index(role), slot = slot,
          drive_name = d.name, labeled = not newly_labeled,
        }
        diag("disk ok: " .. tostring(d.mount) .. " role=" .. role .. " slot=" .. slot .. "/" .. DISKS_PER_ROLE
          .. (newly_labeled and " (neu gelabelt)" or ""))
      else
        diag("disk ohne Rollenzuordnung uebersprungen: " .. tostring(d.mount))
      end
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
  if not idx then
    -- Unbekannte Rolle: wie zuvor Fallback auf irgendeine Disk, damit
    -- nichts komplett verloren geht.
    return stats.disks[stats.disk_index] or stats.disks[1]
  end

  -- Fix (2026-07-07): vorher wurde IMMER die erste zur Rolle passende Disk
  -- zurückgegeben — bei jetzt DISKS_PER_ROLE=4 Disks pro Rolle blieben die
  -- anderen 3 komplett ungenutzt, egal wie voll die erste war. Jetzt:
  -- Round-Robin über alle Disks der Rolle, mit persistentem Cursor pro
  -- Rolle (stats.role_cursor), und ein Health-Check überspringt Disks
  -- unterhalb des Frei-Speicher-Schwellwerts.
  local group = {}
  for _, disk in ipairs(stats.disks) do
    if disk.role_group == idx or disk.role == tostring(role or ""):upper() then
      group[#group + 1] = disk
    end
  end
  if #group == 0 then return nil end
  table.sort(group, function(a, b) return (a.slot or a.id) < (b.slot or b.id) end)

  stats.role_cursor = stats.role_cursor or {}
  local cursor = stats.role_cursor[idx] or 0

  -- Erste Runde: ab Cursor+1 die erste gesunde (genug freier Platz) Disk
  -- der Gruppe suchen, dabei einmal komplett rundlaufen.
  local healthy_threshold = MIN_FREE_BYTES * 4
  for step = 1, #group do
    local pos = ((cursor + step - 1) % #group) + 1
    local disk = group[pos]
    local free = free_space(disk.mount)
    if free == math.huge or free >= healthy_threshold then
      stats.role_cursor[idx] = pos
      return disk
    end
  end

  -- Alle Disks der Gruppe unter dem Schwellwert: die mit dem meisten
  -- freien Platz nehmen (write_log()'s Wipe-Logik greift danach ggf. noch).
  local best, best_free = group[1], -1
  for _, disk in ipairs(group) do
    local free = free_space(disk.mount)
    if free == math.huge then free = math.huge end
    if free > best_free then best, best_free = disk, free end
  end
  return best
end

-- Fix (2026-07-07): Log-Zeilen speicherten bisher nur rohe Epoch-
-- Millisekunden ("[1783449311486]") — von Auge nicht lesbar, man musste sie
-- manuell umrechnen um zu sehen, wie alt ein Log-Export tatsächlich ist.
-- Das hat in dieser Session wiederholt dazu gefuehrt, dass ungewollt
-- derselbe alte Export mehrfach fuer "aktuell" gehalten wurde. Jetzt wird
-- zusaetzlich ein lesbares Datum+Uhrzeit (UTC) vor die rohe Millisekunden-
-- zahl gestellt — die Rohzahl bleibt erhalten (fuer exaktes Sortieren/
-- Parsen), das Datum kommt on top.
local function format_timestamp(ts)
  local ok, formatted = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(tonumber(ts) / 1000))
  end)
  if ok and formatted then return formatted end
  return "?"
end

local function format_log_line(payload)
  local ts = payload.ts or now_ms()
  return string.format("[%s | %s] %s | %s | %s | %s",
    format_timestamp(ts),
    tostring(ts),
    tostring(payload.role or "?"),
    tostring(payload.prefix or "LOG"),
    tostring(payload.level or "INFO"),
    tostring(payload.message or payload.line or ""))
end

-- Fix (2026-07-13): LOG-P1. Vorwaertsdeklaration, da write_log() weiter
-- unten flush_bucket() bereits aufruft (ERROR/CRITICAL-Sofort-Flush),
-- flush_bucket() selbst aber erst danach definiert wird.
local flush_bucket
local flush_due
local FLUSH_LINES = 8
local FLUSH_INTERVAL_MS = 200
local MAX_PENDING_LINES_PER_PATH = 128

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
    -- Fix (2026-07-11): CRITICAL. Vorher wurde hier nur der allgemeine
    -- "Drop"-Zaehler in der Statuszeile hochgezaehlt -- ein Blick auf den
    -- Monitor haette den Anstieg zeigen koennen, aber nichts wies aktiv
    -- darauf hin, WARUM oder fuer WELCHE Rolle Logs verloren gehen. Bei
    -- diesem Fehlerbild (komplette Diskgruppe einer Rolle leer, z.B. durch
    -- verlorene/neu belegte Label) gingen dadurch tagelang unbemerkt ALLE
    -- Logs einer ganzen Rolle verloren (beobachtet: RT und ENERGY), waehrend
    -- andere Rollen mit intakter Diskgruppe ganz normal weiterliefen -- von
    -- aussen sah es aus wie "die Nodes haben aufgehoert zu senden", dabei
    -- kamen die Log-Zeilen durchaus an, wurden aber hier verworfen. Jetzt:
    -- aktive, aber pro Rolle auf 1x alle 5 Minuten begrenzte Warnung direkt
    -- auf dem Bildschirm (diag()), damit das binnen Minuten auffaellt statt
    -- erst bei einer manuellen Log-Analyse Tage spaeter.
    local role_key = tostring(payload.role or "unknown"):upper()
    stats.no_disk_warned = stats.no_disk_warned or {}
    local last_warn = stats.no_disk_warned[role_key] or 0
    local now = now_s()
    if now - last_warn >= 300 then
      stats.no_disk_warned[role_key] = now
      diag("!! KEINE DISK fuer Rolle " .. role_key .. " -- Logs gehen verloren! Disk-Labels pruefen.")
    end
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
    local removed = reclaim_oldest(disk.root, disk.mount, RECLAIM_TARGET_BYTES, path)
    if removed > 0 then
      diag("disk full: removed " .. tostring(removed) .. " oldest log file(s) on " .. tostring(disk.mount))
    end
  end

  local line = format_log_line(payload) .. "\n"
  -- Fix (2026-07-13): CRITICAL (LOG-P1, siehe docs/CODING_AI_OTHER_NODES_
  -- PERFORMANCE_2026-07-12.md). Vorher wurde fuer JEDES einzelne Logevent
  -- eine Datei geoeffnet, EINE Zeile geschrieben, wieder geschlossen --
  -- teurer Datei-I/O pro Event. Jetzt: die Zeile wird nur noch in einen
  -- kleinen Pro-Pfad-Puffer eingereiht (guenstige Tabellen-Operation), der
  -- eigentliche Schreibvorgang passiert gebuendelt in flush_bucket() (siehe
  -- unten), ausgeloest entweder durch flush_lines (8 Zeilen) oder
  -- flush_interval_ms (200ms) oder sofort bei ERROR/CRITICAL. WICHTIG: das
  -- ACK ("written") darf weiterhin erst nach TATSAECHLICH erfolgreicher
  -- Persistierung gesendet werden -- das passiert deshalb nicht mehr hier,
  -- sondern in flush_bucket() nach dem bestaetigten Schreiberfolg.
  stats.pending_writes = stats.pending_writes or {}
  local bucket = stats.pending_writes[path]
  if not bucket then
    -- Fix (2026-07-13): last_flush_attempt_ms muss bei der ERSTELLUNG
    -- eines Puffers auf die AKTUELLE Zeit gesetzt werden, nicht auf 0 --
    -- sonst wuerde die naechste flush_due()-Pruefung (now - 0 >= 200ms)
    -- IMMER sofort "faellig" ergeben, egal wie kurz der Puffer gerade erst
    -- angelegt wurde, und das Zeitintervall waere komplett wirkungslos.
    bucket = { lines = {}, payloads = {}, last_flush_attempt_ms = now_ms(), disk = disk }
    stats.pending_writes[path] = bucket
  end
  if #bucket.lines >= MAX_PENDING_LINES_PER_PATH then
    stats.dropped = stats.dropped + 1
    stats.last_error = "backpressure: " .. tostring(path) .. " puffer voll"
    return false, "backpressure"
  end
  bucket.lines[#bucket.lines + 1] = line
  bucket.payloads[#bucket.payloads + 1] = payload
  if payload.level == "ERROR" or payload.level == "CRITICAL" then
    flush_bucket(path)
  end
  return "queued"
end

-- Fuehrt den tatsaechlichen (gebuendelten) Schreibvorgang fuer einen
-- Zielpfad aus -- alle aktuell gepufferten Zeilen in EINEM Open/Write/
-- Close-Zyklus. Nur bei bestaetigtem Erfolg werden ACKs gesendet und
-- stats.written/node_last_written aktualisiert; bei einem Fehlschlag
-- bleiben die Zeilen unveraendert im Puffer fuer den naechsten Versuch
-- (kein Datenverlust, kein verfruehtes ACK).
flush_bucket = function(path)
  local bucket = stats.pending_writes and stats.pending_writes[path]
  if not bucket or #bucket.lines == 0 then return end
  local combined = table.concat(bucket.lines)
  local ok, err = pcall(function()
    local handle = fs.open(path, "a")
    if not handle then error("fs.open returned nil") end
    handle.write(combined)
    handle.close()
  end)

  if not ok then
    local message = tostring(err or "write failed")
    local lower = message:lower()
    if lower:find("out of space", 1, true) or lower:find("no space", 1, true) then
      local root  = bucket.disk and bucket.disk.root or fs.getDir(path)
      local mount = bucket.disk and bucket.disk.mount or root
      local removed = reclaim_oldest(root, mount, RECLAIM_TARGET_BYTES, path)
      diag("write out-of-space: removed " .. tostring(removed) .. " oldest log file(s), retry")
      ok, err = pcall(function()
        local handle = fs.open(path, "a")
        if not handle then error("fs.open returned nil after reclaim") end
        handle.write(combined)
        handle.close()
      end)
    end
  end

  if not ok then
    stats.last_error = tostring(err or "write failed"):sub(1, 90)
    -- Puffer bewusst NICHT leeren -- naechster flush_due()-Durchlauf
    -- versucht dieselben (noch unbestaetigten) Zeilen erneut.
    return
  end

  for _, payload in ipairs(bucket.payloads) do
    stats.written = stats.written + 1
    send_ack(payload, "written")
    stats.node_last_written = stats.node_last_written or {}
    stats.node_last_written[tostring(payload.node_id or "?")] = { ts = now_s(), role = tostring(payload.role or "?") }
  end
  if bucket.disk then
    stats.last_write_index = bucket.disk.id
    stats.last_write_mount = bucket.disk.mount
  end
  stats.last_write_path = path
  stats.last_error = nil
  stats.pending_writes[path] = nil
end

-- Periodisch (Timer-Tick) aufgerufen: prueft alle offenen Puffer gegen
-- flush_lines/flush_interval_ms und flusht faellige.
flush_due = function()
  if not stats.pending_writes then return end
  local now = now_ms()
  for path, bucket in pairs(stats.pending_writes) do
    if #bucket.lines >= FLUSH_LINES or (now - (bucket.last_flush_attempt_ms or 0)) >= FLUSH_INTERVAL_MS then
      bucket.last_flush_attempt_ms = now
      flush_bucket(path)
    end
  end
end

-- ── Dedupe ─────────────────────────────────────────────────────────────────
-- Fix (2026-07-13): CRITICAL (LOG-P1.2, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md). table.remove(stats.seen_order, 1) verschob
-- bisher bei JEDEM Ueberschreiten von DEDUPE_LIMIT (512) das GESAMTE
-- restliche Array um eine Position -- O(n) statt O(1), und das bei einem
-- Collector, der potenziell viele hundert Events pro Minute verarbeitet.
-- Jetzt: Kopf-/Ende-Index-Paar (seen_head/seen_tail) statt eines echten
-- Array-Shifts -- Entfernen ist nur noch "Kopf-Index um 1 erhoehen, alten
-- Slot auf nil setzen" (O(1)). Um ein unbegrenztes Wachsen der Indizes
-- selbst zu vermeiden, wird die Tabelle periodisch (alle 4096 entfernte
-- Eintraege) einmalig kompaktiert -- das haelt die Gesamtkosten amortisiert
-- O(1) pro Eintrag, weit seltener als vorher bei jedem einzelnen Event.
stats.seen_head = 1
stats.seen_tail = 0
local COMPACT_INTERVAL = 4096
local removed_since_compact = 0

local function seen(event_id)
  return type(event_id) == "string" and event_id ~= "" and stats.seen[event_id] == true
end

local function remember(event_id)
  if type(event_id) ~= "string" or event_id == "" or stats.seen[event_id] then return end
  stats.seen[event_id] = true
  stats.seen_tail = stats.seen_tail + 1
  stats.seen_order[stats.seen_tail] = event_id
  while (stats.seen_tail - stats.seen_head + 1) > DEDUPE_LIMIT do
    local old = stats.seen_order[stats.seen_head]
    stats.seen_order[stats.seen_head] = nil
    stats.seen_head = stats.seen_head + 1
    if old then stats.seen[old] = nil end
    removed_since_compact = removed_since_compact + 1
  end
  if removed_since_compact >= COMPACT_INTERVAL then
    local compacted = {}
    local n = 0
    for i = stats.seen_head, stats.seen_tail do
      local v = stats.seen_order[i]
      if v ~= nil then n = n + 1; compacted[n] = v end
    end
    stats.seen_order = compacted
    stats.seen_head = 1
    stats.seen_tail = n
    removed_since_compact = 0
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

  -- Fix (2026-06-30): LOG hat typischerweise sowohl ein Ender Modem
  -- (wireless, fuer Funkempfang von RT/Energy/Master STATUS/LOG-Events) als
  -- auch ein normales (wired) Modem fuer lokale Disk-/Monitor-Peripherals.
  -- is_modem_name() filterte beide gleich und oeffnete CHANNEL auf JEDEM
  -- gefundenen Modem — das fuehrte dazu, dass auf einem System mit beiden
  -- Modem-Typen der Funkempfang dauerhaft leer blieb (Recv 0 ueber lange
  -- Zeit), weil wired und wireless Modems in CC:Tweaked getrennte Funknetze
  -- sind und nur das Ender Modem ueberhaupt Nachrichten von entfernten
  -- Nodes (RT/Energy/Master) empfangen kann. Jetzt: wireless Modems werden
  -- bevorzugt geoeffnet UND zusaetzlich, defensiv, weiterhin alle gefundenen
  -- Modems geoeffnet (falls z.B. nur ein wired Modem vorhanden ist, soll das
  -- Verhalten wie zuvor erhalten bleiben) — aber wireless wird zuerst geprueft
  -- und separat geloggt, damit ein fehlendes Ender Modem sofort sichtbar ist.
  local names = {}
  local wireless_found = false
  if peripheral and type(peripheral.getNames) == "function" then
    local ok, perifs = pcall(peripheral.getNames)
    if ok and type(perifs) == "table" then
      table.sort(perifs)
      for _, name in ipairs(perifs) do
        if is_modem_name(name) then
          local ok_wrap, modem = pcall(peripheral.wrap, name)
          if ok_wrap and modem and type(modem.open) == "function" then
            local is_wireless = false
            if type(modem.isWireless) == "function" then
              local ok_w, result = pcall(modem.isWireless)
              is_wireless = ok_w and result == true
            end
            if is_wireless then wireless_found = true end
            pcall(modem.open, CHANNEL)
            stats.modems[#stats.modems + 1] = { modem = modem, wireless = is_wireless }
            names[#names + 1] = name .. (is_wireless and "*" or "")
          end
        end
      end
    end
  end

  if not wireless_found and not stats.warned_no_wireless then
    stats.warned_no_wireless = true
    pcall(print, "[LOG] WARNUNG: kein Ender/Wireless-Modem gefunden — Funkempfang von RT/Energy/Master wird nicht funktionieren (nur lokale wired Modems erkannt)")
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
  -- Fix (2026-07-13): CRITICAL (LOG-P1.2, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md). Vorher wurde dasselbe ACK ueber
  -- JEDES gefundene Modem gesendet -- bei Wireless+Wired gleichzeitig
  -- kamen beim Sender mehrere identische ACKs fuer dasselbe Event an.
  -- Jetzt: bevorzugtes Wireless-Modem wird EINMAL versucht, weitere
  -- Modems (Fallback) nur bei tatsaechlichem Sendefehler.
  local entries = stats.modems or {}
  local ordered = {}
  for _, entry in ipairs(entries) do
    if entry.wireless then table.insert(ordered, 1, entry) else table.insert(ordered, entry) end
  end
  for _, entry in ipairs(ordered) do
    local modem = entry.modem
    if modem and type(modem.transmit) == "function" then
      local ok = pcall(modem.transmit, CHANNEL, CHANNEL, ack)
      if ok then
        stats.ack_sent = stats.ack_sent + 1
        return
      end
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

-- Fix (2026-07-15): LOG-P2 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md Abschnitt 10). draw() ruft jetzt ein normales Renderer-Modul
-- ueber require() auf (Standard: default_ui.lua, das dieselbe Anzeige wie
-- der bisherige inline-Code produziert). nodes/log_collector/mockup_main.lua
-- waehlt darueber die alternative mockup_ui.lua-Anzeige, indem es vor dem
-- dofile() dieser Datei den globalen Selektor XR_LOG_RENDERER_MODULE setzt —
-- ohne main.lua als Text einzulesen und zu patchen. Schlaegt der Renderer
-- fehl (fehlendes Modul, Laufzeitfehler), zeigt draw() einen sichtbaren,
-- garantiert funktionierenden Fallback statt abzustuerzen oder leer zu bleiben.
local RENDERER_MODULE = (type(_G) == "table" and _G.XR_LOG_RENDERER_MODULE) or "nodes.log_collector.default_ui"

local function draw_fallback(renderer_name, reason)
  local w, h = begin_frame()
  line_ui(1, 1, string.rep(" ", w), color("black", 32768), color("red", 16384))
  line_ui(2, 1, fit("LOG Collector - Renderer-Fehler", w - 3), color("white", 1), color("red", 16384))
  line_ui(2, 3, "Renderer: " .. fit(tostring(renderer_name), w - 13), color("lightGray", 256))
  line_ui(2, 4, "Fehler: " .. fit(tostring(reason), w - 11), color("yellow", 16))
  line_ui(2, 6, string.format("Recv %s Write %s Drop %s", stats.received, stats.written, stats.dropped), color("white", 1))
  line_ui(2, 7, "Disks: " .. tostring(#stats.disks) .. "  Modem: " .. tostring(stats.modem ~= "" and stats.modem or "NO-MODEM"), color("lightGray", 256))
  if h >= 9 then
    line_ui(2, 9, "Logs werden weiterhin empfangen/geschrieben.", color("lightGray", 256))
  end
  flush_ui()
  stats.last_draw_s = now_s()
end

local function draw()
  refresh_disks(false)
  refresh_modems(false)

  local ctx = {
    stats = stats,
    live_diag = live_diag,
    channel = CHANNEL,
    min_free_bytes = MIN_FREE_BYTES,
    disks_per_role = DISKS_PER_ROLE,
    color = color,
    now_s = now_s,
    free_space = free_space,
    begin_frame = begin_frame,
    queue_segment = queue_segment,
    line_ui = line_ui,
    badge_ui = badge_ui,
    progress_ui = progress_ui,
    draw_pause_button = draw_pause_button,
    draw_log_mode_buttons = draw_log_mode_buttons,
    flush_ui = flush_ui,
    log_mode = function()
      return utils and utils.get_log_mode and utils.get_log_mode() or "all"
    end,
  }

  local ok_renderer, renderer = pcall(require, RENDERER_MODULE)
  if not ok_renderer or type(renderer) ~= "table" or type(renderer.render) ~= "function" then
    self_log("LOG renderer '" .. tostring(RENDERER_MODULE) .. "' unavailable: " .. tostring(renderer), "ERROR")
    draw_fallback(RENDERER_MODULE, renderer)
    return
  end

  local ok_render, render_err = pcall(renderer.render, ctx)
  if not ok_render then
    self_log("LOG renderer '" .. tostring(RENDERER_MODULE) .. "' failed: " .. tostring(render_err), "ERROR")
    draw_fallback(RENDERER_MODULE, render_err)
  end
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
    -- Fix (2026-07-13): LOG-P1. write_log() liefert jetzt "queued" (nicht
    -- mehr "true") -- die Zeile wurde erfolgreich in den Batch-Puffer
    -- aufgenommen, aber NOCH NICHT geschrieben/geackt (das passiert
    -- asynchron in flush_bucket()). remember() bleibt bewusst HIER (nicht
    -- erst beim Flush) -- schuetzt weiterhin gegen einen schnellen Retry
    -- desselben Event_id, der eintrifft, BEVOR der Batch tatsaechlich
    -- geflusht wurde.
    remember(message.event_id)
    -- Fix (2026-07-13): LOG-P1. Zusaetzlich zum periodischen 1s-Timer-Tick
    -- (Sicherheitsnetz, siehe timer-Zweig weiter unten) wird nach JEDEM
    -- Event direkt geprueft, ob ein Puffer bereits faellig ist -- sonst
    -- koennte ein erreichtes flush_lines-Limit (8 Zeilen) bis zu 1s auf den
    -- naechsten Timer-Tick warten muessen, obwohl das Intervall eigentlich
    -- 200ms betragen soll.
    flush_due()
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
-- Feature (2026-07-11): allgemeiner Frische-Watchdog. Ergaenzt die
-- spezifische "no disk for role"-Warnung (die nur EINE moegliche Ursache
-- abdeckt) um eine generelle Pruefung: hat eine BEKANNTE Node (die
-- mindestens einmal erfolgreich geschrieben hat) seit mehr als
-- STALE_THRESHOLD_S nichts Neues mehr geschrieben? Deckt damit auch
-- andere Ursachen ab (Node abgestuerzt, Netzwerkproblem, o.ae.), nicht
-- nur die Disk-Zuordnung. Rate-begrenzt pro Node, damit eine dauerhaft
-- stille Node nicht bei jedem Tick erneut warnt.
local STALE_THRESHOLD_S = 300  -- 5 Minuten ohne neuen Log-Eintrag = auffaellig
local STALE_REWARN_S = 300     -- danach hoechstens alle 5 Minuten erneut warnen
stats.node_stale_warned = stats.node_stale_warned or {}

local function check_log_freshness()
  if not stats.node_last_written then return end
  local now = now_s()
  for node_id, info in pairs(stats.node_last_written) do
    local age = now - (info.ts or now)
    if age >= STALE_THRESHOLD_S then
      local last_warn = stats.node_stale_warned[node_id] or 0
      if now - last_warn >= STALE_REWARN_S then
        stats.node_stale_warned[node_id] = now
        diag(string.format("!! %s (%s) seit %ds ohne neuen Log-Eintrag", node_id, info.role or "?", age))
      end
    else
      -- wieder aktuell -- Warn-Sperre aufheben, damit ein ERNEUTES
      -- Verstummen sofort wieder warnt statt bis zum naechsten
      -- 5-Minuten-Fenster zu warten.
      stats.node_stale_warned[node_id] = nil
    end
  end
end

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

  -- Startup-Diagnose-Report (Kernfunktion, 2026-07-01): siehe
  -- xreactor/core/startup_report.lua.
  local ok_report_mod, report_mod = pcall(require, "core.startup_report")
  if ok_report_mod then
    pcall(function()
      local checks = { report_mod.check_wireless_modem() }
      checks[#checks + 1] = { name = "Disk-Laufwerke", ok = #stats.disks > 0,
        detail = string.format("%d gefunden", #stats.disks) }
      local ok_spk, spk_mod = pcall(require, "optional.speaker_alarm")
      local speaker = ok_spk and spk_mod.new() or nil
      report_mod.run(checks, { log = function(_, msg) self_log(msg, "INFO") end, speaker = speaker })
    end)
  end

  draw()

  local timer = os.startTimer and os.startTimer(1)
  while true do
    local event = { os.pullEvent() }
    local name = event[1]

    -- Fix (2026-07-07): CRITICAL. Bisher war nur handle_log_event() per
    -- pcall abgesichert — ein Fehler in draw()/refresh_disks()/
    -- refresh_modems() (z.B. durch eine unerwartete Peripherie-Antwort)
    -- toetete den GESAMTEN Loop. Das fuehrt zum Crash-Screen ganz unten,
    -- der auf einen Tastendruck wartet — ohne physische Anwesenheit blieb
    -- der Collector danach fuer immer haengen, obwohl "der Computer noch
    -- lief". Jetzt ist jeder Event-Zweig einzeln pcall-isoliert: ein
    -- Fehler wird geloggt, der Loop laeuft beim naechsten Event normal
    -- weiter, statt den ganzen Node lahmzulegen.
    local branch_ok, branch_err = pcall(function()
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
          -- Fix (2026-07-13): CRITICAL (LOG-P1.2, siehe docs/CODING_AI_
          -- OTHER_NODES_PERFORMANCE_2026-07-12.md). Vorher wurde ZUSAETZLICH
          -- zum bereits vorhandenen Timer-Intervall (DRAW_INTERVAL_S=5s)
          -- bei jedem 20. empfangenen Event sofort gezeichnet -- bei hoher
          -- Last (viele Events/s) konnte das den Zeichenaufwand deutlich
          -- oefter ausloesen als beabsichtigt. Jetzt: eigenes, kuerzeres
          -- Mindestintervall (1s) fuer "aktive" Zwischen-Zeichnungen waehrend
          -- Events eintreffen, statt eine reine Ereigniszaehlung. Ein echter
          -- Fehler (not ok) zeichnet weiterhin sofort, unabhaengig vom
          -- Intervall -- das ist wichtige Diagnoseinformation.
          local now_active = now_s()
          if not ok or (now_active - (stats.last_active_draw_s or 0)) >= ACTIVE_DRAW_MIN_INTERVAL_S then
            stats.last_active_draw_s = now_active
            draw()
          end
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
        check_log_freshness()
        flush_due()
        if now_s() - stats.last_draw_s >= DRAW_INTERVAL_S then draw() end
        timer = os.startTimer and os.startTimer(1)
      end
    end)
    if not branch_ok then
      stats.last_error = "loop crashed on event=" .. tostring(name) .. ": " .. tostring(branch_err):sub(1, 80)
      diag(stats.last_error)
      pcall(self_log, stats.last_error, "ERROR")
      -- Timer evtl. durch den Fehler nicht neu gestartet — sicherstellen,
      -- dass der naechste "timer"-Zweig weiterhin ausgeloest wird.
      if name == "timer" and event[2] == timer and os.startTimer then
        timer = os.startTimer(1)
      end
    end
  end
end

-- ── Crash screen ────────────────────────────────────────────────────────────
local ok, err = xpcall(run, function(e) return e end)
if ok then return end
if tostring(err or ""):lower():find("terminate", 1, true) then return end

local is_loop, crash_count = record_crash_and_check_loop()

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
  if is_loop then
    if term.setTextColor then term.setTextColor(color("red", 16384)) end
    print("")
    print("!! CRASH-LOOP ERKANNT (" .. tostring(crash_count) .. " Abstuerze in " .. CRASH_LOOP_WINDOW_S .. "s) !!")
    print("Warte " .. CRASH_LOOP_WAIT_S .. "s vor dem naechsten Neustart-Versuch,")
    print("um den Server nicht mit Reboots im Sekundentakt zu belasten.")
    print("Bitte Ursache manuell pruefen (siehe Fehler oben).")
  end
  if term.setTextColor then term.setTextColor(color("yellow", 16)) end
  print("Taste druecken um neu zu starten...")
end
-- Fix (2026-07-07): CRITICAL. Bisher wartete der Crash-Screen per
-- pcall(os.pullEvent, "key") UNBEGRENZT auf einen Tastendruck — ohne
-- physische Anwesenheit blieb der Node fuer immer auf diesem Screen
-- haengen (vermutlich die Erklaerung fuer "laeuft seit Stunden, loggt
-- aber seit dem Neustart nichts mehr"). Jetzt: max. 30s warten, danach
-- automatischer Reboot-Versuch, auch ohne Tastendruck.
-- Feature (2026-07-11): bei erkannter Crash-Loop (siehe oben) wird diese
-- Wartezeit auf CRASH_LOOP_WAIT_S (5 Minuten) verlaengert, statt weiter
-- alle 30s neu zu starten ohne dass sich je etwas bessert.
local wait_s = is_loop and CRASH_LOOP_WAIT_S or 30
local ok_wait = pcall(function()
  local timer_id = os.startTimer(wait_s)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "key" then return end
    if ev[1] == "timer" and ev[2] == timer_id then return end
  end
end)
if os and os.reboot then os.reboot() end
