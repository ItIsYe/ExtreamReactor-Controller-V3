package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Ventil-Ping: Toleranz und Sichtbarkeit (v824, Befunde der Code-Pruefung
-- nach v823).
--
-- v823 pingte alle 10 s und nannte ein Ventil nach 20 s "ueberfaellig" --
-- eine einzige verlorene Antwort reichte, damit FUEL es kurz nicht mehr
-- oeffnete; eine Lieferung, die genau dann oeffnete, brach ab und setzte
-- den Sicherheits-Riegel. Mit Heartbeats (2 s, 12 s) vertrug FUEL etwa fuenf
-- verlorene Meldungen. Und blieb 6501 offen, weil ein Ventil nie antwortete,
-- stand der Grund nirgends.
--
--   1. Ping alle 5 s; zwei verlorene Antworten hintereinander: weiter
--      online; ueberfaellig nach 17,5 s, weg nach 30 s
--   2. Quittung (VALVE_ACK) und HOP_SCAN zaehlen als Lebenszeichen -- aber
--      nur bei Ventilen, die auf den Ping antworten, und nie fuers
--      Schliessen des Uplinks
--   3. comms_service nennt den Grund (get_uplink_state().reason) und
--      schreibt ihn einmal ins Log, wenn der Uplink 60 s aus demselben
--      Grund offen bleibt -- nicht beim kurzen Anlauf, nicht wiederholt,
--      nicht bei Folge-Nodes
--   4. Seite VENTILE zeigt Uplink 6501 zu/offen mit Grund (Zeile 36)

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

local now = 4000000
local real_epoch = os.epoch
os.epoch = function() return now end
_G.fs = _G.fs or { exists = function() return false end, open = function() return nil end }

local function new_router(peers)
  package.loaded['nodes.fuel.redstone_router'] = nil
  local modem = { isWireless = function() return true end, open = function() end, transmit = function() end }
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
  return router, lib
end

local function pong(router, id)
  return router:handle_valve_pong({ type = 'VALVE_PONG', src = id, dst = 'fuel-1' })
end

-- ══ 1. Takt und Grenzen ════════════════════════════════════════════════════
do
  local router, lib = new_router()
  assert_eq(lib.VALVE_PING_INTERVAL_MS, 5000, 'Ping alle 5 s')
  assert_eq(lib.VALVE_PONG_STALE_MS, 17500, 'ueberfaellig nach 17,5 s')
  assert_eq(lib.VALVE_PONG_DOWN_MS, 30000, 'weg nach 30 s')

  pong(router, 'valve-a'); pong(router, 'valve-b')
  local t0 = now
  -- Zwei Runden ohne Antwort (5 s, 10 s), die dritte Antwort kommt etwas
  -- spaeter als der Ping (15 s + Laufzeit).
  now = t0 + 3 * lib.VALVE_PING_INTERVAL_MS + 500
  assert_eq(router:_valve_link('valve-a'), 'online', 'zwei verlorene Antworten: weiter online')
  assert_true(router:all_valves_answer_ping(), 'und der Uplink darf zu bleiben')
  now = t0 + lib.VALVE_PONG_STALE_MS + 1
  assert_eq(router:_valve_link('valve-a'), 'stale', 'nach 17,5 s ueberfaellig')
  now = t0 + lib.VALVE_PONG_DOWN_MS
  assert_true(router:all_valves_answer_ping(), 'genau 30 s: noch nicht weg')
  now = t0 + lib.VALVE_PONG_DOWN_MS + 1
  assert_eq(router:_valve_link('valve-a'), 'offline', 'nach 30 s weg')
  assert_true(not router:all_valves_answer_ping(), 'und der Uplink wird gebraucht')
end

