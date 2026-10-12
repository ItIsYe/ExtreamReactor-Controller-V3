package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- FUEL-Seite VENTILE (nodes/fuel/valve_page.lua, v819).
--
-- Wunsch des Betreibers (2026-10-12), nachdem FUEL "6 von 29 noch nicht
-- gehoert" meldete: eine eigene Seite, auf der alle Ventile stehen, farbig
-- nach online / offline / nicht aktuell, mit Status und wann sie zuletzt
-- gehoert wurden -- um einfacher reparieren zu koennen.
--
--   1. collect(): Probleme zuerst, Zaehler, "zuletzt gehoert" in groben
--      Stufen, Ventil-Rueckmeldung ZU / AUF / FEHLER, Reaktoren je Ventil
--   2. Zeichnen auf einem echten 82x40-Raster mit den echten Farben:
--      Kopf "4/5", Zusammenfassung, farbiger Zustand, Blaettern ohne
--      Geisterzeilen
--   3. redstone_router.get_valve_status(): zuletzt gehoert und Name bleiben
--      nach dem Ablauf aus der Peer-Tabelle erhalten; eine Rueckmeldung
--      applied=false bleibt false (nicht nil)
--   4. monitor_ui: fuenf Seiten, VENTILE als vierte; die Ventilliste kommt
--      nur ins Modell, solange die Seite offen ist

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local valve_page = require('nodes.fuel.valve_page')
local palette = require('shared.colors')

-- ══ 1. collect() ════════════════════════════════════════════════════════════
local NOW = 2000000000
do
  local data = valve_page.collect({
    { id = 'node-10', label = 'Nord', link = 'online', online = true, last_seen_ms = NOW - 3000,
      ack_applied = true, ack_high = true, affected_routes = { 'Reaktor 1' } },
    { id = 'node-11', label = 'node-11', link = 'unknown', unknown = true, online = false,
      affected_routes = { 'Reaktor 2', 'Reaktor 3' } },
    { id = 'node-12', label = 'Sued', link = 'offline', online = false, last_seen_ms = NOW - 125000,
      ack_applied = true, ack_high = false },
    { id = 'node-13', link = 'stale', online = true, stale = true, last_seen_ms = NOW - 15000 },
    { id = 'node-14', link = 'online', online = true, last_seen_ms = NOW - 1000,
      ack_applied = false, ack_error = 'sorter not found' },
    { id = 'node-15', link = 'waiting', waiting = true, online = false },
    { id = 'node-16', link = 'online', online = true, last_seen_ms = NOW, ack_pending = true, requested_state = 'OPEN' },
  }, NOW)

  local order = {}
  for i, row in ipairs(data.rows) do order[i] = row.id end
  assert_eq(table.concat(order, ','), 'node-11,node-12,node-13,node-14,node-15,node-10,node-16',
    'Reihenfolge: unbekannt, offline, nicht aktuell, Schreibfehler, wartet, online')

  local by = {}
  for _, row in ipairs(data.rows) do by[row.id] = row end
  assert_eq(by['node-11'].state, 'UNBEKANNT', 'Zustand unbekannt')
  assert_eq(by['node-11'].state_key, 'WARNING', 'orange')
  assert_eq(by['node-12'].state, 'OFFLINE', 'offline')
  assert_eq(by['node-12'].state_key, 'EMERGENCY', 'rot')
  assert_eq(by['node-13'].state, 'NICHT AKTUELL', 'stale heisst "nicht aktuell"')
  assert_eq(by['node-13'].state_key, 'LIMITED', 'gelb')
  assert_eq(by['node-10'].state_key, 'OK', 'online gruen')
  assert_eq(by['node-15'].state, 'WARTET', 'Anlauf')

  assert_eq(by['node-11'].heard, 'nie', 'nie gehoert')
  assert_eq(by['node-10'].heard, '< 10 s', 'gerade gehoert: grob, damit die Seite nicht jede Sekunde neu zeichnet')
  assert_eq(by['node-13'].heard, 'vor 10 s', '15 s -> vor 10 s')
  assert_eq(by['node-12'].heard, 'vor 2 min', '125 s -> vor 2 min')
  assert_eq(valve_page.format_heard(NOW - 7300 * 1000, NOW), 'vor 2 h', 'Stunden')

  assert_eq(by['node-10'].valve, 'ZU', 'Rueckmeldung: zu')
  assert_eq(by['node-12'].valve, 'AUF', 'Rueckmeldung: auf')
  assert_eq(by['node-14'].valve, 'FEHLER', 'Rueckmeldung: nicht geschaltet')
  assert_eq(by['node-16'].valve, 'AUF?', 'gesendet, Rueckmeldung steht aus')
  assert_eq(by['node-11'].valve, '-', 'noch keine Rueckmeldung')

  assert_eq(by['node-10'].name, 'Nord', 'Name aus dem Heartbeat')
  assert_eq(by['node-11'].name, '-', 'kein Name, nur die ID')
  assert_eq(by['node-11'].reactors, 'Reaktor 2, Reaktor 3', 'in welchen Ketten das Ventil steht')

  local c = data.counts
  assert_eq(c.total, 7, 'alle'); assert_eq(c.online, 3, 'online'); assert_eq(c.stale, 1, 'nicht aktuell')
  assert_eq(c.offline, 1, 'offline'); assert_eq(c.unknown, 1, 'unbekannt'); assert_eq(c.waiting, 1, 'wartet')
  assert_eq(c.ack_error, 1, 'Schreibfehler')
  assert_eq(data.worst, 'WARNING', 'Gesamtzustand')
  assert_eq(data.first_error.id, 'node-14', 'erster Schreibfehler')
  assert_eq(data.first_error.text, 'sorter not found', 'mit dem Text des Ventils')

  assert_eq(valve_page.collect({}, NOW).worst, 'LIMITED', 'keine Ventile: eingeschraenkt, kein Fehler')
