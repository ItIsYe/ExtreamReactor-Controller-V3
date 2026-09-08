-- Ein Reaktor-Modul, das wegen TEMP/WATER-Limit auf module.state="ERROR"
-- gesetzt wurde, blieb dort fuer immer stehen -- reactor_control.lua/
-- turbine_control.lua pruefen module.state gar nicht (das Feld ist reine
-- Status-/Reporting-Information Richtung MASTER), aber niemand setzte es
-- je zurueck, sobald die Sicherheitsbedingung selbst laengst wieder normal
-- war. update_module_states() muss ein solches Modul zurueck auf
-- STABLE -> RUNNING bringen, sobald (a) weder TEMP- noch WATER-Limit mehr
-- aktiv ist UND (b) RT SAFE bereits verlassen hat (das eigentliche
-- SAFE-Exit-Timing entscheidet weiterhin reactor_control.lua, nicht diese
-- Funktion) -- vorher aber ausdruecklich NICHT, solange RT noch in SAFE
-- haengt.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local lifecycle = require('nodes.rt.module_lifecycle')

local original_epoch = os.epoch
local now_ms = 0
os.epoch = function(_) return now_ms end

local function coolant_ok()
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
  id = 'R1', type = 'reactor', name = 'reactor_0', state = 'ERROR', limits = { 'TEMP' },
  peripheral = {
    getFuelTemperature = function() return 1000 end,  -- weit unter dem Limit -- TEMP erholt
    getCasingTemperature = function() return 900 end,
  },
  safety_temp_state = {}, coolant_safety_state = {},
}

local current_state = 'SAFE'
local logs = {}

local ctx = {
  modules = { R1 = module },
  config = { safety = {
    max_temperature = 2000, temperature_hysteresis = 50, temperature_trip_samples = 2,
    min_water = 0.2, coolant_hysteresis = 0.05, coolant_trip_samples = 3,
    coolant_invalid_grace_samples = 3,
  }},
  evaluate_reactor_coolant = function() return coolant_ok() end,
  get_target_rpm = function() return 1800 end,
  current_state = function() return current_state end,
  STATE = { SAFE = 'SAFE', MASTER = 'MASTER' },
  setState = function() end,
  log = function(_, message) table.insert(logs, tostring(message)) end,
  node_state_machine = {
    -- Vereinfachtes Modell: solange RT (noch) in SAFE ist, steht die
    -- Node-State-Machine auf EMERGENCY; nach dem Verlassen von SAFE (durch
    -- reactor_control.lua, hier durch current_state simuliert) auf RUNNING
    -- -- reicht fuer diesen isolierten module_lifecycle-Test.
    state = function() return current_state == 'SAFE' and 'EMERGENCY' or 'RUNNING' end,
    transition = function() end,
  },
  constants = { node_states = { EMERGENCY = 'EMERGENCY', RUNNING = 'RUNNING' } },
}

now_ms = 0
lifecycle.update_module_states(ctx)
if module.state ~= 'ERROR' then
  error('module must stay ERROR while RT is still in SAFE, even if the limit itself is clear, got ' .. tostring(module.state))
end

-- RT hat SAFE inzwischen verlassen (reactor_control.lua's eigene Exit-Logik
-- hat bereits entschieden, dass es sicher ist) -- die TEMP-Bedingung ist
-- schon seit dem vorigen Tick nicht mehr aktiv.
current_state = 'MASTER'
now_ms = 1000
lifecycle.update_module_states(ctx)
if module.state ~= 'STABLE' then
  error('module must recover to STABLE once the limit is clear and RT has left SAFE, got ' .. tostring(module.state))
end
if module.limits[1] then
  error('recovered module must not still report an active limit')
end

-- Zu frueh (< 3s seit STABLE) darf es noch nicht RUNNING sein --
-- dieselbe Debounce wie bei einem frischen Start.
now_ms = 2000
lifecycle.update_module_states(ctx)
if module.state ~= 'STABLE' then
  error('module must remain STABLE before the 3s debounce elapses, got ' .. tostring(module.state))
end

now_ms = 4001
lifecycle.update_module_states(ctx)
if module.state ~= 'RUNNING' then
  error('module must reach RUNNING after the STABLE debounce elapses, got ' .. tostring(module.state))
end

local saw_transition_log = false
for _, message in ipairs(logs) do
  if message:find('R1 ERROR %-> STABLE', 1, false) or message:find('ERROR -> STABLE', 1, true) then
    saw_transition_log = true
  end
end
if not saw_transition_log then
  error('expected a logged ERROR -> STABLE module state transition')
end

os.epoch = original_epoch
print('rt_module_error_recovery_test.lua: ok')
