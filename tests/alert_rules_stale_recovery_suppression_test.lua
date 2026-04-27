package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.os = _G.os or {}
os.epoch = function() return 42000 end

local health = require('core.health')
local alert_rules = require('core.alert_rules').new({
  alert_raise_after_s = 0,
  alert_clear_after_s = 0,
  alert_cooldown_s = 0,
  comms_down_warn_secs = 0,
  comms_down_crit_secs = 10,
})

local alerts = select(1, alert_rules:evaluate({
  now = 42000,
  nodes = {
    {
      id = 'ENERGY-1',
      role = 'ENERGY_NODE',
      stale = true,
      recovering = true,
      managed = true,
      health = {
        status = health.status.DEGRADED,
        reasons = {
          [health.reasons.NO_MATRIX] = true
        }
      }
    }
  }
}))

for _, alert in ipairs(alerts or {}) do
  if alert.code == 'NODE_DEGRADED' then
    error('NODE_DEGRADED must be suppressed while node is stale/recovering')
  end
  if alert.code == 'MATRIX_MISSING' then
    error('MATRIX_MISSING must be suppressed while node is stale/recovering')
  end
end

print('alert_rules_stale_recovery_suppression_test.lua: ok')