-- ══ 2. Quittung und HOP_SCAN als Lebenszeichen ════════════════════════════
do
  local router, lib = new_router()
  pong(router, 'valve-a'); pong(router, 'valve-b')
  local t0 = now
  now = t0 + lib.VALVE_PONG_STALE_MS + 500
  assert_eq(router:_valve_link('valve-a'), 'stale', 'ohne weitere Zeichen ueberfaellig')

  -- Eine Quittung: SPERREN an valve-a, valve-a bestaetigt.
  assert_true(router:_set_valve('valve-a', true), 'SPERREN geht raus')
  local entry = router._state.pending_valve_acks['valve-a']
  router:handle_valve_ack({ type = 'VALVE_ACK', command_id = entry.command_id,
    src = 'valve-a', dst = 'fuel-1', applied = true, high = true })
  assert_eq(router:_valve_link('valve-a'), 'online', 'die Quittung haelt es online')
  -- Eine Quittung mit falscher Identitaet zaehlt nicht.
  assert_true(router:_set_valve('valve-b', true), 'SPERREN an valve-b')
  local entry_b = router._state.pending_valve_acks['valve-b']
  router:handle_valve_ack({ type = 'VALVE_ACK', command_id = entry_b.command_id,
    src = 'valve-x', dst = 'fuel-1', applied = true, high = true })
  assert_eq(router:_valve_link('valve-b'), 'stale', 'fremde Quittung: kein Lebenszeichen')
  -- HOP_SCAN.
  router:handle_hop_scan({ type = 'HOP_SCAN', src = 'valve-b', items = {}, ts = now })
  assert_eq(router:_valve_link('valve-b'), 'online', 'HOP_SCAN haelt es online')

  -- Fuers Schliessen zaehlt nur die Ping-Antwort.
  now = t0 + lib.VALVE_PONG_DOWN_MS + 1
  router:handle_hop_scan({ type = 'HOP_SCAN', src = 'valve-a', items = {}, ts = now })
  assert_eq(router:_valve_link('valve-a'), 'online', 'frischer HOP_SCAN: schaltbar')
  local ok, missing = router:all_valves_answer_ping()
  assert_true(not ok and missing == 'valve-a', 'aber ohne Ping-Antwort braucht FUEL den Uplink')
end

do
  -- Ein Ventil bis v822 (antwortet nie auf den Ping): seine Quittung zaehlt
  -- nicht -- erklaert comms es fuer weg, bleibt es weg.
  local hb = { ['valve-a'] = { last_seen = now, age = 0, down = false, stale = false, role = R.VALVE_NODE } }
  local router = new_router(function() return hb end)
  pong(router, 'valve-b')   -- ein anderes Ventil spricht schon v823
  assert_true(router:_set_valve('valve-a', true), 'SPERREN an das alte Ventil')
  local entry = router._state.pending_valve_acks['valve-a']
  router:handle_valve_ack({ type = 'VALVE_ACK', command_id = entry.command_id,
    src = 'valve-a', dst = 'fuel-1', applied = true, high = true })
  hb['valve-a'] = { last_seen = now - 20000, age = 20, down = true, stale = true, role = R.VALVE_NODE }
  assert_eq(router:_valve_link('valve-a'), 'offline', 'altes Ventil: comms entscheidet, nicht die Quittung')
end

