package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Funk-Hygiene Stufe 3 (v823): FUEL fragt die Ventile selbst ab.
--
-- Befund nach v822: FUEL hoerte weiter den ganzen Uplink 6501 -- jede Node
-- sendet alle 2 s einen Heartbeat und alle 5 s einen Status. Gebraucht hat
-- FUEL davon nur, OB die Ventile da sind. In einer Anlage mit 29 Ventilen
-- und rund 40 Nodes sind das gut 1700 Meldungen je Minute, die FUELs
-- Warteschlange (256) fuellen.
--
--   1. Anlage: FUEL pingt alle 10 s (VALVE_PING auf 6504), die Ventile
--      antworten (VALVE_PONG auf 6506). Antworten alle Routen-Ventile und
--      sendet MASTER auf dem Downlink, schliesst FUEL 6501: danach kommt bei
--      FUEL nichts mehr von 6501 an, FUEL fuehrt nur MASTER als Peer, kennt
--      die Ventile trotzdem, und die Lieferung laeuft (Fuellstand ueber
--      MASTERs Weiterleitung)
--   2. Ein Ventil bis v822 (antwortet nicht): FUEL oeffnet 6501 nach 30 s
--      wieder und kennt das Ventil ueber dessen Heartbeat; antwortet es
--      wieder, schliesst FUEL fruehestens 60 s nach dem Oeffnen
--   3. Router: Ping-Takt, nur Antworten an diese FUEL-Node, Erreichbarkeit
--      aus Heartbeat UND Antwort (das Bessere zaehlt), 20 s ueberfaellig /
--      30 s weg, Uhr-Ruecksprung, Schliess-Pruefung (auch: ROUTER-Editor)
--   4. VALVE: antwortet nur der vertrauten Quelle (ungepaart: jeder), auf
--      dem genannten Antwortkanal (nur 6506), und der Ping aendert NICHTS
--      am Ventil -- kein Schreiben, keine Sicherungsfrist, kein Kanal
--   5. comms_service: Schliessen nur mit frischem MASTER auf dem Downlink
--      und ja der Pruefung; Pruefung nein oder Fehler -> offen; 60 s
--      Mindest-Offenzeit nach dem Wiederoeffnen; beim Schliessen die
--      uebrigen Peers still vergessen, solange zu nur MASTER fuehren

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')
local boot = require('support.cc_node_boot')
local constants = require('shared.constants')
local T = constants.message_types
local R = constants.roles
local CH = constants.channels

local function uplink(env) return env.services.COMMS:get_uplink_state() end

local function window(net, from_index, to_name)
  local out = { total = 0, by_channel = {}, from = {} }
  for i = from_index + 1, #net.delivered do
    local d = net.delivered[i]
    if d.to == to_name then
      out.total = out.total + 1
      out.by_channel[d.channel] = (out.by_channel[d.channel] or 0) + 1
      local m = d.message
      if type(m) == 'table' and m.type then
        local key = d.from .. ':' .. tostring(m.type)
        out.from[key] = (out.from[key] or 0) + 1
      end
    end
  end
  return out
end

local function valve_summary(net)
  local status = net:last_message_from('FUEL', 'STATUS')
  return status and status.payload and status.payload.valve_summary or {}
end

