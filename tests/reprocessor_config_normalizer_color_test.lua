package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression coverage for config_normalizer.lua's target color validation
-- (added alongside the Sorter-color routing rewrite): a valid color is
-- normalized to uppercase, an invalid/missing one is warned about but left
-- in place (feed_router.lua skips it at runtime rather than the normalizer
-- silently dropping/renaming the target). Also covers the sorter/
-- sorter_chest "missing while targets are configured" warnings (2026-09-17
-- rebuild: no config.buffers/ZUSATZ-KISTE anymore, exactly one shared
-- Sorter-Kiste).

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
  debug_logging = false, reset_log_on_start = true,
  heartbeat_interval = 2, discovery_interval = 15, status_interval = 5,
  comms = { ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0 },
  channels = { control = 6500, status = 6501 },
}

local warnings = {}
local function add_warning(msg) warnings[#warnings + 1] = msg end

local config = {
  version = 1, role = 'REPROCESSOR-NODE', node_id = 'REPROC-1',
  debug_logging = false, reset_log_on_start = true,
  heartbeat_interval = 2, discovery_interval = 15, status_interval = 5,
  comms = { ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0 },
  feed = {
    enabled = true, me_bridge = 'me_bridge', sorter = 'logistical_sorter_0', sorter_chest = 'sorter_chest_0',
    waste_item = 'bigreactors:cyanite_ingot',
    feed_amount = 2, interval_min_s = 20, interval_max_s = 60, discovery_interval = 60,
    targets = {
      { label = 'Reprocessor A', color = 'aqua' },     -- valid, lowercase -> must be uppercased
      { label = 'Reprocessor B', color = 'NOT_A_COLOR' }, -- invalid -> warn, left in place
      { label = 'Reprocessor C' },                      -- missing color -> warn, left in place
      -- Saved under a name removed from adapters/logistical_sorter.lua's
      -- COLORS by the 2026-09-17 fix (confirmed against the operator's
      -- real sorter) -- must be migrated to its replacement, not treated
      -- as invalid: an update must never silently break/lose an
      -- already-configured route.
      { label = 'Reprocessor D', color = 'DARK_BLUE' },
      { label = 'Reprocessor E', color = 'bright_pink' }, -- lowercase legacy name too
    },
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

assert_eq(config.feed.targets[4].color, 'BLUE', 'a legacy DARK_BLUE must be migrated to its current replacement BLUE')
assert_eq(config.feed.targets[5].color, 'PINK', 'a legacy bright_pink must be migrated to its current replacement PINK (case-insensitive)')
local found_d_migration = false
for _, w in ipairs(warnings) do
  if w:find('targets%[4%]') and w:find('migrated') then found_d_migration = true end
end
assert_eq(found_d_migration, true, 'a legacy color migration must produce a "migrated" warning naming targets[4], not an "invalid" one')

-- With sorter AND sorter_chest already configured, neither warning fires.
for _, w in ipairs(warnings) do
  assert_eq(w:find('sorter_chest') == nil, true, 'sorter_chest is already configured, must not warn')
  assert_eq(w:find('feed.sorter fehlt') == nil, true, 'sorter is already configured, must not warn')
end

-- sorter/sorter_chest stay nil when missing -- no fabricated placeholder
-- default (2026-09-17 rebuild: previously sorter defaulted to
-- "logistical_sorter_0", a name that never existed in the real build).
local config2 = { feed = { targets = {} } }
config_normalizer.normalize(config2, defaults, function() end, utils)
assert_eq(config2.feed.sorter, nil, 'sorter must stay nil when missing, not default to a placeholder name')
assert_eq(config2.feed.sorter_chest, nil, 'sorter_chest must stay nil when missing')

-- With Reprocessor targets actually configured but no Sorter or Sorter-
-- Kiste chosen yet, both must warn explicitly (mirrors FUEL's logistics.
-- export_chest "missing; unsafe/unconfigured" warning), not stay silent
-- behind a made-up placeholder default.
local config3 = {
  feed = { targets = { { label = 'Reprocessor A', color = 'RED' } } },
}
local warnings3 = {}
config_normalizer.normalize(config3, defaults, function(msg) warnings3[#warnings3 + 1] = msg end, utils)
local found_sorter_chest_warning, found_sorter_warning = false, false
for _, w in ipairs(warnings3) do
  if w:find('sorter_chest') then found_sorter_chest_warning = true end
  if w:find('feed.sorter fehlt') then found_sorter_warning = true end
end
assert_eq(found_sorter_chest_warning, true, 'targets configured without any Sorter-Kiste must produce a dedicated warning')
assert_eq(found_sorter_warning, true, 'targets configured without any Sorter must produce a dedicated warning')

-- No targets configured at all -- missing sorter/sorter_chest must not
-- warn (nothing to feed yet, matching FUEL's own gate on #reactors > 0).
local config4 = { feed = { targets = {} } }
local warnings4 = {}
config_normalizer.normalize(config4, defaults, function(msg) warnings4[#warnings4 + 1] = msg end, utils)
for _, w in ipairs(warnings4) do
  assert_eq(w:find('sorter_chest') == nil, true, 'no targets configured yet must not warn about a missing Sorter-Kiste')
  assert_eq(w:find('feed.sorter fehlt') == nil, true, 'no targets configured yet must not warn about a missing Sorter')
end

print('reprocessor_config_normalizer_color_test.lua: ok')
