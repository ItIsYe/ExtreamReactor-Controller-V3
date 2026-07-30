-- tests/start_lua_incomplete_install_blocks_role_test.lua
--
-- Regression test fuer INSTALL-P0.1/P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitte 3+4): xreactor/start.lua muss bei
-- JEDEM Boot das zweiteilige Generationsjournal pruefen und die Rolle
-- NICHT starten, solange der klassifizierte Gesamtzustand nicht ABSENT
-- oder VALID_COMMITTED ist -- insbesondere auch dann nicht, wenn ein
-- Journalslot existiert, aber nicht sauber geparst werden kann (CORRUPT/
-- UNREADABLE) statt schlicht zu fehlen. start.lua ist boot-seitig sehr
-- side-effect-lastig (dofile(entry), parallel.waitForAny, os.reboot) und
-- daher nicht direkt per require() testbar -- der betroffene Guard-
-- Codeblock wird per Start-/End-Marker aus dem echten Quelltext extrahiert
-- und isoliert mit gemocktem fs/http/os ausgefuehrt (gleiche Technik wie
-- bei den installer_*_critical_write_abort_test.lua-Tests). Da der
-- extrahierte Text direkt aus der Datei kommt, faellt dieser Test
-- automatisch durch, sobald der pre-fix-Code (git stash) wieder aktiv ist
-- (die Guard-Logik existiert dort schlicht nicht -- der Marker selbst
-- waere nicht auffindbar).

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
local src = read_file(repo_root .. "/xreactor/start.lua")

local guard_snippet = extract(src, "local function p(msg)", "\nlocal function read_role()")

-- Sanity: the extraction must actually contain the guard, not just p().
if not guard_snippet:find("Rolle wird NICHT gestartet", 1, true) then
  error("extracted snippet does not contain the expected recovery guard -- marker drifted")
end

local SLOT_A = "/xreactor_install_journal.a.lua"
local SLOT_B = "/xreactor_install_journal.b.lua"

