-- tests/installer_journal_state_machine_test.lua
--
-- Regression/unit test fuer installer/journal.lua (INSTALL-P0.1/P0.2, siehe
-- docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitte 3+4).
-- Treibt das echte Modul mit einer gemockten fs gegen ein In-Memory-
-- Dateisystem:
--  - Round-Trip (write -> read liefert dieselben Felder),
--  - PREPARED/INSTALLING/VERIFYING/COMMITTED-Alternierung zwischen den
--    beiden Generationsslots (jeder write() ruehrt NUR den jeweils
--    "stale" Slot an, der andere bleibt unangetastet),
--  - classify() trennt PREPARED/INSTALLING/VERIFYING von COMMITTED und
--    "kein Journal vorhanden",
--  - Crashsimulation: ein Abbruch WAEHREND des Schreibens eines neuen
--    Slots darf die zuletzt bestaetigte Generation im jeweils anderen
--    Slot nicht gefaehrden (INSTALL-P0.1),
--  - ein beschaedigtes/unlesbares Journal wird fail-closed als
--    CORRUPT/UNREADABLE erkannt, NICHT als "kein Journal vorhanden"
--    (INSTALL-P0.2),
--  - clear() loescht nur den veralteten Einzeldatei-Pfad, niemals eine
--    bestaetigte Generation.

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

local function reset() files = {} end

-- ── Kein Journal vorhanden: ABSENT, kein Recovery ───────────────────────────
reset()
do
  local status, j = journal.classify()
  if status ~= journal.STATUS.ABSENT or j ~= nil then
    error("expected ABSENT/nil for a fresh filesystem, got " .. tostring(status))
  end
end

-- ── Round-Trip: write -> read liefert dieselben Felder ──────────────────────
reset()
do
  local ok_w, err_w = journal.write({
    state = journal.STATE.PREPARED,
    ref = "abc123def456",
    manifest_id = "manifest-v468",
    role = "FUEL-NODE",
    started_at = 123456789,
    expected_files = { "nodes/fuel/main.lua", "shared/constants.lua" },
  })
  if not ok_w then error("journal.write failed: " .. tostring(err_w)) end
  if not fs.exists(journal.SLOT_A) then error("first write must land in SLOT_A") end
  if fs.exists(journal.SLOT_B) then error("first write must not touch SLOT_B") end

  local read_back = journal.read()
  if not read_back then error("journal.read() returned nil after a successful write") end
  if read_back.state ~= "PREPARED" then error("state mismatch: " .. tostring(read_back.state)) end
  if read_back.generation ~= 0 then error("expected first generation to be 0, got " .. tostring(read_back.generation)) end
  if read_back.ref ~= "abc123def456" then error("ref mismatch: " .. tostring(read_back.ref)) end
  if read_back.manifest_id ~= "manifest-v468" then error("manifest_id mismatch") end
  if read_back.role ~= "FUEL-NODE" then error("role mismatch") end
  if read_back.started_at ~= 123456789 then error("started_at mismatch: " .. tostring(read_back.started_at)) end
  if #read_back.expected_files ~= 2 then error("expected_files length mismatch") end
  if read_back.expected_files[1] ~= "nodes/fuel/main.lua" then error("expected_files[1] mismatch") end
  if read_back.expected_files[2] ~= "shared/constants.lua" then error("expected_files[2] mismatch") end
end

