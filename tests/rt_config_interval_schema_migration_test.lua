package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer RT-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 5 "Altconfig-Migration und Schedulernachweis").
-- Vor diesem Fix blieb eine bestehende, persistierte config/rt.lua mit dem
-- historischen Default autonom.reactor_adjust_interval=5.0 (bzw.
-- reactor_adjust_interval_individual=1.0) fuer immer auf diesem Wert, da
-- beide gueltige Zahlen sind und die generische "type(...) ~= number"-
-- Normalisierung sie nie anfasste. Treibt die echte config_normalizer.lua
-- (require()-bares Modul ohne Boot-Seiteneffekte) direkt.

local config_normalizer = require('nodes.rt.config_normalizer')
local rt_default_config = require('nodes.rt.config')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function deep_copy(t)
  if type(t) ~= 'table' then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end

local defaults = rt_default_config
assert_true(type(defaults.version) == 'number' and defaults.version >= 5,
  'config.lua must have bumped its schema version for this migration to have a real target')
assert_eq(defaults.autonom.reactor_adjust_interval, 0.10, 'sanity: current default should be 0.10')
assert_eq(defaults.autonom.reactor_adjust_interval_individual, 0.10, 'sanity: current default should be 0.10')

-- 1. Ein alter, persistierter Config-Stand mit den historischen Default-
--    Werten (5.0/1.0) wird gezielt auf die neuen 0.10-Defaults migriert,
--    und die Schema-Version wird auf den aktuellen Stand angehoben.
do
  local cfg = { version = 4, autonom = { reactor_adjust_interval = 5.0, reactor_adjust_interval_individual = 1.0 } }
  local warnings = {}
  local changed = config_normalizer.migrate_schema_version(cfg, defaults, function(w) table.insert(warnings, w) end)

  assert_true(changed, 'migration must report a change when historical defaults are found')
  assert_eq(cfg.autonom.reactor_adjust_interval, 0.10, 'reactor_adjust_interval must migrate from the historical 5.0 default')
  assert_eq(cfg.autonom.reactor_adjust_interval_individual, 0.10, 'reactor_adjust_interval_individual must migrate from the historical 1.0 default')
  assert_eq(cfg.version, defaults.version, 'version must be bumped to the current schema version')
  assert_true(#warnings >= 2, 'migration should log what it changed')
end

-- 2. Ein bewusst vom Nutzer auf einen ANDEREN Wert gesetztes Intervall darf
--    NICHT blind ueberschrieben werden -- nur die historischen DEFAULT-
--    Werte sind das Migrationsziel, nicht jeder beliebige alte Wert.
do
  local cfg = { version = 4, autonom = { reactor_adjust_interval = 2.5, reactor_adjust_interval_individual = 0.75 } }
  local changed = config_normalizer.migrate_schema_version(cfg, defaults, function() end)

  assert_true(changed, 'the version bump alone still counts as a change')
  assert_eq(cfg.autonom.reactor_adjust_interval, 2.5, 'a deliberately customized value must not be overwritten')
  assert_eq(cfg.autonom.reactor_adjust_interval_individual, 0.75, 'a deliberately customized value must not be overwritten')
  assert_eq(cfg.version, defaults.version, 'version must still be bumped even when no interval needed migrating')
end

-- 3./4. Migration laeuft garantiert nur einmal: ein bereits auf dem
--    aktuellen Schema-Stand liegender Config-Stand (der Normalfall bei
--    jedem Boot NACH der ersten Migration, da main.lua das Ergebnis sofort
--    persistiert) loest keine erneute Aenderung mehr aus -- auch nicht,
--    wenn (aus welchem Grund auch immer) wieder ein Wert von 5.0/1.0
--    vorliegt, der DIESMAL absichtlich vom Nutzer gesetzt sein koennte.
do
  local cfg = deep_copy(defaults)
  cfg.autonom.reactor_adjust_interval = 5.0
  cfg.autonom.reactor_adjust_interval_individual = 1.0
  local changed = config_normalizer.migrate_schema_version(cfg, defaults, function() end)

  assert_true(not changed, 'a config already on the current schema version must not be touched again')
  assert_eq(cfg.autonom.reactor_adjust_interval, 5.0, 'once migrated past, a later user-set 5.0 must be respected (not re-migrated)')
  assert_eq(cfg.autonom.reactor_adjust_interval_individual, 1.0, 'once migrated past, a later user-set 1.0 must be respected (not re-migrated)')
end

-- 5. Ein Config-Stand ganz ohne version-Feld (aeltester denkbarer Bestand)
--    wird ebenfalls migriert (from_version faellt sicher auf 1 zurueck).
do
  local cfg = { autonom = { reactor_adjust_interval = 5.0 } }
  local changed = config_normalizer.migrate_schema_version(cfg, defaults, function() end)
  assert_true(changed)
  assert_eq(cfg.autonom.reactor_adjust_interval, 0.10)
  assert_eq(cfg.version, defaults.version)
end

-- 6. safety.measurement_grace_samples: derselbe Fall wie oben, nur eine
--    Schemastufe spaeter. Der Schluessel kam mit v6 neu dazu, und
--    core/utils.lua's migrate_config() fuellt fehlende Defaults nicht nur
--    ein, es PERSISTIERT sie auch -- eine Installation, die v6 schon
--    gesehen hat, traegt die damaligen 200 Takte (20 s) auf Platte, und
--    ein geaenderter Default waere dort nie angekommen. Mit v7 gilt die
--    Betreibervorgabe von 30 Minuten (18000 Takte).
do
  assert_eq(defaults.safety.measurement_grace_samples, 18000,
    'sanity: der aktuelle Default sind 30 Minuten bei 10 Hz')

  local warnings = {}
  local cfg = { version = 6, safety = { measurement_grace_samples = 200 } }
  local changed = config_normalizer.migrate_schema_version(cfg, defaults,
    function(w) table.insert(warnings, w) end)
  assert_true(changed, 'die Migration muss eine Aenderung melden')
  assert_eq(cfg.safety.measurement_grace_samples, 18000,
    'der historische Default 200 muss auf den neuen Wert migriert werden')
  assert_eq(cfg.version, defaults.version)
  assert_true(#warnings >= 1, 'und protokolliert werden')
end

do
  local cfg = { version = 6, safety = { measurement_grace_samples = 600 } }
  config_normalizer.migrate_schema_version(cfg, defaults, function() end)
  assert_eq(cfg.safety.measurement_grace_samples, 600,
    'ein bewusst gesetzter eigener Wert darf nicht ueberschrieben werden')
end

do
  local cfg = deep_copy(defaults)
  cfg.safety.measurement_grace_samples = 200
  local changed = config_normalizer.migrate_schema_version(cfg, defaults, function() end)
  assert_true(not changed, 'auf dem aktuellen Schemastand wird nicht erneut migriert')
  assert_eq(cfg.safety.measurement_grace_samples, 200,
    'ein danach vom Nutzer gesetztes 200 bleibt stehen')
end

-- 7. safety.*_trip_samples: die Entprellung der Sicherheitsgrenzen wird in
--    REGELTAKTEN gezaehlt, und der Takt ist mit dem 10-Hz-Umbau zehnmal
--    kuerzer geworden. Die historischen 3 Takte bedeuteten damit nur noch
--    300 ms -- drei zuckende Messwerte in Folge reichten fuer eine
--    Abschaltung. Mit v8 gilt 1 Sekunde (10 Takte).
do
  assert_eq(defaults.safety.temperature_trip_samples, 10,
    'sanity: der aktuelle Default ist 1 Sekunde bei 10 Hz')
  assert_eq(defaults.safety.coolant_trip_samples, 10)
  assert_eq(defaults.safety.coolant_invalid_grace_samples, 10)

  local warnings = {}
  local cfg = { version = 7, safety = {
    temperature_trip_samples = 3,
    coolant_trip_samples = 3,
    coolant_invalid_grace_samples = 3,
  } }
  local changed = config_normalizer.migrate_schema_version(cfg, defaults,
    function(w) table.insert(warnings, w) end)
  assert_true(changed, 'die Migration muss eine Aenderung melden')
  assert_eq(cfg.safety.temperature_trip_samples, 10)
  assert_eq(cfg.safety.coolant_trip_samples, 10)
  assert_eq(cfg.safety.coolant_invalid_grace_samples, 10)
  assert_eq(cfg.version, defaults.version)
  assert_true(#warnings >= 3, 'jeder migrierte Schluessel wird protokolliert')
end

do
  -- Ein bewusst gesetzter eigener Wert bleibt stehen -- auch ein
  -- ABSICHTLICH schaerferer.
  local cfg = { version = 7, safety = {
    temperature_trip_samples = 2,
    coolant_trip_samples = 40,
    coolant_invalid_grace_samples = 3,
  } }
  config_normalizer.migrate_schema_version(cfg, defaults, function() end)
  assert_eq(cfg.safety.temperature_trip_samples, 2,
    'ein eigener, schaerferer Wert darf nicht aufgeweicht werden')
  assert_eq(cfg.safety.coolant_trip_samples, 40,
    'ein eigener, traegerer Wert bleibt ebenfalls stehen')
  assert_eq(cfg.safety.coolant_invalid_grace_samples, 10,
    'nur der historische Default wird angehoben')
end

do
  local cfg = deep_copy(defaults)
  cfg.safety.temperature_trip_samples = 3
  local changed = config_normalizer.migrate_schema_version(cfg, defaults, function() end)
  assert_true(not changed, 'auf dem aktuellen Schemastand wird nicht erneut migriert')
  assert_eq(cfg.safety.temperature_trip_samples, 3,
    'ein danach vom Nutzer gesetztes 3 bleibt stehen')
end

print('rt_config_interval_schema_migration_test.lua: ok')
