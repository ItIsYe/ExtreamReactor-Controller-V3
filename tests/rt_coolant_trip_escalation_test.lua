package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Wiederholtes kurzes Antriggern des Coolant-Low-Schutzes (z.B. weil der
-- Wassernachfluss dem Verbrauch kurzzeitig hinterherhinkt) soll nach einer
-- konfigurierbaren Anzahl Trips innerhalb eines Zeitfensters den
-- automatischen, temperatur-basierten SAFE-Exit sperren -- statt endlos zu
-- oszillieren. Die Sperre loest sich von selbst wieder, sobald der reale
-- (nicht vom Zero-Glitch-Filter maskierte) Kuehlmittel-Messwert ununter-
-- brochen ueber der Recovery-Schwelle liegt -- ohne manuellen Eingriff.

local lifecycle = require('nodes.rt.module_lifecycle')
local reactor_control = require('nodes.rt.reactor_control')

local original_epoch = os.epoch
local now_ms = 0
os.epoch = function(_) return now_ms end

local function persistent_diag()
  return {
    triggered = true, low_detected = true, condition = 'COOLANT_LOW_PERSISTENT',
    coolant_amount = 8000, coolant_amount_max = 200000, coolant_ratio = 0.04,
    coolant_ratio_raw = 0.04, min_water = 0.2, recover_threshold = 0.25,
    hysteresis = 0.05, source = 'x', source_method = 'x', measurement_state = 'FRESH',
    measurement_valid = true, stale_fallback_used = false, low_ticks = 3, trip_samples = 3,
    invalid_ticks = 0, invalid_grace_samples = 3, zero_glitch_pending = false,
    causality = 'COOLANT_PRIMARY',
  }
end

local function recovered_diag()
  return {
    triggered = false, low_detected = false, condition = 'COOLANT_OK',
    coolant_amount = 60000, coolant_amount_max = 200000, coolant_ratio = 0.3,
    coolant_ratio_raw = 0.3, min_water = 0.2, recover_threshold = 0.25, hysteresis = 0.05,
    source = 'x', source_method = 'x', measurement_state = 'FRESH', measurement_valid = true,
    stale_fallback_used = false, low_ticks = 0, trip_samples = 3, invalid_ticks = 0,
    invalid_grace_samples = 3, zero_glitch_pending = false, causality = 'COOLANT_PRIMARY',
  }
end

local module = {
  id = 'R1', type = 'reactor', name = 'reactor_0', state = 'RUNNING', limits = {},
  peripheral = {}, safety_temp_state = {}, coolant_safety_state = {},
}
local current_state = 'RUNNING'
local diag_queue = {}

local ctx = {
  modules = { R1 = module },
  config = { safety = {
    max_temperature = 2000, temperature_hysteresis = 50, temperature_trip_samples = 2,
    min_water = 0.2, coolant_hysteresis = 0.05, coolant_trip_samples = 3,
    coolant_invalid_grace_samples = 3, coolant_trip_escalation_count = 4,
    coolant_trip_escalation_window_s = 600, coolant_recovery_confirm_ms = 4000,
  }},
  evaluate_reactor_coolant = function() return table.remove(diag_queue, 1) end,
  get_target_rpm = function() return 1800 end,
  current_state = function() return current_state end,
  STATE = { SAFE = 'SAFE', MASTER = 'MASTER' },
  setState = function(next_state) current_state = next_state end,
  log = function() end,
  node_state_machine = { state = function() return 'RUNNING' end, transition = function() end },
  constants = { node_states = { EMERGENCY = 'EMERGENCY', RUNNING = 'RUNNING' } },
  warn_once = function() end,
}

local function trip_once(t_start)
  now_ms = t_start
  diag_queue = { persistent_diag(), persistent_diag() }
  lifecycle.update_module_states(ctx)   -- Pending-Trip armen
  now_ms = t_start + 4000
  lifecycle.update_module_states(ctx)   -- Bestaetigungsverzoegerung -> SAFE
  if current_state ~= 'SAFE' then
    error('expected SAFE after confirm delay, got ' .. tostring(current_state))
  end
  current_state = 'RUNNING'             -- naechster Trip beginnt wieder aus RUNNING