end

-- ══ 2. Zeichnen ═════════════════════════════════════════════════════════════
local function new_monitor()
  local W, H = 82, 40
  local chars, fgs, bgs = {}, {}, {}
  for y = 1, H do
    chars[y], fgs[y], bgs[y] = {}, {}, {}
    for x = 1, W do chars[y][x] = '?'; fgs[y][x] = 0; bgs[y][x] = 0 end
  end
  local cx, cy, fg, bg = 1, 1, 0, 0
  local mon = {}
  function mon.getSize() return W, H end
  function mon.setCursorPos(x, y) cx, cy = x, y end
  function mon.setTextColor(c) fg = c end
  function mon.setBackgroundColor(c) bg = c end
  function mon.write(s)
    s = tostring(s or '')
    for i = 1, #s do
      local x = cx + i - 1
      if x >= 1 and x <= W and cy >= 1 and cy <= H then
        chars[cy][x] = s:sub(i, i); fgs[cy][x] = fg; bgs[cy][x] = bg
      end
    end
    cx = cx + #s
  end
  function mon.line(y) return table.concat(chars[y]) end
  function mon.bg(x, y) return bgs[y][x] end
  return mon
end

do
  local list = {}
  for i = 1, 23 do
    list[#list + 1] = { id = string.format('node-%02d', 40 + i), label = 'Ventil ' .. i, link = 'online',
      online = true, last_seen_ms = NOW - 1000, ack_applied = true, ack_high = true,
      affected_routes = { 'Reaktor ' .. i } }
  end
  for i = 1, 6 do
    list[#list + 1] = { id = string.format('node-%02d', 10 + i), label = string.format('node-%02d', 10 + i),
      link = 'unknown', unknown = true, online = false, affected_routes = { 'Reaktor 9' } }
  end
  local data = valve_page.collect(list, NOW)
  local page = valve_page.new()
  local mon = new_monitor()
  assert_true(page.render(mon, { node_id = 'node-64' }, true, data, '4/5'), 'zeichnet auf 82x40')

  assert_true(mon.line(2):find('FUEL NODE - VENTILE', 1, true) ~= nil, 'Titel')
  assert_true(mon.line(2):find('4/5', 1, true) ~= nil, 'Seitennummer')
  assert_true(mon.line(4):find('29 VENTILE', 1, true) ~= nil, 'Zusammenfassung: ' .. mon.line(4))
  assert_true(mon.line(4):find('UNBEKANNT 6', 1, true) ~= nil, 'Zusammenfassung zaehlt die unbekannten')
  assert_true(mon.line(4):find('WARTET 0', 1, true) ~= nil, 'Zusammenfassung passt ganz in die Zeile')
  assert_true(mon.line(6):find('Ventilkette neu einlernen', 1, true) ~= nil, 'Legende sagt, was zu tun ist')
  assert_true(mon.line(9):find('ZULETZT', 1, true) ~= nil, 'Spaltenkopf')

  local first = mon.line(11)
  assert_true(first:find('UNBEKANNT', 1, true) ~= nil, 'Probleme oben: ' .. first)
  assert_true(first:find('node-11', 1, true) ~= nil, 'mit der ID aus der Kette')
  assert_true(first:find('nie', 1, true) ~= nil, 'nie gehoert')
  assert_true(first:find('Reaktor 9', 1, true) ~= nil, 'und in welcher Kette sie steht')
  assert_eq(mon.bg(3, 11), palette.get('WARNING'), 'UNBEKANNT ist orange hinterlegt')
  local online_row = mon.line(17)
  assert_true(online_row:find('ONLINE', 1, true) ~= nil, 'danach die gesunden: ' .. online_row)
  assert_eq(mon.bg(3, 17), palette.get('OK'), 'ONLINE ist gruen hinterlegt')
  assert_true(online_row:find('ZU', 1, true) ~= nil, 'Ventil-Rueckmeldung')
  assert_true(mon.line(30):find('node-', 1, true) ~= nil, '20 Zeilen auf Seite 1')

  local st = page.get_state()
  assert_eq(st.pages, 2, '29 Ventile -> zwei Seiten')
  assert_true(st.next ~= nil and st.prev == nil, 'auf Seite 1 nur WEITER')
  assert_true(st.next.y >= 33 and st.next.y2 <= 35, 'Blaetterknoepfe ueber dem Footer (38..40)')

  assert_true(page.handle_touch(st.next.x1, st.next.y), 'WEITER getippt')
  page.render(mon, { node_id = 'node-64' }, false, data, '4/5')   -- ohne Loeschen
  assert_true(mon.line(11):find('node-', 1, true) ~= nil, 'Seite 2 beginnt oben')
  assert_true(mon.line(19):find('node-', 1, true) ~= nil, '9 Eintraege auf Seite 2')
  assert_eq(mon.line(20):sub(2, 80), string.rep(' ', 79), 'darunter leer -- keine Reste von Seite 1')
  assert_eq(mon.line(30):sub(2, 80), string.rep(' ', 79), 'bis zur letzten Listenzeile')
  st = page.get_state()
  assert_true(st.prev ~= nil and st.next == nil, 'auf Seite 2 nur ZURUECK')

  -- Ohne Daten (Router noch nicht da): kein Absturz, ehrlicher Hinweis.
  local empty = new_monitor()
  assert_true(page.render(empty, {}, true, nil, '4/5'), 'zeichnet auch ohne Daten')
  assert_true(empty.line(4):find('GELADEN', 1, true) ~= nil, 'Hinweis "wird geladen"')
  assert_eq(page.render({ getSize = function() return 60, 25 end }, {}, true, data, '4/5'), false,
    'falsche Monitorgroesse: nicht zeichnen')
