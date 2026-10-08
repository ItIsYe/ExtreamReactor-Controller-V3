-- tests/auto_update_integrity_repair_test.lua
--
-- Der Auto-Updater prueft die installierten Dateien gegen ihre Pruefsummen
-- und installiert bei einer Abweichung neu -- aber nicht in einer Schleife.
--
-- Betreiberentscheidung 2026-10-08: Pruefsummen entscheiden, ob Dateien
-- noch genommen werden duerfen. installer/auto_update.lua ruft dafuer nach
-- einem Versions-Check ohne neue Fassung core/install_integrity.lua auf
-- (beim ersten Check nach dem Start, dann alle 6 h).
--
--   1. Dateien weichen ab, noch kein Versuch -> Reparatur (Quiesce +
--      Installer), der Versuch wird auf der Platte gemerkt
--   2. "Neustart" (Modul frisch geladen), Abweichung besteht weiter ->
--      KEINE zweite Reparatur innerhalb der Abklingzeit
--   3. Dateien passen -> keine Reparatur, Meldung "ok"
--
-- Gefahren wird die echte make_loop() mit simulierter Uhr. Der Installer-
-- Download schlaegt im Test fehl, damit nichts installiert wird; danach
-- startet der Updater den Rechner neu (os.reboot wird nur gezaehlt).

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local real = { print = print, os = os, fs = rawget(_G, 'fs'), http = rawget(_G, 'http'),
  parallel = rawget(_G, 'parallel'), dofile = dofile }

local ARMING_PATH = '/xreactor_config/remote_update.lua'
local RELEASE_PATH = '/xreactor/release.lua'
local REPAIR_STATE_PATH = '/xreactor_config/install_repair.lua'

local disk = {}           -- ueberlebt den "Neustart" zwischen den Laeufen
local now_s = 0           -- Weltuhr laeuft ueber Neustarts weiter