end

trip_once(0)
if module.coolant_trip_count ~= 1 then error('expected trip_count=1, got ' .. tostring(module.coolant_trip_count)) end
if module.coolant_trip_locked then error('must not be locked after 1st trip') end

trip_once(10000)
if module.coolant_trip_count ~= 2 then error('expected trip_count=2, got ' .. tostring(module.coolant_trip_count)) end

trip_once(20000)
if module.coolant_trip_count ~= 3 then error('expected trip_count=3, got ' .. tostring(module.coolant_trip_count)) end
if module.coolant_trip_locked then error('must not be locked after 3rd trip') end

trip_once(30000)
if module.coolant_trip_count ~= 4 then error('expected trip_count=4, got ' .. tostring(module.coolant_trip_count)) end
if not module.coolant_trip_locked then error('must be locked after 4th trip within escalation window') end

-- reactor_control-Kontext fuer den SAFE-Exit-Check (mit Reaktorliste, sonst
-- laeuft die Pruefschleife nie und der Test wird sinnlos).
local rc_ctx = {
  current_state = function() return current_state end,
  STATE = { SAFE = 'SAFE', MASTER = 'MASTER' },
  config = { safety = {
    max_temperature = 2000, temperature_hysteresis = 50, coolant_recovery_confirm_ms = 4000,
  }, reactors = { 'R1' } },
  modules = ctx.modules,
  peripherals = { reactors = {} },
  setState = function(next_state) current_state = next_state end,
  warn_once = function() end,
  log = function() end,
  CONFIG = { ROD_MAX = 100 },
}
reactor_control.applyReactorRods = function() end

-- Solange die Sperre aktiv ist und der Messwert weiterhin schlecht ist,
-- darf SAFE trotz gutem all_cool (kein Peripheral -> Temperatur "unbekannt,
-- sicher bleiben") nicht automatisch verlassen werden.
current_state = 'SAFE'
now_ms = 40000
module.coolant_safety_diag = persistent_diag()
reactor_control.updateReactorControl(rc_ctx)
if current_state ~= 'SAFE' then
  error('must stay SAFE while coolant still bad, got ' .. tostring(current_state))
end

-- Kuehlmittel erholt sich jetzt real -- aber ein einzelner guter Tick reicht
-- nicht: die Sperre bleibt, bis die Erholung sustained (>= coolant_recovery_confirm_ms) ist.
now_ms = 40100
module.coolant_safety_diag = recovered_diag()
reactor_control.updateReactorControl(rc_ctx)
if current_state ~= 'SAFE' then
  error('must stay SAFE immediately after recovery starts (not yet sustained), got ' .. tostring(current_state))
end
if not module.coolant_trip_locked then
  error('lock must not clear before the recovery confirm window elapsed')
end

now_ms = 40100 + 3000  -- noch innerhalb des 4000ms-Fensters
module.coolant_safety_diag = recovered_diag()
reactor_control.updateReactorControl(rc_ctx)
if current_state ~= 'SAFE' then
  error('must stay SAFE mid-way through the recovery confirm window, got ' .. tostring(current_state))
end

-- Nach sustained Erholung >= coolant_recovery_confirm_ms hebt sich die
-- Sperre automatisch auf -- ohne jeden manuellen Befehl -- und der reguläre
-- Temperatur-Exit (kein Peripheral -> als kuehl angenommen) greift sofort.
now_ms = 40100 + 4000
module.coolant_safety_diag = recovered_diag()
reactor_control.updateReactorControl(rc_ctx)
if module.coolant_trip_locked then
  error('lock must clear automatically once coolant recovery is sustained')
end
if module.coolant_trip_count ~= 0 then
  error('trip_count must reset once the lock clears automatically')
end
if current_state ~= 'MASTER' then
  error('expected automatic SAFE-Exit to MASTER once unlocked and temperature is fine, got ' .. tostring(current_state))
end

os.epoch = original_epoch
print('rt_coolant_trip_escalation_test.lua: ok')
