-- installer/init.lua
-- Einstiegspunkt. Wird von /installer via dofile aufgerufen.

local http_mod     = dofile("/xreactor/installer/http.lua")
local manifest_mod = dofile("/xreactor/installer/manifest.lua")
local stage_mod    = dofile("/xreactor/installer/stage.lua")
local ui_mod       = dofile("/xreactor/installer/ui.lua")

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

local sha = http_mod.resolve_sha()
local base_url = sha
  and (GITHUB_RAW .. sha .. "/xreactor/")
  or  (GITHUB_RAW .. "beta/xreactor/")
p(sha and ("SHA-PIN: " .. sha:sub(1,10)) or "WARN: SHA nicht auflösbar")

-- Fix (2026-07-08): CRITICAL. Vorher wurde das Manifest ausschliesslich
-- ueber die SHA-gepinnte URL geladen, OHNE Fallback — waehrend
-- http_mod.download_file() fuer JEDE einzelne Datei bereits einen
-- Fallback auf den ungepinnten "beta"-Branch-Pfad hat, falls die
-- SHA-gepinnte URL fehlschlaegt. Ergebnis: wenn resolve_sha() einen
-- nicht ganz aktuellen Commit lieferte (z.B. durch API-Verzoegerung/
-- Rate-Limit-Umstaende), aber die SHA-gepinnte manifest.lua-URL trotzdem
-- erfolgreich (nur mit veraltetem Inhalt) antwortete, blieb das Manifest
-- auf altem Stand — waehrend einzelne Dateien beim Download ueber den
-- Fallback-Pfad bereits den neuesten Stand bekamen. Beobachtet als
-- "Installation: size mismatch ... got <neu> expected <alt>". Jetzt wird
-- das Manifest immer vom ungepinnten "beta"-Branch-Pfad geladen (garantiert
-- konsistent mit dem, was download_file() im Fallback-Fall sowieso liefert)
-- — die SHA bleibt nur fuer die einzelnen Datei-Downloads relevant, wo sie
-- ohnehin bereits denselben Fallback-Schutz hat.
local manifest_url = GITHUB_RAW .. "beta/xreactor/manifest.lua"
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

-- Wichtige Dateien sichern
local PRESERVE = { "config/node_id.txt", "config/capacity_cache.lua", "config/role.lua", "config/optional_features.lua", "config/ampel_thresholds.lua" }
local preserved = {}
for _, rel in ipairs(PRESERVE) do
  local src = INSTALL_ROOT .. "/" .. rel
  if fs.exists(src) then
    local f = fs.open(src, "r"); if f then preserved[rel] = f.readAll(); f.close() end
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
  local raw = preserved["config/optional_features.lua"]
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

-- Alte Installation löschen
if fs.exists(INSTALL_ROOT) then
  p("Entferne alte Installation..."); pcall(fs.delete, INSTALL_ROOT)
end
pcall(fs.makeDir, INSTALL_ROOT)

-- Dateien installieren
local expected = manifest_mod.files_for_role(manifest, role.label, selected_features)
local file_list = {}
for rel, entry in pairs(expected) do table.insert(file_list, { path = rel, entry = entry }) end
table.sort(file_list, function(a, b)
  local sa = tonumber((a.entry or {}).size_bytes) or 0
  local sb = tonumber((b.entry or {}).size_bytes) or 0
  if sa ~= sb then return sa > sb end
  return a.path < b.path
end)

p("Installiere " .. #file_list .. " Dateien...")
local ok, err = stage_mod.install(file_list, INSTALL_ROOT, http_mod, sha,
  function(done, total, rel) ui_mod.progress(done, total, rel) end)
if not ok then error("Installation: " .. tostring(err), 0) end

-- Gesicherte Dateien wiederherstellen
for rel, content in pairs(preserved) do
  local dst = INSTALL_ROOT .. "/" .. rel
  local dir = fs.getDir(dst)
  if dir and dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  local f = fs.open(dst, "w"); if f then f.write(content); f.close() end
  p("Wiederhergestellt: " .. rel)
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
  stage_mod.write(INSTALL_ROOT .. "/config/optional_features.lua", table.concat(parts))
end

-- Rolle konfigurieren
stage_mod.write(INSTALL_ROOT .. "/config/role.lua",
  string.format("return { role = %q }\n", role.label))

-- startup.lua
local existing_startup = nil
if fs.exists(STARTUP_PATH) then
  local f = fs.open(STARTUP_PATH, "r"); if f then existing_startup = f.readAll(); f.close() end
end
local is_xreactor = existing_startup and (
  existing_startup:find("/xreactor/start.lua", 1, true) or
  existing_startup:find("XReactor", 1, true))
if not existing_startup or is_xreactor then
  stage_mod.write(STARTUP_PATH, STARTUP_CONTENT); p("startup.lua konfiguriert")
else
  p("WARN: startup.lua nicht von XReactor — unverändert")
end

-- Auto-Update Config
local auto_cfg = INSTALL_ROOT .. "/config/remote_update.lua"
if not fs.exists(auto_cfg) then
  stage_mod.write(auto_cfg,
    "return {\n  enabled = true,\n  auto_update = true,\n  check_interval_s = 120,\n}\n")
  p("Auto-Update Config angelegt")
end

ui_mod.ok("Installation abgeschlossen: " .. role.label)
_G.__xreactor_installer_completed = true
_G.__xreactor_installer_role = role.label
