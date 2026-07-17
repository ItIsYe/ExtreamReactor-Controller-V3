-- tests/installer_monolith_critical_write_abort_test.lua
--
-- Regression test fuer INSTALL-P0.3 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 5), fuer den monolithischen
-- Top-Level-Installer "/installer". Dieselbe Klasse von Fixes wie in
-- installer/init.lua (siehe installer_init_critical_write_abort_test.lua)
-- muss auch im tatsaechlich ausgefuehrten Live-Codepfad von "/installer"
-- greifen (NICHT im nur eingebetteten init_src-Text -- siehe Kommentar in
-- installer selbst: "dies ist der Codepfad, der TATSAECHLICH laeuft").
-- Codeblöcke werden per Start-/End-Marker aus dem echten Quelltext
-- extrahiert, damit dieser Test automatisch durchfaellt, sobald der
-- pre-fix-Code (git stash) wieder aktiv ist.

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
local src = read_file(repo_root .. "/installer")

-- ── Fall 1: role.lua-Schreibfehler im Live-Installflow muss abbrechen ───────
do
  local role_snippet = extract(src, "-- ── Rolle + Config", "local startup_path")

  _G.stage_mod = { write = function() return false, "simulated disk full" end }
  _G.INSTALL_ROOT = "/xreactor"
  _G.role = { label = "FUEL-NODE" }
  _G.fs = { exists = function() return true end }

  local chunk, lerr = load(role_snippet, "=snippet", "t")
  if not chunk then error("snippet failed to parse: " .. tostring(lerr) .. "\n---\n" .. role_snippet) end
  local ok, err = pcall(chunk)
  if ok then
    error("CRITICAL: role.lua write failure did not abort /installer's live install flow")
  end
  if not tostring(err):find("role.lua konnte nicht geschrieben werden", 1, true) then
    error("expected role.lua abort error, got: " .. tostring(err))
  end
end

-- ── Fall 2: INSTALL_ROOT-Neuanlage-Fehler im Live-Installflow muss abbrechen ─
do
  local root_snippet = extract(src, "-- ── Alte Installation löschen", "-- ── Eingebettete Module")

  local existed = { ["/xreactor"] = true }
  _G.INSTALL_ROOT = "/xreactor"
  _G.fs = {
    exists = function(p) return existed[p] == true end,
    delete = function(p) existed[p] = nil end,
    makeDir = function(p) end,
  }
  _G.pcall = pcall
  _G.p = function() end

  local chunk, lerr = load(root_snippet, "=snippet", "t")
  if not chunk then error("snippet failed to parse: " .. tostring(lerr) .. "\n---\n" .. root_snippet) end
  local ok, err = pcall(chunk)
  if ok then
    error("CRITICAL: failed INSTALL_ROOT re-creation did not abort /installer's live install flow")
  end
  if not tostring(err):find("Installationsverzeichnis konnte nicht angelegt werden", 1, true) then
    error("expected INSTALL_ROOT creation abort error, got: " .. tostring(err))
  end
end

print("installer_monolith_critical_write_abort_test.lua: ok")
