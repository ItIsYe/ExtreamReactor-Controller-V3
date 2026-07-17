-- tests/installer_journal_ordering_and_release_last_test.lua
--
-- Regression test fuer INSTALL-P0.1 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 3, Fix-Punkte 3+5): sowohl der
-- modulare Installer (installer/init.lua) als auch der tatsaechlich
-- ausgefuehrte Live-Installflow im Monolithen (/installer) muessen:
--  1) release.lua aus der Hauptinstallationsschleife ausschliessen und erst
--     als eigenen, letzten Schritt installieren,
--  2) das Installationsjournal in der Reihenfolge PREPARED -> INSTALLING ->
--     VERIFYING -> COMMITTED schreiben, mit COMMITTED strikt NACH dem
--     release.lua-Schritt.
--
-- Strukturelle Pruefung direkt am Quelltext (Positionsvergleich der
-- relevanten Marker), da ein voller End-to-End-Lauf des Installers externe
-- Netzwerk-/Downloadabhaengigkeiten haette. Faellt automatisch durch,
-- sobald der pre-fix-Code (git stash) wieder aktiv ist -- dort existieren
-- die journal_mod-Aufrufe und der separate release.lua-Schritt schlicht
-- nicht.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function pos(src, needle, from)
  local p = src:find(needle, from or 1, true)
  assert(p, "marker not found: " .. needle)
  return p
end

local function check_ordering(src, label, search_from)
  search_from = search_from or 1
  local file_list_excludes_release = pos(src, 'rel ~= "release.lua"', search_from)

  local prepared_write = pos(src, "journal_mod.STATE.PREPARED", search_from)
  local installing_write = pos(src, "journal_mod.STATE.INSTALLING", prepared_write)
  local verifying_write = pos(src, "journal_mod.STATE.VERIFYING", installing_write)

  -- release.lua wird als eigener, separater stage_mod.install()-Aufruf
  -- NACH der VERIFYING-Markierung installiert (also nachdem die
  -- Hauptschleife fertig ist), und die COMMITTED-Markierung muss danach
  -- kommen, nicht davor.
  local release_last_install = pos(src, 'path = "release.lua"', verifying_write)
  local committed_write = pos(src, "journal_mod.STATE.COMMITTED", release_last_install)
  local journal_clear = pos(src, "journal_mod.clear()", committed_write)

  if not (prepared_write < installing_write and installing_write < verifying_write
      and verifying_write < release_last_install and release_last_install < committed_write
      and committed_write < journal_clear) then
    error(label .. ": journal/release ordering is not PREPARED < INSTALLING < VERIFYING < release.lua < COMMITTED < clear()")
  end

  if file_list_excludes_release >= verifying_write then
    error(label .. ": release.lua exclusion from the main file_list must happen before the VERIFYING stage")
  end
end

local repo_root = os.getenv("REPO_ROOT") or "."

check_ordering(read_file(repo_root .. "/xreactor/installer/init.lua"), "installer/init.lua")

-- /installer embeds a full-text COPY of init.lua (init_src, used only for
-- later on-disk deployment, never executed live -- see comment in the file
-- itself) BEFORE its own actually-executed live install flow. Anchor the
-- search past that embedded copy via a marker that only exists in the live
-- flow (the box-drawing "── ... ──" heading, not present in the plain-text
-- embedded copy), so this test verifies the code path that really runs.
local mono_src = read_file(repo_root .. "/installer")
local live_flow_start = pos(mono_src, "beim manuellen/direkten Aufruf von /installer")
check_ordering(mono_src, "/installer (live flow)", live_flow_start)

print("installer_journal_ordering_and_release_last_test.lua: ok")
