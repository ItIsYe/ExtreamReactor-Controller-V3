package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer MASTER-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 10 "Config-Editor behauptet Uebernahme vor
-- ACK_APPLIED"). Treibt die echten, require()-baren Module master/
-- message_handlers.lua und master/housekeeping.lua (keine Boot-
-- Seiteneffekte) und beweist die neue Verdrahtung:
--  1. ACK_DELIVERED loest keinen "Unknown message type"-Alarm mehr aus und
--     markiert ein laufendes Config-Editor-Edit-Ziel als DELIVERED.
--  2. ACK_APPLIED korreliert gegen dasselbe Ziel (per message_id/ack_for)
--     und laesst master/config_edits.lua ueber APPLIED/REJECTED
--     entscheiden.
--  3. housekeeping.handle_command_timeouts() speist ausbleibende ACKs
--     (max_retries erschoepft) als TIMEOUT in dieselbe Zustandsmaschine
--     ein.

local constants = require('shared.constants')
local health = require('core.health')
local utils = require('core.utils')
local message_handlers = require('master.message_handlers')
local housekeeping = require('master.housekeeping')
local config_edits = require('master.config_edits')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_handler(nodes, edits_state, alarms)
  return message_handlers.new({
    constants = constants, utils = utils, health = health, nodes = nodes,
    comms = function() return { get_peers = function() return {} end } end,
    sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end },
    mark_rt_sync_dirty = function() end,
    add_alarm = function(id, severity, msg) alarms[#alarms + 1] = { id = id, severity = severity, msg = msg } end,
    master_time_label = function() return '12:00:00' end,
    log = function() end,
    config_edits_state = edits_state,
    on_config_edit_change = function() end,
  })
end

-- 1+2. ACK_DELIVERED then ACK_APPLIED for a real, in-flight config-editor
--    edit: no spurious alarm, and the shared config_edits_state actually
--    transitions QUEUED -> DELIVERED -> APPLIED.
do
  local nodes = {}
  local alarms = {}
  local edits_state = {}
  local fake_comms = {
    send_command = function(_self, id, payload, opts)
      return { message = { message_id = 'MSG-1' } }
    end,
  }
  config_edits.send_edit(edits_state, 'fuel_reserve', 3000, { nodes = { ['FUEL-1'] = { role = constants.roles.FUEL_NODE } }, comms = fake_comms, constants = constants })
  assert_eq(edits_state.fuel_reserve.pending.targets['FUEL-1'].status, 'QUEUED', 'setup: edit must start QUEUED')

  local handler = make_handler(nodes, edits_state, alarms)

  handler.update_node({
    type = constants.message_types.ACK_DELIVERED, ack_for = 'MSG-1',
    src = 'FUEL-1', sender_id = 'FUEL-1', node_id = 'FUEL-1', role = constants.roles.FUEL_NODE,
  })
  assert_eq(#alarms, 0, 'ACK_DELIVERED must not raise an "Unknown message type" alarm -- this was the pre-fix bug')
  assert_eq(edits_state.fuel_reserve.pending.targets['FUEL-1'].status, 'DELIVERED', 'ACK_DELIVERED must be wired through to config_edits.handle_ack_delivered')

  handler.update_node({
    type = constants.message_types.ACK_APPLIED, ack_for = 'MSG-1',
    src = 'FUEL-1', sender_id = 'FUEL-1', node_id = 'FUEL-1', role = constants.roles.FUEL_NODE,
    payload = { result = { ok = true } },
  })
  assert_eq(#alarms, 0, 'a successful ACK_APPLIED must not raise an alarm')
  local model = config_edits.model_for(edits_state, 'fuel_reserve', 2000)
  assert_eq(model.confirmed_value, 3000, 'ACK_APPLIED must be wired through to config_edits.handle_ack_applied and promote the confirmed value once all targets applied')
  assert_true(model.pending == nil, 'a fully-applied single-target edit must clear pending')
end

-- 3. housekeeping.handle_command_timeouts must feed an exhausted-retry
--    COMMAND timeout into config_edits.handle_timeout via the same
--    message_id correlation.
do
  local nodes = {}
  local edits_state = {}
  local fake_comms_for_edit = {
    send_command = function() return { message = { message_id = 'MSG-TIMEOUT-1' } } end,
  }
  config_edits.send_edit(edits_state, 'water_target', 500, { nodes = { ['WATER-1'] = { role = constants.roles.WATER_NODE } }, comms = fake_comms_for_edit, constants = constants })

  local timed_out_message = {
    type = constants.message_types.COMMAND,
    message_id = 'MSG-TIMEOUT-1',
    dst = 'WATER-1',
    payload = { command = { target = 'SET_TARGET', value = 500 } },
  }
  local housekeeping_comms = {
    consume_timeouts = function() return { { message = timed_out_message } } end,
  }

  housekeeping.handle_command_timeouts({
    constants = constants, utils = utils, comms = housekeeping_comms, nodes = nodes,
    log = function() end,
    config_edits_state = edits_state,
    on_config_edit_change = function() end,
  })

  assert_eq(edits_state.water_target.pending.targets['WATER-1'].status, 'TIMEOUT',
    'an exhausted-retry command timeout must be fed into config_edits.handle_timeout via the outgoing message_id')
  local model = config_edits.model_for(edits_state, 'water_target', 0)
  assert_eq(model.confirmed_value, 0, 'a timed-out edit must not promote the confirmed value')
  assert_true(model.pending.resolved == true, 'a timed-out single-target edit must resolve (not hang forever as pending)')
  -- Pre-existing behavior (unrelated to this fix) must still work: the
  -- generic per-node last_command_result is still recorded for the
  -- overview/diagnostics pages.
  assert_true(nodes['WATER-1'] ~= nil, 'housekeeping must still register the node for the generic timeout bookkeeping')
  assert_eq(nodes['WATER-1'].last_command_result.reason_code, 'ACK_TIMEOUT', 'generic last_command_result timeout bookkeeping must be unchanged')
end

print('master_config_edit_ack_wiring_test.lua: ok')
