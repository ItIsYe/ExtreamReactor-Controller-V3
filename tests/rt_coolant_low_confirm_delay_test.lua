package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local lifecycle = require('nodes.rt.module_lifecycle')

local original_epoch = os.epoch
local now_ms = 0
os.epoch = function(_)
  return now_ms
end

local function diag(overrides)
  local data = {
    triggered = false,
    low_detected = false,
    condition = 'COOLANT_OK',
    coolant_amount = 50000,
    coolant_amount_max = 200000,
    coolant_ratio = 0.25,
    coolant_ratio_raw = 0.25,
    min_water = 0.2,
    recover_threshold = 0.25,
    hysteresis = 0.05,
    source = 'getCoolantAmount/getCoolantAmountMax',
    source_method = 'getCoolantAmount+getCoolantAmountMax',
    measurement_state = 'FRESH',
    measurement_valid = true,
    stale_fallback_used = false,
    low_ticks = 3,
    trip_samples = 3,
    invalid_ticks = 0,
    invalid_grace_samples = 3,
    zero_glitch_pending = false,
    causality = 'COOLANT_PRIMARY'
  }
  for key, value in pairs(overrides or {}) do
    data[key] = value
  end
  return data
end

local samples = {
  diag({ triggered = true, low_detected = true, condition = 'COOLANT_LOW_PERSISTENT', coolant_amount = 10000, coolant_ratio = 0.05, coolant_ratio_raw = 0.05 }),
  diag({ triggered = true, low_detected = true, condition = 'COOLANT_LOW_PERSISTENT', coolant_amount = 9000, coolant_ratio = 0.045, coolant_ratio_raw = 0.045 }),
  diag({ triggered = false, low_detected = false, condition = 'COOLANT_OK', coolant_amount = 60000, coolant_ratio = 0.3, coolant_ratio_raw = 0.3, low_ticks = 0 }),
  diag({ triggered = true, low_detected = true, condition = 'COOLANT_LOW_PERSISTENT', coolant_amount = 11000, coolant_ratio = 0.055, coolant_ratio_raw = 0.055 }),
  diag({ triggered = true, low_detected = true, condition = 'COOLANT_LOW_PERSISTENT', coolant_amount = 8000, coolant_ratio = 0.04, coolant_ratio_raw = 0.04 }),
}

local sample_index = 0
local logs = {}
local safe_reason = nil
local emergency_transitions = 0
local current_state = 'RUNNING'

local module = {
  id = 'R1',
  type = 'reactor',
  name = 'reactor_0',
  state = 'RUNNING',
  limits = {},
  peripheral = {},
  safety_temp_state = {},
  coolant_safety_state = {},
}

local ctx = {
  modules = { R1 = module },
  config = {
    safety = {
      max_temperature = 2000,
      temperature_hysteresis = 50,
      temperature_trip_samples = 2,
      min_water = 0.2,
      coolant_hysteresis = 0.05,
      coolant_trip_samples = 3,
      coolant_invalid_grace_samples = 3,
    },
  },
  evaluate_reactor_coolant = function()
    sample_index = sample_index + 1
    local sample = samples[sample_index]
    if not sample then
      error('missing coolant sample for index ' .. tostring(sample_index))
    end
    return sample
  end,
  get_target_rpm = function() return 1800 end,
  current_state = function() return current_state end,
  STATE = { SAFE = 'SAFE' },
  setState = function(_, reason)
    current_state = 'SAFE'
    safe_reason = reason
  end,
  log = function(_, message)
    table.insert(logs, tostring(message))
  end,
  node_state_machine = {
    state = function()
      if emergency_transitions > 0 then
        return 'EMERGENCY'
      end
      return 'RUNNING'
    end,
    transition = function(_, state)
      if state == 'EMERGENCY' then
        emergency_transitions = emergency_transitions + 1
      end
    end,
  },
  constants = { node_states = { EMERGENCY = 'EMERGENCY', RUNNING = 'RUNNING' } },
}

now_ms = 0
lifecycle.update_module_states(ctx)
if safe_reason ~= nil or emergency_transitions ~= 0 then
  error('coolant low pending must not immediately enter SAFE/EMERGENCY')
end
if not module.coolant_low_pending_trip then
  error('coolant low pending trip must be armed on first persistent low sample')
end

now_ms = 3000
lifecycle.update_module_states(ctx)
if safe_reason ~= nil or emergency_transitions ~= 0 then
  error('coolant low <4s must remain pending without SAFE transition')
end

now_ms = 3500
lifecycle.update_module_states(ctx)
if module.coolant_low_pending_trip ~= nil then
  error('recovered coolant must abort pending trip before confirmation delay')
end
if safe_reason ~= nil or emergency_transitions ~= 0 then
  error('recovery during pending window must avoid SAFE/EMERGENCY transition')
end

now_ms = 4000
lifecycle.update_module_states(ctx)
if module.coolant_low_pending_trip == nil then
  error('coolant low after recovery must start a new pending trip timer')
end

now_ms = 8100
lifecycle.update_module_states(ctx)
if safe_reason ~= 'SAFETY_COOLANT_LOW' then
  error('persistent coolant low >=4s must enter SAFE with SAFETY_COOLANT_LOW reason')
end
if emergency_transitions ~= 1 then
  error('persistent coolant low >=4s must transition node state machine to EMERGENCY once')
end
if module.state ~= 'ERROR' then
  error('confirmed coolant trip must set reactor module state to ERROR')
end

local saw_pending = false
local saw_aborted = false
local saw_confirmed = false
for _, message in ipairs(logs) do
  if message:find('COOLANT_LOW_PENDING', 1, true) then
    saw_pending = true
  end
  if message:find('COOLANT_LOW_ABORTED_RECOVERED', 1, true) then
    saw_aborted = true
  end
  if message:find('COOLANT_LOW_CONFIRMED', 1, true) then
    saw_confirmed = true
  end
end
if not saw_pending then
  error('pending coolant trip log marker missing')
end
if not saw_aborted then
  error('aborted coolant trip log marker missing')
end
if not saw_confirmed then
  error('confirmed coolant trip log marker missing')
end

os.epoch = original_epoch
print('rt_coolant_low_confirm_delay_test.lua: ok')
