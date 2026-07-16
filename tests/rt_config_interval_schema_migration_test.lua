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

print('rt_config_interval_schema_migration_test.lua: ok')
