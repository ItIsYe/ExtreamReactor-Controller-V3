package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local controller_lib = require('nodes.valve.controller')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_controller(opts)
  opts = opts or {}
  local writes, persisted, logs, acks = {}, {}, {}, {}
  local config = { sorter_name = 'logisticalSorter_1', trusted_source = opts.trusted_source }
  local peripheral_api = {
    find = function() return nil end,
    wrap = function(name)
      if name == 'left' then
        return { transmit = function(_, _, message) acks[#acks + 1] = message end }
      end
      return { setAutoMode = function(value) writes[#writes + 1] = value end }
    end,
  }
  local controller = controller_lib.new({
    config = config, config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = {
      log = function(_, message, level) logs[#logs + 1] = { message = message, level = level } end,
      write_config = function(path, value)
        persisted[#persisted + 1] = { path = path, trusted_source = value.trusted_source }
        if opts.persist_ok == false then return false, 'simulated persistence failure' end
        return true
      end,
    },
    peripheral_api = peripheral_api,
    colors_api = { orange = 1, red = 2, green = 3 },
    os_api = { epoch = function() return 1000000 end },
  })
  return controller, config, writes, persisted, logs, acks
end

local function command(src, id, high)
  return { 'modem_message', 'left', 6504, 6504,
    { type = 'SET_VALVE', dst = 'VALVE-1', src = src, command_id = id, high = high } }
end

-- First successfully applied command persistently pairs an unconfigured node.
do
  local controller, _, _, persisted = make_controller()
  assert_true(controller:handle_event(command('FUEL-1', 'CMD-1', true)))
  local state = controller:get_state()
  assert_eq(state.trusted_source, 'FUEL-1', 'first accepted sender must become trusted_source')
  assert_true(state.pairing_persisted, 'successful pairing must be reported as persistent')
  assert_eq(#persisted, 1, 'pairing must write the user config exactly once')
  assert_eq(persisted[1].trusted_source, 'FUEL-1')
end

-- Once paired, a different sender is rejected before any actuator write.
do
  local controller, _, writes, persisted, logs = make_controller({ trusted_source = 'FUEL-1' })
  assert_true(not controller:handle_event(command('INTRUDER-1', 'CMD-2', false)))
  assert_eq(#writes, 0, 'untrusted sender must never touch the sorter')
  assert_eq(#persisted, 0, 'existing pairing must not be rewritten')
  local warned = false
  for _, entry in ipairs(logs) do
    if entry.level == 'WARN' and entry.message:find('untrusted source', 1, true) then warned = true end
  end
  assert_true(warned, 'untrusted sender rejection must be visible in the log')
end

-- Pairing is all-or-nothing. If persistence fails, roll back trust in RAM,
-- physically return to BLOCKED and reject the command ACK.
do
  local controller, config, writes, persisted, _, acks = make_controller({ persist_ok = false })
  assert_true(not controller:handle_event(command('FUEL-1', 'CMD-3', false)))
  local state = controller:get_state()
  assert_eq(config.trusted_source, nil, 'failed persistence must not leave a volatile trust binding')
  assert_true(not state.pairing_persisted, 'failed persistence must be reported')
  assert_true(state.pairing_error ~= nil, 'persistence error must be diagnosable')
  assert_eq(writes[1], true, 'requested OPEN first enables sorter auto mode')
  assert_eq(writes[#writes], false, 'rollback must physically disable auto mode (BLOCKED)')
  assert_eq(state.current_high, true, 'rollback must leave the confirmed state BLOCKED')
  assert_eq(#persisted, 1)
  assert_true(acks[#acks].applied == false and acks[#acks].persisted == false,
    'failed pairing must never emit a successful/persisted ACK')
end

-- A failed cached peripheral handle is discarded so the next attempt wraps a
-- newly attached/replaced sorter.
do
  local wraps = 0
  local controller = controller_lib.new({
    config = { sorter_name = 'logisticalSorter_1', trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = {
      find = function() return nil end,
      wrap = function()
        wraps = wraps + 1
        if wraps == 1 then return { setAutoMode = function() error('detached') end } end
        return { setAutoMode = function() end }
      end,
    },
    colors_api = { orange = 1, red = 2, green = 3 },
    os_api = { epoch = function() return 1000000 end },
  })
  assert_true(not controller:apply_valve(true, true), 'detached cached handle must fail visibly')
  assert_true(controller:apply_valve(true, true), 'next attempt must wrap and use the replacement sorter')
  assert_eq(wraps, 2, 'failed handle must not remain cached')
end

print('valve_sender_pairing_and_sorter_reconnect_test.lua: ok')
