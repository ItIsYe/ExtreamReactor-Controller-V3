-- tests/installer_init_critical_write_abort_test.lua
--
-- Regression test fuer INSTALL-P0.3 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 5): installer/init.lua ignorierte
-- bisher die Rueckgabewerte mehrerer kritischer Dateisystem-Operationen
-- (INSTALL_ROOT loeschen/anlegen, role.lua schreiben) und lief bei einem
-- Fehlschlag einfach weiter, statt die Installation kontrolliert
-- abzubrechen. installer/init.lua ist ein Einstiegspunkt mit vielen
-- Boot-Seiteneffekten (dofile(), interaktive Prompts, http, os.reboot) und
-- daher nicht direkt per require() testbar -- stattdessen werden die
-- betroffenen Codebloecke ueber Start-/End-Marker aus dem echten
-- Quelltext extrahiert und isoliert in einer Sandbox ausgefuehrt (gleiche
-- Technik wie bei anderen boot-lastigen main.lua-Tests in dieser Suite).
-- Da der extrahierte Text direkt aus der Datei kommt, faellt dieser Test
-- automatisch durch, sobald der pre-fix-Code (git stash) wieder aktiv ist.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function extract(src, start_marker, end_marker)
  local start_idx = assert(src:find(start_marker, 1, true), "start marker not found: " .. start_marker)
  local end_idx = assert(src:find(end_marker, start_idx, true), "end marker not found: " .. end_marker)
  return src:sub(start_idx, end_idx - 1)
end

local repo_root = os.getenv("REPO_ROOT") or "."
local src = read_file(repo_root .. "/xreactor/installer/init.lua")

local function run_snippet(snippet, env_setup)
  local chunk, lerr = load(snippet, "=snippet", "t")
  if not chunk then error("snippet failed to parse: " .. tostring(lerr) .. "\n---\n" .. snippet) end
  env_setup()
  return pcall(chunk)
end

-- ── Fall 1: role.lua-Schreibfehler muss abbrechen ───────────────────────────
do
  local role_snippet = extract(src, "-- Rolle konfigurieren", "-- startup.lua")

  _G.stage_mod = { write = function() return false, "simulated disk full" end }
  _G.INSTALL_ROOT = "/xreactor"
  _G.role = { label = "FUEL-NODE" }

  local ok, err = run_snippet(role_snippet, function() end)
  if ok then
    error("CRITICAL: role.lua write failure did not abort installation (silent continue)")
  end
  if not tostring(err):find("role.lua konnte nicht geschrieben werden", 1, true) then
    error("expected role.lua abort error, got: " .. tostring(err))
  end
end

-- ── Fall 2: INSTALL_ROOT-Neuanlage-Fehler muss abbrechen ────────────────────
do
  local root_snippet = extract(src, "-- Alte Installation löschen", "-- Minimal-Restore sofort")

  local existed = { ["/xreactor"] = true }
  _G.INSTALL_ROOT = "/xreactor"
  _G.fs = {
    exists = function(p) return existed[p] == true end,
    delete = function(p) existed[p] = nil end,
    -- simuliert fehlgeschlagenes makeDir: Verzeichnis existiert danach nicht
    makeDir = function(p) end,
  }
  _G.pcall = pcall
  _G.p = function() end

  local ok, err = run_snippet(root_snippet, function() end)
  if ok then
    error("CRITICAL: failed INSTALL_ROOT re-creation did not abort installation")
  end
  if not tostring(err):find("Installationsverzeichnis konnte nicht angelegt werden", 1, true) then
    error("expected INSTALL_ROOT creation abort error, got: " .. tostring(err))
  end
end

print("installer_init_critical_write_abort_test.lua: ok")