-- ══ 3. comms_service: Grund und einmalige Log-Zeile ══════════════════════
local utils = require('core.utils')
local real_log = utils.log
local lines = {}
utils.log = function(prefix, message, level)
  lines[#lines + 1] = { prefix = prefix, message = tostring(message), level = level }
end
local function count_lines(fragment)
  local n = 0
  for _, line in ipairs(lines) do
    if line.message:find(fragment, 1, true) then n = n + 1 end
  end
  return n
end

local comms_service = require('services.comms_service')
local function new_service(opts)
  local svc = comms_service.new({ config = { channels = { control = CH.CONTROL, status = CH.STATUS } },
    uplink_close_check = opts.check, listen_uplink = opts.listen_uplink, log_prefix = 'FUEL' })
  svc.network = { role = opts.role or R.FUEL_NODE, modem = { open = function() end, close = function() end } }
  svc.comms = { receive = function() end, tick = function() end, forget_peers = function() end }
  return svc
end
local function master_hb(svc)
  svc:handle_event({ 'modem_message', 'back', CH.CONTROL, CH.CONTROL,
    { type = T.HEARTBEAT, role = R.MASTER, src = 'master-1' }, 1 })
end

do
  local answer = { false, 'Ventil valve-9 antwortet nicht auf VALVE_PING' }
  local svc = new_service({ check = function() return answer[1], answer[2] end })
  svc:tick()
  assert_true(tostring(svc:get_uplink_state().reason):find('noch nicht', 1, true) ~= nil,
    'vor MASTER: "MASTER noch nicht auf dem Downlink gehoert"')
  master_hb(svc)
  assert_eq(svc:get_uplink_state().reason, answer[2], 'Grund: das Ventil, das nicht antwortet')
  assert_eq(count_lines('bleibt offen'), 0, 'nicht sofort ins Log')
  now = now + comms_service.UPLINK_HOLD_LOG_MS - 1000
  master_hb(svc); svc:tick()
  assert_eq(count_lines('bleibt offen'), 0, 'vor 60 s nicht ins Log')
  now = now + 1000
  master_hb(svc); svc:tick()
  assert_eq(count_lines('bleibt offen'), 1, 'nach 60 s aus demselben Grund: einmal ins Log')
  assert_true(count_lines('valve-9') >= 1, 'mit dem Grund')
  now = now + 5 * comms_service.UPLINK_HOLD_LOG_MS
  master_hb(svc); svc:tick()
  assert_eq(count_lines('bleibt offen'), 1, 'nicht wiederholt')

  -- Anderer Grund: Uhr beginnt von vorn.
  answer = { false, 'Ventil valve-7 antwortet nicht auf VALVE_PING' }
  master_hb(svc)
  now = now + comms_service.UPLINK_HOLD_LOG_MS
  master_hb(svc); svc:tick()
  assert_eq(count_lines('bleibt offen'), 2, 'neuer Grund nach 60 s: wieder einmal')

  -- Zu: Grund ist der Schliessgrund. Wieder offen: Wartezeit als Grund.
  answer = { true, 'alle Ventile antworten' }
  master_hb(svc)
  assert_eq(svc:get_uplink_state().closed, true, 'zu')
  assert_eq(svc:get_uplink_state().reason, 'alle Ventile antworten', 'Schliessgrund')
  answer = { false, 'Ventil valve-7 antwortet nicht auf VALVE_PING' }
  svc:tick()
  answer = { true, 'alle Ventile antworten' }
  svc:tick()
  assert_eq(svc:get_uplink_state().closed, false, 'Mindest-Offenzeit')
  assert_true(tostring(svc:get_uplink_state().reason):find('fruehestens', 1, true) ~= nil,
    'Grund: Mindest-Offenzeit')
end

do
  -- Folge-Node: keine "bleibt offen"-Zeile (ihr Grund beim Start ist nur:
  -- MASTER noch nicht gehoert).
  local before = count_lines('bleibt offen')
  local svc = new_service({ listen_uplink = false, role = R.RT_NODE })
  svc:tick()
  now = now + 2 * comms_service.UPLINK_HOLD_LOG_MS
  svc:tick()
  assert_eq(count_lines('bleibt offen'), before, 'Folge-Node: nichts ins Log')
end
utils.log = real_log

-- ══ 4. Seite VENTILE ═══════════════════════════════════════════════════════
do
  local valve_page = require('nodes.fuel.valve_page')
  local status = { { id = 'v', link = 'online', online = true } }
  local closed = valve_page.collect(status, now, nil, { closed = true, reason = 'alle antworten' })
  assert_true(closed.uplink.text:find('ZU', 1, true) ~= nil, 'zu: ' .. closed.uplink.text)
  local open = valve_page.collect(status, now, nil, { closed = false, reason = 'Ventil v9 antwortet nicht auf VALVE_PING' })
  assert_true(open.uplink.text:find('OFFEN', 1, true) ~= nil, 'offen')
  assert_true(open.uplink.text:find('v9', 1, true) ~= nil, 'mit Grund')
  assert_eq(valve_page.collect(status, now).uplink, nil, 'ohne Angabe: nichts')

  local chars = {}
  for y = 1, 40 do chars[y] = {} for x = 1, 82 do chars[y][x] = ' ' end end
  local cx, cy = 1, 1
  local mon = { getSize = function() return 82, 40 end, setCursorPos = function(x, y) cx, cy = x, y end,
    setTextColor = function() end, setBackgroundColor = function() end,
    write = function(s) s = tostring(s); for i = 1, #s do local x = cx + i - 1
      if x >= 1 and x <= 82 and chars[cy] then chars[cy][x] = s:sub(i, i) end end; cx = cx + #s end }
  valve_page.new().render(mon, {}, true, open, '4/5')
  local row = table.concat(chars[36])
  assert_true(row:find('UPLINK 6501: OFFEN', 1, true) ~= nil, 'Zeile 36: ' .. row)

  -- monitor_ui reicht den Zustand von FUELs comms durch.
  local monitor_ui = require('nodes.fuel.monitor_ui')
  local data = monitor_ui.collect_valve_page({
    get_rs_router = function() return { get_valve_status = function() return status end } end,
    comms = { get_uplink_state = function() return { closed = false, reason = 'Grund X' } end },
  }, now)
  assert_true(data.uplink ~= nil and data.uplink.text:find('Grund X', 1, true) ~= nil,
    'monitor_ui gibt den Uplink-Zustand an die Seite')
end

os.epoch = real_epoch
print('ok fuel_valve_ping_tolerance_test')
