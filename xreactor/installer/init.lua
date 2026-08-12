-- installer/init.lua
-- Einstiegspunkt der eigentlichen Installationslogik.
--
-- Fix (2026-07-17): CRITICAL. INSTALL-P1 aus docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md (Abschnitt 8, "Zwei unabhaengige Installer-
-- implementierungen"). Vorher lud diese Datei ihre Abhaengigkeiten selbst
-- per dofile() von festen /xreactor/installer/*.lua-Pfaden -- eine
-- Annahme, die nur zutrifft, wenn /xreactor bereits existiert. Der
-- monolithische Root-Installer (/installer) musste deshalb fuer die
-- Erstinstallation eine KOMPLETTE, eigenstaendige Kopie dieser gesamten
-- Datei als eingebettetes Textliteral mitfuehren, mit allen Folgen
-- doppelter Pflege (siehe Git-Historie: mehrfache manuelle Resynchronisation
-- bei jedem Fix). Jetzt nimmt diese Datei ihre Abhaengigkeiten als
-- Parameter entgegen (dependency injection statt hartkodierter dofile()-
-- Pfade) -- ob die uebergebenen Module von der lokalen Festplatte
-- (dofile()) oder aus frisch heruntergeladenem Text (load()) stammen, ist
-- fuer die eigentliche Installationslogik hier unten unveraendert
-- irrelevant. /installer ist dadurch auf einen kleinen, stabilen Bootstrap
-- reduziert, der genau einen Ref aufloest, die kanonischen Installermodule
-- dieses Refs herunterlaedt und ausschliesslich DIESE Funktion hier
-- ausfuehrt -- keine zweite, separat gepflegte Installationslogik mehr.
return function(deps)

local http_mod     = deps.http_mod
local manifest_mod = deps.manifest_mod
local stage_mod    = deps.stage_mod
local ui_mod       = deps.ui_mod
local journal_mod  = deps.journal_mod
local plan_validator_mod = deps.plan_validator_mod
local reactor_naming_mod = deps.reactor_naming_mod

local INSTALL_ROOT    = "/xreactor"
local STARTUP_PATH    = "/startup.lua"
-- Fix (2026-07-10): CRITICAL. installer/stage.lua's atomarer Schreib-
-- vorgang (M.write()) hat zwar das lange Zeitfenster von frueher beseitigt
-- (siehe dortiger Fix-Kommentar vom 2026-07-07), aber es bleibt ein extrem
-- kurzes Restfenster zwischen "alte Datei -> Backup verschieben" und
-- "neue Datei -> Zielpfad verschieben" (zwei getrennte fs.move()-Aufrufe;
-- CC:Tweaked's fs.move() kann eine bereits existierende Zieldatei nicht
-- direkt ueberschreiben, ein echter Single-Step-Atomic-Replace ist damit
-- nicht moeglich). Bei GENUG Update-Durchlaeufen (LOG_COLLECTOR hat die
-- meisten Dateien zu aktualisieren, daher haeufiger betroffen) wird dieses
-- seltene Fenster irgendwann getroffen -- ein Absturz/Neustart/Chunk-
-- Unload GENAU in diesem Moment liess start.lua fehlen, CraftOS zeigte
-- "No such program" beim Boot, ohne jede Moeglichkeit zur Selbstheilung,
-- da /startup.lua bisher blind "shell.run(...)" aufrief. Jetzt prueft
-- /startup.lua selbst zuerst, ob die Zieldatei existiert -- falls nicht,
-- wird automatisch das ".xr_prev"-Backup (vom letzten erfolgreichen
-- Schreibvorgang) zurueckgeholt, BEVOR CraftOS ueberhaupt die Chance hat
-- "No such program" zu zeigen. Nur wenn WEDER Ziel NOCH Backup existieren
-- (z.B. beim allerersten Boot vor der Erstinstallation), erscheint eine
-- klare, hilfreiche Fehlermeldung statt der kryptischen CraftOS-Meldung.
local STARTUP_CONTENT = [===[-- XReactor startup
local target = "/xreactor/start.lua"
if not fs.exists(target) then
  local backup = target .. ".xr_prev"
  if fs.exists(backup) then
    pcall(fs.move, backup, target)
  end
end
if fs.exists(target) then
  shell.run(target)
else
  print("[BOOT] FEHLER: " .. target .. " fehlt (kein Backup gefunden).")
  print("[BOOT] Bitte Installer erneut ausfuehren:")
  print("[BOOT]   wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer installer")
  print("[BOOT]   installer")
end
]===]
local GITHUB_RAW      = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

local function p(msg) pcall(print, tostring(msg)) end

-- Fix (2026-07-14): CRITICAL. GLOBAL-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md. Vorher wurde nur
-- eine kleine feste Dateiliste (PRESERVE) vor dem Loeschen von /xreactor
-- gesichert. Rollenbezogene Configs (master.lua, rt.lua, energy.lua,
-- water.lua, fuel.lua, reprocessor.lua, valve.lua), Routingdateien
-- (fuel_routes.lua, reproc_routes.lua) und vor allem die Remote-Update-
-- Arming-Config (Token, deaktivierter Zustand, Intervall) stehen in
-- KEINEM Manifest -- sie werden ausschliesslich zur Laufzeit von den
-- jeweiligen Nodes angelegt. Ein Update/Reinstall loeschte sie bisher
-- ersatzlos; remote_update.lua wurde danach sogar automatisch mit
-- unsicheren Defaults (kein Token) neu angelegt. Jetzt wird der GESAMTE
-- Ordner /xreactor/config rekursiv gesichert (nicht nur eine Allowlist),
-- als eine kompakte Datei AUSSERHALB von /xreactor geschrieben, sofort
-- zurueckgelesen und byte-genau verifiziert -- ERST DANACH darf
-- /xreactor geloescht werden. Kein vollstaendiges Installationsbackup
-- (Speicherlimit von CC:Tweaked bleibt beachtet), nur der kleine
-- config-Ordner.
local CONFIG_DIR               = INSTALL_ROOT .. "/config"
local RECOVERY_DIR             = "/xreactor_recovery"
local RECOVERY_CONFIG_BACKUP   = RECOVERY_DIR .. "/config_backup.lua"
-- Denylist statt Allowlist: nur nachweislich regenerierbare Installer-
-- Zwischendateien werden ausgeschlossen. Alles andere in config/ bleibt
-- standardmaessig erhalten, auch zukuenftige, heute noch unbekannte
-- Configdateien.
local CONFIG_RESTORE_DENY_SUFFIX = { ".xr_tmp", ".xr_prev" }

local function config_restore_denied(rel)
  for _, suffix in ipairs(CONFIG_RESTORE_DENY_SUFFIX) do
    if rel:sub(-#suffix) == suffix then return true end
  end
  return false
end

local function list_files_recursive(dir, prefix, out)
  prefix = prefix or ""
  out = out or {}
  if not fs.exists(dir) then return out end
  local ok_is_dir, is_dir = pcall(fs.isDir, dir)
  if not ok_is_dir or not is_dir then
    error("Config-Verzeichnis kann nicht sicher gelesen werden: " .. tostring(dir), 0)
  end
  local ok, entries = pcall(fs.list, dir)
  if not ok or type(entries) ~= "table" then
    error("Config-Verzeichnis kann nicht aufgelistet werden: " .. tostring(dir), 0)
  end
  for _, name in ipairs(entries) do
    local full = dir .. "/" .. name
    local rel = (prefix == "" and name or (prefix .. "/" .. name))
    local ok_child, child_is_dir = pcall(fs.isDir, full)
    if not ok_child then
      error("Config-Eintrag kann nicht geprueft werden: " .. tostring(full), 0)
    end
    if child_is_dir then
      list_files_recursive(full, rel, out)
    else
      out[#out + 1] = rel
    end
  end
  return out
end

local function serialize_config_backup(files_map)
  local parts = { "return {\n" }
  for rel, content in pairs(files_map) do
    parts[#parts + 1] = "  [" .. string.format("%q", rel) .. "] = " .. string.format("%q", content) .. ",\n"
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

local function backup_config_dir()
  local files_map = {}
  if not fs.exists(CONFIG_DIR) then return files_map end
  for _, rel in ipairs(list_files_recursive(CONFIG_DIR)) do
    if not config_restore_denied(rel) then
      local f = fs.open(CONFIG_DIR .. "/" .. rel, "r")
      if not f then error("Config-Datei kann nicht gesichert werden: " .. rel, 0) end
      local ok_read, content = pcall(f.readAll)
      local ok_close, close_err = pcall(f.close)
      if not ok_read or type(content) ~= "string" then
        error("Config-Datei kann nicht gelesen werden: " .. rel, 0)
      end
      if not ok_close then
        error("Config-Datei kann nicht geschlossen werden: " .. rel .. " (" .. tostring(close_err) .. ")", 0)
      end
      files_map[rel] = content
    end
  end
  return files_map
end

-- Der Bootstrap waehlt genau einen Ref und reicht ihn fuer Manifest und
-- saemtliche Dateien weiter. Es gibt hier weder eine zweite Aufloesung noch
-- einen dateiweisen Fallback auf einen anderen Ref. Bewegt sich "beta"
-- waehrend eines Laufs, verhindern die Manifest-Hashes einen gemischten
-- Commit; der komplette Installationslauf muss dann neu gestartet werden.
local ref = deps.ref
if type(ref) ~= "string" or ref == "" then
  error("installer/init.lua: deps.ref fehlt oder ungueltig", 0)
end
p(("ref: " .. ref))

local manifest_url = GITHUB_RAW .. ref .. "/xreactor/manifest.lua"
local manifest, merr = manifest_mod.load_remote(manifest_url, http_mod)
if not manifest then error("Manifest: " .. tostring(merr), 0) end
p("Manifest: " .. tostring(manifest.manifest_id or manifest.manifest_version))

-- Rolle bestimmen
local role = nil
local role_path = INSTALL_ROOT .. "/config/role.lua"
if fs.exists(role_path) then
  local f = fs.open(role_path, "r"); if f then
    local src = f.readAll(); f.close()
    local loader = load(src, "=role", "t", {})
    if loader then
      local ok, result = pcall(loader)
      if ok and type(result) == "table" and type(result.role) == "string" then
        local existing = result.role
        p("Vorhandene Rolle: " .. existing)
        if _G.__xreactor_remote_update or ui_mod.confirm("Rolle '" .. existing .. "' behalten?") then
          role = { key = existing:lower(), label = existing:upper() }
        end
      end
    end
  end
end
if not role then
  -- Fix (2026-07-06): CRITICAL. Bei _G.__xreactor_remote_update==true
  -- (unbeaufsichtigter automatischer Auto-Update-Lauf, KEIN Nutzer
  -- anwesend) durfte hier NIEMALS auf eine interaktive Rollenauswahl
  -- (read()) gewartet werden — falls config/role.lua aus irgendeinem
  -- Grund fehlte, leer war, oder nicht geparst werden konnte, blieb der
  -- gesamte Auto-Update-Prozess fuer immer haengen (kein Timeout, keine
  -- Nutzereingabe kommt je), was sich als "haengt regelmaessig" aeusserte.
  -- Jetzt: bei automatischem Lauf ohne gueltige Rolle sofort mit Fehler
  -- abbrechen, statt endlos zu warten — der aufrufende auto_update.lua-
  -- Loop faengt das als fehlgeschlagenen Versuch ab und pausiert/versucht
  -- es spaeter erneut, anstatt den ganzen Computer einzufrieren.
  --
  -- Fix (2026-07-08): Dieser Schutz war zwischenzeitlich (seit dem
  -- "Phase 1"-Rewrite von installer/manifest.lua, 2026-06-28) aus dieser
  -- Quelldatei verschwunden — nur die eingebettete Kopie im monolithischen
  -- /installer hatte ihn noch. Beim Neubau des eingebetteten init_src-
  -- Blocks fuer den SHA-Pinning-Fix (v357) wurde dadurch versehentlich
  -- auch diese Schutzfunktion mit ueberschrieben. Hier aus der Diff-
  -- Historie wiederhergestellt.
  if _G.__xreactor_remote_update then
    error("Automatisches Update abgebrochen: config/role.lua fehlt oder ist ungueltig — keine Rolle bekannt und keine interaktive Auswahl im unbeaufsichtigten Modus moeglich.", 0)
  end
  role = ui_mod.select_role()
  if not role then error("Ungültige Rolle", 0) end
end

ui_mod.header("Installiere " .. role.label)

-- A manual RT installation names every currently visible reactor exactly
-- once. The resulting config is included in the full config backup below,
-- so reinstalling does not ask again. Unattended updates never prompt.
if role.label == "RT" then
  if type(reactor_naming_mod) ~= "table" or type(reactor_naming_mod.run) ~= "function" then
    error("RT-Reaktornamensmodul fehlt oder ist ungueltig", 0)
  end
  local naming_ok, naming_state = reactor_naming_mod.run({
    fs = fs,
    peripheral = peripheral,
    remote_update = _G.__xreactor_remote_update == true,
    output = p,
    input = function() return read and read() or "" end,
    write = function(path, content) return stage_mod.write(path, content) end,
  })
  if not naming_ok then
    error("Reaktornamen konnten nicht sicher geladen/gespeichert werden: "
      .. tostring(naming_state), 0)
  elseif naming_state == "saved" then
    p("Reaktornamen gespeichert; dieser Schritt wird bei Reinstallationen nicht erneut angezeigt.")
  elseif naming_state == "no_reactors_detected" and not _G.__xreactor_remote_update then
    p("WARN: Keine Reaktoren erkannt; Namensschritt bleibt fuer eine spaetere manuelle Installation offen.")
  elseif naming_state == "already_completed_topology_changed" then
    p("WARN: Reaktortopologie hat sich seit der Benennung geaendert. Vorhandene Namen bleiben unveraendert; neue Reaktoren erscheinen vorerst mit technischer ID.")
  end
end

-- Gesamten config-Ordner sichern (siehe Fix-Kommentar oben). Backup wird
-- sofort zurueckgelesen und byte-genau verifiziert, BEVOR /xreactor
-- geloescht werden darf -- ein defektes Backup darf niemals als
-- Sicherheitsnetz fuer das bevorstehende Loeschen gelten.
local config_backup = backup_config_dir()
do
  local backup_count = 0
  for _ in pairs(config_backup) do backup_count = backup_count + 1 end
  if backup_count > 0 then
    local ok_dir, dir_err = pcall(fs.makeDir, RECOVERY_DIR)
    if not ok_dir or not fs.exists(RECOVERY_DIR) then
      error("Recovery-Verzeichnis konnte nicht angelegt werden: " .. tostring(dir_err), 0)
    end
    local serialized = serialize_config_backup(config_backup)
    local ok_bak, bak_err = stage_mod.write(RECOVERY_CONFIG_BACKUP, serialized)
    if not ok_bak then
      error("Config-Backup fehlgeschlagen, breche vor Loeschen ab: " .. tostring(bak_err), 0)
    end
    local reread = stage_mod.read(RECOVERY_CONFIG_BACKUP)
    local restored_map
    if reread then
      local loader = load(reread, "=config_backup", "t", {})
      if loader then
        local ok_call, result = pcall(loader)
        if ok_call and type(result) == "table" then restored_map = result end
      end
    end
    if not restored_map then
      error("Config-Backup-Verifikation fehlgeschlagen (nicht lesbar) -- breche vor Loeschen ab.", 0)
    end
    for rel, content in pairs(config_backup) do
      if restored_map[rel] ~= content then
        error("Config-Backup-Verifikation fehlgeschlagen (Mismatch bei " .. rel .. ") -- breche vor Loeschen ab.", 0)
      end
    end
    p("Config gesichert: " .. backup_count .. " Datei(en) -> " .. RECOVERY_CONFIG_BACKUP)
  end
end

-- Feature (2026-07-01): bestehende Auswahl optionaler Features laden (falls
-- vorhanden — z.B. bei einem Reinstall). Bei einer Erstinstallation ist das
-- leer und der Nutzer wird unten interaktiv gefragt.
--
-- Fix (2026-07-08): diese komplette optionale-Features-Auswahl (Laden,
-- interaktive Abfrage, Persistieren) war seit dem "Phase 1"-Rewrite aus
-- dieser Quelldatei verschwunden — nur der veraltete, separate Wrapper-
-- Codepfad im monolithischen /installer hatte sie noch. Ohne sie wurden
-- optionale Peripherie-Features (Ampel, Speaker-Alarm, Pocket-Query)
-- beim manuellen Installer-Lauf ungefragt IMMER mitinstalliert, sobald
-- die Rolle passte — keine Nutzerwahl mehr moeglich. Hier wiederhergestellt.
local function load_selected_features()
  local raw = config_backup["optional_features.lua"]
  if not raw then return {} end
  local ok, loaded = pcall(function()
    local chunk = load(raw, "=optional_features", "t", {})
    if not chunk then return nil end
    return chunk()
  end)
  if ok and type(loaded) == "table" then return loaded end
  return {}
end
local selected_features = load_selected_features()

-- Optionale Features interaktiv abfragen (nur bei manuellem Installer-Lauf,
-- nicht beim automatischen Auto-Update-Reinstall — dort wird die zuvor
-- gespeicherte Auswahl einfach uebernommen, kein erneutes Nachfragen).
-- Bekannte optionale Peripherals werden aus dem Manifest selbst abgeleitet
-- (jeder Eintrag mit optional=true und einem feature-Namen), damit neue
-- optionale Module in Zukunft automatisch hier auftauchen, ohne dass diese
-- Abfrage-Logik jedes Mal angepasst werden muss.
local function collect_optional_feature_names(manifest_tbl, role_label)
  local seen, names = {}, {}
  local function matches_role(entry)
    -- Fix (2026-07-06): CRITICAL. Diese Funktion listete bisher JEDES
    -- optional=true Feature im gesamten Manifest auf, unabhaengig davon
    -- ob dessen required_for die aktuell gewaehlte Rolle ueberhaupt
    -- zulaesst — z.B. wurde "ampel installieren?" (required_for={"RT",
    -- "ENERGY",...}, explizit OHNE "MASTER") trotzdem beim Installieren
    -- von MASTER angezeigt, obwohl master_ampel das dafuer vorgesehene,
    -- getrennte Feature ist. Jetzt: ein Feature erscheint nur, wenn es
    -- entweder KEIN required_for hat (fuer jede Rolle gedacht) oder die
    -- gewaehlte Rolle explizit in required_for auftaucht.
    if type(entry.required_for) ~= "table" then return true end
    if not role_label then return true end
    for _, v in ipairs(entry.required_for) do
      if tostring(v):upper() == tostring(role_label):upper() then return true end
    end
    return false
  end
  local function scan(entries)
    for _, e in ipairs(entries or {}) do
      if type(e) == "table" and e.optional == true and e.feature and not seen[e.feature] and matches_role(e) then
        seen[e.feature] = true
        names[#names + 1] = e.feature
      end
    end
  end
  scan(manifest_tbl.base_files)
  for _, rentries in pairs(manifest_tbl.roles or {}) do
    scan(rentries)
  end
  table.sort(names)
  return names
end

if term and term.setCursorPos and not _G.__xreactor_remote_update then
  local feature_names = collect_optional_feature_names(manifest, role.label)
  if #feature_names > 0 then
    p("")
    p("Optionale Peripherie-Erweiterungen (nur installieren wenn Hardware vorhanden ist):")
    for _, fname in ipairs(feature_names) do
      local already = selected_features[fname] == true
      io.write("  " .. fname .. " installieren? [j/N" .. (already and ", bereits aktiv" or "") .. "]: ")
      local answer = read and read() or ""
      if tostring(answer):lower() == "j" or tostring(answer):lower() == "y" then
        selected_features[fname] = true
      elseif tostring(answer) ~= "" then
        selected_features[fname] = false
      end
      -- Leere Eingabe bei Reinstall = bestehende Auswahl beibehalten (already).
    end
  end
end

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.1 aus docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md (Abschnitt 3). Bricht der Lauf zwischen dem
-- Loeschen des alten Baums und dem vollstaendigen, verifizierten Ende ab,
-- gab es bisher KEINE erkennbare Spur -- der naechste Boot startete die
-- (moeglicherweise unvollstaendige) Rolle einfach normal weiter. Das
-- Installationsjournal (installer/journal.lua) lebt AUSSERHALB von
-- /xreactor und wird JETZT SCHON, vor dem ersten destruktiven Schritt,
-- mit Ziel-Ref/Manifest-ID/Rolle/erwarteter Dateiliste als PREPARED
-- geschrieben -- xreactor/start.lua prueft dieses Journal bei jedem Boot
-- und startet die Rolle NICHT, solange es nicht COMMITTED ist (siehe dort).
local expected = manifest_mod.files_for_role(manifest, role.label, selected_features)
local expected_paths = {}
for rel in pairs(expected) do expected_paths[#expected_paths + 1] = rel end
table.sort(expected_paths)

-- Fix (2026-07-17): CRITICAL. INSTALL/MANIFEST-P1 aus docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md (Abschnitt 7). Vor diesem Fix fehlten
-- vollstaendige Guards fuer die geplante Installationsmenge (erlaubte
-- Rollenwerte, erwarteter Entrypoint, doppelte/unsichere Pfade, gueltige
-- Hash-/Groessenfelder, Manifest-Selbstkonsistenz, maximale Groesse) --
-- ein strukturell fehlerhafter Plan wurde erst waehrend/nach dem Loeschen
-- des alten Baums entdeckt (oder gar nicht). plan_validator.validate()
-- lehnt die GESAMTE Installation ab, sobald irgendeine Bedingung verletzt
-- ist, NOCH VOR dem ersten destruktiven Schritt.
local ok_plan, err_plan = plan_validator_mod.validate({ role = role, manifest = manifest, files = expected })
if not ok_plan then
  error("Installationsplan ungueltig: " .. tostring(err_plan), 0)
end

local ok_journal, err_journal = journal_mod.write({
  state = journal_mod.STATE.PREPARED,
  ref = ref,
  manifest_id = tostring(manifest.manifest_id or manifest.manifest_version),
  role = role.label,
  started_at = os.epoch("utc"),
  expected_files = expected_paths,
})
if not ok_journal then
  error("Installationsjournal konnte nicht angelegt werden: " .. tostring(err_journal), 0)
end

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.3 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 5). Die
-- Ergebnisse von fs.delete/fs.makeDir hier sowie von jedem stage_mod.write()
-- weiter unten wurden bisher verworfen -- ein Fehlschlag (z.B. kein Platz,
-- schreibgeschuetzter Datentraeger) blieb unbemerkt und die Installation
-- lief mit einer teilweise/nicht angelegten Zielstruktur bzw. ohne Rolle
-- weiter, statt sofort kontrolliert abzubrechen.
-- Alte Installation löschen
if fs.exists(INSTALL_ROOT) then
  p("Entferne alte Installation...")
  pcall(fs.delete, INSTALL_ROOT)
  if fs.exists(INSTALL_ROOT) then
    error("Alte Installation konnte nicht entfernt werden: " .. INSTALL_ROOT, 0)
  end
end
pcall(fs.makeDir, INSTALL_ROOT)
if not fs.exists(INSTALL_ROOT) then
  error("Installationsverzeichnis konnte nicht angelegt werden: " .. INSTALL_ROOT, 0)
end

-- Minimal-Restore sofort nach Neuanlage des Roots: bricht die
-- Installation danach ab (Downloadfehler, Stromausfall), bleiben Rolle
-- und Remote-Update-Arming trotzdem erhalten -- kein Node ohne Rolle,
-- kein unbeabsichtigtes Re-Arm mit unsicheren Defaults.
for _, rel in ipairs({ "role.lua", "remote_update.lua", "node_id.txt" }) do
  local content = config_backup[rel]
  if content then
    local ok_mr, err_mr = stage_mod.write(CONFIG_DIR .. "/" .. rel, content)
    if not ok_mr then
      error("Minimal-Restore fehlgeschlagen: " .. rel .. " — " .. tostring(err_mr), 0)
    end
  end
end

local ok_j2, err_j2 = journal_mod.write({
  state = journal_mod.STATE.INSTALLING,
  ref = ref,
  manifest_id = tostring(manifest.manifest_id or manifest.manifest_version),
  role = role.label,
  started_at = os.epoch("utc"),
  expected_files = expected_paths,
})
if not ok_j2 then error("Installationsjournal (INSTALLING) fehlgeschlagen: " .. tostring(err_j2), 0) end

-- Dateien installieren. release.lua wird BEWUSST ausgeschlossen und erst
-- ganz am Ende, zusammen mit dem Journal-Commit, geschrieben (siehe
-- Abschnitt 3, Fix-Punkt 5: "release.lua und Completion-Marker zuletzt
-- atomar committen") -- sonst koennte ein Absturz waehrend dieser Schleife
-- release.lua bereits auf dem neuen Stand hinterlassen, obwohl andere
-- Dateien noch fehlen, und ein reines Versions-/Manifest-Diffing wuerde
-- die Installation faelschlich als aktuell/abgeschlossen ansehen.
local file_list = {}
for rel, entry in pairs(expected) do
  if rel ~= "release.lua" then table.insert(file_list, { path = rel, entry = entry }) end
end
table.sort(file_list, function(a, b)
  local sa = tonumber((a.entry or {}).size_bytes) or 0
  local sb = tonumber((b.entry or {}).size_bytes) or 0
  if sa ~= sb then return sa > sb end
  return a.path < b.path
end)

p("Installiere " .. #file_list .. " Dateien...")
-- Fix (2026-07-16): CRITICAL. INSTALL-P0 aus
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md (Abschnitt 15).
-- stage_mod.verify() prüfte bisher nur Existenz/Lesbarkeit/Größe/Syntax,
-- nicht den CRC32-Hash aus dem Manifest -- eine Datei mit korrekter Größe
-- und gültiger Lua-Syntax, aber verändertem Inhalt, konnte akzeptiert
-- werden. manifest_mod.crc32 ist die gemeinsame Pruefsummenfunktion.
-- wird jetzt durchgereicht, damit stage_mod.verify() jeden Write
-- tatsächlich gegen den erwarteten Hash prüft.
local ok, err = stage_mod.install(file_list, INSTALL_ROOT, http_mod, ref,
  function(done, total, rel) ui_mod.progress(done, total, rel) end,
  manifest_mod.crc32)
if not ok then error("Installation: " .. tostring(err), 0) end

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.1 (Abschnitt 3, Fix-Punkt 4):
-- "Entrypoint und Rollenabhaengigkeiten pruefen" -- stage_mod.install() hat
-- zwar jede Datei einzeln gegen Groesse/CRC32 verifiziert, aber diese
-- zusaetzliche Existenzpruefung ueber die GESAMTE erwartete Dateiliste
-- (die den Rollen-Entrypoint, z.B. nodes/fuel/main.lua, immer enthaelt, da
-- sie direkt aus manifest_mod.files_for_role() stammt) faengt zusaetzlich
-- den Fall ab, dass eine Datei aus file_list aus einem anderen Grund
-- (Race, externer Eingriff) zwischen Install und hier wieder verschwunden
-- ist.
local ok_verify_journal, err_verify_journal = journal_mod.write({
  state = journal_mod.STATE.VERIFYING,
  ref = ref,
  manifest_id = tostring(manifest.manifest_id or manifest.manifest_version),
  role = role.label,
  started_at = os.epoch("utc"),
  expected_files = expected_paths,
})
if not ok_verify_journal then
  error("Installationsjournal (VERIFYING) fehlgeschlagen: " .. tostring(err_verify_journal), 0)
end
for _, item in ipairs(file_list) do
  if not fs.exists(INSTALL_ROOT .. "/" .. item.path) then
    error("Verifikation fehlgeschlagen, Datei fehlt nach Installation: " .. item.path, 0)
  end
end

-- Gesamten config-Ordner wiederherstellen (ueberschreibt die bereits
-- minimal wiederhergestellten Dateien mit demselben Inhalt -- idempotent).
-- Jede Datei wird nach dem Schreiben erneut gelesen und byte-genau mit
-- dem Backup verglichen. Bleibt etwas fehlgeschlagen, wird das Recovery-
-- Backup NICHT geloescht, damit eine manuelle/spaetere Wiederherstellung
-- weiterhin moeglich ist.
do
  local restored, failed = 0, {}
  for rel, content in pairs(config_backup) do
    local dst = CONFIG_DIR .. "/" .. rel
    local ok_w, err_w = stage_mod.write(dst, content)
    if not ok_w then
      failed[#failed + 1] = rel .. " (" .. tostring(err_w) .. ")"
    elseif stage_mod.read(dst) ~= content then
      failed[#failed + 1] = rel .. " (verify mismatch)"
    else
      restored = restored + 1
    end
  end
  if restored > 0 then p("Config wiederhergestellt: " .. restored .. " Datei(en)") end
  if #failed > 0 then
    p("WARN: Config-Wiederherstellung unvollstaendig: " .. table.concat(failed, ", "))
    p("WARN: Recovery-Backup bleibt erhalten: " .. RECOVERY_CONFIG_BACKUP)
    error("Config-Wiederherstellung unvollstaendig -- Installation bleibt fail-closed", 0)
  else
    pcall(fs.delete, RECOVERY_CONFIG_BACKUP)
  end
end

-- Feature (2026-07-01): aktuelle (ggf. gerade interaktiv geaenderte) Auswahl
-- optionaler Features persistieren — ueberschreibt das reine PRESERVE-
-- Backup mit dem tatsaechlich aktuellen Stand, damit eine Aenderung bei
-- diesem Lauf auch beim naechsten Auto-Update-Reinstall erhalten bleibt.
do
  local parts = { "return {\n" }
  for fname, enabled in pairs(selected_features) do
    if enabled == true then
      parts[#parts + 1] = "  [" .. string.format("%q", fname) .. "] = true,\n"
    end
  end
  parts[#parts + 1] = "}\n"
  local ok_of, err_of = stage_mod.write(INSTALL_ROOT .. "/config/optional_features.lua", table.concat(parts))
  if not ok_of then
    error("optional_features.lua konnte nicht geschrieben werden: " .. tostring(err_of), 0)
  end
end

-- Rolle konfigurieren
do
  local ok_role, err_role = stage_mod.write(INSTALL_ROOT .. "/config/role.lua",
    string.format("return { role = %q }\n", role.label))
  if not ok_role then
    error("role.lua konnte nicht geschrieben werden: " .. tostring(err_role), 0)
  end
end

-- startup.lua
local existing_startup = nil
if fs.exists(STARTUP_PATH) then
  local f = fs.open(STARTUP_PATH, "r"); if f then existing_startup = f.readAll(); f.close() end
end
local is_xreactor = existing_startup and (
  existing_startup:find("/xreactor/start.lua", 1, true) or
  existing_startup:find("XReactor", 1, true))
if not existing_startup or is_xreactor then
  local ok_su, err_su = stage_mod.write(STARTUP_PATH, STARTUP_CONTENT)
  if not ok_su then
    error("startup.lua konnte nicht geschrieben werden: " .. tostring(err_su), 0)
  end
  p("startup.lua konfiguriert")
else
  p("WARN: startup.lua nicht von XReactor — unverändert")
end

-- Auto-Update Config
local auto_cfg = INSTALL_ROOT .. "/config/remote_update.lua"
if not fs.exists(auto_cfg) then
  local ok_au, err_au = stage_mod.write(auto_cfg,
    "return {\n  enabled = true,\n  auto_update = true,\n  check_interval_s = 120,\n}\n")
  if not ok_au then
    error("remote_update.lua konnte nicht geschrieben werden: " .. tostring(err_au), 0)
  end
  p("Auto-Update Config angelegt")
end

-- Fix (2026-07-17): CRITICAL. INSTALL-P0.1 (Abschnitt 3, Fix-Punkt 5):
-- "release.lua und Completion-Marker ZULETZT atomar committen". release.lua
-- wurde oben bewusst aus der Hauptinstallationsschleife ausgeschlossen --
-- jetzt, nachdem WIRKLICH alles andere (Dateien, Config, Rolle, Startup)
-- erfolgreich geschrieben und verifiziert ist, wird sie als einzelne,
-- letzte Datei installiert und CRC32-verifiziert. Erst danach wird das
-- Journal auf COMMITTED gesetzt und sofort geloescht -- ein Absturz VOR
-- diesem Punkt hinterlaesst garantiert kein neues release.lua (der alte
-- Stand bleibt fuer jede Versions-/Diagnoseanzeige "aktuell"), ein Absturz
-- NACH diesem Punkt bedeutet eine vollstaendige, verifizierte Installation.
local release_entry = expected["release.lua"]
if release_entry then
  local ok_rel, err_rel = stage_mod.install(
    { { path = "release.lua", entry = release_entry } },
    INSTALL_ROOT, http_mod, ref, nil, manifest_mod.crc32)
  if not ok_rel then error("release.lua: " .. tostring(err_rel), 0) end
end

local ok_commit, err_commit = journal_mod.write({
  state = journal_mod.STATE.COMMITTED,
  ref = ref,
  manifest_id = tostring(manifest.manifest_id or manifest.manifest_version),
  role = role.label,
  started_at = os.epoch("utc"),
  expected_files = expected_paths,
})
if not ok_commit then
  error("Installationsjournal (COMMITTED) konnte nicht geschrieben werden: " .. tostring(err_commit), 0)
end
journal_mod.clear()

ui_mod.ok("Installation abgeschlossen: " .. role.label)
_G.__xreactor_installer_completed = true
_G.__xreactor_installer_role = role.label

end
