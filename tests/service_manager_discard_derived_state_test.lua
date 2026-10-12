-- tests/service_manager_discard_derived_state_test.lua
--
-- Ein Dienst, der wiederholt an seinem eigenen abgeleiteten Zustand
-- scheitert, bekommt Gelegenheit, ihn zu verwerfen.
--
-- Bis v814 wiederholte services/service_manager.lua's schedule_retry() einen
-- scheiternden tick() nur, mit Backoff. Ein Dienst, der sich ein Handle
-- gemerkt hatte, das nicht mehr gilt, scheiterte daran bis zum Neustart.
--
--   1. Dienst mit gemerktem, totem Handle und discard_derived_state():
--      nach 3 Fehlschlaegen in Folge wird verworfen, der naechste Versuch
--      holt ein frisches Handle und laeuft wieder
--   2. verworfen wird je 3 Fehlschlaege in Folge, nicht bei jedem
--   3. ein Dienst ohne die Methode verhaelt sich wie bisher
--   4. wirft das Verwerfen, laeuft der Manager weiter; "Terminated" geht durch
--   5. Fehler in init() verwerfen nichts (init laeuft ohnehin erneut)
--   6. die Fehlerzeile nennt erst den Dienst, dann die Stufe
--   7. matrix_sampling_service verwirft ueber runtime:invalidate()

local now = 0
local logs = {}

