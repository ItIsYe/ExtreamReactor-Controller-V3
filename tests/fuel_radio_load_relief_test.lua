package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- FUEL verliert keine Funkmeldungen mehr durch Ueberlast (v820).
--
-- Befund im Spiel (2026-10-12): auf der Seite VENTILE blieben immer
-- dieselben VALVE-Nodes "nie gehoert", alle mit Ender-Modem. FUEL hoert --
-- wie jede Node -- jede Meldung jeder anderen Node; auf einer grossen Anlage
-- (rund 40 Nodes, alle auf EINEM Lua-Thread des Servers) lief FUELs
-- Ereignis-Warteschlange (256) ueber, CC:Tweaked verwarf Meldungen still.
-- Gemessen (Anlagen-Harness, 3 RT + MASTER + 12 Ventile): je Meldung
-- 0.119 ms vorher, 0.061 ms nachher; Bildschirm-Modell 159-mal statt 30-mal
-- in 30 s gebaut.
--
--   1. services/ui_service.lua: passive Ereignisse bauen das Modell
--      hoechstens einmal je Intervall (vorher: nach Ablauf des Intervalls bei
--      JEDEM Ereignis neu, bis zum erzwungenen Zeichnen)
--   2. core/comms.lua payload_filter: Nachrichten, deren Inhalt die Rolle
--      nicht braucht, aktualisieren nur den Absender -- keine Kopie, keine
--      Handler; Ungueltiges und Filterfehler laufen den vollen Weg; ohne
--      Filter alles wie bisher
--   3. protocol.sanitize_envelope(): derselbe Umschlag wie
--      sanitize_message(), nur ohne Nutzlast
--   4. FUELs Filter: Inhalt von MASTER, mit Ziel, und ausser
--      Heartbeat/Status/Hello/Alarm -- sonst nur der Absender
--   5. FUELs Fuellstand-Mithoerer kopiert nur noch RT-Statusmeldungen
--   6. Seite VENTILE zeigt verlorene Timer (Ueberlast-Anzeige)

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local constants = require('shared.constants')
local T = constants.message_types
local R = constants.roles

local now = 5000000
local real_epoch = os.epoch
os.epoch = function() return now end

-- ══ 1. ui_service: hoechstens ein Modell je Intervall ══════════════════════
do
  package.loaded['services.ui_service'] = nil
  local ui_service = require('services.ui_service')
  local builds, renders = 0, 0
  local svc = ui_service.new({
    interval = 1, force_interval = 2,
    build_model = function() builds = builds + 1; return { snapshot = 'gleich' } end,
    render = function() renders = renders + 1 end,
  })
  svc:tick(nil, nil)                       -- erstes Zeichnen
  assert_eq(renders, 1, 'erstes Zeichnen')
  local before = builds
  -- 1.0 .. 1.95 s danach: 20 Funkmeldungen, Stand unveraendert.
  now = now + 1000
  for _ = 1, 20 do
    svc:tick(nil, { 'modem_message', 'back', 1, 1, {}, 1 })
    now = now + 45
  end
  assert_eq(builds - before, 1,
    'unveraenderter Stand: EIN Modell je Intervall, nicht eins je Funkmeldung (vorher 20)')
  assert_eq(renders, 1, 'und nichts gezeichnet')
  -- Nach dem naechsten Intervall wieder pruefen; das erzwungene Zeichnen
  -- (force_interval) bleibt.
  now = now + 200
  svc:tick(nil, { 'modem_message', 'back', 1, 1, {}, 1 })
  assert_eq(renders, 2, 'nach force_interval wird weiter gezeichnet')
  -- Touch bleibt sofort.
  svc:tick(nil, { 'monitor_touch', 'monitor_0', 3, 3 })
  assert_eq(renders, 3, 'Touch zeichnet sofort')
end

