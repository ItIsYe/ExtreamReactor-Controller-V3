package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
if not os.epoch then
  local fake_now = 200000
  os.epoch = function()
    fake_now = fake_now + 100
    return fake_now
  end
end

-- Regression test (Log-Analyse 2026-09-18, disk8.zip, node-102): eine RT-
-- Node kann nach einem Master-Verbindungsabbruch dauerhaft in AUTONOM
-- stecken bleiben, waehrend node.mode im Master noch "MASTER" zeigt. Der
-- Status-Payload-basierte Mode-Abgleich (runtime_ops_rt.sync_rt_node)
-- vergleicht nur node.mode gegen node.desired_mode -- blieb node.mode aus
-- irgendeinem Grund auf dem alten Wert stehen, wurde NIE ein neues
-- SET_MODE gesendet, waehrend der Master 20+ Minuten lang SET_SETPOINTS
-- verschickte, die die Node mit reason_code=INVALID_STATE ablehnte (jedes
-- Mal frisch beobachtbar in "Command failed on node-102: autonom:
-- ignoring setpoints").
--
-- Ein INVALID_STATE-ACK ist der direkteste Beweis, den der Master fuer den
-- echten RT-Modus bekommen kann. message_handlers.lua muss node.mode bei
-- so einem ACK sofort verwerfen, damit der naechste sync_rt_node()-Lauf
-- den Mismatch garantiert erkennt und ein neues SET_MODE nachsendet,
-- statt endlos auf einen naechsten (evtl. nie ankommenden) Status-Payload
-- zu warten.

local constants = require('shared.constants')
local handlers = require('master.message_handlers')
local health = require('core.health')
local utils = require('core.utils')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local node_id = utils.normalize_node_id('rt-102')
local nodes = { [node_id] = { id = node_id, role = constants.roles.RT_NODE, mode = 'MASTER' } }
local dirty_reasons = {}

local h = handlers.new({
  constants = constants,
  utils = utils,
  health = health,
  nodes = nodes,
  comms = function() return { get_peers = function() return {} end, send_command = function() end } end,
  sequencer = { enqueue = function() end, notify_stable = function() end, notify_ack = function() end, active = nil },
  mark_rt_sync_dirty = function(_, reason) dirty_reasons[#dirty_reasons + 1] = reason end,
  add_alarm = function() end,
  master_time_label = function() return '12:00:00' end,
  log = function() end
})

-- MASTER still believes mode=MASTER; the node rejects a setpoint with the
-- exact reason_code command_handler.lua's set_setpoints() sends when the
-- node's real mode isn't MASTER.
h.update_node({
  type = constants.message_types.ACK_APPLIED, sender_id = 'rt-102', node_id = 'rt-102', role = constants.roles.RT_NODE,
  ack_for = 'SET_SETPOINTS',
  payload = { result = { ok = false, error = 'autonom: ignoring setpoints', reason_code = 'INVALID_STATE', command_target = constants.command_targets.SET_SETPOINTS } }
})

assert_true(nodes[node_id].mode == nil, 'an INVALID_STATE rejection must discard the stale cached node.mode so the next sync detects the mismatch')

local found_desync_mark = false
for _, reason in ipairs(dirty_reasons) do
  if reason == 'mode_desync' then found_desync_mark = true end
end
assert_true(found_desync_mark, 'an INVALID_STATE rejection must mark rt_sync dirty so the mode correction is not deferred to the next unrelated sync')

-- A successful ACK must never trigger this -- only a genuine INVALID_STATE
-- rejection is authoritative proof of a mode desync.
nodes[node_id].mode = 'MASTER'
h.update_node({
  type = constants.message_types.ACK_APPLIED, sender_id = 'rt-102', node_id = 'rt-102', role = constants.roles.RT_NODE,
  ack_for = 'SET_SETPOINTS',
  payload = { result = { ok = true, command_target = constants.command_targets.SET_SETPOINTS } }
})
assert_true(nodes[node_id].mode == 'MASTER', 'a successful ACK must never discard node.mode')

print('master_ack_invalid_state_mode_resync_test.lua: ok')
