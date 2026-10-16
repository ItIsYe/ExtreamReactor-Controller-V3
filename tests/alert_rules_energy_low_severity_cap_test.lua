-- A low/not-full total energy level is expected operating behavior, not a
-- fault: ENERGY_LOW must never escalate to CRITICAL, even far below the
-- configured crit threshold -- at most WARN.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.os = _G.os or {}
os.epoch = function() return 10000 end

local constants = require('shared.constants')

local rules = require('core.alert_rules').new({
  alert_raise_after_s = 0,
  alert_clear_after_s = 0,
  alert_cooldown_s = 0,
  energy_warn_pct = 25,
  energy_crit_pct = 15,
})

local alerts = rules:evaluate({
  now = 10000,
  nodes = {
    {
      id = 'ENERGY-1',
      role = constants.roles.ENERGY_NODE,
      stored = 1,
      capacity = 1000, -- 0.1% full -- far below both warn and crit thresholds
    },
  },
})

local energy_low = nil
for _, a in ipairs(alerts) do
  if a.code == 'ENERGY_LOW' then energy_low = a end
end

if not energy_low then error('expected an ENERGY_LOW alert for a near-empty energy store') end
if energy_low.severity ~= 'WARN' then
  error('ENERGY_LOW must be capped at WARN, got: ' .. tostring(energy_low.severity))
end

print('alert_rules_energy_low_severity_cap_test.lua: ok')
