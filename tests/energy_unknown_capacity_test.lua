package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: eine unbekannte Speicherkapazitaet wurde zu scheinbar
-- frischen 100 % Fuellstand.
--
-- read_metric() machte aus einer FEHLENDEN Methode wie aus einem
-- nil-Rueckgabewert beides "0, kein Fehler". Anschliessend setzte der
-- Kapazitaets-Rueckfall die Kapazitaet auf den INHALT. Ergebnis:
-- stored=1000, capacity=1000, Fuellstand 100 %, stale=false, ok=true --
-- nicht von einem echten, vollen Speicher zu unterscheiden.
--
-- Kein Randfall: adapters/energy_storage.lua gibt fuer den passiven
-- ER2-Reaktorport ausdruecklich capacity = nil zurueck, weil dieses Geraet
-- seine Kapazitaet nur in getEnergyStats() fuehrt. Und der MASTER rechnet
-- aus stored/capacity seinen Lastabwurf (master/runtime_ops_profile.lua:
-- energy_pct = stored / capacity * 100).

local runtime_lib = require('nodes.energy.storage_snapshot_runtime')
local utils = require('core.utils')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

local NOW = 1000000
local function sample(storages)
  local errors = {}
  local rt = runtime_lib.new({
    now_ms = function() return NOW end,
    config = { capacity_interval_s = 5, status_interval = 5 },
    devices = { storages = storages },
    utils = utils,
    record_error = function(k, e) errors[#errors + 1] = tostring(k) end,
  })
  return rt.sample_storage_stats(NOW), errors, rt
end

local function adapter(stored, capacity_fn)
  return { getStored = function() return stored end,
           getCapacity = capacity_fn,
           getInput = function() return 0 end,
           getOutput = function() return 0 end }
end

-- 1. Fehlende Kapazitaetsmethode (ER2-Reaktorport): keine erfundene Kapazitaet.
do
  local snap = sample({ { id = 'port', name = 'port', adapter = adapter(1000, nil) } })
  local s = snap.stores[1]
  assert_eq(s.stored, 1000, 'der Inhalt bleibt der echte Messwert')
  assert_true(s.capacity ~= 1000, 'die Kapazitaet darf NICHT der Inhalt sein -- das war der Fehler')
  assert_eq(s.capacity, 0)
  assert_eq(s.capacity_known, false, 'und sie muss als unbekannt ausgewiesen sein')
  assert_eq(snap.capacity_complete, false)
  assert_eq(snap.capacity_unknown, 1)
end

-- 2. Methode vorhanden, liefert aber nil ohne Fehler: genauso.
do
  local snap = sample({ { id = 'c', name = 'c', adapter = adapter(1000, function() return nil end) } })
  assert_eq(snap.stores[1].capacity_known, false)
  assert_true(snap.stores[1].capacity ~= 1000)
end

-- 3. Ein echter Lesefehler bleibt ein Fehler und markiert stale.
do
  local snap, errors = sample({ { id = 'c', name = 'c',
    adapter = adapter(1000, function() return nil, 'peripheral missing' end) } })
  assert_eq(snap.stale, true, 'ein Lesefehler markiert den Abzug weiterhin als stale')
  assert_eq(snap.stores[1].ok, false)
  assert_true(#errors >= 1, 'und wird gemeldet')
end

-- 4. Der Normalfall bleibt vollstaendig unveraendert.
do
  local snap = sample({ { id = 'c', name = 'c', adapter = adapter(1000, function() return 4000 end) } })
  local s = snap.stores[1]
  assert_eq(s.stored, 1000); assert_eq(s.capacity, 4000)
  assert_eq(s.capacity_known, true)
  assert_eq(snap.capacity_complete, true)
  assert_eq(snap.capacity_unknown, 0)
  assert_eq(snap.total.stored, 1000); assert_eq(snap.total.capacity, 4000)
end

-- 5. Der Kern: Zaehler und Nenner nur GEMEINSAM. Ein Speicher ohne
--    bekannte Kapazitaet darf seinen Inhalt nicht in einen Quotienten
--    einbringen, zu dem er keinen Nenner beitraegt -- sonst waere der
--    Fuellstand genauso verfaelscht wie vorher, nur in die andere Richtung.
do
  local snap = sample({
    { id = 'gut',      name = 'gut',      adapter = adapter(1000, function() return 4000 end) },
    { id = 'unbekannt',name = 'unbekannt',adapter = adapter(9000, nil) },
  })
  assert_eq(snap.total.capacity, 4000, 'nur die bekannte Kapazitaet zaehlt in den Nenner')
  assert_eq(snap.total.stored, 1000, 'und nur der zugehoerige Inhalt in den Zaehler')
  assert_eq(snap.total.stored / snap.total.capacity, 0.25,
    'der Fuellstand des abgedeckten Teils muss stimmen')
  assert_eq(snap.total.stored_all, 10000,
    'der wahre Gesamtinhalt geht trotzdem nicht verloren')
  assert_eq(snap.capacity_unknown, 1)
  assert_eq(snap.capacity_complete, false)
end

-- 6. Die Abdeckung steht auch im gelesenen Ergebnis, nicht nur im Abzug.
do
  local _, _, rt = sample({
    { id = 'gut',      name = 'gut',      adapter = adapter(1000, function() return 4000 end) },
    { id = 'unbekannt',name = 'unbekannt',adapter = adapter(9000, nil) },
  })
  local out = rt.read_storage_stats({ max_age_ms = 60000 })
  assert_eq(out.capacity_complete, false, 'ein Verbraucher muss die Luecke sehen koennen')
  assert_eq(out.capacity_unknown, 1)
  assert_eq(out.stored, 1000); assert_eq(out.capacity, 4000)
  assert_eq(out.stored_all, 10000)
end

print('energy_unknown_capacity_test.lua: ok')