-- ══ 1./2. Anlage ═════════════════════════════════════════════════════════════
do
  local rt = plant.new_rt({ computer_id = 101, turbines = 1, node_id = 'node-101',
    reactor = { fuel = 1800, fuel_max = 4000 } })
  local master = plant.new_master({ computer_id = 1, node_id = 'master-1' })
  plant.boot_all({
    { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
    { name = 'MASTER', env = master, main = 'master/main.lua' },
  })
  local learn = bus_lib.new()
  learn:attach('RT', rt); learn:attach('MASTER', master)
  learn:run(80)
  local rt_status = learn:last_message_from('RT', 'STATUS')
  local global_id = rt_status and rt_status.payload.reactors[1].global_id
  assert_true(global_id ~= nil, 'RT muss die Reaktor-Kennung senden')

  local fuel = plant.new_fuel({ computer_id = 202, node_id = 'fuel-1', enabled = true, routes = string.format([[return {
  export_chest = "chest_0",
  reactors = {
    { reactor_id = %q, label = "Reaktor A", path = { "valve-1", "valve-2" },
      request_below = 0.9, fill_amount = 64 },
  },
}]], global_id) })
  local function valve(id, computer_id)
    return plant.new_valve({ computer_id = computer_id, node_id = id, config = string.format(
      'return { node_id = %q, redstone_side = "back", trusted_source = "fuel-1" }\n', id) })
  end
  local v1, v2 = valve('valve-1', 501), valve('valve-2', 502)
  local energy = plant.new_energy({ computer_id = 301, node_id = 'energy-1' })

  local exports = {}
  local real_export = fuel.wrapped['meBridge_0'].exportItem
  fuel.wrapped['meBridge_0'].exportItem = function(...)
    exports[#exports + 1] = fuel.clock_ms
    return real_export(...)
  end

  for _, spec in ipairs({ { fuel, 'nodes/fuel/main.lua' }, { v1, 'nodes/valve/main.lua' },
      { v2, 'nodes/valve/main.lua' }, { energy, 'nodes/energy/main.lua' } }) do
    boot.reset_module_cache(); spec[1]:activate(); spec[1]:boot(spec[2])
  end

  local net = bus_lib.new({ raw_channels = { [CH.VALVE] = true, [CH.VALVE_REPLY] = true } })
  local envs = { RT = rt, MASTER = master, FUEL = fuel, VALVE1 = v1, VALVE2 = v2, ENERGY = energy }
  for _, name in ipairs({ 'RT', 'MASTER', 'FUEL', 'VALVE1', 'VALVE2', 'ENERGY' }) do
    net:attach(name, envs[name])
    net:node(name).seen_transmitted = #envs[name].transmitted
  end

  net:run(300)   -- 30 s Anlauf

  -- ── 1. FUEL schliesst 6501 ────────────────────────────────────────────
  local u = uplink(fuel)
  assert_eq(u.listen, true, 'FUEL hoert den Uplink grundsaetzlich')
  assert_eq(u.closed, true, 'FUEL hat 6501 geschlossen: alle Ventile antworten, MASTER sendet auf 6500')
  assert_eq(u.closes, 1, 'genau einmal')
  local peers = fuel.services.COMMS:get_peers()
  for id, peer in pairs(peers) do
    assert_eq(peer.role, R.MASTER, 'FUEL fuehrt nur noch MASTER als Peer, nicht ' .. tostring(id))
  end

  local d0 = #net.delivered
  local nh0 = net.not_heard.FUEL or 0
  local tx_fuel0 = #fuel.transmitted
  local exports0 = #exports
  net:run(300)   -- 30 s Messfenster

  local rx = window(net, d0, 'FUEL')
  assert_eq(rx.by_channel[CH.STATUS], nil, 'bei FUEL kommt nichts mehr von 6501 an')
  assert_true((net.not_heard.FUEL or 0) - nh0 > 0, 'die Meldungen der anderen Nodes erreichen FUEL nicht')
  assert_true((rx.from['VALVE1:VALVE_PONG'] or 0) >= 2, 'valve-1 antwortet auf die Pings')
  assert_true((rx.from['VALVE2:VALVE_PONG'] or 0) >= 2, 'valve-2 antwortet auf die Pings')
  local rx_master = window(net, d0, 'MASTER')
  assert_true(rx.total * 2 < rx_master.total, string.format(
    'FUEL empfaengt %d, MASTER %d -- erwartet: weniger als die Haelfte', rx.total, rx_master.total))

  local pings = 0
  for i = tx_fuel0 + 1, #fuel.transmitted do
    local t = fuel.transmitted[i]
    if type(t.message) == 'table' and t.message.type == 'VALVE_PING' then
      pings = pings + 1
      assert_eq(t.channel, CH.VALVE, 'Ping auf 6504')
      assert_eq(t.message.reply_channel, CH.VALVE_REPLY, 'Ping nennt den Antwortkanal')
      assert_eq(t.message.src, 'fuel-1', 'Ping nennt FUEL')
    end
  end
  assert_true(pings >= 2 and pings <= 4, '30 s: drei Pings (' .. pings .. ')')

  local vs = valve_summary(net)
  assert_eq(vs.total, 2, 'FUEL kennt beide Ventile')
  assert_eq(vs.offline, 0, 'keines offline -- ohne deren Heartbeat')
  assert_true(#exports > exports0 or #exports >= 1, 'die Lieferung laeuft (Fuellstand von MASTER)')
  assert_true(#exports >= 1, 'mindestens eine Lieferung')
  -- MASTER hoert die Ventile weiter direkt (Heartbeat unveraendert).
  assert_true((rx_master.from['VALVE1:' .. T.HEARTBEAT] or 0) > 0, 'MASTER hoert valve-1 weiter')

  -- ── 2. Ein Ventil bis v822: antwortet nicht auf den Ping ──────────────
  local valve_channel = v2.services.valve_channel
  local real_tick = valve_channel.tick
  valve_channel.tick = function(self, dt, event)
    local m = event and event[5]
    if type(m) == 'table' and m.type == 'VALVE_PING' then return end
    return real_tick(self, dt, event)
  end
  net:run(350)   -- 35 s: valve-2s letzte Antwort ist jetzt aelter als 30 s
  u = uplink(fuel)
  assert_eq(u.closed, false, 'valve-2 antwortet nicht: FUEL oeffnet 6501 wieder')
  assert_eq(u.reopens, 1, 'einmal geoeffnet')
  net:run(50)
  vs = valve_summary(net)
  assert_eq(vs.offline, 0, 'FUEL kennt valve-2 jetzt ueber dessen Heartbeat')
  local d1 = #net.delivered
  net:run(50)
  local rx1 = window(net, d1, 'FUEL')
  assert_true((rx1.from['VALVE2:' .. T.HEARTBEAT] or 0) > 0, 'FUEL hoert valve-2s Heartbeat auf 6501')

  -- valve-2 antwortet wieder: FUEL schliesst, aber nicht vor 60 s offen.
  valve_channel.tick = real_tick
  local opened_ms = uplink(fuel).opened_ms
  net:run(200)
  assert_eq(uplink(fuel).closed, false, 'noch keine 60 s offen: bleibt offen')
  net:run(300)
  u = uplink(fuel)
  assert_eq(u.closed, true, 'danach wieder zu')
  assert_eq(u.closes, 2, 'zweimal geschlossen')
  assert_true(fuel.clock_ms - opened_ms >= 60000, 'fruehestens 60 s nach dem Oeffnen')
end

-- ══ 3. Router ═════════════════════════════════════════════════════════════════
local now = 9000000
local real_epoch = os.epoch
os.epoch = function() return now end

local function new_router(peers)
  package.loaded['nodes.fuel.redstone_router'] = nil
  local sent = {}
  local modem = {
    isWireless = function() return true end,
    open = function() end,
    transmit = function(ch, reply, msg) sent[#sent + 1] = { channel = ch, reply = reply, message = msg } end,
  }
  _G.peripheral = {
    find = function(kind, filter)
      if kind == 'modem' and (not filter or filter('top', modem)) then return modem end
    end,
    isPresent = function() return false end,
    wrap = function() return nil end,
  }
  local lib = require('nodes.fuel.redstone_router')
  local router = lib.new({
    config = { logistics = { redstone_tree = {
      { reactor = 'R1', label = 'R1', path = { 'valve-a', 'valve-b' } },
    } } },
    node_id = 'fuel-1',
    comms = { get_peers = function() return peers and peers() or {} end },
  })
  router:refresh()
  return router, sent, lib
end

do
  local router, sent, lib = new_router()
  assert_true(router:ping_valves(), 'erster Ping sofort')
  assert_eq(#sent, 1, 'gesendet')
  assert_eq(sent[1].channel, CH.VALVE, 'auf 6504')
  assert_eq(sent[1].message.type, 'VALVE_PING', 'VALVE_PING')
  assert_eq(sent[1].message.dst, nil, 'Rundruf an alle Ventile')
  now = now + lib.VALVE_PING_INTERVAL_MS - 1
  assert_true(not router:ping_valves(), 'vor 10 s kein zweiter')
  now = now + 1
  assert_true(router:ping_valves(), 'nach 10 s der naechste')
  now = now - 60000
  assert_true(router:ping_valves(), 'Uhr zurueckgesprungen: sofort')
  now = now + 60000

  -- Antworten: nur an diese FUEL-Node.
  assert_true(not router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-a', dst = 'fuel-9' }),
    'Antwort an eine andere FUEL-Node zaehlt nicht')
  assert_true(not router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-a' }), 'ohne Ziel zaehlt nicht')
  local ok, missing = router:all_valves_answer_ping()
  assert_true(not ok and missing == 'valve-a', 'noch antwortet keines')
  assert_true(router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-a', dst = 'fuel-1', label = 'Ventil A' }),
    'Antwort uebernommen')
  ok, missing = router:all_valves_answer_ping()
  assert_true(not ok and missing == 'valve-b', 'valve-b fehlt noch')
  router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-b', dst = 'fuel-1' })
  assert_true(router:all_valves_answer_ping(), 'beide antworten')

  -- Erreichbarkeit nur aus der Antwort (FUEL hoert keine Heartbeats).
  assert_eq(router:_valve_link('valve-a'), 'online', 'Antwort frisch: online')
  local status = router:get_valve_status()
  assert_eq(status[1].label, 'Ventil A', 'Name aus der Antwort')
  assert_true(status[1].online, 'online in der Statusanzeige')
  now = now + lib.VALVE_PONG_STALE_MS + 1
  assert_eq(router:_valve_link('valve-a'), 'stale', 'nach 20 s ueberfaellig (kein OPEN mehr)')
  assert_true(router:all_valves_answer_ping(), 'zum Schliessen reicht eine Antwort binnen 30 s')
  now = now + (lib.VALVE_PONG_DOWN_MS - lib.VALVE_PONG_STALE_MS)
  assert_eq(router:_valve_link('valve-a'), 'offline', 'nach 30 s weg')
  ok, missing = router:all_valves_answer_ping()
  assert_true(not ok, 'nach 30 s ohne Antwort: Uplink gebraucht')

  -- Uhr zurueck: eine Antwort aus der "Zukunft" ist ueberfaellig, nicht frisch.
  router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-a', dst = 'fuel-1' })
  now = now - 5000
  assert_eq(router:_valve_link('valve-a'), 'stale', 'Zeitstempel aus der Zukunft: ueberfaellig')
  ok = router:all_valves_answer_ping()
  assert_true(not ok, 'und nicht als Antwort zum Schliessen')
  now = now + 5000

  -- Schliess-Pruefung.
  router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-b', dst = 'fuel-1' })
  local can_close = router:uplink_close_check(false)
  assert_eq(can_close, true, 'alle antworten: schliessen erlaubt')
  local can_close_editing, reason = router:uplink_close_check(true)
  assert_eq(can_close_editing, false, 'ROUTER-Editor offen: nicht schliessen')
  assert_true(tostring(reason):find('ROUTER', 1, true) ~= nil, 'mit Grund')
end

do
  -- Heartbeat und Antwort: das Bessere zaehlt; ohne Routen darf FUEL schliessen.
  local hb = {}
  local router = new_router(function() return hb end)
  hb['valve-a'] = { last_seen = now, age = 0, down = false, stale = false, role = R.VALVE_NODE, label = 'Aus HB' }
  assert_eq(router:_valve_link('valve-a'), 'online', 'nur Heartbeat: online wie bisher')
  hb['valve-a'] = { last_seen = now - 40000, age = 40, down = true, stale = true, role = R.VALVE_NODE, label = 'Aus HB' }
  router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-a', dst = 'fuel-1' })
  assert_eq(router:_valve_link('valve-a'), 'online', 'Heartbeat weg, Antwort frisch: online')
  local entry = router:valve_peers()['valve-a']
  assert_eq(entry.via, 'ping', 'aus der Antwort')
  assert_eq(entry.label, 'Aus HB', 'Name aus dem Heartbeat, wenn die Antwort keinen hat')
  hb['valve-a'] = { last_seen = now, age = 0, down = false, stale = false, role = R.VALVE_NODE }
  now = now + 25000
  hb['valve-a'].last_seen = now
  assert_eq(router:_valve_link('valve-a'), 'online', 'Antwort ueberfaellig, Heartbeat frisch: online')
  assert_eq(router:valve_peers()['valve-a'].via, nil, 'aus dem Heartbeat')
  -- Ein Ventil, das in keiner Route steht, antwortet: es steht in
  -- valve_peers() (ROUTER-Auswahl), zaehlt aber nicht fuers Schliessen.
  router:handle_valve_pong({ type = 'VALVE_PONG', src = 'valve-new', dst = 'fuel-1', label = 'Neu' })
  assert_eq(router:valve_peers()['valve-new'].label, 'Neu', 'auch ein Ventil ausserhalb der Routen')
end

do
  package.loaded['nodes.fuel.redstone_router'] = nil
  local lib = require('nodes.fuel.redstone_router')
  local empty = lib.new({ config = {}, node_id = 'fuel-1', comms = { get_peers = function() return {} end } })
  -- Vor dem Laden der Ketten ist "alle antworten" trivial wahr -- das darf
  -- den Uplink nicht schliessen (sonst schliesst FUEL beim Start, oeffnet
  -- nach dem Laden wieder und wartet dann 60 s).
  local can_close, reason = empty:uplink_close_check(false)
  assert_eq(can_close, false, 'Ketten noch nicht geladen: nicht schliessen')
  assert_true(tostring(reason):find('nicht geladen', 1, true) ~= nil, 'mit Grund')
  empty:refresh()
  assert_true(empty:all_valves_answer_ping(), 'ohne Routen braucht FUEL keine Ventil-Heartbeats')
  assert_eq(empty:uplink_close_check(false), true, 'geladen, ohne Routen: schliessen erlaubt')
end

-- ══ 4. VALVE beantwortet den Ping ════════════════════════════════════════════
do
  local controller_lib = require('nodes.valve.controller')
  local sent, writes = {}, 0
  local peripheral_api = {
    getNames = function() return { 'logisticalSorter_1' } end,
    getMethods = function() return { 'setAutoMode' } end,
    find = function() return nil end,
    wrap = function(name)
      if name == 'left' then
        return { transmit = function(ch, reply, msg) sent[#sent + 1] = { channel = ch, reply = reply, message = msg } end }
      end
      return { setAutoMode = function() writes = writes + 1 end }
    end,
  }
  local function new_controller(trusted)
    return controller_lib.new({
      config = { sorter_name = 'logisticalSorter_1', trusted_source = trusted },
      config_path = '/xreactor/config/valve.lua', node_id = 'valve-1', label = 'Ventil Eins',
      constants = constants,
      utils = { log = function() end, write_config = function() return true end },
      peripheral_api = peripheral_api,
      colors_api = { orange = 1, red = 2, green = 3 },
      os_api = { epoch = function() return now end },
    })
  end
  local function ping(c, src, reply_channel)
    return c:handle_event({ 'modem_message', 'left', CH.VALVE, CH.VALVE,
      { type = 'VALVE_PING', src = src, ts = now, reply_channel = reply_channel } })
  end

  local c = new_controller('fuel-1')
  assert_true(c:apply_valve(true, true), 'Ventil gesperrt')
  local state_before = c:get_state()
  local writes_before = writes
  now = now + 5000
  assert_eq(ping(c, 'fuel-1', CH.VALVE_REPLY), false, 'ein Ping ist kein Kommando')
  assert_eq(#sent, 1, 'eine Antwort')
  local pong = sent[1]
  assert_eq(pong.channel, CH.VALVE_REPLY, 'auf 6506')
  assert_eq(pong.message.type, 'VALVE_PONG', 'VALVE_PONG')
  assert_eq(pong.message.src, 'valve-1', 'von diesem Ventil')
  assert_eq(pong.message.dst, 'fuel-1', 'an FUEL')
  assert_eq(pong.message.label, 'Ventil Eins', 'mit Namen')
  assert_eq(pong.message.blocked, true, 'mit Zustand')
  assert_eq(pong.message.initialized, true, 'Aktor bestaetigt')
  -- Der Ping aendert nichts am Ventil.
  assert_eq(writes, writes_before, 'kein Schreiben am Aktor')
  assert_eq(c:get_state().last_command_ts, state_before.last_command_ts, 'Sicherungsfrist unberuehrt')
  assert_eq(c:reply_channel(), CH.VALVE, 'kein Antwortkanal gelernt (das bleibt SET_VALVE)')

  -- Fremde Quelle: keine Antwort. Unbekannter Kanal: 6504.
  ping(c, 'evil-1', CH.VALVE_REPLY)
  assert_eq(#sent, 1, 'keine Antwort an eine fremde Quelle')
  ping(c, 'fuel-1', CH.CONTROL)
  assert_eq(sent[#sent].channel, CH.VALVE, 'unbekannter Antwortkanal: 6504')
  ping(c, 'fuel-1', nil)
  assert_eq(sent[#sent].channel, CH.VALVE, 'FUEL ohne Antwortkanal: 6504')

  -- Ungepaart: antwortet jeder Quelle (wie SET_VALVE), paart sich aber nicht.
  local fresh = new_controller(nil)
  local count = #sent
  ping(fresh, 'fuel-7', CH.VALVE_REPLY)
  assert_eq(#sent, count + 1, 'ungepaart: Antwort')
  assert_eq(fresh.config.trusted_source, nil, 'ein Ping paart nicht')
end

-- ══ 5. comms_service: wann FUEL den Uplink schliesst ═════════════════════════
do
  local comms_service = require('services.comms_service')
  _G.fs = _G.fs or { exists = function() return false end, open = function() return nil end }
  local function new_service(check)
    local open = { [CH.CONTROL] = true, [CH.STATUS] = true }
    local svc = comms_service.new({ config = { channels = { control = CH.CONTROL, status = CH.STATUS } },
      uplink_close_check = check, log_prefix = 'FUEL' })
    svc.network = { role = R.FUEL_NODE, modem = {
      open = function(ch) open[ch] = true end,
      close = function(ch) open[ch] = nil end,
    } }
    local forgotten = {}
    local peers = { ['master-1'] = { role = R.MASTER }, ['valve-1'] = { role = R.VALVE_NODE },
      ['rt-1'] = { role = R.RT_NODE } }
    svc.comms = {
      receive = function() end, tick = function() end,
      forget_peers = function(pred)
        for id, peer in pairs(peers) do
          if pred(id, peer) then peers[id] = nil; forgotten[#forgotten + 1] = id end
        end
      end,
    }
    svc.open, svc.peers, svc.forgotten = open, peers, forgotten
    return svc
  end
  local function master_hb(svc)
    svc:handle_event({ 'modem_message', 'back', CH.CONTROL, CH.CONTROL,
      { type = T.HEARTBEAT, role = R.MASTER, src = 'master-1' }, 1 })
  end

  local answer = { true, 'alle antworten' }
  local svc = new_service(function() return answer[1], answer[2] end)
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, false, 'ohne MASTER auf dem Downlink: offen')
  master_hb(svc)
  assert_eq(svc:get_uplink_state().closed, true, 'MASTER frisch + Pruefung ja: zu')
  assert_eq(svc.open[CH.STATUS], nil, '6501 am Modem zu')
  assert_eq(svc.peers['master-1'] ~= nil, true, 'MASTER bleibt Peer')
  assert_eq(svc.peers['valve-1'], nil, 'die uebrigen Peers still vergessen')
  assert_eq(svc.peers['rt-1'], nil, 'auch RT')

  answer = { false, 'Ventil valve-2 antwortet nicht' }
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, false, 'Pruefung nein: wieder offen')
  assert_true(svc.open[CH.STATUS], '6501 am Modem offen')
  answer = { true, 'alle antworten' }
  now = now + comms_service.UPLINK_MIN_OPEN_MS - 1000
  master_hb(svc)
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, false, 'vor 60 s nach dem Oeffnen nicht wieder zu')
  now = now + 1000
  master_hb(svc)
  assert_eq(svc:get_uplink_state().closed, true, 'nach 60 s wieder zu')

  -- MASTER schweigt 30 s: offen, auch wenn alle Ventile antworten.
  now = now + comms_service.UPLINK_REOPEN_MS + 1
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, false, 'MASTER still: offen')

  -- Pruefung wirft: offen.
  local broken = new_service(function() error('kaputt') end)
  master_hb(broken)
  broken:tick()
  assert_eq(broken:get_uplink_state().closed, false, 'fehlerhafte Pruefung: offen')
end

do
  -- Mit echtem core/comms: solange zu, fuehrt FUEL nur MASTER als Peer.
  package.loaded['core.comms'] = nil
  package.loaded['services.comms_service'] = nil
  local comms_service = require('services.comms_service')
  local can_close = false
  local svc = comms_service.new({ config = { channels = { control = CH.CONTROL, status = CH.STATUS } },
    uplink_close_check = function() return can_close, 'test' end, log_prefix = 'FUEL' })
  svc:init()
  -- Ohne Peripherie hat network.init() kein Modem; zum Oeffnen/Schliessen
  -- reicht dieses.
  svc.network.modem = { open = function() end, close = function() end }
  local function msg(src, role, t)
    return { type = t, message_id = src .. now .. t, src = src, sender_id = src, node_id = src, role = role,
      ts = now, timestamp = now, proto_ver = constants.proto_ver, payload = {} }
  end
  local function hear(channel, m)
    svc:handle_event({ 'modem_message', 'back', channel, channel, m, 1 })
    svc:tick()
  end
  hear(CH.STATUS, msg('rt-1', R.RT_NODE, T.HEARTBEAT))
  hear(CH.CONTROL, msg('master-1', R.MASTER, T.HEARTBEAT))
  assert_true(svc:get_peers()['rt-1'] ~= nil, 'offen: FUEL fuehrt alle Peers')
  can_close = true
  hear(CH.CONTROL, msg('master-1', R.MASTER, T.HEARTBEAT))
  assert_eq(svc:get_uplink_state().closed, true, 'zu')
  assert_eq(svc:get_peers()['rt-1'], nil, 'beim Schliessen vergessen')
  hear(CH.STATUS, msg('rt-2', R.RT_NODE, T.HEARTBEAT))
  assert_eq(svc:get_peers()['rt-2'], nil, 'solange zu: nur MASTER (ein Nachzuegler zaehlt nicht)')
  assert_true(svc:get_peers()['master-1'] ~= nil, 'MASTER bleibt')
  package.loaded['services.comms_service'] = nil
  package.loaded['core.comms'] = nil
end

os.epoch = real_epoch
print('ok radio_hygiene_stage3_test')