-- Faehrt einen frisch gestarteten Auto-Updater `seconds` lang.
--   integrity_result: was core/install_integrity.check() liefert
local function boot_and_run(seconds, integrity_result)
  local lines = {}
  local counters = { quiesce = 0, reboot = 0, installer_downloads = 0 }
  local boot_clock = 0
  local timers, next_id = {}, 0

  _G.print = function(msg) lines[#lines + 1] = tostring(msg) end
  _G.os = {
    startTimer = function(delay)
      next_id = next_id + 1
      timers[next_id] = boot_clock + (tonumber(delay) or 0)
      return next_id
    end,
    cancelTimer = function(id) timers[id] = nil end,
    pullEvent = function() return coroutine.yield() end,
    epoch = function() return now_s * 1000 end,
    clock = function() return boot_clock end,
    sleep = function() end,
    getComputerID = function() return 0 end,
    reboot = function() counters.reboot = counters.reboot + 1 end,
    date = real.os.date,
  }
  _G.fs = {
    exists = function(p) return disk[p] ~= nil end,
    open = function(p, mode)
      if mode == 'r' then
        if disk[p] == nil then return nil end
        return { readAll = function() return disk[p] end, close = function() end }
      end
      local buffer = ''
      return { write = function(c) buffer = buffer .. tostring(c) end, close = function() disk[p] = buffer end }
    end,
    delete = function(p) disk[p] = nil end,
  }
  _G.http = {
    get = function(url)
      if url:find('/xreactor/release.lua', 1, true) then
        return { getResponseCode = function() return 200 end,
          readAll = function() return 'return { manifest_version = 814 }\n' end, close = function() end }
      end
      counters.installer_downloads = counters.installer_downloads + 1
      return nil
    end,
  }
  _G.parallel = nil
  local integrity_module = assert(loadfile('xreactor/core/install_integrity.lua'))()
  integrity_module.check = function() return integrity_result end
  _G.dofile = function(path)
    if path == '/xreactor/core/update_handshake.lua' then
      return {
        STATE = { SAFE_OUTPUTS_APPLIED = 'S', RUNTIME_STOPPED = 'R', UPDATE_REQUESTED = 'U', QUIESCE_REQUESTED = 'Q' },
        peek_remote_update = function() return nil end,
        consume_remote_update = function() end,
        request_quiesce = function() counters.quiesce = counters.quiesce + 1; return true end,
        wait_for_runtime_stopped = function() return true end,
        reset = function() end,
      }
    end
    if path == '/xreactor/core/install_integrity.lua' then return integrity_module end
    error('unexpected dofile: ' .. tostring(path))
  end

  package.loaded['installer.auto_update'] = nil
  local auto_update = require('installer.auto_update')
  local co = coroutine.create(auto_update.make_loop(120, {}))
  local ok, err = coroutine.resume(co)
  assert(ok, err)
  for _ = 1, seconds do
    now_s = now_s + 1
    boot_clock = boot_clock + 1
    local due = {}
    for id, at in pairs(timers) do if at <= boot_clock then due[#due + 1] = id end end
    table.sort(due)
    for _, id in ipairs(due) do
      timers[id] = nil
      ok, err = coroutine.resume(co, 'timer', id)
      assert(ok, err)
    end
    ok, err = coroutine.resume(co, 'modem_message', 'back', 1, 1, {}, 1)
    assert(ok, err)
  end

  _G.print, _G.os, _G.fs, _G.http, _G.parallel, _G.dofile =
    real.print, real.os, real.fs, real.http, real.parallel, real.dofile
  local function count(pattern)
    local n = 0
    for _, line in ipairs(lines) do if line:find(pattern, 1, true) then n = n + 1 end end
    return n
  end
  for _, line in ipairs(lines) do
    assert_true(not line:find('Fehler abgefangen', 1, true), 'unerwarteter Fehler im Auto-Updater: ' .. line)
  end
  return counters, count
end

disk[ARMING_PATH] = 'return { enabled = true, auto_update = true }\n'
disk[RELEASE_PATH] = 'return { manifest_version = 814 }\n'

local bad = { ok = false, checked = 120, missing = {}, changed = { 'nodes/rt/main.lua' },
  manifest_id = 'manifest-v814', manifest_version = 814, payload_digest = 'abcdef12' }

-- ══ 1. Abweichung, noch kein Versuch: Reparatur ══════════════════════════
local counters, count = boot_and_run(200, bad)
assert_true(count('passen NICHT') >= 1, 'die Abweichung muss gemeldet werden')
assert_eq(count('Reparatur-Installation startet'), 1, 'genau eine Reparatur')
assert_eq(counters.quiesce, 1, 'die Reparatur fordert einen Quiesce an, wie ein Update')
assert_true(counters.installer_downloads >= 1, 'die Reparatur laedt den Installer')
assert_true(disk[REPAIR_STATE_PATH] ~= nil, 'der Versuch muss auf der Platte gemerkt werden')
assert_true(disk[REPAIR_STATE_PATH]:find('abcdef12', 1, true) ~= nil, 'gemerkt wird die Fassung')

-- ══ 2. Neustart, Abweichung besteht weiter: keine zweite Reparatur ════════
counters, count = boot_and_run(200, bad)
assert_eq(count('Reparatur-Installation startet'), 0,
  'innerhalb der Abklingzeit darf dieselbe Fassung nicht erneut repariert werden -- Schleifengefahr')
assert_eq(counters.quiesce, 0, 'kein Quiesce ohne Reparatur')
assert_true(count('schon versucht') >= 1, 'das Auslassen muss gemeldet werden')

-- ══ 3. Dateien passen ═════════════════════════════════════════════════════
counters, count = boot_and_run(200, { ok = true, checked = 120, missing = {}, changed = {},
  manifest_id = 'manifest-v814', payload_digest = 'abcdef12' })
assert_eq(counters.quiesce, 0, 'passende Dateien: kein Quiesce')
assert_true(count('Dateipruefung ok: 120 Dateien passen zu manifest-v814') >= 1, 'Meldung bei passenden Dateien')

print('ok auto_update_integrity_repair_test')
