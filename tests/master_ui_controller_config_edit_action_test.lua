package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer MASTER-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 10). Treibt das echte, require()-bare master/
-- ui_controller.lua (keine Boot-Seiteneffekte -- M.new()'s "c = opts"
-- macht controller.handle_action() unabhaengig von der schweren
-- build_models()-Maschinerie testbar) und beweist:
--  1. fuel_reserve_adjust/water_target_adjust/reactor_fill_target_adjust
--     lesen den aktuellen Wert jetzt aus get_config_edit_model() statt aus
--     c.state.*_pct, und schreiben c.state.*_pct NICHT MEHR optimistisch
--     (der alte Bug: der Monitor zeigte den neuen Wert sofort an, auch
--     wenn kein einziges Ziel ihn je bestaetigt hat).
--  2. config_edit_target_cycle ruft c.calc.cycle_config_edit_target(key).

local ui_controller_lib = require('master.ui_controller')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- 1a. fuel_reserve_adjust: reads the confirmed value via
--     get_config_edit_model, calls set_fuel_reserve with cur+delta, and
--     must NOT touch c.state.fuel_reserve_pct at all.
do
  local set_calls = {}
  local model_calls = {}
  local c_state = {}
  local controller = ui_controller_lib.new({
    state = c_state,
    calc = {
      get_config_edit_model = function(key, fallback)
        model_calls[#model_calls + 1] = key
        if key == 'fuel_reserve' then return { target = 'ALL', confirmed_value = 2000, pending = nil } end
        return { target = 'ALL', confirmed_value = fallback, pending = nil }
      end,
      set_fuel_reserve = function(new_val) set_calls[#set_calls + 1] = new_val; return true, 1 end,
    },
  })

  local handled = controller.handle_action({ type = 'fuel_reserve_adjust', delta = 250 })
  assert_true(handled, 'fuel_reserve_adjust must be handled')
  assert_eq(#set_calls, 1, 'set_fuel_reserve must be called exactly once')
  assert_eq(set_calls[1], 2250, 'the new value must be the CONFIRMED value (2000) plus delta (250), not a stale optimistic local value')
  assert_true(c_state.fuel_reserve_pct == nil,
    'c.state.fuel_reserve_pct must NOT be written anymore -- this is the exact bug being fixed: ' ..
    'the old code showed the new value immediately regardless of any ACK_APPLIED result')
end

-- 1b. reactor_fill_target_adjust: confirmed_value is stored as a raw
--     0.0-1.0 ratio; the UI works in percent -- conversion must happen
--     both directions without ever touching c.state.
do
  local set_calls = {}
  local controller = ui_controller_lib.new({
    state = {},
    calc = {
      get_config_edit_model = function(key, fallback)
        if key == 'reactor_fill_target' then return { target = 'ALL', confirmed_value = 0.5, pending = nil } end
        return { target = 'ALL', confirmed_value = fallback, pending = nil }
      end,
      set_reactor_fill_target = function(new_ratio) set_calls[#set_calls + 1] = new_ratio end,
    },
  })
  local handled = controller.handle_action({ type = 'reactor_fill_target_adjust', delta = 5 })
  assert_true(handled, 'reactor_fill_target_adjust must be handled')
  assert_eq(#set_calls, 1, 'set_reactor_fill_target must be called exactly once')
  assert_true(math.abs(set_calls[1] - 0.55) < 0.0001, 'confirmed 50% + 5% delta must send 0.55, got ' .. tostring(set_calls[1]))
end

-- 1c. water_target_adjust: same pattern, plus a failed send must still
--     surface an alarm.
do
  local alarm_calls = {}
  local controller = ui_controller_lib.new({
    state = {},
    calc = {
      get_config_edit_model = function(key, fallback)
        if key == 'water_target' then return { target = 'ALL', confirmed_value = 1000, pending = nil } end
        return { target = 'ALL', confirmed_value = fallback, pending = nil }
      end,
      set_water_target = function(new_val) return false, 'kein WATER-Node gefunden' end,
      add_alarm = function(sender, severity, msg) alarm_calls[#alarm_calls + 1] = { sender = sender, severity = severity, msg = msg } end,
    },
  })
  local handled = controller.handle_action({ type = 'water_target_adjust', delta = -250 })
  assert_true(handled, 'water_target_adjust must be handled even when the send fails')
  assert_eq(#alarm_calls, 1, 'a failed send must still raise exactly one alarm')
end

-- 2. config_edit_target_cycle delegates to cycle_config_edit_target(key).
do
  local cycle_calls = {}
  local controller = ui_controller_lib.new({
    state = {},
    calc = {
      cycle_config_edit_target = function(key) cycle_calls[#cycle_calls + 1] = key; return 'RT-2' end,
    },
  })
  local handled = controller.handle_action({ type = 'config_edit_target_cycle', key = 'reactor_fill_target' })
  assert_true(handled, 'config_edit_target_cycle must be handled')
  assert_eq(#cycle_calls, 1, 'cycle_config_edit_target must be called exactly once')
  assert_eq(cycle_calls[1], 'reactor_fill_target', 'the correct setting key must be forwarded')
end

print('master_ui_controller_config_edit_action_test.lua: ok')
