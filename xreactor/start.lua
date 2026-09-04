-- XReactor start.lua
-- Liest Rolle, startet Node + Auto-Update Loop parallel.

local INSTALL_ROOT = "/xreactor"
local ROLE_PATH    = INSTALL_ROOT .. "/config/role.lua"
local RELEASE_PATH = INSTALL_ROOT .. "/release.lua"

local ROLE_ENTRY = {
  MASTER        = INSTALL_ROOT .. "/master/main.lua",
  RT            = INSTALL_ROOT .. "/nodes/rt/main.lua",
  ENERGY        = INSTALL_ROOT .. "/nodes/energy/main.lua",
  WATER         = INSTALL_ROOT .. "/nodes/water/main.lua",
  FUEL          = INSTALL_ROOT .. "/nodes/fuel/main.lua",
  -- Eigenstaendiger Redstone-Valve-Controller.
  VALVE         = INSTALL_ROOT .. "/nodes/valve/main.lua",
  REPROCESSING  = INSTALL_ROOT .. "/nodes/reprocessor/main.lua",
  LOG           = INSTALL_ROOT .. "/nodes/log_collector/mockup_main.lua",
  LOG_COLLECTOR = INSTALL_ROOT .. "/nodes/log_collector/mockup_main.lua",
}

local function p(msg) pcall(print, tostring(msg)) end

-- Entfernt nur echte, installer-eigene, jederzeit regenerierbare
-- Zwischenverzeichnisse -- NICHT /xreactor_logs (core/logger.lua's
-- DEFAULT_LOG_DIR), da ein knapper Speicherstand keine Erlaubnis ist,
-- vorhandene Logs zu vernichten.
local function cleanup_space()
  if not fs.getFreeSpace then return end
  local ok, free = pcall(fs.getFreeSpace, "/")
  if ok and type(free) == "number" and free < 4096 then
    pcall(fs.delete, "/xreactor_stage")
    pcall(fs.delete, "/xreactor_backup_prev")
    p("STARTUP: Speicher bereinigt")
  end
end
cleanup_space()