_G.os = {
  epoch = function() return now end,
  clock = function() return now / 1000 end,
}

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local utils = require('core.utils')
utils.log = function(prefix, message, level)
  logs[#logs + 1] = { prefix = prefix, message = message, level = level }
end
local function count_logs(needle)
  local n = 0
  for _, entry in ipairs(logs) do
    if tostring(entry.message):find(needle, 1, true) then n = n + 1 end
  end
  return n
end

local service_manager = require('services.service_manager')

-- Laeuft den Manager `seconds` Sekunden, ein tick je Sekunde (der Backoff
-- ist hoechstens 1 s, siehe backoff_cap_s unten).
local function run(manager, seconds)
  for _ = 1, seconds do
    now = now + 1000
    manager:tick(1)
  end
end

-- ══ 1./2. Totes Handle, das verworfen werden kann ═════════════════════════
local generation = 0           -- jedes frische Handle bekommt eine neue Nummer
local dead_generation = 1      -- das erste Handle ist tot (Chunk neu geladen)
local svc = { name = 'SAMPLER', handle = nil, ok_ticks = 0, discards = {} }
function svc:tick()
  if not self.handle then
    generation = generation + 1
    self.handle = { gen = generation }
  end
  if self.handle.gen == dead_generation then error('No peripheral attached') end
  self.ok_ticks = self.ok_ticks + 1
end
function svc:discard_derived_state(stage, err, failures)
  self.discards[#self.discards + 1] = { stage = stage, err = tostring(err), failures = failures }
  self.handle = nil
end

local manager = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
manager:add(svc)
manager:init()

run(manager, 2)
assert_eq(#svc.discards, 0, 'nach 2 Fehlschlaegen wird noch nichts verworfen')
assert_eq(svc.ok_ticks, 0, 'mit totem Handle laeuft der Dienst nicht')
run(manager, 1)
assert_eq(#svc.discards, 1, 'nach 3 Fehlschlaegen in Folge wird verworfen')
assert_eq(svc.discards[1].stage, 'tick', 'Stufe')
assert_eq(svc.discards[1].failures, 3, 'Fehlschlaege in Folge')
assert_true(svc.discards[1].err:find('No peripheral attached', 1, true) ~= nil, 'der Fehler wird mitgegeben')
run(manager, 3)
assert_true(svc.ok_ticks >= 2, 'nach dem Verwerfen holt der Dienst ein frisches Handle und laeuft wieder')
assert_eq(count_logs('abgeleiteten Zustand verworfen'), 1, 'das Verwerfen steht im Log')
local st = manager.service_state[svc]
assert_eq(st.retries, 0, 'nach dem ersten Erfolg ist die Fehlerserie vorbei')
assert_eq(st.total_failures, 3, 'die Gesamtzahl der Fehlschlaege bleibt sichtbar')
assert_eq(st.discards, 1, 'die Zahl der Verwerfungen bleibt sichtbar')

-- 2. Bleibt der Dienst kaputt, wird je 3 Fehlschlaege verworfen.
local always = { name = 'BROKEN', discards = 0 }
function always:tick() error('kaputt') end
function always:discard_derived_state() self.discards = self.discards + 1 end
local m2 = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
m2:add(always)
m2:init()
run(m2, 9)
assert_eq(always.discards, 3, '9 Fehlschlaege in Folge -> 3 Verwerfungen')

-- ══ 3. Ohne die Methode wie bisher ════════════════════════════════════════
local plain = { name = 'PLAIN', ticks = 0 }
function plain:tick() self.ticks = self.ticks + 1; error('kaputt') end
local m3 = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
m3:add(plain)
m3:init()
run(m3, 6)
assert_eq(plain.ticks, 6, 'ein Dienst ohne die Methode wird weiter wiederholt')
assert_eq(m3.service_state[plain].discards, 0, 'und es wird nichts verworfen')

-- ══ 4. Werfendes Verwerfen; Terminated geht durch ═════════════════════════
local bad_discard = { name = 'BADDISCARD', ticks = 0 }
function bad_discard:tick() self.ticks = self.ticks + 1; error('kaputt') end
function bad_discard:discard_derived_state() error('verwerfen kaputt') end
local m4 = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
m4:add(bad_discard)
m4:init()
local ok, err = pcall(run, m4, 4)
assert_true(ok, 'ein werfendes Verwerfen darf den Manager nicht abbrechen: ' .. tostring(err))
assert_eq(bad_discard.ticks, 4, 'der Dienst wird weiter wiederholt')
assert_true(count_logs('verwerfen des abgeleiteten Zustands fehlgeschlagen') >= 1, 'das Scheitern steht im Log')

local term = { name = 'TERM' }
function term:tick() error('kaputt') end
function term:discard_derived_state() error('Terminated') end
local m5 = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
m5:add(term)
m5:init()
ok, err = pcall(run, m5, 3)
assert_true(not ok and tostring(err):find('Terminated', 1, true) ~= nil,
  'Terminated aus dem Verwerfen muss durchgereicht werden (Strg+T)')

-- ══ 5. init()-Fehler verwerfen nichts ═════════════════════════════════════
local init_fail = { name = 'INITFAIL', discards = 0 }
function init_fail:init() error('init kaputt') end
function init_fail:tick() end
function init_fail:discard_derived_state() self.discards = self.discards + 1 end
local m6 = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
m6:add(init_fail)
m6:init()
run(m6, 6)
assert_eq(init_fail.discards, 0, 'Fehler in init() verwerfen nichts')

-- ══ 6. Die Fehlerzeile ════════════════════════════════════════════════════
assert_true(count_logs('Service SAMPLER failed (tick)') >= 1,
  'die Fehlerzeile nennt erst den Dienst, dann die Stufe')
assert_eq(count_logs('Service tick failed (SAMPLER)'), 0, 'nicht mehr vertauscht')

-- ══ 7. matrix_sampling_service ════════════════════════════════════════════
do
  local sampler_lib = require('services.matrix_sampling_service')
  local invalidated = 0
  local runtime = {
    tick = function() error('matrix kaputt') end,
    invalidate = function() invalidated = invalidated + 1 end,
  }
  local sampler = sampler_lib.new({ name = 'MATRIX_SAMPLE', interval = 0.1, runtime = runtime })
  local m7 = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
  m7:add(sampler)
  m7:init()
  run(m7, 3)
  assert_eq(invalidated, 1, 'nach 3 Fehlschlaegen verwirft MATRIX_SAMPLE die Caches der Runtime')

  -- Eine Runtime ohne invalidate() (STORAGE_SAMPLE) bleibt unberuehrt.
  local plain_sampler = sampler_lib.new({ name = 'STORAGE_SAMPLE', interval = 0.1,
    runtime = { tick = function() error('storage kaputt') end } })
  local m8 = service_manager.new({ log_prefix = 'TEST', backoff_base_s = 1, backoff_cap_s = 1 })
  m8:add(plain_sampler)
  m8:init()
  ok, err = pcall(run, m8, 3)
  assert_true(ok, 'ohne invalidate() darf das Verwerfen nicht scheitern: ' .. tostring(err))
end

print('ok service_manager_discard_derived_state_test')
