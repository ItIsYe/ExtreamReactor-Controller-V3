package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (external code analysis, 2026-09-18): a partial
-- reactor_rods_individual override, e.g.
--   reactor_rods_individual = { cooldown_s = 0.2 }
-- used to REPLACE the entire default rod_cfg table wholesale (the "or"
-- fallback only triggers when the override is falsy -- any truthy table,
-- even a partial one, wins outright). max_step_up/down, deadband,
-- hysteresis, and min/max all disappeared, which could silence the
-- regulator entirely (missing max_step -> step=0 in core/control_rails.lua).
--
-- Fix: a provided override is now deep-merged onto the same defaults
-- (ctx.utils.merge_defaults()) instead of replacing them -- only missing
-- keys get filled in, nothing the operator set is overwritten.

local reactor_control = require('nodes.rt.reactor_control')
local rails = require('core.control_rails')
local safety = require('core.safety')
local utils = require('core.utils')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local fake_clock = 0
local original_clock = os.clock
os.clock = function() return fake_clock end

local applied_calls = {}
local current_rods = 95

local ctx = {
  -- The exact partial override from the analysis's own example.
  config = { reactors = { 'R1' }, rails = { reactor_rods_individual = { cooldown_s = 0.2 } } },
  CONFIG = { ROD_MIN = 0, ROD_MAX = 100, LOG_PREFIX = 'TEST', MIN_APPLY_INTERVAL = 0 },
  reactor_ctrl = {},
  safety = safety,
  rails = rails,
  utils = utils,
  peripherals = { reactors = { R1 = {} } },
  fluid = {
    read_amount = function() return 2000 end,   -- 20% fill, well below the 50% target
    read_capacity = function() return 10000 end,
    read_coolant_sample = function() return { coolant_ratio = 1.0 } end,
  },
  adapters = {
    reactor = {
      read_control_rods = function() return current_rods end,
      apply_rod_level = function(name, level)
        table.insert(applied_calls, { name = name, level = level })
        current_rods = level
        return true
      end,
    },
  },
  reactor_steam_guard = { apply = function(_, target) return target, { unavailable = true } end },
  current_state = function() return 'MASTER' end,
  STATE = { SAFE = 'SAFE' },
  warn_once = function() end,
  log = function() end,
}

reactor_control.controlReactorsIndividually(ctx)
fake_clock = fake_clock + 1
reactor_control.controlReactorsIndividually(ctx)
os.clock = original_clock

assert_true(#applied_calls >= 1,
  'a reactor 30 percentage points below target must still regulate with a PARTIAL '
  .. 'reactor_rods_individual override -- max_step_up/down must have survived the merge, '
  .. 'not been silently dropped to 0')
assert_true(applied_calls[1].level < 95,
  'rods must move down (more power) despite the partial override, got level=' .. tostring(applied_calls[1].level))

print('rt_reactor_rods_individual_deep_merge_test.lua: ok')