-- ── PREPARED/INSTALLING/VERIFYING/COMMITTED alternieren zwischen Slots ──────
reset()
do
  local expect_slot = { journal.SLOT_A, journal.SLOT_B, journal.SLOT_A, journal.SLOT_B }
  local states = { journal.STATE.PREPARED, journal.STATE.INSTALLING, journal.STATE.VERIFYING, journal.STATE.COMMITTED }
  local last_generation = -1
  for i, state in ipairs(states) do
    local ok_w = journal.write({ state = state, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
    if not ok_w then error("write failed for state=" .. state) end
    if not fs.exists(expect_slot[i]) then
      error("write for state=" .. state .. " expected to land in slot #" .. i .. " but that slot is empty")
    end
    local status, j = journal.classify()
    if j.state ~= state then error("classify() state mismatch after writing " .. state .. ": got " .. tostring(j.state)) end
    if j.generation <= last_generation then
      error("generation must strictly increase; prev=" .. last_generation .. " new=" .. tostring(j.generation))
    end
    last_generation = j.generation
    if state == journal.STATE.COMMITTED then
      if status ~= journal.STATUS.VALID_COMMITTED then error("expected VALID_COMMITTED status") end
    else
      if status ~= journal.STATUS.VALID_INCOMPLETE then error("expected VALID_INCOMPLETE status for " .. state) end
    end
  end
end

-- ── PREPARED/INSTALLING/VERIFYING sind alle "unvollstaendig" ────────────────
reset()
for _, state in ipairs({ journal.STATE.PREPARED, journal.STATE.INSTALLING, journal.STATE.VERIFYING }) do
  reset()
  journal.write({ state = state, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
  local status, incomplete = journal.classify()
  if status ~= journal.STATUS.VALID_INCOMPLETE or not incomplete then
    error("expected classify() to report an incomplete journal for state=" .. state)
  end
  if incomplete.state ~= state then error("classify() state mismatch for " .. state) end
end

-- ── COMMITTED gilt als abgeschlossen, kein Recovery ──────────────────────────
reset()
do
  journal.write({ state = journal.STATE.PREPARED, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
  journal.write({ state = journal.STATE.COMMITTED, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
  local status = journal.classify()
  if status ~= journal.STATUS.VALID_COMMITTED then error("expected VALID_COMMITTED journal") end
end

-- ── INSTALL-P0.1: Ein fehlgeschlagener direkter Write in den stale Slot ─────
-- ── darf die zuletzt bestaetigte Generation nicht gefaehrden ────────────────
reset()
do
  -- Erster Installationslauf: sauber bis COMMITTED durch (landet in SLOT_A,
  -- generation 0 -- ein einzelner write() reicht, weil beide Slots vorher
  -- leer sind).
  journal.write({ state = journal.STATE.COMMITTED, ref = "run1", manifest_id = "m1", role = "RT-NODE", started_at = 1, expected_files = {} })
  local committed_slot = fs.exists(journal.SLOT_A) and journal.SLOT_A or journal.SLOT_B
  local other_slot = (committed_slot == journal.SLOT_A) and journal.SLOT_B or journal.SLOT_A

  -- Naechster Installationslauf beginnt (PREPARED) -- write() zielt auf
  -- den anderen (stale) Slot. Simuliere einen Fehler beim Oeffnen dieses
  -- Slots. Der gueltige COMMITTED-Slot wird nicht angefasst.
  local real_open = fs.open
  fs.open = function(p, mode)
    if mode == "w" and p == other_slot then return nil end
    return real_open(p, mode)
  end
  local ok_w = journal.write({ state = journal.STATE.PREPARED, ref = "run2", manifest_id = "m2", role = "RT-NODE", started_at = 2, expected_files = {} })
  fs.open = real_open
  if ok_w then error("expected the simulated crash to abort journal.write()") end

  -- Trotz Crash: der vorherige COMMITTED-Stand muss weiterhin die alleinige,
  -- gueltige Quelle sein -- kein Rollenstart-Blocker, kein Datenverlust.
  local status, j = journal.classify()
  if status ~= journal.STATUS.VALID_COMMITTED then
    error("crash during next write must not disturb the previous COMMITTED generation, got " .. tostring(status))
  end
  if j.ref ~= "run1" then error("expected the untouched previous COMMITTED journal (run1), got ref=" .. tostring(j.ref)) end
end

-- ── INSTALL-P0.1: Abgeschnittener stale Slot faellt auf COMMITTED zurueck ───
reset()
do
  journal.write({ state = journal.STATE.COMMITTED, ref = "run1", manifest_id = "m1", role = "RT-NODE", started_at = 1, expected_files = {} })
  local committed_slot = fs.exists(journal.SLOT_A) and journal.SLOT_A or journal.SLOT_B
  local other_slot = (committed_slot == journal.SLOT_A) and journal.SLOT_B or journal.SLOT_A

  local real_open = fs.open
  fs.open = function(p, mode)
    if mode == "w" and p == other_slot then
      return {
        write = function() error("simulated interrupted stale-slot write") end,
        close = function() files[p] = "" end,
      }
    end
    return real_open(p, mode)
  end
  local ok_w = journal.write({ state = journal.STATE.PREPARED, ref = "run2", manifest_id = "m2", role = "RT-NODE", started_at = 2, expected_files = {} })
  fs.open = real_open
  if ok_w then error("expected the simulated tmp-write crash to abort journal.write()") end

  local status, j = journal.classify()
  if status ~= journal.STATUS.VALID_COMMITTED or j.ref ~= "run1" then
    error("interrupted stale-slot write must leave the previous COMMITTED generation fully intact")
  end
end

-- ── Journal writes must not use tmp files or fs.move. The two-slot design ───
-- ── itself supplies recovery; extra move steps add CC failure modes. ────────
reset()
do
  local source = assert(io.open("xreactor/installer/journal.lua", "r")):read("*a")
  if source:find("fs" .. ".move", 1, true) then error("journal must not use move-based writes") end
  if source:find(".tmp", 1, true) then error("journal must not create tmp slots") end
end

-- ── INSTALL-P0.2: beschaedigtes/unlesbares Journal ist fail-closed, ─────────
-- ── NICHT gleichbedeutend mit "kein Journal vorhanden" ──────────────────────
reset()
do
  files[journal.SLOT_A] = "not valid { lua syntax !!"
  local status, j = journal.classify()
  if status ~= journal.STATUS.CORRUPT then error("expected CORRUPT for invalid lua syntax, got " .. tostring(status)) end
  if j ~= nil then error("CORRUPT classification must not return a journal table") end
end

reset()
do
  files[journal.SLOT_A] = "" -- leer/abgeschnitten
  local status = journal.classify()
  if status ~= journal.STATUS.UNREADABLE then error("expected UNREADABLE for an empty journal file, got " .. tostring(status)) end
end

reset()
do
  files[journal.SLOT_A] = "return { state = \"BOGUS_STATE\", generation = 0 }\n"
  local status = journal.classify()
  if status ~= journal.STATUS.CORRUPT then error("expected CORRUPT for an unknown state value, got " .. tostring(status)) end
end

reset()
do
  files[journal.SLOT_A] = "return { state = \"PREPARED\" }\n" -- generation fehlt
  local status = journal.classify()
  if status ~= journal.STATUS.CORRUPT then error("expected CORRUPT when generation is missing, got " .. tostring(status)) end
end

-- Ein CORRUPT Slot A neben einem gueltigen, hoeher-generierten COMMITTED
-- Slot B darf den Gesamtzustand NICHT verschlechtern -- der gueltige,
-- neuere Stand gewinnt weiterhin.
reset()
do
  journal.write({ state = journal.STATE.COMMITTED, ref = "good", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
  local winning_slot = fs.exists(journal.SLOT_A) and journal.SLOT_A or journal.SLOT_B
  local stale_slot = (winning_slot == journal.SLOT_A) and journal.SLOT_B or journal.SLOT_A
  files[stale_slot] = "not valid { lua syntax !!"
  local status, j = journal.classify()
  if status ~= journal.STATUS.VALID_COMMITTED or not j or j.ref ~= "good" then
    error("a corrupt stale slot must not shadow a valid, higher-generation winning slot")
  end
end

-- ── clear() entfernt nur den veralteten Einzeldatei-Pfad, niemals eine ──────
-- ── bestaetigte Generation ───────────────────────────────────────────────────
reset()
do
  journal.write({ state = journal.STATE.COMMITTED, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} })
  files[journal.LEGACY_PATH] = "return { state = \"INSTALLING\" }\n"
  journal.clear()
  if fs.exists(journal.LEGACY_PATH) then error("clear() must remove the legacy single-file journal path") end
  if journal.read() == nil then error("clear() must never remove a confirmed COMMITTED generation") end
  if journal.classify() ~= journal.STATUS.VALID_COMMITTED then
    error("classify() must still report VALID_COMMITTED after clear()")
  end
end

print("installer_journal_state_machine_test.lua: ok")
