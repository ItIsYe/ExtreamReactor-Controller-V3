package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Funk-Hygiene Stufe 2 (v822): die Randfaelle der Kanalaufteilung, je
-- Baustein fuer sich (die Anlage selbst: radio_hygiene_stage2_test.lua).
--
--   1. core/comms.lua: Quittungen von MASTER auf dem Downlink, von jeder
--      anderen Rolle auf dem Uplink
--   2. comms_service: NUR Heartbeat/Status von MASTER AUF DEM DOWNLINK
--      schliesst den Uplink -- Kommandos und Hello sendet auch ein MASTER
--      bis v821 dort; nie bei Rollen, die den Uplink hoeren, nie wenn
--      Uplink und Downlink derselbe Kanal sind; Uhr-Ruecksprung oeffnet
--   3. core/utils.lua: Log-Zeilen nennen 6505; 6503 zu, sobald der
--      Collector auf 6505 antwortet (auch eine Quittung an eine andere
--      Node); 45 s Stille auf 6505 -> 6503 wieder offen; nie beim
--      LOG_COLLECTOR selbst; gebuendelte Quittung (event_ids)
--   4. Collector: Quittungen fuer Nodes ab v822 gebuendelt auf 6505, fuer
--      aeltere einzeln auf 6503; hoechstens 32 Kennungen je Quittung
--   5. VALVE: antwortet auf dem Kanal, den FUELs SET_VALVE nennt -- nur
--      6506 wird uebernommen, nie ein beliebiger Kanal, nie von einer
--      fremden Quelle

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local constants = require('shared.constants')
local T = constants.message_types
local R = constants.roles
local CH = constants.channels

local now = 7000000
local real_epoch = os.epoch
os.epoch = function() return now end
-- utils.log() (Uplink-Wechsel) liest beim ersten Aufruf Rolle und Kennung.
_G.fs = _G.fs or { exists = function() return false end, open = function() return nil end }
-- core/utils.lua buendelt Log-Zeilen nach os.clock(): an die Testuhr binden.
local real_clock = os.clock
os.clock = function() return now / 1000 end

local function message(src, role, msg_type, payload, extra)
  local m = {
    type = msg_type, message_id = src .. '-' .. tostring(now) .. '-' .. msg_type,
    src = src, sender_id = src, node_id = src, role = role, label = 'Name ' .. src,
    ts = now, timestamp = now, proto_ver = constants.proto_ver, payload = payload or {},
  }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

