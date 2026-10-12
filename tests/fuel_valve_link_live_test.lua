package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Ventil-Erreichbarkeit LIVE statt als Momentaufnahme (v818).
--
-- Bis v817 legte nodes/fuel/redstone_router.lua's refresh() fest, welche
-- Ventile geschaltet werden duerfen: nur die, die in GENAU DIESEM Augenblick
-- per Funk bekannt waren (_state.integrators). refresh() laeuft beim Start --
-- bevor auch nur ein VALVE-Node seinen ersten Heartbeat geschickt hat -- und
-- danach hoechstens alle 60 s. Bis dahin:
--   * zeigte FUEL "Ventil-Verbindung nicht bereit" (offline = alle), obwohl
--     jeder VALVE-Node laengst funkte;
--   * scheiterte jede Lieferung sofort (block_ack_failed), und der
--     Safety-Latch sperrte alles Weitere.
-- Im Spiel gemeldet als "die Valves verbinden sich nicht mit FUEL".
-- Zusaetzlich sah "unter dieser ID meldet sich NIE ein Node" (falsche
-- Kennung in der Ventilkette) genauso aus wie "Node gerade weg" -- zwei
-- Lagen mit verschiedenen Handgriffen.
--
--   1. Router: Ventile, die sich NACH refresh() melden, sind sofort
--      schaltbar -- ohne erneutes refresh()
--   2. Router: Ventil faellt NACH refresh() aus -> OPEN wird verweigert,
--      BLOCKED geht weiter raus
--   3. Router: waiting -> unknown (Anlaufzeit), seen -> offline (auch nach
--      Ablauf aus der Peer-Tabelle); Exportfreigabe nennt den Grund
--   4. Router: Log -- nichts im Anlauf, "unbekannt" einmal, "offline" nach
--      einer Erholung erneut
--   5. Anzeige: valve_summary zaehlt unknown/waiting getrennt, Banner
--      VALVE_UNKNOWN nennt die Kennungen, VALVE_WAITING im Anlauf,
--      route_state VALVE_UNKNOWN
--   6. Ganze Anlage (RT, MASTER, FUEL, zwei VALVE-Nodes, echter
--      Ventilkanal): die erste Lieferung laeuft wenige Sekunden nach dem
--      Start, nicht erst nach dem ersten 60-s-refresh()

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local constants = require('shared.constants')

-- ══ Router-Teile (1-4): Mock-Funk, eigene Uhr ═══════════════════════════════

local real_epoch = os.epoch
local real_peripheral = rawget(_G, 'peripheral')
local clock = 5000000
os.epoch = function() return clock end

