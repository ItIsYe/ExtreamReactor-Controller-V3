package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local normalizer = require('nodes.fuel.config_normalizer')
local utils = require('core.utils')
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local defaults = {
  role = 'FUEL-NODE', node_id = 'FUEL-1', heartbeat_interval = 2,
  status_interval = 5, channels = { control = 6500, status = 6501 }, comms = {},
  storage_bus = 'meBridge_0', minimum_reserve = 32, target = 32,
  logistics = {
    enabled = false, interval = 5, discovery_interval = 60, max_per_cycle = 64,
    me_bridge = 'me_bridge', export_chest = 'chest_0', reactors = {}, waste = {}, redstone_tree = {},
    valve_open_ms = 2000, sources = {}, destinations = {}, routes = {}
  }
}

local warnings = {}
local cfg = utils.deep_copy(defaults)
cfg.logistics.enabled = true
cfg.logistics.reactors = {
  { name = 'A', fill_amount = 64, min_in_me = 32 }
}
normalizer.normalize(cfg, defaults, function(w) warnings[#warnings + 1] = w end, utils)
assert_true(cfg.logistics.enabled == false,
  'missing reactor_id must disable active logistics instead of always-supply')

local saw_id_warning = false
for _, w in ipairs(warnings) do
  if tostring(w):find('missing reactor_id', 1, true) then saw_id_warning = true end
end
assert_true(saw_id_warning, 'operator must receive a reactor_id warning')

warnings = {}
cfg = utils.deep_copy(defaults)
cfg.logistics.enabled = true
cfg.logistics.reactors = {
  { reactor_id = 'node-1:REACTOR-abcd',
    request_below = 1.2, fill_amount = -5, min_in_me = -1 }
}
normalizer.normalize(cfg, defaults, function(w) warnings[#warnings + 1] = w end, utils)
assert_true(cfg.logistics.enabled == false,
  'out-of-range thresholds/amounts must fail closed')

warnings = {}
cfg = utils.deep_copy(defaults)
cfg.logistics.enabled = true
cfg.logistics.export_chest = nil
cfg.logistics.reactors = {
  { reactor_id = 'node-1:REACTOR-abcd',
    request_below = 0.25, fill_amount = 64, min_in_me = 32 }
}
normalizer.normalize(cfg, defaults, function(w) warnings[#warnings + 1] = w end, utils)
assert_true(cfg.logistics.enabled == false,
  'missing export_chest must disable active logistics (shared hand-off point missing)')

warnings = {}
cfg = utils.deep_copy(defaults)
cfg.logistics.enabled = true
cfg.logistics.reactors = {
  { reactor_id = 'node-1:REACTOR-abcd',
    request_below = 0.25, fill_amount = 64, min_in_me = 32 }
}
normalizer.normalize(cfg, defaults, function(w) warnings[#warnings + 1] = w end, utils)
assert_true(cfg.logistics.enabled == true, 'valid logistics config must remain enabled')

print('fuel_config_fail_closed_test.lua: ok')