-- ══ 2./3. comms payload_filter und sanitize_envelope ═══════════════════════
local function message(src, role, msg_type, payload, extra)
  local m = {
    type = msg_type, message_id = src .. '-' .. tostring(now) .. '-' .. msg_type,
    src = src, sender_id = src, node_id = src, role = role, label = 'Name ' .. src,
    ts = now, timestamp = now, proto_ver = constants.proto_ver, payload = payload,
  }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

do
  local protocol = require('core.protocol')
  local raw = message('valve-1', R.VALVE_NODE, T.STATUS, { a = { b = 1 } }, { dst = 'master-1' })
  local full = protocol.sanitize_message(raw)
  local env = protocol.sanitize_envelope(raw)
  for _, k in ipairs({ 'type', 'message_id', 'sender_id', 'node_id', 'src', 'dst', 'role', 'label', 'ts', 'timestamp' }) do
    assert_eq(env[k], full[k], 'Umschlag gleich: ' .. k)
  end
  assert_eq(env.proto_ver.major, full.proto_ver.major, 'Protokoll gleich')
  assert_eq(env.payload, nil, 'ohne Nutzlast')
  assert_true(type(full.payload) == 'table' and full.payload.a.b == 1, 'sanitize_message unveraendert mit Nutzlast')
end

local function new_comms(filter)
  package.loaded['core.comms'] = nil
  local comms = require('core.comms')
  local network = { id = 'fuel-1', role = R.FUEL_NODE or 'FUEL-NODE',
    channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS } }
  function network:send() return true end
  comms.init({ network = network, node_id = 'fuel-1', role = network.role, config = {},
    logger = function() end, payload_filter = filter })
  return comms
end

