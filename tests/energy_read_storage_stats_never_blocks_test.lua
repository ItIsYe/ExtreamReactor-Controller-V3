-- read_storage_stats() wird ausschliesslich vom Heartbeat-Thread aufgerufen
-- (TELEMETRY/UI via build_status_payload), der laut Architektur (siehe
-- nodes/energy/main.lua) niemals blockierend auf Peripherie zugreifen darf.
-- Nur der separate Matrix-Thread (STORAGE_SAMPLE-Service) darf
-- sample_storage_stats() aufrufen. read_storage_stats() darf deshalb NIE
-- selbst sample_storage_stats() ausloesen, auch wenn der zwischengespeicherte
-- Snapshot laengst veraltet ist -- ein zu alter Snapshot wird stattdessen
-- nur als stale=true durchgereicht.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local snapshot_runtime = require('nodes.energy.storage_snapshot_runtime')
local now = 1000

local blocking_calls = 0
local adapter = {
  -- Wuerde read_storage_stats() faelschlich sample_storage_stats()
  -- ausloesen, wuerde dieser "Peripherie-Call" hier mitgezaehlt werden.
  getStored = function() blocking_calls = blocking_calls + 1; return 100 end,
  getInput = function() blocking_calls = blocking_calls + 1; return 10 end,
  getOutput = function() blocking_calls = blocking_calls + 1; return 5 end,
  getCapacity = function() blocking_calls = blocking_calls + 1; return 200 end,
}
local runtime = snapshot_runtime.new({
  now_ms = function() return now end,
  config = { capacity_interval_s = 5, status_interval = 5 },
  devices = { storages = { { id = 'S1', name = 'S1', adapter = adapter } } },
  utils = { deep_copy = function(v) return v end },
  record_error = function() end,
})

-- Kein sample_storage_stats() wurde je aufgerufen -- der Snapshot ist von
-- Anfang an "veraltet" (ts=0). read_storage_stats() darf trotzdem keinen
-- einzigen Peripherie-Call ausloesen.
local reported = runtime.read_storage_stats({ max_age_ms = 1 })
assert(blocking_calls == 0, 'read_storage_stats() must never call the storage adapter directly, got ' .. tostring(blocking_calls) .. ' calls')
assert(reported.stale == true, 'an unsampled/too-old snapshot must be reported as stale')
assert(reported.stored == 0, 'an unsampled snapshot must report zero, not silently sample')

-- Matrix-Thread sampelt regulaer -- danach liefert read_storage_stats()
-- echte Werte, ohne selbst noch einmal auf die Peripherie zuzugreifen.
runtime.sample_storage_stats(now)
local calls_after_sample = blocking_calls
now = now + 100000 -- weit ueber jedem realistischen max_age_ms
local stale_reported = runtime.read_storage_stats({ max_age_ms = 1 })
assert(blocking_calls == calls_after_sample, 'read_storage_stats() must not re-sample even when the cached snapshot is far too old')
assert(stale_reported.stale == true, 'a far-too-old snapshot must be reported as stale')
assert(stale_reported.stored == 100, 'the last real sample must still be returned, just flagged stale')

print('energy_read_storage_stats_never_blocks_test.lua: ok')
