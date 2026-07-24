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
  -- Feature (2026-07-09): eigenstaendiger Redstone-Valve-Controller,
  -- siehe nodes/valve/main.lua.
  VALVE         = INSTALL_ROOT .. "/nodes/valve/main.lua",
  REPROCESSING  = INSTALL_ROOT .. "/nodes/reprocessor/main.lua",
  LOG           = INSTALL_ROOT .. "/nodes/log_collector/mockup_main.lua",
  LOG_COLLECTOR = INSTALL_ROOT .. "/nodes/log_collector/mockup_main.lua",
}

local function p(msg) pcall(print, tostring(msg)) end

-- Fix (2026-07-16): CRITICAL. INSTALL/LOG-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 16).
-- Bei knappem Speicher wurde hier bei JEDEM Boot "/xreactor_logs"
-- unconditional rekursiv geloescht -- das ist aber KEIN startup-eigenes
-- Zwischenverzeichnis, sondern der tatsaechliche lokale Log-Speicherort
-- (core/logger.lua's DEFAULT_LOG_DIR). Ein knapper Speicherstand durfte
-- niemals als Erlaubnis gelten, vorhandene Logs bei jedem Neustart zu
-- vernichten. Jetzt werden nur noch echte, installer-eigene, jederzeit
-- regenerierbare Zwischenverzeichnisse entfernt.
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

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.1 aus docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md (Abschnitt 3, Fix-Punkt 6): "beim Boot
-- unvollstaendigen Zustand erkennen und entweder Rollback oder
-- kontrollierten Resume ausfuehren". installer/journal.lua schreibt bei
-- jedem Installationslauf ein Journal AUSSERHALB von /xreactor, das erst
-- als LETZTER Schritt (zusammen mit release.lua, siehe dortiger Fix-
-- Kommentar) auf COMMITTED gesetzt wird. Ein Absturz irgendwo zwischen
-- "alter Baum geloescht" und "COMMITTED" hinterlaesst also ein Journal in
-- einem anderen Zustand (PREPARED/INSTALLING/VERIFYING) -- genau das wird
-- hier bei JEDEM Boot geprueft, BEVOR ueberhaupt versucht wird, eine
-- (moeglicherweise unvollstaendige) Rolle zu starten. Der Parser ist
-- bewusst selbststaendig (kein dofile() von installer/journal.lua) -- bei
-- einem sehr fruehen Absturz koennte /xreactor/installer/ selbst noch
-- unvollstaendig sein, das Journal liegt aber immer ausserhalb davon.
--
-- Fix (2026-07-19): CRITICAL. INSTALL-P0.1/P0.2. Die vorherige Fassung
-- hatte zwei Luecken: (1) genau EINE Journaldatei wurde per
-- Delete-dann-Move geschrieben -- ein Crash in diesem kurzen Fenster
-- hinterliess KEIN lesbares Journal, was Boot faelschlich als "keine
-- unvollstaendige Installation" wertete; (2) JEDER Parse-/Lesefehler
-- (kaputte Syntax, leere/abgeschnittene Datei, kein Table) wurde hier
-- identisch zu "Datei existiert nicht" behandelt -- ein beschaedigtes
-- Journal waehrend eines abgebrochenen Updates fuehrte damit zum
-- normalen, ungeschuetzten Rollenstart statt zu Fail-Closed-Recovery.
-- Jetzt: zwei Generationsslots (siehe installer/journal.lua fuer die
-- ausfuehrliche Begruendung -- dieselbe Klassifikationslogik ist hier
-- bewusst dupliziert, nicht dofile()'d) plus eine explizite
-- Statusklassifikation ABSENT/VALID_COMMITTED/VALID_INCOMPLETE/CORRUPT/
-- UNREADABLE. Nur ABSENT (nie ein Installationslauf begonnen) oder
-- VALID_COMMITTED erlauben einen normalen Rollenstart; CORRUPT und
-- UNREADABLE loesen denselben Recovery-Resume aus wie VALID_INCOMPLETE.
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
local function attempt_recovery_resume()
  local body
  local ok_http, r = pcall(http.get, "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer")
  if ok_http and r then
    local ok2, b = pcall(r.readAll); pcall(r.close)
    if ok2 and type(b) == "string" and #b > 0 then body = b end
  end
  if not body then error("Recovery-Installer-Download fehlgeschlagen", 0) end
  local tmp = "/xreactor_recovery_installer.tmp"
  local f = fs.open(tmp, "w")
  if not f then error("Kann Recovery-Installer nicht schreiben: " .. tmp, 0) end
  local ok_w = pcall(function() f.write(body) end)
  pcall(f.close)
  if not ok_w then error("Kann Recovery-Installer nicht schreiben: " .. tmp, 0) end
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

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.2 aus docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md (Abschnitt 4). Das Rollen-Handshake-Objekt
-- (core/update_handshake.lua) wird als GLOBALER Wert bereitgestellt --
-- derselbe etablierte Musterzugriff wie _G.__xreactor_remote_update --
-- damit sowohl die Rollen-Coroutine (dofile(entry), prueft/meldet ueber
-- diesen Handshake) als auch der Auto-Update-Loop (fordert Quiesce an,
-- wartet auf Bestaetigung) dasselbe Objekt sehen, ohne dofile() Argumente
-- uebergeben zu muessen.
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

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.2. parallel.waitForAny() beendete
-- BEIDE Coroutinen, sobald EINE von ihnen zurueckkehrte -- ein sauberer
-- Quiesce-Exit der Rollen-Coroutine (siehe unten) haette dadurch den
-- Auto-Update-Loop VOR dem eigentlichen Installerlauf abgewuergt, statt
-- ihm die Chance zu geben, fortzufahren. parallel.waitForAll() wartet auf
-- BEIDE: die Rollen-Coroutine kann jetzt sauber enden (nach bestaetigtem
-- Quiesce), waehrend der Auto-Update-Loop unbeeinflusst weiterlaeuft und
-- danach den Installer startet (der bei Erfolg ohnehin selbst rebootet).
-- Ein unabgefangener Fehler in irgendeiner Coroutine wird von parallel.*
-- weiterhin sofort nach oben durchgereicht (identisches Verhalten wie
-- vorher bei waitForAny) -- das bestehende pcall(run)-Fehlerhandling
-- unten bleibt unveraendert wirksam.
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
  -- Fix (2026-07-07): CRITICAL. parallel.waitForAny(role_loop, auto_loop)
  -- bedeutet: wirft EINE der beiden Coroutinen (z.B. der Auto-Updater beim
  -- Ausfuehren eines frisch heruntergeladenen, evtl. fehlerhaften
  -- Installer-Skripts via dofile(tmp)) einen unabgefangenen Fehler, stirbt
  -- die GESAMTE parallel.waitForAny-Ausfuehrung — inklusive der eigentlich
  -- gesunden Rollen-Hauptschleife. Bisher wurde der Fehler hier zwar
  -- geloggt, aber dann per error(...) ERNEUT geworfen — das crashte den
  -- gesamten Computer bis in die CraftOS-Shell, wo er ohne physisches
  -- Eingreifen fuer immer haengen blieb (vermutliche Hauptursache fuer
  -- "Node laeuft seit Stunden, loggt aber seit dem letzten Neustart
  -- nichts mehr"). Jetzt: statt erneut zu werfen, nach kurzer Pause ein
  -- automatischer Reboot-Versuch — der Computer heilt sich selbst, auch
  -- wenn der Fehler in der naechsten Runde erneut auftritt (dann eben
  -- wiederholter Reboot statt endlosem Stillstand).
  os.sleep(2)
  if os and os.reboot then os.reboot() end
  error("Failed: " .. role, 0)
end