local transmitted = {}
local modem = {
  isWireless = function() return true end,
  open = function() end,
  transmit = function(_, _, message) transmitted[#transmitted + 1] = message; return true end,
}
_G.peripheral = {
  find = function(kind) if kind == 'modem' then return modem end end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

package.loaded['nodes.fuel.redstone_router'] = nil
local redstone_router = require('nodes.fuel.redstone_router')

local function sent_to(id, high, from)
  local n = 0
  for i = (from or 0) + 1, #transmitted do
    local m = transmitted[i]
    if m.type == 'SET_VALVE' and m.dst == id and (high == nil or m.high == high) then n = n + 1 end
  end
  return n
end

local function new_router(peers, logs)
  local router = redstone_router.new({
    node_id = 'fuel-1',
    config = { logistics = { redstone_tree = {
      { reactor = 'R1', label = 'R1', path = { 'VALVE-A', 'VALVE-B' } },
    } } },
    comms = { get_peers = function() return peers end },
    log = function(level, msg) if logs then logs[#logs + 1] = { level = level, msg = msg } end end,
    warn_once = function() end,
  })
  return router
end

local function ack(router, id)
  local entry = assert(router._state.pending_valve_acks[id], 'kein offenes Kommando fuer ' .. id)
  router:handle_valve_ack({
    type = 'VALVE_ACK', command_id = entry.command_id,
    src = entry.dst, dst = entry.src, applied = true, high = entry.high,
  })
end

-- ── 1. Ventile melden sich NACH refresh() ───────────────────────────────────
do
  local peers = {}                       -- Start: noch kein Heartbeat da
  local router = new_router(peers)
  router:refresh()
  assert_eq(sent_to('VALVE-A'), 0, 'beim Start ist noch kein Ventil bekannt, also nichts gesendet')

  -- Ein paar Sekunden spaeter funken beide -- KEIN neues refresh().
  clock = clock + 4000
  peers['VALVE-A'] = { down = false, stale = false, label = 'Nord' }
  peers['VALVE-B'] = { down = false, stale = false }

  local status = router:get_valve_status()
  assert_eq(status[1].online, true, 'VALVE-A gilt sofort als online, nicht erst nach dem naechsten refresh()')
  assert_eq(status[1].link, 'online', 'link = online')
  assert_eq(status[1].label, 'Nord', 'mit seinem Namen aus dem Heartbeat')

  local exported = false
  local ok = router:begin_transaction('R1', function() exported = true end, 500)
  assert_true(ok, 'Lieferung startet')
  assert_eq(sent_to('VALVE-A', true), 1, 'BLOCKED geht an VALVE-A (vorher: nichts, Ventil nicht in der Momentaufnahme)')
  assert_eq(sent_to('VALVE-B', true), 1, 'und an VALVE-B')
  router:tick(clock)
  assert_true(router._state.transaction ~= nil, 'die Lieferung darf NICHT sofort mit block_ack_failed scheitern')

  ack(router, 'VALVE-A'); ack(router, 'VALVE-B')
  router:tick(clock)
  assert_eq(router._state.transaction.state, 'WAIT_OPEN_ACKS', 'BLOCKED bestaetigt, jetzt wird geoeffnet')
  ack(router, 'VALVE-A'); ack(router, 'VALVE-B')
  router:tick(clock)
  clock = clock + 500
  router:tick(clock)
  assert_true(exported, 'nach bestaetigtem OPEN wird exportiert')
end

-- ── 2. Ventil faellt NACH refresh() aus ─────────────────────────────────────
do
  local peers = { ['VALVE-A'] = { down = false, stale = false }, ['VALVE-B'] = { down = false, stale = false } }
  local router = new_router(peers)
  router:refresh()

  peers['VALVE-B'] = { down = true, stale = true }   -- weg, refresh() weiss davon nichts
  local mark = #transmitted
  assert_eq(router:_set_valve('VALVE-B', false), false,
    'OPEN an ein Ventil, das gerade down ist, wird verweigert (vorher: gesendet, Momentaufnahme)')
  assert_eq(sent_to('VALVE-B', false, mark), 0, 'und nicht gesendet')
  assert_eq(router:_set_valve('VALVE-B', true), true,
    'BLOCKED geht weiter an ein bekanntes, gerade stummes Ventil -- Sperren ist immer sicher')

  peers['VALVE-B'] = { down = false, stale = true }  -- Heartbeat ueberfaellig, noch nicht down
  assert_eq(router:_set_valve('VALVE-B', false), false, 'OPEN auch nicht an ein ueberfaelliges Ventil')
  local ready, why = router:_path_runtime_ready({ 'VALVE-A', 'VALVE-B' })
  assert_eq(ready, false, 'Exportfreigabe verweigert')
  assert_eq(why, 'stale:VALVE-B', 'mit Zustand und Ventil im Grund')
end

-- ── 3. waiting -> unknown, seen -> offline ──────────────────────────────────
do
  local peers = { ['VALVE-A'] = { down = false, stale = false } }
  local router = new_router(peers)
  router:refresh()

  local by_id = {}
  for _, v in ipairs(router:get_valve_status()) do by_id[v.id] = v end
  assert_eq(by_id['VALVE-B'].link, 'waiting', 'gerade gestartet, VALVE-B noch nie gehoert: meldet sich noch')
  assert_eq(by_id['VALVE-B'].waiting, true, 'waiting-Flag')
  assert_eq(by_id['VALVE-B'].unknown, false, 'noch nicht unbekannt')
  assert_eq(by_id['VALVE-B'].online, false, 'aber auch nicht online')

  clock = clock + 61 * 1000
  by_id = {}
  for _, v in ipairs(router:get_valve_status()) do by_id[v.id] = v end
  assert_eq(by_id['VALVE-B'].link, 'unknown', 'nach der Anlaufzeit: unter dieser Kennung meldet sich niemand')
  assert_eq(by_id['VALVE-B'].unknown, true, 'unknown-Flag')
  local ready, why = router:_path_runtime_ready({ 'VALVE-A', 'VALVE-B' })
  assert_eq(ready, false, 'unbekanntes Ventil: kein Export')
  assert_eq(why, 'unknown:VALVE-B', 'Grund nennt es')

  -- VALVE-A war da, ist down und wird von comms nach der Haltezeit
  -- vergessen: das bleibt "offline", wird NICHT zu "unbekannt".
  peers['VALVE-A'] = { down = true, stale = true }
  assert_eq(router:_valve_link('VALVE-A'), 'offline', 'down: offline')
  peers['VALVE-A'] = nil
  assert_eq(router:_valve_link('VALVE-A'), 'offline', 'aus der Peer-Tabelle gealtert: weiter offline, nicht unbekannt')
  assert_eq(router:_set_valve('VALVE-A', true), false, 'ein Ventil, das comms nicht mehr fuehrt, bekommt nichts')
end

-- ── 4. Log: einmal je Stoerung ──────────────────────────────────────────────
do
  local logs = {}
  local peers = {}
  local router = new_router(peers, logs)
  router:refresh()
  router:get_valve_status()
  local function warnings(needle)
    local n = 0
    for _, e in ipairs(logs) do if e.level == 'WARN' and e.msg:find(needle, 1, true) then n = n + 1 end end
    return n
  end
  assert_eq(warnings('VALVE'), 0, 'im Anlauf keine Warnung (vorher: "nicht per Funk erreichbar" fuer jedes Ventil)')

  clock = clock + 61 * 1000
  router:get_valve_status(); router:get_valve_status()
  assert_eq(warnings("Kennung 'VALVE-A'"), 1, 'nach der Anlaufzeit: VALVE-A unbekannt, einmal gemeldet')

  peers['VALVE-A'] = { down = false, stale = false }
  router:get_valve_status()
  peers['VALVE-A'] = { down = true, stale = true }
  router:get_valve_status(); router:get_valve_status()
  assert_eq(warnings("'VALVE-A' offline"), 1, 'Ausfall: einmal gemeldet')
  peers['VALVE-A'] = { down = false, stale = false }
  router:get_valve_status()
  clock = clock + 2 * 60 * 1000
  peers['VALVE-A'] = { down = true, stale = true }
  router:get_valve_status()
  assert_eq(warnings("'VALVE-A' offline"), 2, 'erneuter Ausfall nach einer Erholung: wieder gemeldet')
end

os.epoch = real_epoch
_G.peripheral = real_peripheral

-- ══ 5. Anzeige ══════════════════════════════════════════════════════════════
do
  local status_snapshot = require('nodes.fuel.status_snapshot')
  local ui_completion = require('nodes.fuel.ui_completion')
  local operational_summary = require('nodes.fuel.operational_summary')
  local health = require('core.health')

  -- valve_summary: unbekannt und Anlauf zaehlen NICHT als offline.
  local valve_list = {
    { id = 'VALVE-1', online = true, stale = false, link = 'online' },
    { id = 'VALVE-2', online = false, stale = false, link = 'offline' },
    { id = 'node-12', online = false, stale = false, link = 'unknown', unknown = true },
    { id = 'node-13', online = false, stale = false, link = 'unknown', unknown = true },
    { id = 'VALVE-5', online = false, stale = false, link = 'waiting', waiting = true },
    { id = 'VALVE-6', online = true, stale = true, link = 'stale' },
  }
  local payload = status_snapshot.build_status_payload({
    health = health, non_rt_payload = require('core.non_rt_payload'), devices = {},
    config = { role = 'FUEL', node_id = 'FUEL-1' }, fuel_health = health.new({}), node_id = 'FUEL-1',
    read_fuel = function() return 1000 end, enforce_reserve = function(amount) return amount end,
    is_master_connected = function() return true end, storage = 'meBridge_0', reserve = 2000,
    registry = { get_summary = function() return {} end, get_devices_by_kind = function() return {} end,
      get_diagnostics = function() return {} end },
    get_router = function() return { get_summary = function() return { reactors = {} } end, fuel_status = {} } end,
    get_rs_router = function() return {
      get_valve_status = function() return valve_list end,
      get_routing_state = function() return 'ROUTING_VALID' end,
      get_tree = function() return {} end,
    } end,
  })
  local vs = payload.valve_summary
  assert_eq(vs.total, 6, 'alle Ventile')
  assert_eq(vs.offline, 1, 'offline nur das, das weg ist')
  assert_eq(vs.stale, 1, 'ueberfaellig')
  assert_eq(vs.unknown, 2, 'unbekannte Kennungen getrennt gezaehlt')
  assert_eq(vs.waiting, 1, 'Anlauf getrennt gezaehlt')
  assert_eq(table.concat(vs.unknown_ids, ','), 'node-12,node-13', 'mit ihren Kennungen')

  local function view(valve_summary)
    return ui_completion.compute_view_state({ payload = {
      logistics = { configured_reactor_count = 1, enabled = true, reactors = {} },
      bindings = { storage = 1 }, valve_summary = valve_summary, master_connected = true,
    } }, {}, 100, 10)
  end

  local v = view({ total = 17, offline = 0, stale = 0, unknown = 17, waiting = 0,
    unknown_ids = { 'node-12', 'node-13', 'node-14' } })
  assert_eq(v.code, 'VALVE_UNKNOWN', 'nie gemeldete Kennungen: eigener Hinweis, nicht "Funk pruefen"')
  assert_eq(v.detail, '17 nie gemeldet: node-12, node-13, node-14 (+14)', 'nennt die Kennungen')
  assert_eq(v.action, 'ROUTER > Ventilkette neu einlernen', 'und den richtigen Handgriff')

  v = view({ total = 2, offline = 1, stale = 0, unknown = 0, waiting = 1 })
  assert_eq(v.code, 'VALVE_OFFLINE', 'offline geht dem Anlauf vor')
  v = view({ total = 2, offline = 0, stale = 0, unknown = 0, waiting = 2 })
  assert_eq(v.code, 'VALVE_WAITING', 'im Anlauf: Ventile melden sich noch')
  assert_eq(v.severity, 'LIMITED', 'kein Fehler, nur eingeschraenkt')

  -- route_state je Reaktor
  local summary = { enabled = true, bridge = 'meBridge_0', export_chest = 'chest_0',
    reactors = { { label = 'R1', reactor_id = 'R1', connected = true } } }
  operational_summary.enrich(summary, {
    rs_router = {
      get_routing_state = function() return 'ROUTING_VALID' end,
      get_tree = function() return { { reactor = 'R1', label = 'R1', path = { 'VALVE-A', 'VALVE-B' } } } end,
    },
    valve_status = {
      { id = 'VALVE-A', online = true, stale = false, link = 'online' },
      { id = 'VALVE-B', online = false, stale = false, link = 'unknown', unknown = true },
    },
    config = {},
  })
  assert_eq(summary.reactors[1].route_state, 'VALVE_UNKNOWN', 'Reaktor-Detail nennt die unbekannte Kennung als Grund')
  assert_eq(summary.reactors[1].operational_state, 'BLOCKED', 'und bleibt gesperrt')
end

-- ══ 6. Ganze Anlage ═════════════════════════════════════════════════════════
--
-- RT liest den Reaktor (45 %, Nachliefern unter 90 %), MASTER relais,
-- FUEL liefert ueber die Ventilkette valve-1 > valve-2. Der Bus stellt den
-- Ventilkanal (SET_VALVE/VALVE_ACK) echt zu. Gemessen wird der erste
-- ME-Export nach dem Start von FUEL und den VALVE-Nodes. Mit v817 kam er
-- nach 65.7 s (erstes refresh() nach 60 s), jetzt nach wenigen Sekunden.
do
  local plant = require('support.plant_nodes')
  local bus_lib = require('support.node_message_bus')
  local boot = require('support.cc_node_boot')

  local rt = plant.new_rt({ turbines = 1, node_id = 'node-101', reactor = { fuel = 1800, fuel_max = 4000 } })
  local master = plant.new_master({ node_id = 'master-1' })
  plant.boot_all({
    { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
    { name = 'MASTER', env = master, main = 'master/main.lua' },
  })
  local learn = bus_lib.new()
  learn:attach('RT', rt); learn:attach('MASTER', master)
  learn:run(80)
  local global_id = learn:last_message_from('RT', 'STATUS').payload.reactors[1].global_id
  assert_true(global_id ~= nil, 'RT muss die Reaktor-Kennung senden')

  local routes = string.format([[return {
  export_chest = "chest_0",
  reactors = {
    { reactor_id = %q, label = "Reaktor A", path = { "valve-1", "valve-2" },
      request_below = 0.9, fill_amount = 64 },
  },
}]], global_id)
  local fuel = plant.new_fuel({ node_id = 'fuel-1', routes = routes, enabled = true })
  -- Ventil per Redstone, schon mit FUEL gepaart (die Test-Platte kann das
  -- Pairing nicht schreiben).
  local function valve(id, computer_id)
    return plant.new_valve({ computer_id = computer_id, node_id = id, config = string.format(
      'return { node_id = %q, redstone_side = "back", trusted_source = "fuel-1" }\n', id) })
  end
  local v1, v2 = valve('valve-1', 501), valve('valve-2', 502)

  local exports = {}
  local real_export = fuel.wrapped['meBridge_0'].exportItem
  fuel.wrapped['meBridge_0'].exportItem = function(...)
    exports[#exports + 1] = fuel.clock_ms
    return real_export(...)
  end

  for _, spec in ipairs({ { fuel, 'nodes/fuel/main.lua' }, { v1, 'nodes/valve/main.lua' }, { v2, 'nodes/valve/main.lua' } }) do
    boot.reset_module_cache(); spec[1]:activate(); spec[1]:boot(spec[2])
  end
  local net = bus_lib.new({ raw_channels = { [constants.channels.VALVE] = true } })
  net:attach('RT', rt); net:attach('MASTER', master); net:attach('FUEL', fuel)
  net:attach('VALVE1', v1); net:attach('VALVE2', v2)

  local started = fuel.clock_ms
  net:run(150)   -- 15 s

  local status = net:last_message_from('FUEL', 'STATUS')
  local vs = status and status.payload and status.payload.valve_summary or {}
  assert_eq(vs.total, 2, 'zwei Ventile in der Kette')
  assert_eq(vs.offline, 0, 'keines gilt als offline -- beide funken (vorher: offline=2 bis zum ersten refresh())')
  assert_eq(vs.unknown, 0, 'keines unbekannt')

  local acks = 0
  for _, d in ipairs(net.delivered) do
    if d.to == 'FUEL' and d.channel == constants.channels.VALVE
        and type(d.message) == 'table' and d.message.type == 'VALVE_ACK' and d.message.applied == true then
      acks = acks + 1
    end
  end
  assert_true(acks >= 4, 'die Ventile bestaetigen BLOCKED und OPEN (' .. acks .. ' Bestaetigungen)')
  assert_true(#exports >= 1, 'innerhalb von 15 s nach dem Start muss die erste Lieferung laufen'
    .. ' -- vorher kam sie erst nach dem ersten refresh() nach 60 s')
  assert_true(exports[1] - started <= 15000, string.format('erste Lieferung nach %.1f s', (exports[1] - started) / 1000))
end

print('ok fuel_valve_link_live_test')
