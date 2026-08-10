package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local matrix_runtime_lib = require('nodes.energy.matrix_snapshot_runtime')
local storage_runtime_lib = require('nodes.energy.storage_snapshot_runtime')
local utils = require('core.utils')
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local now = 1000
local matrix_fail = false
local adapter = {
  getStored = function() if matrix_fail then return nil, 'stored failed' end; return 100 end,
  getCapacity = function() if matrix_fail then return nil, 'capacity failed' end; return 1000 end,
  getInput = function() if matrix_fail then return nil, 'input failed' end; return 5 end,
  getOutput = function() if matrix_fail then return nil, 'output failed' end; return 6 end,
  features = {},
}
local groups = {
  { key = 'matrix-1', representative = { name = 'matrix_0', adapter = adapter }, ports = {} }
}
local matrix = matrix_runtime_lib.new({
  config = {
    matrix_metric_poll_interval = 1,
    matrix_metric_call_budget = 4,
    matrix_metric_per_matrix_budget = 4,
    matrix_metric_time_budget_ms = 10000,
    matrix_sample_min_tick_spacing_ms = 1,
  },
  get_groups = function() return groups end,
})

matrix:tick(now)
local first = matrix:get_snapshot(100000)
assert_true(first.stale == false, 'first complete matrix sample should be fresh')
assert_true(first.matrices[1].stored == 100 and first.matrices[1].capacity == 1000,
  'first matrix values should be recorded')

matrix_fail = true
now = 3000
matrix:tick(now)
local degraded = matrix:get_snapshot(100000)
assert_true(degraded.matrices[1].stored == 100,
  'failed read should retain last-good value for stable rendering')
assert_true(degraded.matrices[1].status == 'DEGRADED',
  'freshly failed read with recent last-good value should be degraded')

now = 7000
matrix:tick(now)
local stale = matrix:get_snapshot(100000)
assert_true(stale.matrices[1].stale == true,
  'repeated failed reads must not refresh last-good measurement age')
assert_true(stale.stale == true,
  'top-level matrix snapshot must propagate stale measurement state')

-- Non-matrix storage: capacity failures are part of the freshness contract.
now = 1000
local capacity_fail = false
local storage_adapter = {
  getStored = function() return 50 end,
  getCapacity = function() if capacity_fail then return nil, 'capacity failed' end; return 500 end,
  getInput = function() return 1 end,
  getOutput = function() return 2 end,
}
local storage = storage_runtime_lib.new({
  now_ms = function() return now end,
  config = { capacity_interval_s = 1, status_interval = 5 },
  devices = { storages = { { id = 's1', name = 'cell_0', adapter = storage_adapter } } },
  utils = utils,
})
storage.sample_storage_stats(now)
assert_true(storage.read_storage_stats({ max_age_ms = 100000 }).stale == false,
  'initial storage capacity sample should be fresh')
capacity_fail = true
now = 3000
storage.sample_storage_stats(now)
local storage_failed = storage.read_storage_stats({ max_age_ms = 100000 })
assert_true(storage_failed.stale == true,
  'capacity read failure must mark storage data stale')
assert_true(storage_failed.stores[1].ok == false,
  'capacity read failure must mark individual storage degraded')

print('energy_failed_reads_stay_stale_test.lua: ok')
