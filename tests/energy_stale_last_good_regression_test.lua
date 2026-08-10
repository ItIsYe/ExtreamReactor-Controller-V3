package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local snapshot_runtime = require('nodes.energy.storage_snapshot_runtime')
local now = 1000
local failing = false
local adapter = {
  getStored = function() if failing then return nil, 'read failed' end return 100 end,
  getInput = function() if failing then return nil, 'read failed' end return 10 end,
  getOutput = function() if failing then return nil, 'read failed' end return 5 end,
  getCapacity = function() return 200 end,
}
local runtime = snapshot_runtime.new({
  now_ms = function() return now end,
  config = { capacity_interval_s = 5, status_interval = 5 },
  devices = { storages = { { id = 'S1', name = 'S1', adapter = adapter } } },
  utils = { deep_copy = function(v) return v end },
  record_error = function() end,
})

local good = runtime.sample_storage_stats(now)
assert(good.stale == false and good.total.stored == 100)
failing = true
for _ = 1, 4 do
  now = now + 100
  local stale = runtime.sample_storage_stats(now)
  assert(stale.total.stored == 100, 'last-good value should remain visible')
  assert(stale.stale == true, 'failed read must mark aggregate stale')
  assert(stale.stores[1].ok == false, 'failed store must be marked not ok')
end
now = now + 100
local backed_off = runtime.sample_storage_stats(now)
assert(backed_off.total.stored == 100, 'backoff keeps last-good value')
assert(backed_off.stale == true, 'backoff over failed device must remain stale')
assert(backed_off.stores[1].ok == false, 'backoff must not pretend the store recovered')
local reported = runtime.read_storage_stats({ max_age_ms = 10000 })
assert(reported.stale == true, 'read_storage_stats must propagate snapshot stale state')

local f = assert(io.open('xreactor/nodes/energy/status_payload.lua', 'r'))
local status_src = f:read('*a'); f:close()
assert(status_src:find('energy.data_stale', 1, true), 'ENERGY payload must publish data_stale')
assert(status_src:find('STALE_DATA', 1, true), 'ENERGY health must degrade on stale data')

print('energy_stale_last_good_regression_test.lua: ok')
