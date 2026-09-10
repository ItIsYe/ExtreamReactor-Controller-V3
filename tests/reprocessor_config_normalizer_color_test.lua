package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for config_normalizer.lua's target color validation
-- (added alongside the Sorter-color routing rewrite): a valid color is
-- normalized to uppercase, an invalid/missing one is warned about but left
-- in place (feed_router.lua skips it at runtime rather than the normalizer
-- silently dropping/renaming the target).

package.loaded['adapters.logistical_sorter'] = nil
package.loaded['nodes.reprocessor.config_normalizer'] = nil
package.loaded['core.non_rt_config'] = package.loaded['core.non_rt_config'] or nil

_G.peripheral = { isPresent = function() return false end }

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local utils = require('core.utils')
local config_normalizer = require('nodes.reprocessor.config_normalizer')

local defaults = {
  version = 1, role = 'REPROCESSOR-NODE', node_id = 'REPROC-1',
  debug_logging = false, reset_log_on_start = true, buffers = { 'chemical_tank_0' },
  heartbeat_interval = 2, discovery_interval = 15, status_interval = 5,
  comms = { ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0 },
  channels = { control = 6500, status = 6501 },
}

local warnings = {}
local function add_warning(msg) warnings[#warnings + 1] = msg end

local config = {
  version = 1, role = 'REPROCESSOR-NODE', node_id = 'REPROC-1',
  debug_logging = false, reset_log_on_start = true, buffers = { 'chemical_tank_0' },
  heartbeat_interval = 2, discovery_interval = 15, status_interval = 5,
  comms = { ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0 },
  feed = {
    enabled = true, me_bridge = 'me_bridge', sorter = 'logistical_sorter_0',
    export_inlet = 'mekanism:logistical_transporter_0', waste_item = 'bigreactors:cyanite_ingot',
    feed_amount = 2, interval_min_s = 20, interval_max_s = 60, discovery_interval = 60,
    targets = {
      { label = 'Reprocessor A', color = 'aqua' },     -- valid, lowercase -> must be uppercased
      { label = 'Reprocessor B', color = 'NOT_A_COLOR' }, -- invalid -> warn, left in place
      { label = 'Reprocessor C' },                      -- missing color -> warn, left in place
    },
    chest = { enabled = true, target = 'chest_0' },
  },
}

config_normalizer.normalize(config, defaults, add_warning, utils)

assert_eq(config.feed.targets[1].color, 'AQUA', 'a valid lowercase color must be normalized to uppercase')

local found_b, found_c = false, false
for _, w in ipairs(warnings) do
  if w:find('targets%[2%]') then found_b = true end
  if w:find('targets%[3%]') then found_c = true end
end
assert_eq(found_b, true, 'an invalid color must produce a warning naming targets[2]')
assert_eq(found_c, true, 'a missing color must produce a warning naming targets[3]')
assert_eq(config.feed.targets[2].color, 'NOT_A_COLOR', 'an invalid color is left in place, not silently rewritten')
assert_eq(config.feed.targets[3].color, nil, 'a missing color stays nil, not defaulted to some color')

assert_eq(config.feed.chest.enabled, true, 'chest.enabled must pass through unchanged when already valid')
assert_eq(config.feed.chest.target, 'chest_0', 'chest.target must pass through unchanged when already valid')

-- An enabled chest with no target peripheral is warned about but left in
-- place, exactly like a colorless target -- feed_router.lua skips it at
-- runtime rather than the normalizer silently inventing a default.
local config_bad_chest = {
  version = 1, role = 'REPROCESSOR-NODE', node_id = 'REPROC-1',
  debug_logging = false, reset_log_on_start = true, buffers = { 'chemical_tank_0' },
  heartbeat_interval = 2, discovery_interval = 15, status_interval = 5,
  comms = { ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0 },
  channels = { control = 6500, status = 6501 },
  feed = { targets = {}, chest = { enabled = true, target = nil } },
}
local warnings_chest = {}
config_normalizer.normalize(config_bad_chest, defaults, function(msg) warnings_chest[#warnings_chest + 1] = msg end, utils)
local found_chest_warning = false
for _, w in ipairs(warnings_chest) do
  if w:find('feed.chest') then found_chest_warning = true end
end
assert_eq(found_chest_warning, true, 'an enabled chest without a target must produce a dedicated warning')
assert_eq(config_bad_chest.feed.chest.target, nil, 'a missing chest target stays nil, not defaulted to some peripheral')

-- A disabled/absent chest must not warn at all.
local config_no_chest = { feed = { targets = {} } }
local warnings_none = {}
config_normalizer.normalize(config_no_chest, defaults, function(msg) warnings_none[#warnings_none + 1] = msg end, utils)
assert_eq(config_no_chest.feed.chest.enabled, false, 'chest defaults to disabled when absent')
for _, w in ipairs(warnings_none) do
  assert_eq(w:find('feed.chest') == nil, true, 'a disabled chest must never produce a chest warning')
end

-- export_inlet/sorter defaults apply when missing.
local config2 = { feed = { targets = {} } }
config_normalizer.normalize(config2, defaults, function() end, utils)
assert_eq(config2.feed.sorter, 'logistical_sorter_0')
assert_eq(config2.feed.export_inlet, 'mekanism:logistical_transporter_0')

print('reprocessor_config_normalizer_color_test.lua: ok')
