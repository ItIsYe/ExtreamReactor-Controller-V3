package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local health = require('core.health')
local controller_lib = require('master.ui_controller')

local hold = false
local controller = controller_lib.new({
  constants = constants,
  health = health,
  config = { energy_warn_pct = 25, energy_crit_pct = 15 },
  nodes = {},
  alarms = {},
  comms = { get_diagnostics = function() return {} end },
  sequencer = { ramp_profile = 'NORMAL', state = 'IDLE', queue = {} },
  trends = { is_dirty = function() return false end, clear_dirty = function() end },
  trend_cache = { energy = {}, energy_arrow = '→' },
  state = { monitor_cache = {}, last_draw = 0, power_target = 0, active_profile = 'BASELOAD', auto_profile = false, rt_global_off_hold = false },
  calc = {
    apply_profile = function() end,
    get_auto_profile = function() return false end,
    get_active_profile = function() return 'BASELOAD' end,
    get_power_target = function() return 0 end,
    get_rt_global_off_hold = function() return hold end,
    set_rt_global_off_hold = function(value) hold = value end
  }
})

controller.handle_action({ type = 'rt_hold' })
if hold ~= true then
  error('expected first rt_hold action to enable hold')
end
controller.handle_action({ type = 'rt_hold' })
if hold ~= false then
  error('expected second rt_hold action to disable hold')
end

print('master_ui_controller_rt_hold_toggle_test.lua: ok')
