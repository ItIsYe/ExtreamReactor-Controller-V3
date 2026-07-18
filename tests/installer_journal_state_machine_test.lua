-- tests/installer_journal_state_machine_test.lua
--
-- Regression/unit test fuer installer/journal.lua (INSTALL-P0.1, siehe
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitt 3).
-- Treibt das echte Modul mit einer gemockten fs gegen ein In-Memory-
-- Dateisystem: Round-Trip (write -> read liefert dieselben Felder),
-- check_incomplete() klassifiziert PREPARED/INSTALLING/VERIFYING als
-- unvollstaendig, COMMITTED und "kein Journal vorhanden" als vollstaendig/
-- normal, und clear() entfernt das Journal zuverlaessig.

local files = {}

_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  delete = function(p) files[p] = nil end,
  open = function(p, mode)
    if mode == "w" then
      local buf = {}
      return {
        write = function(content) buf[#buf + 1] = content end,
        close = function() files[p] = table.concat(buf) end,
      }
    elseif mode == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
  move = function(src, dst)
    files[dst] = files[src]
    files[src] = nil
  end,
}

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
local journal = require("installer.journal")

-- ── Kein Journal vorhanden: normal, kein Recovery ───────────────────────────
if journal.check_incomplete() ~= nil then
  error("expected check_incomplete() to be nil when no journal file exists")
end

-- ── Round-Trip: write -> read liefert dieselben Felder ──────────────────────
local ok_w, err_w = journal.write({
  state = journal.STATE.PREPARED,
  ref = "abc123def456",
  manifest_id = "manifest-v468",
  role = "FUEL-NODE",
  started_at = 123456789,
  expected_files = { "nodes/fuel/main.lua", "shared/constants.lua" },
})
if not ok_w then error("journal.write failed: " .. tostring(err_w)) end
if not fs.exists(journal.PATH) then error("journal file was not created at journal.PATH") end

local read_back = journal.read()
if not read_back then error("journal.read() returned nil after a successful write") end
if read_back.state ~= "PREPARED" then error("state mismatch: " .. tostring(read_back.state)) end
if read_back.ref ~= "abc123def456" then error("ref mismatch: " .. tostring(read_back.ref)) end
if read_back.manifest_id ~= "manifest-v468" then error("manifest_id mismatch") end
if read_back.role ~= "FUEL-NODE" then error("role mismatch") end
if read_back.started_at ~= 123456789 then error("started_at mismatch: " .. tostring(read_back.started_at)) end
if #read_back.expected_files ~= 2 then error("expected_files length mismatch") end
if read_back.expected_files[1] ~= "nodes/fuel/main.lua" then error("expected_files[1] mismatch") end
if read_back.expected_files[2] ~= "shared/constants.lua" then error("expected_files[2] mismatch") end

-- ── PREPARED/INSTALLING/VERIFYING sind alle "unvollstaendig" ────────────────
for _, state in ipairs({ journal.STATE.PREPARED, journal.STATE.INSTALLING, journal.STATE.VERIFYING }) do
  journal.write({ state = state, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
  local incomplete = journal.check_incomplete()
  if not incomplete then
    error("expected check_incomplete() to report an incomplete journal for state=" .. state)
  end
  if incomplete.state ~= state then error("check_incomplete() state mismatch for " .. state) end
end

-- ── COMMITTED gilt als abgeschlossen, kein Recovery ──────────────────────────
journal.write({ state = journal.STATE.COMMITTED, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
if journal.check_incomplete() ~= nil then
  error("expected check_incomplete() to be nil for a COMMITTED journal")
end

-- ── clear() entfernt das Journal zuverlaessig ───────────────────────────────
journal.clear()
if fs.exists(journal.PATH) then error("journal file still exists after clear()") end
if journal.read() ~= nil then error("journal.read() should return nil after clear()") end

print("installer_journal_state_machine_test.lua: ok")
