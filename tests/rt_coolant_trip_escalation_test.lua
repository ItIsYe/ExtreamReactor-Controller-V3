package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Wiederholtes kurzes Antriggern des Coolant-Low-Schutzes (z.B. weil der
-- Wassernachfluss dem Verbrauch kurzzeitig hinterherhinkt) soll nach einer
-- konfigurierbaren Anzahl Trips innerhalb eines Zeitfensters den
-- automatischen, temperatur-basierten SAFE-Exit sperren -- statt endlos zu
-- oszillieren, muss ein Bediener den Reaktor manuell per SET_MODE=MASTER
-- wieder freigeben.

local lifecycle = require('nodes.rt.module_lifecycle')
local reactor_control = require('nodes.rt.reactor_control')
local state_handlers = require('nodes.rt.state_handlers')

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
    coolant_trip_escalation_window_s = 600,
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

-- SAFE-Exit darf trotz guter Temperatur nicht auto-verlassen werden, solange gesperrt.
current_state = 'SAFE'
local rc_ctx = {
  current_state = function() return current_state end,
  STATE = { SAFE = 'SAFE', MASTER = 'MASTER' },
  config = { safety = { max_temperature = 2000, temperature_hysteresis = 50 } },
  modules = ctx.modules,
  peripherals = { reactors = {} },
  setState = function(next_state) current_state = next_state end,
  warn_once = function() end,
  log = function() end,
  CONFIG = { ROD_MAX = 100 },
}
reactor_control.applyReactorRods = function() end
reactor_control.updateReactorControl(rc_ctx)
if current_state ~= 'SAFE' then
  error('must stay SAFE while coolant_trip_locked, got ' .. tostring(current_state))
end

-- Manuelles SET_MODE=MASTER (Bediener bestaetigt Kuehlmittel wieder ok) hebt die Sperre auf.
local sh_ctx = {
  STATE = { MASTER = 'MASTER', AUTONOM = 'AUTONOM', SAFE = 'SAFE' },
  modules = ctx.modules,
  log = function() end,
  is_master_connected = function() return true end,
  get_current_state = function() return current_state end,
  set_current_state = function(v) current_state = v end,
  get_node_state_machine = function()
    return { state = function() return 'EMERGENCY' end, transition = function() end }
  end,
  constants = { node_states = { OFF = 'OFF', AUTONOM = 'AUTONOM', STARTUP = 'STARTUP' } },
}
state_handlers.apply_mode(sh_ctx, sh_ctx.STATE.MASTER)
if module.coolant_trip_locked ~= false then error('lock must clear after manual MASTER apply') end
if module.coolant_trip_count ~= 0 then error('trip_count must reset after manual MASTER apply') end

os.epoch = original_epoch
print('rt_coolant_trip_escalation_test.lua: ok')
