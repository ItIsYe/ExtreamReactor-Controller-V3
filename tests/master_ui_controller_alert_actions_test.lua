-- Die detaillierte Alerts-Ansicht (master/ui/alerts.lua, AUX-Monitor) erzeugt
-- Action-Tables vom Typ alert_ack/alert_ack_visible/alert_ack_all/
-- alert_mute_rule/alert_unmute_rule/alert_mute_node/alert_unmute_node --
-- ui_controller.handle_action() kannte davon bislang nur den unabhaengigen
-- alarm_ack-Typ (aus der einfacheren alarms.lua-Ansicht). Die Buttons ACK,
-- ACK VIS, ACK ALL, MUTE RULE, MUTE NODE taten dadurch sichtbar nichts.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local constants = require('shared.constants')
local health = require('core.health')
local controller_lib = require('master.ui_controller')

local calls = {}
local function record(name)
  return function(...) calls[#calls + 1] = { name = name, ... } end
end

local alert_service = {
  ack = record('ack'),
  ack_visible = record('ack_visible'),
  ack_all = record('ack_all'),
  mute_rule = record('mute_rule'),
  unmute_rule = record('unmute_rule'),
  mute_node = record('mute_node'),
  unmute_node = record('unmute_node'),
}

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
  alert_service = alert_service,
  calc = {},
})

local function assert_called(name, expected_args)
  for _, c in ipairs(calls) do
    if c.name == name then
      for i, v in ipairs(expected_args or {}) do
        if c[i] ~= v then
          error(name .. ': expected arg ' .. i .. '=' .. tostring(v) .. ', got ' .. tostring(c[i]))
        end
      end
      return
    end
  end
  error('expected ' .. name .. ' to have been called')
end

local ok1 = controller.handle_action({ type = 'alert_ack', id = 'ALERT-1' })
if ok1 ~= true then error('alert_ack must report handled=true') end
assert_called('ack', { alert_service, 'ALERT-1' })

local ok2 = controller.handle_action({ type = 'alert_ack_visible', ids = { 'A', 'B' } })
if ok2 ~= true then error('alert_ack_visible must report handled=true') end
assert_called('ack_visible', { alert_service })

local ok3 = controller.handle_action({ type = 'alert_ack_all' })
if ok3 ~= true then error('alert_ack_all must report handled=true') end
assert_called('ack_all', { alert_service })

local ok4 = controller.handle_action({ type = 'alert_mute_rule', code = 'RT_NO_REDUNDANCY', minutes = 15 })
if ok4 ~= true then error('alert_mute_rule must report handled=true') end
assert_called('mute_rule', { alert_service, 'RT_NO_REDUNDANCY', 15 })

local ok5 = controller.handle_action({ type = 'alert_unmute_rule', code = 'RT_NO_REDUNDANCY' })
if ok5 ~= true then error('alert_unmute_rule must report handled=true') end
assert_called('unmute_rule', { alert_service, 'RT_NO_REDUNDANCY' })

local ok6 = controller.handle_action({ type = 'alert_mute_node', node_id = 'RT-1', minutes = 10 })
if ok6 ~= true then error('alert_mute_node must report handled=true') end
assert_called('mute_node', { alert_service, 'RT-1', 10 })

local ok7 = controller.handle_action({ type = 'alert_unmute_node', node_id = 'RT-1' })
if ok7 ~= true then error('alert_unmute_node must report handled=true') end
assert_called('unmute_node', { alert_service, 'RT-1' })

-- Ein Action-Typ ohne die noetigen Felder (z.B. id fehlt) darf nicht
-- faelschlich als behandelt gemeldet werden.
local ok_missing = controller.handle_action({ type = 'alert_ack' })
if ok_missing ~= false then
  error('alert_ack without an id must not report handled=true')
end

print('master_ui_controller_alert_actions_test.lua: ok')
