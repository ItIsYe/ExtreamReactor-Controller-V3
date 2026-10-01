package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: ein wegen seiner HERKUNFT verworfenes ACK erreichte trotzdem
-- die Anwendungshandler.
--
-- core/comms.lua's handle_ack() prueft die Quelle gegen das Ziel des
-- ausgehenden Kommandos und verwirft ein fremdes ACK fuer seinen
-- Inflight-Eintrag -- korrekt. handle_message() rief danach aber UNBEDINGT
-- dispatch_handlers(). Die Anwendungsschicht sah das ACK also trotzdem.
-- master/config_edits.lua korreliert nur ueber die Nachrichten-ID, also
-- bestaetigte ein ACK eines anderen Nodes mit derselben ID einen Edit,
-- auf den das eigentliche Ziel nie geantwortet hatte -- waehrend die
-- Transportebene ihn weiterhin fuer offen hielt.

local function install_stubs()
  _G.fs = { exists = function() return false end, open = function() return nil end,
            getDir = function() return '' end, makeDir = function() end,
            getSize = function() return 0 end, move = function() end, delete = function() end }
  _G.textutils = { serialize = function(v) return tostring(v) end, unserialize = function() return nil end }
  _G.settings = { get = function() return false end }
  _G.os = _G.os or {}
  local now = 1000000
  os.epoch = function() return now end
  os.time = function() return 0 end
  os.date = function() return '00:00:00' end
  return function(ms) now = now + ms; return now end
end
local advance = install_stubs()

local constants = require('shared.constants')
local comms_lib = require('core.comms')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

local sent = {}
local net = {
  id = 'MASTER-1', role = constants.roles.MASTER,
  channels = { control = 6500, status = 6501 },
  send = function(_, _, payload) sent[#sent + 1] = payload; return true end,
}
local comms = comms_lib.init({
  network = net, node_id = 'MASTER-1', role = constants.roles.MASTER,
  proto_ver = constants.proto_ver, log_prefix = 'MASTER', config = {},
})

local dispatched = {}
comms.on(constants.message_types.ACK_APPLIED, function(message)
  dispatched[#dispatched + 1] = tostring(message.src)
end)
comms.on(constants.message_types.ACK_DELIVERED, function(message)
  dispatched[#dispatched + 1] = 'delivered:' .. tostring(message.src)
end)

-- Ein Kommando an FUEL-good senden und dessen message_id merken.
comms.send('FUEL-good', constants.message_types.COMMAND,
  { target = 'FUEL-good', command = { target = 'SET_RESERVE', value = 5000 } },
  { require_ack = true, require_applied = true, channel = 6500 })
comms.tick()
assert_true(#sent >= 1, 'das Kommando muss den Draht erreicht haben')
local message_id = sent[1].message_id
assert_true(message_id ~= nil)

local function ack_from(src, msg_type)
  return {
    type = msg_type, message_id = src .. '-ack-' .. tostring(#dispatched),
    sender_id = src, src = src, node_id = src,
    role = constants.roles.FUEL_NODE,
    ts = 1000000, timestamp = 1000000,
    proto_ver = { major = 1, minor = 0 },
    ack_for = message_id,
    payload = { result = { ok = true, persisted = true } },
  }
end

-- 1. ACK einer FREMDEN Quelle: wird verworfen UND nicht weitergereicht.
do
  comms.receive(ack_from('FUEL-other', constants.message_types.ACK_APPLIED))
  comms.tick()
  assert_eq(#dispatched, 0,
    'ein ACK mit falschem Absender darf die Anwendungshandler gar nicht erst erreichen')
end

-- 2. Dasselbe fuer die Zustellquittung.
do
  comms.receive(ack_from('FUEL-other', constants.message_types.ACK_DELIVERED))
  comms.tick()
  assert_eq(#dispatched, 0, 'auch die Zustellquittung einer fremden Quelle bleibt draussen')
end

-- 3. Das ACK des ECHTEN Ziels geht weiterhin durch.
do
  comms.receive(ack_from('FUEL-good', constants.message_types.ACK_APPLIED))
  comms.tick()
  assert_eq(#dispatched, 1, 'das ACK des eigentlichen Ziels muss ankommen')
  assert_eq(dispatched[1], 'FUEL-good')
end

-- 4. Ein ACK ohne passenden Inflight-Eintrag (doppelt, oder nach einem
--    Neustart dieser Node) wird wie bisher weitergereicht -- hier wurde
--    nichts wegen der Herkunft verworfen, es gibt nur nichts mehr zu
--    quittieren. Das war vorher so und muss so bleiben.
do
  dispatched = {}
  comms.receive(ack_from('FUEL-good', constants.message_types.ACK_APPLIED))
  comms.tick()
  assert_eq(#dispatched, 1,
    'ein ACK ohne Inflight-Eintrag darf nicht faelschlich als Herkunftsfehler behandelt werden')
end

print('comms_rejected_ack_not_dispatched_test.lua: ok')
