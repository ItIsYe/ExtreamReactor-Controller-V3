package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.os = _G.os or {}
os.epoch = function() return 25000 end

local health = require('core.health')
local alert_rules = require('core.alert_rules').new({
  alert_raise_after_s = 0,
  alert_clear_after_s = 0,
  alert_cooldown_s = 0,
  comms_down_warn_secs = 0,
  comms_down_crit_secs = 10,
})

local alerts = select(1, alert_rules:evaluate({
  now = 25000,
  nodes = {
    {
      id = 'ENERGY-1',
      role = 'ENERGY_NODE',
      status = health.status.DOWN,
      offline = true,
      health = {
        status = health.status.DOWN,
        reasons = {
          [health.reasons.COMMS_DOWN] = true,
          [health.reasons.NO_MATRIX] = true,
        }
      }
    }
  }
}))

local saw_comms_down = false
for _, alert in ipairs(alerts or {}) do
  if alert.code == 'NODE_COMMS_DOWN' then
    saw_comms_down = true
  end
  if alert.code == 'MATRIX_MISSING' then
    error('MATRIX_MISSING must be suppressed while node is offline/comms-down')
  end
end

if not saw_comms_down then
  error('expected NODE_COMMS_DOWN alert for offline node')
end

print('alert_rules_matrix_missing_offline_suppression_test.lua: ok')