-- ══ 1. Quittungskanal ══════════════════════════════════════════════════════
local function ack_channel(role, node_id)
  package.loaded['core.comms'] = nil
  local comms = require('core.comms')
  local sent = {}
  local network = { id = node_id, role = role,
    channels = { control = CH.CONTROL, status = CH.STATUS } }
  function network:send(channel, msg) sent[#sent + 1] = { channel = channel, message = msg }; return true end
  comms.init({ network = network, node_id = node_id, role = role, config = {}, logger = function() end })
  comms.on(T.COMMAND, function() return { ok = true } end)
  comms.receive(message('master-1', R.MASTER, T.COMMAND,
    { target = node_id, command = { target = 'X' } }, { dst = node_id }))
  comms.tick()
  comms.tick()
  local channels = {}
  for _, item in ipairs(sent) do
    if item.message.type == T.ACK_DELIVERED or item.message.type == T.ACK_APPLIED then
      channels[#channels + 1] = item.channel
    end
  end
  return channels
end

do
  local rt = ack_channel(R.RT_NODE, 'rt-1')
  assert_true(#rt >= 1, 'RT quittiert')
  for _, ch in ipairs(rt) do assert_eq(ch, CH.STATUS, 'RT quittiert auf dem Uplink') end
  local valve = ack_channel(R.VALVE_NODE, 'valve-1')
  for _, ch in ipairs(valve) do assert_eq(ch, CH.STATUS, 'VALVE quittiert auf dem Uplink') end
  local master = ack_channel(R.MASTER, 'master-9')
  assert_true(#master >= 1, 'MASTER quittiert (Zustellung)')
  for _, ch in ipairs(master) do assert_eq(ch, CH.CONTROL, 'MASTER quittiert auf dem Downlink') end
end

-- ══ 2. Wann der Uplink schliesst ═══════════════════════════════════════════
local comms_service = require('services.comms_service')

local function new_service(opts)
  local modem_open = { [CH.CONTROL] = true, [CH.STATUS] = true }
  local svc = comms_service.new({ config = opts.config or { channels = { control = CH.CONTROL, status = CH.STATUS } },
    listen_uplink = opts.listen_uplink, log_prefix = 'TEST' })
  svc.network = { role = opts.role or R.RT_NODE, modem = {
    open = function(ch) modem_open[ch] = true end,
    close = function(ch) modem_open[ch] = nil end,
  } }
  local received = 0
  svc.comms = { receive = function() received = received + 1 end, tick = function() end }
  svc.modem_open = modem_open
  svc.received = function() return received end
  return svc
end

local function event(channel, msg) return { 'modem_message', 'back', channel, channel, msg, 1 } end

do
  local svc = new_service({ listen_uplink = false })
  -- Ein MASTER bis v821 sendet Kommandos und Hello auf 6500 -- das zeigt
  -- nicht, dass er auch Heartbeat/Status dort sendet.
  svc:handle_event(event(CH.CONTROL, message('master-1', R.MASTER, T.COMMAND)))
  svc:handle_event(event(CH.CONTROL, message('master-1', R.MASTER, T.HELLO)))
  -- Eine Node bis v821 sendet Hello auf 6500.
  svc:handle_event(event(CH.CONTROL, message('rt-2', R.RT_NODE, T.HEARTBEAT)))
  -- MASTERs Heartbeat auf 6501 (MASTER bis v821).
  svc:handle_event(event(CH.STATUS, message('master-1', R.MASTER, T.HEARTBEAT)))
  assert_eq(svc:get_uplink_state().closed, false, 'nichts davon schliesst den Uplink')
  assert_true(svc.modem_open[CH.STATUS], '6501 offen')
  assert_eq(svc.received(), 4, 'alles geht weiter an comms')

  svc:handle_event(event(CH.CONTROL, message('master-1', R.MASTER, T.STATUS)))
  assert_eq(svc:get_uplink_state().closed, true, 'MASTERs Status auf 6500 schliesst')
  assert_eq(svc.modem_open[CH.STATUS], nil, '6501 am Modem zu')
  assert_true(svc.modem_open[CH.CONTROL], '6500 bleibt offen')
  -- Rolle in anderer Schreibweise (wie in role.lua): auch MASTER.
  svc:handle_event(event(CH.CONTROL, message('master-1', 'master', T.HEARTBEAT)))
  assert_eq(svc:get_uplink_state().closes, 1, 'nur einmal geschlossen')

  -- 30 s Frist, gemessen ab der letzten MASTER-Meldung auf dem Downlink.
  now = now + comms_service.UPLINK_REOPEN_MS
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, true, 'genau 30 s: noch zu')
  now = now + 1
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, false, 'danach wieder offen')
  assert_true(svc.modem_open[CH.STATUS], '6501 am Modem wieder offen')

  -- Uhr springt zurueck: wieder oeffnen, statt ewig zu warten.
  svc:handle_event(event(CH.CONTROL, message('master-1', R.MASTER, T.HEARTBEAT)))
  assert_eq(svc:get_uplink_state().closed, true, 'wieder zu')
  now = now - 60000
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, false, 'Uhr-Ruecksprung: wieder offen')
  now = now + 60000
end

do
  -- Rollen, die den Uplink hoeren (MASTER, FUEL, alles ohne Angabe).
  local svc = new_service({ role = R.FUEL_NODE })
  svc:handle_event(event(CH.CONTROL, message('master-1', R.MASTER, T.HEARTBEAT)))
  assert_eq(svc:get_uplink_state().closed, false, 'FUEL schliesst nie')
  assert_true(svc:get_uplink_state().master_downlink_ms ~= nil, 'merkt sich MASTER trotzdem')

  -- Uplink und Downlink derselbe Kanal: nie schliessen.
  local same = new_service({ listen_uplink = false, config = { channels = { control = 6600, status = 6600 } } })
  same.modem_open[6600] = true
  same:handle_event(event(6600, message('master-1', R.MASTER, T.HEARTBEAT)))
  assert_eq(same:get_uplink_state().closed, false, 'gleicher Kanal: bleibt offen')
  assert_true(same.modem_open[6600], 'Kanal nicht geschlossen')
end

do
  -- Sendekanal je Rolle.
  local function sent_channel(role, method, ...)
    local svc = new_service({ role = role })
    local channel
    svc.comms = { send = function(_, _, _, opts) channel = opts.channel; return true end }
    svc[method](svc, ...)
    return channel
  end
  for _, method in ipairs({ 'publish_status', 'send_heartbeat', 'send_alert', 'send_hello' }) do
    assert_eq(sent_channel(R.MASTER, method, {}), CH.CONTROL, 'MASTER ' .. method .. ' auf dem Downlink')
    assert_eq(sent_channel(R.RT_NODE, method, {}), CH.STATUS, 'RT ' .. method .. ' auf dem Uplink')
    assert_eq(sent_channel(R.VALVE_NODE, method, {}), CH.STATUS, 'VALVE ' .. method .. ' auf dem Uplink')
  end
  assert_eq(sent_channel(R.MASTER, 'send_command', 'rt-1', { target = 'X' }), CH.CONTROL, 'Kommandos auf dem Downlink')
end

-- ══ 3. Log-Kanal der Nodes ═════════════════════════════════════════════════
local function load_utils(role)
  package.loaded['core.utils'] = nil
  package.loaded['core.logger'] = { log = function() end }
  local open = {}
  local transmitted = {}
  local modem = {
    isWireless = function() return true end,
    open = function(ch) open[ch] = true end,
    close = function(ch) open[ch] = nil end,
    transmit = function(ch, reply, payload) transmitted[#transmitted + 1] = { channel = ch, payload = payload } end,
  }
  _G.peripheral = {
    getNames = function() return { 'modem_0' } end,
    getType = function() return 'modem' end,
    wrap = function() return modem end,
  }
  _G.fs = {
    exists = function(p) return p == '/xreactor_config/role.lua' end,
    open = function(p)
      if p ~= '/xreactor_config/role.lua' then return nil end
      return { readAll = function() return 'return { role = "' .. role .. '" }' end, close = function() end }
    end,
  }
  _G.os.getComputerID = function() return 42 end
  local utils = require('core.utils')
  utils.set_log_mode('all')
  return utils, open, transmitted
end

do
  local utils, open, transmitted = load_utils('rt')
  -- Den Log-Puffer der Node leeren (er geht nach 250 ms raus).
  local function flush()
    now = now + 300
    utils.flush_remote_logs(false)
  end
  utils.log('RT', 'erste Zeile', 'INFO')
  flush()
  assert_true(open[CH.LOG], '6503 offen (Collector bis v821 antwortet dort)')
  assert_true(open[CH.LOG_REPLY], '6505 offen')
  local payload = transmitted[#transmitted] and transmitted[#transmitted].payload
  assert_true(payload ~= nil, 'Log-Zeile gesendet')
  local entry = payload.entries and payload.entries[1] or payload
  assert_eq(entry.reply_channel, CH.LOG_REPLY, 'die Log-Zeile nennt den Antwortkanal')
  assert_eq(transmitted[#transmitted].channel, CH.LOG, 'gesendet auf 6503')

  -- Ping auf 6503 (Collector bis v821): 6503 bleibt offen.
  utils.handle_remote_log_message({ type = 'LOG_PING', collector_node = 'LOG-1' }, CH.LOG)
  assert_true(open[CH.LOG], 'Ping auf 6503: bleibt offen')
  assert_eq(utils.remote_log_status().log_channel_closed, false, 'nicht geschlossen')
  -- Ohne Kanal (aelterer Aufrufer): zaehlt nicht.
  utils.handle_remote_log_message({ type = 'LOG_PING', collector_node = 'LOG-1' })
  assert_true(open[CH.LOG], 'ohne Kanal: bleibt offen')

  -- Eine Quittung an eine ANDERE Node auf 6505: der Collector ist ab v822.
  utils.handle_remote_log_message({ type = 'LOG_ACK', event_id = 'x', to_node = 'node-99' }, CH.LOG_REPLY)
  assert_eq(open[CH.LOG], nil, '6503 zu, sobald der Collector auf 6505 antwortet')
  assert_true(open[CH.LOG_REPLY], '6505 bleibt offen')
  assert_eq(utils.remote_log_status().log_channel_closes, 1, 'einmal geschlossen')

  -- Die Modem-Auffrischung (alle 10 s) oeffnet 6503 NICHT wieder.
  now = now + 11 * 1000
  utils.flush_remote_logs(true)
  assert_eq(open[CH.LOG], nil, 'Auffrischung laesst 6503 zu')

  -- Gebuendelte Quittung: alle genannten Zeilen gelten als zugestellt.
  local before = #transmitted
  for i = 1, 3 do utils.log('RT', 'Zeile ' .. i, 'INFO') end
  flush()
  local ids = {}
  for index = before + 1, #transmitted do
    local t = transmitted[index]
    for _, e in ipairs(t.payload.entries or { t.payload }) do
      if e.event_id then ids[#ids + 1] = e.event_id end
    end
  end
  assert_eq(#ids, 3, 'drei Zeilen gesendet')
  local pending_before = utils.remote_log_status().pending
  assert_true(pending_before >= 3, 'Zeilen warten auf Quittung (' .. pending_before .. ')')
  utils.handle_remote_log_message({ type = 'LOG_ACK', event_ids = ids, to_node = 'pc-42' }, CH.LOG_REPLY)
  assert_eq(utils.remote_log_status().pending, pending_before - 3, 'eine gebuendelte Quittung erledigt alle drei Zeilen')
  -- Eine gebuendelte Quittung an eine andere Node erledigt nichts.
  utils.log('RT', 'noch eine', 'INFO')
  flush()
  local last = transmitted[#transmitted].payload
  local last_id = (last.entries and last.entries[#last.entries] or last).event_id
  local pending_mid = utils.remote_log_status().pending
  utils.handle_remote_log_message({ type = 'LOG_ACK', event_ids = { last_id }, to_node = 'node-7' }, CH.LOG_REPLY)
  assert_eq(utils.remote_log_status().pending, pending_mid, 'fremde Quittung zaehlt nicht')
  local t_reply = now

  -- 45 s nichts auf 6505: 6503 wieder offen (v824; in v822 60 s -- laenger
  -- als die 45 s, nach denen die Node den Collector fuer offline haelt).
  now = t_reply + 45 * 1000
  utils.flush_remote_logs(false)
  assert_eq(open[CH.LOG], nil, 'genau 45 s: noch zu')
  now = t_reply + 45 * 1000 + 1
  utils.flush_remote_logs(false)
  assert_true(open[CH.LOG], 'nach 45 s ohne Antwort auf 6505: 6503 wieder offen')
  assert_eq(utils.remote_log_status().log_channel_reopens, 1, 'einmal wieder geoeffnet')
end

do
  -- Der LOG_COLLECTOR schliesst 6503 nie -- dort kommen die Log-Zeilen an.
  for _, role in ipairs({ 'LOG_COLLECTOR', 'LOG', 'log-collector' }) do
    local utils, open = load_utils(role)
    utils.log('LOG', 'x', 'INFO')
    utils.handle_remote_log_message({ type = 'LOG_PING', collector_node = 'LOG-2' }, CH.LOG_REPLY)
    assert_true(open[CH.LOG], role .. ': 6503 bleibt offen')
  end
end
package.loaded['core.utils'] = nil
package.loaded['core.logger'] = nil

-- ══ 4. Collector: gebuendelte Quittungen ═══════════════════════════════════
do
  local function read(path)
    local f = assert(io.open(path, 'r'))
    local c = f:read('*a')
    f:close()
    return c
  end
  local source = read('xreactor/nodes/log_collector/main.lua')
  local s = source:find('local function transmit_ack(ack, channel)', 1, true)
  local e = source:find('-- Unaddressed presence beacon', s, true)
  assert_true(s and e, 'transmit_ack/send_ack/send_acks gefunden')
  local chunk = 'local send_ack, send_acks\n' .. source:sub(s, e - 1)
    .. '\nreturn { send_ack = send_ack, send_acks = send_acks }\n'
  local sent = {}
  local env = setmetatable({
    stats = { ack_sent = 0, modems = { { wireless = true, modem = {
      transmit = function(ch, reply, ack) sent[#sent + 1] = { channel = ch, reply = reply, ack = ack } end } } } },
    computer_node_id = function() return 'LOG-1' end,
    now_ms = function() return 1 end,
    CHANNEL = 6503, REPLY_CHANNEL = 6505,
  }, { __index = _G })
  local mod = assert(load(chunk, '=collector_acks', 't', env))()

  local payloads = {
    { node_id = 'rt-1', ack = true, event_id = 'rt-1:1', reply_channel = 6505 },
    { node_id = 'rt-1', ack = true, event_id = 'rt-1:2', reply_channel = 6505 },
    { node_id = 'old-1', ack = true, event_id = 'old-1:1' },
    { node_id = 'rt-1', ack = true, event_id = 'rt-1:3', reply_channel = 6505 },
    { node_id = 'old-1', ack = true, event_id = 'old-1:2' },
    -- Ein beliebiger Kanal aus einer Funkmeldung wird nie uebernommen.
    { node_id = 'odd-1', ack = true, event_id = 'odd-1:1', reply_channel = 6500 },
    { node_id = 'noack', ack = false, event_id = 'n:1', reply_channel = 6505 },
  }
  mod.send_acks(payloads, 'written')
  local batched, single = {}, {}
  for _, item in ipairs(sent) do
    assert_eq(item.channel, item.reply, 'Antwortkanal = Kanal')
    if item.ack.event_ids then batched[#batched + 1] = item else single[#single + 1] = item end
  end
  assert_eq(#batched, 1, 'EINE Quittung fuer rt-1')
  assert_eq(batched[1].channel, 6505, 'auf 6505')
  assert_eq(batched[1].ack.to_node, 'rt-1', 'an rt-1')
  assert_eq(table.concat(batched[1].ack.event_ids, ','), 'rt-1:1,rt-1:2,rt-1:3', 'mit allen Kennungen in Reihenfolge')
  assert_eq(batched[1].ack.type, 'LOG_ACK', 'als LOG_ACK')
  assert_eq(batched[1].ack.status, 'written', 'Status')
  assert_eq(#single, 3, 'aeltere Node und fremder Kanal: einzeln')
  for _, item in ipairs(single) do
    assert_eq(item.channel, 6503, 'einzeln auf 6503: ' .. tostring(item.ack.event_id))
    assert_true(item.ack.event_id ~= nil and item.ack.event_ids == nil, 'Einzelquittung wie bisher')
  end
  assert_eq(env.stats.ack_sent, 4, 'vier Sendungen statt sechs')

  -- Hoechstens 32 Kennungen je Quittung.
  sent = {}
  local many = {}
  for i = 1, 70 do many[i] = { node_id = 'rt-2', ack = true, event_id = 'rt-2:' .. i, reply_channel = 6505 } end
  mod.send_acks(many, 'written')
  assert_eq(#sent, 3, '70 Kennungen in drei Quittungen')
  assert_eq(#sent[1].ack.event_ids, 32, 'erste voll')
  assert_eq(#sent[3].ack.event_ids, 6, 'Rest')

  -- Duplikat-Quittung (send_ack) an eine Node ab v822: auf 6505.
  sent = {}
  mod.send_ack({ node_id = 'rt-1', ack = true, event_id = 'rt-1:9', reply_channel = 6505 }, 'duplicate')
  assert_eq(sent[1].channel, 6505, 'Einzelquittung an neue Node auf 6505')
end

-- ══ 5. VALVE lernt den Antwortkanal ═══════════════════════════════════════
do
  local controller_lib = require('nodes.valve.controller')
  local acks = {}
  local peripheral_api = {
    getNames = function() return { 'logisticalSorter_1' } end,
    getMethods = function() return { 'setAutoMode' } end,
    find = function() return nil end,
    wrap = function(name)
      if name == 'left' then
        return { transmit = function(ch, reply, msg) acks[#acks + 1] = { channel = ch, reply = reply, message = msg } end }
      end
      return { setAutoMode = function() end }
    end,
  }
  local controller = controller_lib.new({
    config = { sorter_name = 'logisticalSorter_1', trusted_source = 'fuel-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'valve-1',
    constants = constants,
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = peripheral_api,
    colors_api = { orange = 1, red = 2, green = 3 },
    os_api = { epoch = function() return now end },
  })
  assert_eq(controller:reply_channel(), CH.VALVE, 'vor der ersten SET_VALVE: 6504')

  local seq = 0
  local function set_valve(src, reply_channel)
    seq = seq + 1
    return controller:handle_event({ 'modem_message', 'left', CH.VALVE, CH.VALVE,
      { type = 'SET_VALVE', dst = 'valve-1', src = src, command_id = 'C' .. seq, high = true,
        reply_channel = reply_channel } })
  end

  -- FUEL bis v821: kein reply_channel -> 6504.
  assert_true(set_valve('fuel-1', nil), 'angenommen')
  assert_eq(acks[#acks].channel, CH.VALVE, 'Quittung auf 6504')
  assert_eq(controller:reply_channel(), CH.VALVE, 'weiter 6504')

  -- FUEL ab v822: 6506.
  assert_true(set_valve('fuel-1', CH.VALVE_REPLY), 'angenommen')
  assert_eq(acks[#acks].channel, CH.VALVE_REPLY, 'Quittung auf 6506')
  assert_eq(acks[#acks].reply, CH.VALVE_REPLY, 'Antwortkanal 6506')
  assert_eq(controller:reply_channel(), CH.VALVE_REPLY, 'gelernt: 6506 (HOP_SCAN, Teach)')

  -- Ein beliebiger Kanal wird nie uebernommen.
  assert_true(set_valve('fuel-1', CH.CONTROL), 'angenommen')
  assert_eq(acks[#acks].channel, CH.VALVE, 'unbekannter Kanal: Quittung auf 6504')
  assert_eq(controller:reply_channel(), CH.VALVE, 'und zurueck auf 6504')

  -- Fremde Quelle: nichts gesendet, nichts gelernt.
  assert_true(set_valve('fuel-1', CH.VALVE_REPLY), 'angenommen')
  local accepted_id = 'C' .. seq
  local before = #acks
  assert_true(not set_valve('evil-1', CH.CONTROL), 'fremde Quelle abgewiesen')
  assert_eq(#acks, before, 'keine Quittung an eine fremde Quelle')
  assert_eq(controller:reply_channel(), CH.VALVE_REPLY, 'fremde Quelle aendert den Kanal nicht')

  -- Abgelehnte Wiederverwendung einer Kennung: Quittung auf dem Kanal der Meldung.
  controller:handle_event({ 'modem_message', 'left', CH.VALVE, CH.VALVE,
    { type = 'SET_VALVE', dst = 'valve-1', src = 'fuel-1', command_id = accepted_id, high = false,
      reply_channel = CH.VALVE_REPLY } })
  assert_eq(acks[#acks].message.error, 'COMMAND_ID_REUSE', 'Wiederverwendung abgelehnt')
  assert_eq(acks[#acks].channel, CH.VALVE_REPLY, 'auch die Ablehnung auf 6506')
end

os.epoch = real_epoch
os.clock = real_clock
print('ok radio_hygiene_stage2_unit_test')