-- journal_files: optional table { [SLOT_A]=content, [SLOT_B]=content }.
local function run_guard(journal_files, http_should_succeed)
  local fs_files = {}
  if journal_files then
    for path, content in pairs(journal_files) do fs_files[path] = content end
  end
  local written = {}
  local reboot_calls = 0
  local sleep_calls = 0
  local dofile_calls = {}

  _G.fs = {
    exists = function(p) return fs_files[p] ~= nil end,
    open = function(p, mode)
      if mode == "r" then
        if not fs_files[p] then return nil end
        return { readAll = function() return fs_files[p] end, close = function() end }
      elseif mode == "w" then
        local buf = {}
        return {
          write = function(content) buf[#buf + 1] = content end,
          close = function() written[p] = table.concat(buf) end,
        }
      end
      return nil
    end,
    getFreeSpace = function() return 1024 * 1024 end,
    delete = function() end,
  }
  _G.http = {
    get = function()
      if http_should_succeed then
        return { readAll = function() return "-- fake installer body" end, close = function() end }
      end
      error("simulated network failure")
    end,
  }
  _G.os = _G.os or {}
  os.reboot = function() reboot_calls = reboot_calls + 1 end
  os.sleep = function() sleep_calls = sleep_calls + 1 end
  os.epoch = os.epoch or function() return 0 end
  _G.dofile = function(path) dofile_calls[#dofile_calls + 1] = path end
  local orig_print = print
  _G.print = function() end

  local chunk, lerr = load(guard_snippet, "=snippet", "t")
  if not chunk then error("snippet failed to parse: " .. tostring(lerr) .. "\n---\n" .. guard_snippet) end
  local ok, err = pcall(chunk)
  _G.print = orig_print
  return ok, err, reboot_calls, sleep_calls, dofile_calls
end

local function journal(state, generation)
  return string.format(
    'return { state = %q, generation = %d, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} }\n',
    state, generation or 0)
end

-- ── Fall 1: kein Journal vorhanden (beide Slots ABSENT) -- Guard darf ──────
-- ── NICHT feuern ─────────────────────────────────────────────────────────────
do
  local ok = run_guard(nil, true)
  if not ok then error("guard must not abort boot when no install journal slot exists") end
end

-- ── Fall 2: Journal COMMITTED -- Guard darf NICHT feuern ────────────────────
do
  local ok = run_guard({ [SLOT_A] = journal("COMMITTED", 3) }, true)
  if not ok then error("guard must not abort boot when the install journal is COMMITTED") end
end

-- ── Fall 3: Journal INSTALLING, Recovery-Download schlaegt fehl (kein Netz) ──
-- Die Rolle darf NIEMALS gestartet werden -- der Guard muss abbrechen
-- (error()), bevor der restliche start.lua-Code (der die Rolle startet)
-- ueberhaupt erreicht wird, und muss einen Reboot fuer den naechsten
-- Recovery-Versuch ausloesen.
do
  local ok, err, reboot_calls, sleep_calls, dofile_calls = run_guard(
    { [SLOT_A] = journal("INSTALLING", 1) }, false)
  if ok then
    error("CRITICAL: guard did not abort boot for an incomplete (INSTALLING) journal with failed recovery download")
  end
  if not tostring(err):find("Recovery%-Resume nicht abgeschlossen") then
    error("expected recovery-abort error, got: " .. tostring(err))
  end
  if reboot_calls ~= 1 then error("expected exactly one os.reboot() call for the retry loop, got " .. reboot_calls) end
  if sleep_calls ~= 1 then error("expected exactly one os.sleep() call before the retry reboot, got " .. sleep_calls) end
  if #dofile_calls ~= 0 then error("dofile(recovery installer) should not have run since http.get failed") end
end

-- ── Fall 4: Journal VERIFYING, Recovery-Download gelingt ────────────────────
-- Der Guard muss weiterhin abbrechen (die Rolle wird in DIESEM Boot nicht
-- gestartet -- der frisch heruntergeladene /installer uebernimmt und
-- rebootet nach Abschluss selbst), aber der Recovery-Installer muss
-- tatsaechlich ausgefuehrt worden sein.
do
  local ok, err, reboot_calls, sleep_calls, dofile_calls = run_guard(
    { [SLOT_A] = journal("VERIFYING", 1) }, true)
  if ok then
    error("CRITICAL: guard did not abort boot for an incomplete (VERIFYING) journal even though recovery ran")
  end
  if #dofile_calls ~= 1 then
    error("expected the downloaded recovery installer to be dofile()'d exactly once, got " .. #dofile_calls)
  end
end

-- ── Fall 5 (INSTALL-P0.1): SLOT_B traegt die hoehere, gueltige Generation ───
-- (COMMITTED) -- ein aelterer, niedrigerer Stand in SLOT_A darf den Boot
-- nicht blockieren. Simuliert exakt den Normalfall nach mehreren
-- Installationslaeufen (Slots alternieren).
do
  local ok = run_guard({
    [SLOT_A] = journal("VERIFYING", 2),
    [SLOT_B] = journal("COMMITTED", 3),
  }, true)
  if not ok then error("guard must follow the HIGHER generation (COMMITTED) even when the other slot is an older, incomplete state") end
end

-- ── Fall 6 (INSTALL-P0.1): umgekehrt -- SLOT_A hoehere Generation, aber ─────
-- unvollstaendig; SLOT_B niedrigere Generation, COMMITTED. Der neuere,
-- unvollstaendige Stand muss den Boot blockieren.
do
  local ok = run_guard({
    [SLOT_A] = journal("INSTALLING", 4),
    [SLOT_B] = journal("COMMITTED", 3),
  }, false)
  if ok then error("guard must follow the HIGHER generation (INSTALLING) even when the other, older slot was COMMITTED") end
end

-- ── Fall 7 (INSTALL-P0.2): ein Slot existiert, ist aber nicht gueltig ───────
-- parsebar (kaputte Syntax) -- das MUSS als fail-closed CORRUPT behandelt
-- werden, NICHT wie "kein Journal vorhanden". Die Rolle darf nicht starten.
do
  local ok = run_guard({ [SLOT_A] = "not valid { lua syntax !!" }, false)
  if ok then error("CRITICAL: a corrupt journal slot must block boot, not be treated as absent") end
end

-- ── Fall 8 (INSTALL-P0.2): leere/abgeschnittene Datei (UNREADABLE) ──────────
do
  local ok = run_guard({ [SLOT_A] = "" }, false)
  if ok then error("CRITICAL: an empty/truncated journal slot must block boot, not be treated as absent") end
end

print("start_lua_incomplete_install_blocks_role_test.lua: ok")
