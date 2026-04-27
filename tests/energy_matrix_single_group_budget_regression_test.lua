local now = 0
_G.os = {
  epoch = function() return now end
}

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local runtime_lib = require('nodes.energy.matrix_snapshot_runtime')

local calls = 0
local adapter = {
  getStored = function() calls = calls + 1 return 1 end,
  getCapacity = function() calls = calls + 1 return 2 end,
  getInput = function() calls = calls + 1 return 3 end,
  getOutput = function() calls = calls + 1 return 4 end
}

local rt = runtime_lib.new({
  config = {
    matrix_metric_poll_interval = 2,
    matrix_metric_call_budget = 4,
    matrix_metric_per_matrix_budget = 1,
    matrix_metric_time_budget_ms = 2000
  },
  get_groups = function()
    return {
      {
        key = 'matrix-1',
        representative = { name = 'm1', adapter = adapter },
        ports = { { name = 'm1', adapter = adapter } }
      }
    }
  end
})

now = 3000
local snapshot = rt:get_snapshot(0)
if calls < 4 then
  error('expected single matrix poll to read all metrics without artificial per-matrix throttling')
end
if snapshot.diag and snapshot.diag.throttled then
  error('expected no throttling for single-matrix sweep')
end

print('energy_matrix_single_group_budget_regression_test.lua: ok')