-- installer/journal.lua schreibt bei jedem Installationslauf ein Journal
-- ausserhalb von /xreactor, das erst als letzter Schritt (zusammen mit
-- release.lua) auf COMMITTED gesetzt wird. Wird bei jedem Boot geprueft,
-- BEVOR versucht wird, eine moeglicherweise unvollstaendige Rolle zu
-- starten. Der Parser ist bewusst selbststaendig (kein dofile() von
-- installer/journal.lua) -- bei einem sehr fruehen Absturz koennte
-- /xreactor/installer/ selbst noch unvollstaendig sein.
--
-- Zwei Generationsslots (dieselbe Klassifikationslogik wie
-- installer/journal.lua, hier bewusst dupliziert statt dofile()'d) plus
-- eine explizite Statusklassifikation ABSENT/VALID_COMMITTED/
-- VALID_INCOMPLETE/CORRUPT/UNREADABLE. Nur ABSENT oder VALID_COMMITTED
-- erlauben einen normalen Rollenstart; CORRUPT und UNREADABLE loesen
-- denselben Recovery-Resume aus wie VALID_INCOMPLETE.
local INSTALL_JOURNAL_SLOT_A = "/xreactor_install_journal.a.lua"
local INSTALL_JOURNAL_SLOT_B = "/xreactor_install_journal.b.lua"

local JOURNAL_STATUS = {
  ABSENT           = "ABSENT",
  VALID_COMMITTED  = "VALID_COMMITTED",
  VALID_INCOMPLETE = "VALID_INCOMPLETE",
  CORRUPT          = "CORRUPT",
  UNREADABLE       = "UNREADABLE",
}

local function read_journal_slot(path)
  if not fs.exists(path) then return JOURNAL_STATUS.ABSENT, nil end
  local f = fs.open(path, "r")
  if not f then return JOURNAL_STATUS.UNREADABLE, nil end
  local ok_read, src = pcall(f.readAll)
  pcall(f.close)
  if not ok_read or type(src) ~= "string" or #src == 0 then
    return JOURNAL_STATUS.UNREADABLE, nil
  end
  local loader = load(src, "=install_journal", "t", {})
  if not loader then return JOURNAL_STATUS.CORRUPT, nil end
  local ok, result = pcall(loader)
  if not ok or type(result) ~= "table" or type(result.state) ~= "string" then
    return JOURNAL_STATUS.CORRUPT, nil
  end
  if type(result.generation) ~= "number" then return JOURNAL_STATUS.CORRUPT, nil end
  if result.state == "COMMITTED" then return JOURNAL_STATUS.VALID_COMMITTED, result end
  return JOURNAL_STATUS.VALID_INCOMPLETE, result
end

local function classify_install_journal()
  local status_a, journal_a = read_journal_slot(INSTALL_JOURNAL_SLOT_A)
  local status_b, journal_b = read_journal_slot(INSTALL_JOURNAL_SLOT_B)

  local function generation_of(status, journal)
    if status == JOURNAL_STATUS.VALID_COMMITTED or status == JOURNAL_STATUS.VALID_INCOMPLETE then
      return journal.generation
    end
    return -1
  end

  local gen_a, gen_b = generation_of(status_a, journal_a), generation_of(status_b, journal_b)
  if gen_a < 0 and gen_b < 0 then
    if status_a == JOURNAL_STATUS.ABSENT and status_b == JOURNAL_STATUS.ABSENT then
      return JOURNAL_STATUS.ABSENT, nil
    end
    if status_a == JOURNAL_STATUS.UNREADABLE or status_b == JOURNAL_STATUS.UNREADABLE then
      return JOURNAL_STATUS.UNREADABLE, nil
    end
    return JOURNAL_STATUS.CORRUPT, nil
  end

  if gen_a >= gen_b then return status_a, journal_a end
  return status_b, journal_b
end

-- Kontrollierter Resume: statt zu versuchen, chirurgisch nur die fehlenden
-- Dateien nachzuinstallieren (fehleranfaellig, kaum verlaesslich testbar),
-- wird der komplette, bereits robuste (SHA-Pinning, CRC32-Verifikation,
-- Config-Backup/Restore, siehe installer/init.lua) Installationslauf per
-- frisch heruntergeladenem /installer erneut ausgefuehrt -- exakt derselbe
-- Mechanismus, den auto_update.lua fuer normale Updates bereits verwendet.
-- Das garantiert nach Abschluss entweder einen vollstaendigen, COMMITTED
-- neuen Stand (der Installer rebootet danach selbst), oder -- falls dieser
-- Versuch seinerseits fehlschlaegt (z.B. kein Netzwerk) -- ein erneut
-- unvollstaendiges Journal, das den naechsten Boot wieder in genau diesen
-- Recoverypfad schickt, statt jemals die (unvollstaendige) Rolle zu
-- starten.
-- Derselbe haengen-anfaellige, unbewachte pcall(http.get, url)-Musterfehler
-- wie bereits in installer/http.lua, installer/auto_update.lua, /installer
-- und /installer_pocket gefunden und behoben: ohne eigenes Timeout haengt
-- ein blockierender http.get() hier den kompletten Boot fuer immer, noch
-- bevor irgendein anderes Modul geladen ist. try_once() erneut nach
-- demselben bewaehrten Muster: eine synchrone http.get()-Anfrage gegen ein
-- einfaches os.sleep()-Timeout ueber parallel.waitForAny() racen.
local RECOVERY_REQUEST_TIMEOUT_S = 15

local function recovery_try_once(url)
  if type(parallel) ~= "table" or type(parallel.waitForAny) ~= "function" then
    local ok, r = pcall(http.get, url)
    if not ok or not r then return nil, type(r) == "string" and r or "http.get fehlgeschlagen" end
    local ok2, body = pcall(r.readAll); pcall(r.close)
    if not ok2 or type(body) ~= "string" or #body == 0 then return nil, "readAll fehlgeschlagen" end
    return body
  end

  local body, err, done = nil, nil, false
  local ok_race, race_err = pcall(parallel.waitForAny,
    function()
      local ok, r = pcall(http.get, url)
      if ok and r then
        local ok2, b = pcall(r.readAll); pcall(r.close)
        if ok2 and type(b) == "string" and #b > 0 then
          body = b
        else
          err = "readAll fehlgeschlagen"
        end
      else
        err = type(r) == "string" and r or "http.get fehlgeschlagen"
      end
      done = true
    end,
    function() os.sleep(RECOVERY_REQUEST_TIMEOUT_S) end)

  if not ok_race then return nil, "Anfrage fehlgeschlagen: " .. tostring(race_err) end
  if not done then return nil, "timeout" end
  return body, err
end

local function attempt_recovery_resume()
  local body, last_err
  for attempt = 1, 4 do
    local b, err = recovery_try_once("https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer")
    if b then body = b; break end
    last_err = err
    if attempt < 4 then os.sleep(attempt * 2) end
  end
  if not body then error("Recovery-Installer-Download fehlgeschlagen: " .. tostring(last_err), 0) end
  local tmp = "/xreactor_recovery_installer.tmp"
  local f = fs.open(tmp, "w")
  if not f then error("Kann Recovery-Installer nicht schreiben: " .. tmp, 0) end
  local ok_w = pcall(function() f.write(body) end)
  pcall(f.close)
  if not ok_w then error("Kann Recovery-Installer nicht schreiben: " .. tmp, 0) end
  -- A crash may have happened before the installer restored role.lua into
  -- the new /xreactor tree. The verified recovery backup is outside that
  -- tree; restore the minimal unattended-install identity before rerunning
  -- /installer so it never falls into an interactive role prompt.
  local backup_path = "/xreactor_recovery/config_backup.lua"
  if (not fs.exists(ROLE_PATH)) and fs.exists(backup_path) then
    local backup_file = fs.open(backup_path, "r")
    if not backup_file then error("Recovery-Config-Backup nicht lesbar", 0) end
    local ok_read, backup_source = pcall(backup_file.readAll)
    pcall(backup_file.close)
    if not ok_read or type(backup_source) ~= "string" then
      error("Recovery-Config-Backup nicht lesbar", 0)
    end
    local loader, load_err = load(backup_source, "=recovery_config_backup", "t", {})
    if not loader then error("Recovery-Config-Backup ungueltig: " .. tostring(load_err), 0) end
    local ok_backup, backup = pcall(loader)
    if not ok_backup or type(backup) ~= "table" then
      error("Recovery-Config-Backup ungueltig", 0)
    end
    for _, rel in ipairs({ "role.lua", "remote_update.lua", "node_id.txt" }) do
      local content = backup[rel]
      if type(content) == "string" then
        local dst = INSTALL_ROOT .. "/config/" .. rel
        local dir = fs.getDir(dst)
        if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
        local out = fs.open(dst, "w")
        if not out then error("Recovery-Minimal-Config nicht schreibbar: " .. rel, 0) end
        local ok_restore, restore_err = pcall(function() out.write(content) end)
        pcall(out.close)
        if not ok_restore then
          error("Recovery-Minimal-Config fehlgeschlagen: " .. rel .. " (" .. tostring(restore_err) .. ")", 0)
        end
      end
    end
  end
  if not fs.exists(ROLE_PATH) then
    error("Recovery kann Rolle nicht bestimmen: role.lua und Backup fehlen", 0)
  end
  _G.__xreactor_remote_update = true
  dofile(tmp)
end

local journal_status, install_journal = classify_install_journal()
if journal_status ~= JOURNAL_STATUS.ABSENT and journal_status ~= JOURNAL_STATUS.VALID_COMMITTED then
  local detail = (journal_status == JOURNAL_STATUS.VALID_INCOMPLETE)
    and tostring(install_journal.state) or journal_status
  p("[BOOT] WARN: unvollstaendige Installation erkannt (Zustand: " .. detail .. ")")
  p("[BOOT] Rolle wird NICHT gestartet -- kontrollierter Recovery-Resume...")
  local ok_resume, resume_err = pcall(attempt_recovery_resume)
  if not ok_resume then
    p("[BOOT] FEHLER: Recovery-Resume fehlgeschlagen: " .. tostring(resume_err))
  end
  p("[BOOT] Neustart in 5 Sekunden fuer erneuten Recovery-Versuch...")
  os.sleep(5)
  if os and os.reboot then os.reboot() end
  error("Recovery-Resume nicht abgeschlossen -- Rolle wird nicht gestartet", 0)
end

local function read_role()
  if not fs.exists(ROLE_PATH) then return nil, "Role config fehlt" end
  local f = fs.open(ROLE_PATH, "r"); if not f then return nil, "Kann role.lua nicht lesen" end
  local src = f.readAll(); f.close()
  local loader, err = load(src, "=role", "t", {})
  if not loader then return nil, "role.lua Syntax: " .. tostring(err) end
  local ok, result = pcall(loader)
  if not ok or type(result) ~= "table" or type(result.role) ~= "string" then
    return nil, "role.lua ungültig"
  end
  return result.role
end

local role, role_err = read_role()
if not role then p("[BOOT] FEHLER: " .. tostring(role_err)); error(role_err, 0) end

local entry = ROLE_ENTRY[role]
if not entry then p("[BOOT] Unbekannte Rolle: " .. role); error("Unbekannte Rolle: " .. role, 0) end

local rel_v = "?"
if fs.exists(RELEASE_PATH) then
  local f = fs.open(RELEASE_PATH, "r"); if f then
    local src = f.readAll(); f.close()
    local v = src:match('release_id%s*=%s*"([^"]+)"')
    if v then rel_v = v end
  end
end
p("[BOOT] XReactor " .. role .. " | " .. rel_v)

local DELAYS = { LOG = 0, LOG_COLLECTOR = 0, MASTER = 2 }
local delay = DELAYS[role] or 8
if delay > 0 then
  local reason = role == "MASTER" and "LOG_COLLECTOR" or "LOG_COLLECTOR + MASTER"
  p("[BOOT] Warte " .. delay .. "s auf " .. reason .. "...")
  for i = delay, 1, -1 do p("  Start in " .. i .. "s..."); os.sleep(1) end
end

-- Handshake-Objekt als globaler Wert (wie _G.__xreactor_remote_update),
-- damit die Rollen-Coroutine (dofile(entry)) und der Auto-Update-Loop
-- dasselbe Objekt sehen, ohne dofile()-Argumente zu uebergeben.
local update_handshake_lib = dofile("/xreactor/core/update_handshake.lua")
local update_handshake = update_handshake_lib.new()
_G.__xreactor_update_handshake = update_handshake

local auto_loop = nil
local auto_path = INSTALL_ROOT .. "/installer/auto_update.lua"
if fs.exists(auto_path) then
  local ok_load, auto_mod = pcall(dofile, auto_path)
  if ok_load and type(auto_mod) == "table" and type(auto_mod.make_loop) == "function" then
    local interval = 120
    local cfg_path = INSTALL_ROOT .. "/config/remote_update.lua"
    if fs.exists(cfg_path) then
      local f = fs.open(cfg_path, "r"); if f then
        local src = f.readAll(); f.close()
        local loader = load(src, "=cfg", "t", {})
        if loader then
          local ok2, cfg = pcall(loader)
          if ok2 and type(cfg) == "table" then interval = tonumber(cfg.check_interval_s) or 120 end
        end
      end
    end
    auto_loop = auto_mod.make_loop(interval, update_handshake)
    p("[BOOT] Auto-Update Loop bereit (" .. interval .. "s)")
  else
    p("[BOOT] WARN: auto_update.lua Fehler: " .. tostring(auto_mod))
  end
else
  p("[BOOT] WARN: installer/auto_update.lua fehlt")
end

-- parallel.waitForAll() (nicht waitForAny()) wartet auf BEIDE Coroutinen:
-- die Rollen-Coroutine kann sauber enden (nach bestaetigtem Quiesce),
-- waehrend der Auto-Update-Loop unbeeinflusst weiterlaeuft und den
-- Installer startet -- waitForAny() wuerde den Auto-Update-Loop vorzeitig
-- abwuergen, sobald die Rollen-Coroutine zurueckkehrt.
local function run()
  if auto_loop then
    parallel.waitForAll(function() dofile(entry) end, auto_loop)
  else
    dofile(entry)
  end
end

local ok, err = pcall(run)
if not ok then
  p("[BOOT] FEHLER: " .. tostring(err))
  -- Statt den Fehler erneut zu werfen (crasht bis in die CraftOS-Shell, wo
  -- er ohne physisches Eingreifen fuer immer haengen bliebe): nach kurzer
  -- Pause ein automatischer Reboot-Versuch -- der Computer heilt sich
  -- selbst, auch bei wiederholtem Fehler in der naechsten Runde.
  os.sleep(2)
  if os and os.reboot then os.reboot() end
  error("Failed: " .. role, 0)
end
