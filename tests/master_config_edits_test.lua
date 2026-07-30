package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer MASTER-P1 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 10 "Config-Editor behauptet Uebernahme vor
-- ACK_APPLIED"). Treibt das echte, require()-bare master/config_edits.lua
-- (reines Datenmodul, keine Boot-Seiteneffekte) direkt.

local config_edits = require('master.config_edits')

local constants = {
  roles = { FUEL_NODE = 'FUEL-NODE', WATER_NODE = 'WATER-NODE', RT_NODE = 'RT-NODE' },
}

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_comms()
  local sent = {}
  local next_id = 0
  return {
    sent = sent,
    send_command = function(_self, id, payload, opts)
      next_id = next_id + 1
      local message_id = 'MSG-' .. next_id
      sent[#sent + 1] = { id = id, payload = payload, opts = opts, message_id = message_id }
      return { message = { message_id = message_id } }
    end,
  }
end

-- 1. cycle_target: ALLE -> Node1 -> Node2 -> ALLE, ueberspringt Nodes
--    anderer Rollen.
do
  local nodes = {
    ['FUEL-1'] = { role = constants.roles.FUEL_NODE },
    ['FUEL-2'] = { role = constants.roles.FUEL_NODE },
    ['WATER-1'] = { role = constants.roles.WATER_NODE },
  }
  local edits_state = {}
  local t1 = config_edits.cycle_target(edits_state, 'fuel_reserve', nodes, constants)
  assert_eq(t1, 'FUEL-1', 'first cycle from ALL must select the first sorted FUEL node')
  local t2 = config_edits.cycle_target(edits_state, 'fuel_reserve', nodes, constants)
  assert_eq(t2, 'FUEL-2', 'second cycle must select the next FUEL node')
  local t3 = config_edits.cycle_target(edits_state, 'fuel_reserve', nodes, constants)
  assert_eq(t3, 'ALL', 'cycling past the last node must wrap back to ALL')
end

-- 2. send_edit: target=ALL sends to every matching-role node with
--    require_applied=true, and records a QUEUED entry per target keyed by
--    the real outgoing message_id.
do
  local nodes = {
    ['FUEL-1'] = { role = constants.roles.FUEL_NODE },
    ['FUEL-2'] = { role = constants.roles.FUEL_NODE },
    ['WATER-1'] = { role = constants.roles.WATER_NODE },
  }
  local comms = make_comms()
  local edits_state = {}
  local ok, count = config_edits.send_edit(edits_state, 'fuel_reserve', 4200, { nodes = nodes, comms = comms, constants = constants })
  assert_true(ok, 'send_edit must succeed when matching nodes exist')
  assert_eq(count, 2, 'send_edit must report exactly 2 targets')
  assert_eq(#comms.sent, 2, 'exactly 2 send_command calls expected')
  for _, s in ipairs(comms.sent) do
    assert_eq(s.payload.target, 'SET_RESERVE', 'command target must be SET_RESERVE')
    assert_eq(s.payload.value, 4200, 'value must be forwarded unchanged')
    assert_true(s.opts and s.opts.require_applied == true,
      'send_edit must request require_applied=true -- without it MASTER can never know whether a target actually applied the value')
  end
  local st = edits_state.fuel_reserve
  assert_true(st.pending ~= nil, 'a pending edit must be recorded')
  assert_eq(st.pending.value, 4200, 'pending value must match')
  assert_eq(st.pending.targets['FUEL-1'].status, 'QUEUED', 'each target starts as QUEUED')
  assert_eq(st.pending.targets['FUEL-2'].status, 'QUEUED', 'each target starts as QUEUED')
  assert_true(st.pending.targets['WATER-1'] == nil, 'a WATER node must not receive the FUEL command')
end

-- 3. send_edit: no matching node -> failure, nothing sent.
do
  local nodes = { ['WATER-1'] = { role = constants.roles.WATER_NODE } }
  local comms = make_comms()
  local edits_state = {}
  local ok, err = config_edits.send_edit(edits_state, 'fuel_reserve', 1000, { nodes = nodes, comms = comms, constants = constants })
  assert_eq(ok, false, 'send_edit must fail when no matching-role node exists')
  assert_eq(#comms.sent, 0, 'no send_command call expected')
end

-- 4. send_edit: a specific (non-ALL) target that is still present and
--    matches the role is the ONLY node addressed -- proves single-node
--    targeting actually works, not just the ALL broadcast path.
do
  local nodes = {
    ['FUEL-1'] = { role = constants.roles.FUEL_NODE },
    ['FUEL-2'] = { role = constants.roles.FUEL_NODE },
  }
  local comms = make_comms()
  local edits_state = { fuel_reserve = { target = 'FUEL-2' } }
  local ok, count = config_edits.send_edit(edits_state, 'fuel_reserve', 999, { nodes = nodes, comms = comms, constants = constants })
  assert_true(ok, 'send_edit must succeed for a single valid target')
  assert_eq(count, 1, 'exactly one target must be addressed')
  assert_eq(#comms.sent, 1, 'exactly one send_command call expected')
  assert_eq(comms.sent[1].id, 'FUEL-2', 'the selected node, not FUEL-1, must receive the command')
end

-- 5. send_edit: a stale selected target (no longer present / role
--    changed) falls back to ALL rather than silently doing nothing.
do
  local nodes = { ['FUEL-1'] = { role = constants.roles.FUEL_NODE } }
  local comms = make_comms()
  local warn_logs = {}
  local edits_state = { fuel_reserve = { target = 'FUEL-GONE' } }
  local ok, count = config_edits.send_edit(edits_state, 'fuel_reserve', 500, {
    nodes = nodes, comms = comms, constants = constants,
    log = function(msg, level) if level == 'WARN' then warn_logs[#warn_logs + 1] = msg end end,
  })
  assert_true(ok, 'send_edit must fall back to ALL when the selected target vanished')
  assert_eq(count, 1, 'the fallback must still reach the remaining matching node')
  assert_true(#warn_logs >= 1, 'a stale target selection must be logged as WARN')
end

-- 6. ACK_DELIVERED then ACK_APPLIED for ALL targets: confirmed_value only
--    updates once every target has actually applied it -- never earlier.
do
  local nodes = {
    ['FUEL-1'] = { role = constants.roles.FUEL_NODE },
    ['FUEL-2'] = { role = constants.roles.FUEL_NODE },
  }
  local comms = make_comms()
  local edits_state = {}
  config_edits.send_edit(edits_state, 'fuel_reserve', 3000, { nodes = nodes, comms = comms, constants = constants })
  local id1, id2 = comms.sent[1].message_id, comms.sent[2].message_id

  local model_before = config_edits.model_for(edits_state, 'fuel_reserve', 2000)
  assert_eq(model_before.confirmed_value, 2000, 'confirmed_value must stay at the fallback/previous value while a send is in flight')
  assert_true(model_before.pending ~= nil, 'a pending edit must be visible in the model')
  assert_eq(model_before.pending.applied, 0, 'no target has applied yet')

  config_edits.handle_ack_delivered(edits_state, { ack_for = id1 })
  assert_eq(edits_state.fuel_reserve.pending.targets['FUEL-1'].status, 'DELIVERED', 'ACK_DELIVERED must move a QUEUED target to DELIVERED')

  config_edits.handle_ack_applied(edits_state, { ack_for = id1, payload = { result = { ok = true } } })
  local model_mid = config_edits.model_for(edits_state, 'fuel_reserve', 2000)
  assert_eq(model_mid.confirmed_value, 2000,
    'confirmed_value must NOT update after only ONE of two targets applied -- this is the exact bug being fixed: ' ..
    'the old code showed the new value as soon as it was typed, regardless of any ACK')
  assert_eq(model_mid.pending.applied, 1, 'exactly one target has applied so far')

  config_edits.handle_ack_applied(edits_state, { ack_for = id2, payload = { result = { ok = true } } })
  local model_after = config_edits.model_for(edits_state, 'fuel_reserve', 2000)
  assert_eq(model_after.confirmed_value, 3000, 'confirmed_value must update once ALL targets have applied')
  assert_true(model_after.pending == nil, 'a fully-applied edit must clear the pending state')
end

-- 7. A rejected ACK on one of several targets must NOT promote the
--    confirmed value, and must surface the failing target.
do
  local nodes = {
    ['FUEL-1'] = { role = constants.roles.FUEL_NODE },
    ['FUEL-2'] = { role = constants.roles.FUEL_NODE },
  }
  local comms = make_comms()
  local edits_state = {}
  config_edits.send_edit(edits_state, 'fuel_reserve', 3000, { nodes = nodes, comms = comms, constants = constants })
  local id1, id2 = comms.sent[1].message_id, comms.sent[2].message_id

  config_edits.handle_ack_applied(edits_state, { ack_for = id1, payload = { result = { ok = true } } })
  config_edits.handle_ack_applied(edits_state, { ack_for = id2, payload = { result = { ok = false, error = 'invalid value' } } })

  local model = config_edits.model_for(edits_state, 'fuel_reserve', 2000)
  assert_eq(model.confirmed_value, 2000, 'a rejection on any target must keep the old confirmed value')
  assert_true(model.pending ~= nil, 'the resolved-but-failed edit must remain visible for the operator')
  assert_true(model.pending.resolved == true, 'a fully-resolved (even if failed) edit must be marked resolved')
  assert_eq(#model.pending.failed, 1, 'exactly one failing target must be reported')
end

-- 8. A timeout (no ACK at all) on a target must resolve the same way as a
--    rejection -- confirmed_value stays put, target shows as failed.
do
  local nodes = { ['FUEL-1'] = { role = constants.roles.FUEL_NODE } }
  local comms = make_comms()
  local edits_state = {}
  config_edits.send_edit(edits_state, 'fuel_reserve', 3000, { nodes = nodes, comms = comms, constants = constants })
  local id1 = comms.sent[1].message_id

  config_edits.handle_timeout(edits_state, id1)
  local model = config_edits.model_for(edits_state, 'fuel_reserve', 2000)
  assert_eq(model.confirmed_value, 2000, 'a timed-out target must not promote the confirmed value')
  assert_true(model.pending.resolved == true, 'a timed-out single-target edit must resolve immediately')
  assert_eq(edits_state.fuel_reserve.pending.targets['FUEL-1'].status, 'TIMEOUT', 'the target status must be TIMEOUT')
end

print('master_config_edits_test.lua: ok')