end

-- ══ 3. Router-Felder ════════════════════════════════════════════════════════
do
  local clock = NOW
  local real_epoch = os.epoch
  os.epoch = function() return clock end
  local real_peripheral = rawget(_G, 'peripheral')
  local sent = {}
  local modem = { isWireless = function() return true end, open = function() end,
    transmit = function(_, _, m) sent[#sent + 1] = m; return true end }
  _G.peripheral = { find = function(k) if k == 'modem' then return modem end end,
    isPresent = function() return false end, wrap = function() return nil end }
  package.loaded['nodes.fuel.redstone_router'] = nil
  local redstone_router = require('nodes.fuel.redstone_router')
  local peers = { ['VALVE-A'] = { down = false, stale = false, label = 'Nord', last_seen = clock - 2000 } }
  local router = redstone_router.new({
    node_id = 'fuel-1',
    config = { logistics = { redstone_tree = { { reactor = 'R1', label = 'R1', path = { 'VALVE-A' } } } } },
    comms = { get_peers = function() return peers end },
    log = function() end, warn_once = function() end,
  })
  router:refresh()

  -- Ventil meldet: nicht geschaltet.
  local entry = assert(router._state.pending_valve_acks['VALVE-A'], 'BLOCKED gesendet')
  router:handle_valve_ack({ type = 'VALVE_ACK', command_id = entry.command_id, src = entry.dst, dst = entry.src,
    applied = false, high = true, error = 'sorter not found' })
  local vs = router:get_valve_status()[1]
  assert_eq(vs.ack_applied, false, 'applied=false bleibt false -- nicht nil (and/or-Falle)')
  assert_eq(vs.ack_error, 'sorter not found', 'mit dem Text des Ventils')
  assert_eq(vs.last_seen_ms, clock - 2000, 'zuletzt gehoert aus der Peer-Tabelle')
  assert_eq(vs.label, 'Nord', 'Name')

  -- comms hat den Peer nach der Haltezeit vergessen.
  peers['VALVE-A'] = nil
  clock = clock + 300 * 1000
  vs = router:get_valve_status()[1]
  assert_eq(vs.link, 'offline', 'war da, ist weg')
  assert_eq(vs.last_seen_ms, NOW - 2000, 'zuletzt gehoert bleibt bekannt')
  assert_eq(vs.label, 'Nord', 'der Name auch')
  assert_eq(valve_page.collect({ vs }, clock).rows[1].heard, 'vor 5 min', 'auf der Seite: vor 5 min')

  os.epoch = real_epoch
  _G.peripheral = real_peripheral
end

-- ══ 4. Einbindung in monitor_ui ═════════════════════════════════════════════
do
  package.loaded['nodes.fuel.monitor_ui'] = nil
  package.loaded['optional.ampel'] = nil
  local scale = 1.0
  local physical = {
    getSize = function() return 82, 40 end, getTextScale = function() return scale end,
    setTextScale = function(v) scale = v end, setCursorPos = function() end, write = function() end,
    setBackgroundColor = function() end, setTextColor = function() end,
  }
  _G.window = { create = function(_, _, _, w, h)
    local t = { setVisible = function() end, getSize = function() return w, h end,
      getTextScale = function() return scale end, setCursorPos = function() end, write = function() end,
      setBackgroundColor = function() end, setTextColor = function() end }
    return t
  end }

  local captured_pages, current_name = nil, 'Overview'
  local fake_router = {
    set_monitor_name = function() end, invalidate_layout = function() end,
    needs_render = function() return false end, render = function() return true end,
    get_diagnostics = function() return { error_count = 0 } end, handle_input = function() return false end,
    current = function() return { name = current_name } end,
  }
  local status_calls = 0
  local ctx = {
    devices = { monitor = physical, monitor_name = 'monitor_0' },
    ui_router = { new = function(opts) captured_pages = opts.pages; return fake_router end },
    fuel_ui = {
      render_overview = function() end, render_details = function() end, render_diagnostics = function() end,
      handle_diagnostics_touch = function() return false end,
      compute_view_state = function() return { code = 'READY', severity = 'OK' } end,
    },
    get_router_ui = function() return { render = function() end, handle_touch = function() return false end } end,
    get_rs_router = function() return { get_valve_status = function()
      status_calls = status_calls + 1
      return { { id = 'node-11', link = 'unknown', unknown = true, online = false } }
    end } end,
    ui = {}, colors = {}, keys = { left = 1, pageUp = 2, right = 3, pageDown = 4 },
    build_status_payload = function() return { health = { status = 'OK' } } end,
    master_peer_state = function() return nil end,
    registry = { get_summary = function() return {} end },
    support_ui_pages = require('nodes.support.ui_pages'),
    config = { node_id = 'node-64' },
  }
  local monitor_ui = require('nodes.fuel.monitor_ui')
  monitor_ui.render_monitor(ctx, {})

  assert_eq(#captured_pages, 5, 'fuenf Seiten')
  local names = {}
  for i, p in ipairs(captured_pages) do names[i] = p.name end
  assert_eq(table.concat(names, ','), 'Overview,Details,Diagnostics,Valves,Router', 'VENTILE als vierte, vor dem Router')

  local model = monitor_ui.build_model(ctx)
  assert_eq(model.valve_page, nil, 'auf einer anderen Seite: keine Ventilliste im Modell')
  assert_eq(model.snapshot.valve_page, nil, 'und nicht im Vergleichsstand')
  assert_eq(status_calls, 0, 'und kein Abfragen des Routers')

  current_name = 'Valves'
  model = monitor_ui.build_model(ctx)
  assert_true(model.valve_page ~= nil, 'auf der Seite VENTILE: Liste im Modell')
  assert_eq(model.valve_page.rows[1].id, 'node-11', 'aus dem Router')
  assert_true(model.snapshot.valve_page == model.valve_page, 'im Vergleichsstand: Textaenderung -> neu zeichnen')

  local mon = new_monitor()
  local footer = captured_pages[4].render(mon, model, true)
  assert_true(mon.line(2):find('4/5', 1, true) ~= nil, 'Seite 4/5')
  assert_true(mon.line(11):find('node-11', 1, true) ~= nil, 'zeigt die Ventile')
  assert_true(type(footer) == 'table' and footer.left and footer.right, 'mit dem gemeinsamen Footer')
  assert_eq(captured_pages[4].handle_touch(1, 1), false, 'Tippen ins Leere: nichts')

  _G.window = nil
end

print('ok fuel_valve_page_test')