do
  local protocol = require('core.protocol')
  local copies = 0
  local real_sanitize = protocol.sanitize_message
  protocol.sanitize_message = function(m) copies = copies + 1; return real_sanitize(m) end

  local fuel_status_network = require('nodes.fuel.fuel_status_network')
  local comms = new_comms(fuel_status_network.make_payload_filter(constants))
  local handled = {}
  comms.on('*', function(m) handled[#handled + 1] = m.type .. ':' .. tostring(m.src) end)

  -- Status einer anderen Node mit grosser Nutzlast: nur der Absender zaehlt.
  local big = { turbines = {} }
  for i = 1, 50 do big.turbines[i] = { rpm = 1800, flow = 2000, id = 'T' .. i } end
  comms.receive(message('rt-1', R.RT_NODE, T.STATUS, big))
  comms.receive(message('valve-7', R.VALVE_NODE, T.HEARTBEAT, { state = {} }))
  comms.tick()
  assert_eq(copies, 0, 'Heartbeat/Status anderer Nodes werden nicht kopiert')
  assert_eq(#handled, 0, 'und an keinen Handler gereicht')
  local peers = comms.get_peer_state()
  assert_true(peers['valve-7'] ~= nil, 'aber der Absender gilt als gehoert')
  assert_eq(peers['valve-7'].role, R.VALVE_NODE, 'mit Rolle')
  assert_eq(peers['valve-7'].label, 'Name valve-7', 'mit Namen (Seite VENTILE)')
  assert_eq(peers['rt-1'].last_message_type, T.STATUS, 'und letztem Typ')
  assert_eq(comms.get_diagnostics().metrics.peer_only, 2, 'gezaehlt')

  -- MASTER: voller Weg (Alarme, Relais).
  comms.receive(message('master-1', R.MASTER, T.STATUS, { alerts = {} }))
  -- Mit Ziel: voller Weg.
  comms.receive(message('rt-1', R.RT_NODE, T.STATUS, {}, { dst = 'fuel-1' }))
  -- Anderer Typ (Fehler): voller Weg.
  comms.receive(message('rt-2', R.RT_NODE, T.ERROR, { code = 'X' }))
  comms.tick()
  assert_eq(copies, 3, 'MASTER, gezielte Meldung und Fehler laufen den vollen Weg')
  assert_eq(#handled, 3, 'und erreichen die Handler')

  -- Ungueltig (keine Rolle): voller Weg -> wie bisher verworfen, nicht gehoert.
  local bad = message('valve-9', R.VALVE_NODE, T.HEARTBEAT, {})
  bad.role = nil
  comms.receive(bad)
  comms.tick()
  assert_eq(comms.get_peer_state()['valve-9'], nil, 'ungueltige Meldung zaehlt nicht als gehoert')

  protocol.sanitize_message = real_sanitize
end

-- Filter, der fehlschlaegt: voller Weg. Ohne Filter: alles wie bisher.
do
  local comms = new_comms(function() error('kaputt') end)
  local handled = 0
  comms.on('*', function() handled = handled + 1 end)
  comms.receive(message('valve-1', R.VALVE_NODE, T.HEARTBEAT, {}))
  comms.tick()
  assert_eq(handled, 1, 'fehlerhafter Filter: voller Weg')

  comms = new_comms(nil)
  handled = 0
  comms.on('*', function() handled = handled + 1 end)
  comms.receive(message('valve-1', R.VALVE_NODE, T.HEARTBEAT, {}))
  comms.tick()
  assert_eq(handled, 1, 'ohne Filter: unveraendert jede Nachricht an die Handler')
  assert_eq(comms.get_diagnostics().metrics.peer_only, 0, 'nichts nur als Lebenszeichen')
end

-- ══ 5. Mithoerer kopiert nur RT-Status ═════════════════════════════════════
do
  local protocol = require('core.protocol')
  local copies = 0
  local real_sanitize = protocol.sanitize_message
  protocol.sanitize_message = function(m) copies = copies + 1; return real_sanitize(m) end
  local fuel_status_network = require('nodes.fuel.fuel_status_network')
  local cache = fuel_status_network.new()
  local svc = fuel_status_network.make_overhear_service(cache, constants, constants.channels.STATUS)
  local function ev(m) return { 'modem_message', 'back', constants.channels.STATUS, constants.channels.STATUS, m, 1 } end
  svc.tick(svc, nil, ev(message('valve-1', R.VALVE_NODE, T.STATUS, { x = 1 })))
  svc.tick(svc, nil, ev(message('valve-2', R.VALVE_NODE, T.HEARTBEAT, { x = 1 })))
  assert_eq(copies, 0, 'Status/Heartbeat einer VALVE-Node: nicht kopiert')
  svc.tick(svc, nil, ev(message('rt-1', R.RT_NODE, T.STATUS, { reactors = {} })))
  assert_eq(copies, 1, 'RT-Status: gelesen wie bisher')
  protocol.sanitize_message = real_sanitize
end

-- ══ 6. Seite VENTILE: Ueberlast-Anzeige ═════════════════════════════════════
do
  local valve_page = require('nodes.fuel.valve_page')
  local data = valve_page.collect({ { id = 'v', link = 'online', online = true } }, now, { lost = 4, late = 1 })
  assert_eq(data.load.lost, 4, 'verlorene Timer')
  local chars = {}
  for y = 1, 40 do chars[y] = {} for x = 1, 82 do chars[y][x] = ' ' end end
  local cx, cy = 1, 1
  local mon = { getSize = function() return 82, 40 end, setCursorPos = function(x, y) cx, cy = x, y end,
    setTextColor = function() end, setBackgroundColor = function() end,
    write = function(s) s = tostring(s); for i = 1, #s do local x = cx + i - 1
      if x >= 1 and x <= 82 then chars[cy][x] = s:sub(i, i) end end; cx = cx + #s end }
  valve_page.new().render(mon, {}, true, data, '4/5')
  local row5 = table.concat(chars[5])
  assert_true(row5:find('Timer verloren 4', 1, true) ~= nil, 'Zeile 5 zeigt die verlorenen Timer: ' .. row5)
  assert_true(row5:find('UEBERLAST', 1, true) ~= nil, 'und nennt die Ueberlast')
end

os.epoch = real_epoch
print('ok fuel_radio_load_relief_test')
