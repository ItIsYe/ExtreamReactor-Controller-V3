from pathlib import Path

ROOT = Path('.')

def read(path): return (ROOT / path).read_text(encoding='utf-8')
def write(path, text): (ROOT / path).write_text(text, encoding='utf-8')
def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one anchor, got {count}: {old[:120]!r}')
    write(path, text.replace(old, new, 1))

# MASTER wiring fixture: persistent config success must say persisted=true.
p = 'tests/master_config_edit_ack_wiring_test.lua'
replace_once(p,
'''    payload = { result = { ok = true } },
''',
'''    payload = { result = { ok = true, persisted = true } },
''')

# RT mock: Lua locals are not visible inside their own RHS table initializer.
p = 'tests/rt_update_quiesce_hardware_confirmation_test.lua'
replace_once(p,
'''local reactor={active=true,setActive=function(v) reactor.active=v end,getActive=function() return reactor.active end}
''',
'''local reactor={active=true}
reactor.setActive=function(v) reactor.active=v end
reactor.getActive=function() return reactor.active end
''')

# VALVE source-extraction marker: use the stable boundary after the complete
# handler instead of the old exact final ACK line/signature.
for p in ['tests/valve_failed_write_retry_test.lua', 'tests/valve_sender_pairing_and_sorter_reconnect_test.lua']:
    replace_once(p,
'''local BLOCK_B = extract(SOURCE, 'local SEEN_COMMAND_LIMIT = 16',
  'send_valve_ack(reply_side, message.command_id, applied, current_high, last_write_error, message.src)\\nend')
''',
'''local BLOCK_B = extract(SOURCE, 'local SEEN_COMMAND_LIMIT = 16',
  '\\nlocal comms = comms_service.new({')
-- Drop the boundary marker itself; the extracted chunk only needs the helper
-- declarations and handle_valve_channel_event().
BLOCK_B = BLOCK_B:sub(1, #BLOCK_B - #'\\nlocal comms = comms_service.new({')
''')

# Existing pairing regression 1d represented the old unsafe behavior. The new
# contract is fail-closed: persistence failure removes RAM trust, blocks the
# valve again, and does not remember the command as successful.
p = 'tests/valve_sender_pairing_and_sorter_reconnect_test.lua'
replace_once(p,
'''-- 1d. Persistenzfehler waehrend des Pairings: das Pairing gilt trotzdem
--     sofort im RAM (Command wird verarbeitet), aber ein WARN macht die
--     fehlende Dauerhaftigkeit sichtbar (analog zu WATER/RT-P1).
do
  local inst = make_pairing_instance({ write_config_ok = false })
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-4', high = true } }
  inst.handle_valve_channel_event(event)

  assert_eq(inst.get_trusted_source(), 'FUEL-1', 'pairing must still take effect in RAM even if persistence fails')
  local found_warn = false
  for _, entry in ipairs(inst.log_lines) do
    if entry.level == 'WARN' and tostring(entry.msg):find('konnte nicht persistiert', 1, true) then found_warn = true end
  end
  assert_true(found_warn, 'a failed pairing persistence must be logged as WARN')
end
''',
'''-- 1d. Persistenzfehler waehrend des Pairings: kein RAM-Trust darf
--     zurueckbleiben. Der Safety-Aktor wird wieder BLOCKED gesetzt und die
--     command_id gilt NICHT als erfolgreich verarbeitet.
do
  local inst = make_pairing_instance({ write_config_ok = false })
  local event = { 'modem_message', 'left', 6504, 6504, { type = 'SET_VALVE', dst = 'VALVE-1', src = 'FUEL-1', command_id = 'CMD-4', high = false } }
  inst.handle_valve_channel_event(event)

  assert_eq(inst.get_trusted_source(), nil, 'failed durable pairing must undo RAM trust')
  assert_eq(inst.get_current_high(), true, 'failed pairing persistence must force the sorter back to BLOCKED')
  assert_true(not inst.seen_command_ids['CMD-4'], 'failed pairing must not dedupe a future retry as successful')
  local found_error = false
  for _, entry in ipairs(inst.log_lines) do
    if entry.level == 'ERROR' and tostring(entry.msg):find('NICHT dauerhaft gespeichert', 1, true) then found_error = true end
  end
  assert_true(found_error, 'failed durable pairing must be surfaced as ERROR')
end
''')

print('phase5 followup fixtures updated')
