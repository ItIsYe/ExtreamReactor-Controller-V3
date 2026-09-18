package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test (external code analysis, 2026-09-18): controlReactorsIndividually()
-- computed its steam-fill-error as an ABSOLUTE mB quantity
-- (fill_margin = (fill_ratio - fill_target) * fill_capacity), compared
-- against a deadband hardcoded in absolute mB (5000). For a small reactor
-- (e.g. a 10,000 mB internal tank), even the maximum possible deviation
-- from the 50% target (fill_ratio 0 or 1) only produces a 5000 mB margin --
-- exactly AT the deadband edge, meaning such a reactor could barely ever
-- regulate. A 100,000 mB reactor's SAME 5000 mB deadband is only 5% of its
-- range, behaving completely differently under the identical config.
--
-- Fix: fill_margin is now a percentage-point error (0-100 scaled, like the
-- rod level itself: (fill_ratio - fill_target) * 100), and the default
-- deadband/hysteresis were rescaled to match (3/1 percentage points).
-- This test drives a small (10,000 mB) reactor sitting well below target
-- and confirms the rods actually move -- under the old absolute-mB scheme,
-- this exact scenario produced a margin within the deadband and rods
-- never moved.

local reactor_control = require('nodes.rt.reactor_control')
local rails = require('core.control_rails')
local safety = require('core.safety')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- rails.step()'s cooldown_s is measured against os.clock(), read directly
-- inside reactor_control.lua (not injectable via ctx) -- monkey-patch it so
-- the test can advance past the 0.5s apply cooldown deterministically
-- instead of a real sleep.
local fake_clock = 0
local original_clock = os.clock
os.clock = function() return fake_clock end

local applied_calls = {}
local current_rods = 95 -- close to fully inserted, matching a low-power idle state

local ctx = {
  config = { reactors = { 'R1' }, rails = {} }, -- no override -> uses new percent-based defaults
  CONFIG = { ROD_MIN = 0, ROD_MAX = 100, LOG_PREFIX = 'TEST', MIN_APPLY_INTERVAL = 0 },
  reactor_ctrl = {},
  safety = safety,
  rails = rails,
  utils = { safe_wrap = function() return nil end },
  peripherals = { reactors = { R1 = {} } },
  fluid = {
    -- Small 10,000 mB internal tank, sitting at 20% fill (well below the
    -- 50% target) -- a real, significant power shortfall.
    read_amount = function() return 2000 end,
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
fake_clock = fake_clock + 1 -- past cooldown_s (0.5s default) and MIN_APPLY_INTERVAL
reactor_control.controlReactorsIndividually(ctx)
os.clock = original_clock

assert_true(#applied_calls >= 1,
  'a reactor at 20% fill (30 percentage points below the 50% target) must actually move its rods -- '
  .. 'under the old absolute-mB deadband, this exact 10,000 mB reactor scenario never regulated')
assert_true(applied_calls[1].level < 95,
  'the fill shortfall must drive rods DOWN (more power), got level=' .. tostring(applied_calls[1].level))

print('rt_reactor_fill_deadband_percent_test.lua: ok')
