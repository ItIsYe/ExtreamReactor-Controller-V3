package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- FUEL-Routen mit KURZER Reaktor-Kennung werden auf die GLOBALE umgestellt
-- -- vorsichtig (nodes/fuel/route_identity.lua).
--
-- Die Lage beim Betreiber: 8 RT-Knoten, 16 Reaktoren, aber nur 2 kurze
-- Kennungen -- CC:Tweaked nummeriert die Peripherie je Rechner, auf jedem
-- Knoten heissen die Reaktoren "BigReactors-Reactor_1"/"_2". MASTER
-- (master/fuel_relay.lua) fuehrt den Fuellstand unter der globalen
-- Kennung "<node_id>:<kurz>" und verwirft den kurzen Alias, sobald zwei
-- Knoten ihn benutzen. Eine Route mit kurzer Kennung bekommt dann keinen
-- Fuellstand mehr: der Reaktor wird nie beliefert, und nichts sagt es.
--
--   1. plan(): umgestellt wird nur, wenn der Routen-Name unter den
--      Reaktoren mit dieser kurzen Kennung genau EINEN trifft; mehrdeutig,
--      falscher Name, kein Name, schon global eingelernt -> bleibt, gemeldet
--   2. apply(): erst die Datei, dann die Laufzeit-Config; ein Fehlschlag
--      laesst beides stehen und wartet 10 min; "busy" schreibt nichts
--   3. router_ui: derselbe atomare Schreibweg wie SPEICHERN; is_editing()
--   4. Ende zu Ende mit echt gebooteten Knoten: zwei RT mit derselben
--      kurzen Kennung, MASTER, FUEL mit einer alten Route -> nach der
--      Umstellung steht die globale Kennung in fuel_routes.lua, und FUEL
--      kennt den Fuellstand des richtigen Reaktors

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local route_identity = require('nodes.fuel.route_identity')

-- ══ 1. plan() ═════════════════════════════════════════════════════════════
--
-- Ein Cache, wie fuel_status_network ihn fuehrt: je globale Kennung ein
-- Eintrag; der kurze Alias fehlt, weil die Kennung kollidiert.
local function entry(node, short, label)
  return { global_reactor_id = node .. ':' .. short, local_reactor_id = short,
    label = label, source_node = node, fuel_amount = 1000, fuel_capacity = 4000, ts = 1 }
end
local cache = { master_relay = {}, direct_heard = {} }
local function put(e) cache.master_relay[e.global_reactor_id] = e end
put(entry('rt-1', 'REACTOR-A', 'Reaktor 1'))
put(entry('rt-1', 'REACTOR-B', 'Reaktor 2'))
put(entry('rt-2', 'REACTOR-A', 'Reaktor 3'))
put(entry('rt-2', 'REACTOR-B', 'Reaktor 4'))
put(entry('rt-3', 'REACTOR-A', 'Doppelt'))
put(entry('rt-4', 'REACTOR-A', 'doppelt '))   -- gleicher Name, anders geschrieben
-- Mithoeren kennt rt-2 auch direkt -- dieselbe globale Kennung, kein Doppel.
cache.direct_heard['rt-2:REACTOR-B'] = entry('rt-2', 'REACTOR-B', 'Reaktor 4')

local routes = {
  { reactor_id = 'REACTOR-A', label = 'Reaktor 3' },      -- 1 eindeutig -> rt-2
  { reactor_id = 'rt-1:REACTOR-A', label = 'Reaktor 1' }, -- 2 schon global
  { reactor_id = 'REACTOR-A', label = 'Doppelt' },        -- 3 Name trifft zwei
  { reactor_id = 'REACTOR-B', label = 'Reaktor 9' },      -- 4 kein Reaktor heisst so
  { reactor_id = 'REACTOR-B', label = 'REACTOR-B' },      -- 5 ohne echten Namen
  { reactor_id = 'REACTOR-A', label = ' reaktor 1 ' },    -- 6 Reaktor 1 hat schon eine Route
  { reactor_id = 'REACTOR-Z', label = 'Reaktor 7' },      -- 7 Netz kennt sie (noch) nicht
  { reactor_id = 'REACTOR-B', label = 'reaktor 4' },      -- 8 eindeutig -> rt-2 (Gross/klein egal)
}
local plan = route_identity.plan(routes, cache)

assert_eq(#plan.changes, 2, 'genau zwei Routen lassen sich eindeutig zuordnen')
assert_eq(plan.changes[1].index, 1, 'Route 1')
assert_eq(plan.changes[1].to, 'rt-2:REACTOR-A', 'Route 1 -> rt-2 (Name "Reaktor 3")')
assert_eq(plan.changes[2].index, 8, 'Route 8')
assert_eq(plan.changes[2].to, 'rt-2:REACTOR-B', 'Route 8 -> rt-2 (Name "reaktor 4")')

local status_of = {}
for _, p in ipairs(plan.problems) do status_of[p.index] = p.status end
assert_eq(status_of[2], nil, 'eine globale Kennung ist kein Problem')
assert_eq(status_of[3], 'ambiguous', 'Name trifft zwei Reaktoren')
assert_eq(status_of[4], 'label_mismatch', 'kein Reaktor mit diesem Namen')
assert_eq(status_of[5], 'no_label', 'ohne Namen keine Zuordnung')
assert_eq(status_of[6], 'duplicate', 'Reaktor 1 hat schon eine Route mit globaler Kennung')
assert_eq(status_of[7], nil, 'eine Kennung, die das Netz (noch) nicht kennt, bleibt still')
for _, p in ipairs(plan.problems) do
  assert_true(route_identity.describe_problem(p):find('ROUTER', 1, true) ~= nil,
    'jede Meldung sagt, was zu tun ist: ' .. route_identity.describe_problem(p))
end

-- Alte Eintraege mit reactor_port (frueherer Feldname) zaehlen genauso.
do
  local p = route_identity.plan({ { reactor_port = 'REACTOR-B', label = 'Reaktor 2' } }, cache)
  assert_eq(#p.changes, 1, 'reactor_port wird wie reactor_id behandelt')
  assert_eq(p.changes[1].from, 'REACTOR-B', 'von der alten Kennung')
  assert_eq(p.changes[1].to, 'rt-1:REACTOR-B', 'auf die globale')
end

-- Ist die kurze Kennung gerade eindeutig, weil der andere Knoten schweigt,
-- entscheidet trotzdem der Name -- nicht die Kennung allein.
do
  local quiet = { master_relay = {} }
  quiet.master_relay['rt-1:REACTOR-A'] = entry('rt-1', 'REACTOR-A', 'Reaktor 1')
  local p = route_identity.plan({ { reactor_id = 'REACTOR-A', label = 'Reaktor 3' } }, quiet)
  assert_eq(#p.changes, 0, 'Reaktor 3 sendet gerade nicht -- die Route darf nicht auf Reaktor 1 umgestellt werden')
  assert_eq(p.problems[1].status, 'label_mismatch', 'gemeldet als "kein Reaktor heisst so"')
end

-- ══ 2. apply() ════════════════════════════════════════════════════════════
local function fresh_lg()
  return { export_chest = 'chest_0', reactors = {
    { reactor_id = 'REACTOR-A', label = 'Reaktor 3', path = { 'v1' }, disabled_reason = nil },
    { reactor_id = 'rt-1:REACTOR-A', label = 'Reaktor 1', path = { 'v2' } },
  } }
end

do -- Erfolg: Datei zuerst, dann die Laufzeit-Config
  local lg, written, applied = fresh_lg(), nil, nil
  local n, problems, reason, changes = route_identity.apply(lg, cache, {
    save = function(snapshot)
      assert_eq(lg.reactors[1].reactor_id, 'REACTOR-A', 'beim Schreiben ist die Laufzeit-Config noch unveraendert')
      written = snapshot
      return true
    end,
    on_applied = function(c) applied = c end,
  })
  assert_eq(n, 1, 'eine Route umgestellt')
  assert_eq(reason, nil, 'ohne Grund')
  assert_eq(#problems, 0, 'keine Probleme')
  assert_eq(written.reactors[1].reactor_id, 'rt-2:REACTOR-A', 'die Datei bekommt die globale Kennung')
  assert_eq(written.reactors[1].path[1], 'v1', 'der Rest der Route bleibt')
  assert_eq(written.export_chest, 'chest_0', 'die Export-Kiste bleibt')
  assert_eq(lg.reactors[1].reactor_id, 'rt-2:REACTOR-A', 'danach auch die Laufzeit-Config')
  assert_eq(applied and applied[1].from, 'REACTOR-A', 'on_applied bekommt die Aenderungen')
end

do -- Schreiben scheitert: nichts aendert sich, kein neuer Versuch vor 10 min
  local lg, attempts, state = fresh_lg(), 0, {}
  local deps = { state = state, now = 1000,
    save = function() attempts = attempts + 1; return false, 'Platte voll' end }
  local n, _, reason = route_identity.apply(lg, cache, deps)
  assert_eq(n, 0, 'nichts umgestellt')
  assert_true(reason:find('save_failed', 1, true) ~= nil, 'Grund: ' .. tostring(reason))
  assert_eq(lg.reactors[1].reactor_id, 'REACTOR-A', 'die Laufzeit-Config bleibt')
  deps.now = 1000 + 5 * 60 * 1000
  n, _, reason = route_identity.apply(lg, cache, deps)
  assert_eq(reason, 'backoff', 'nach 5 min kein neuer Versuch')
  assert_eq(attempts, 1, 'nur ein Schreibversuch')
  deps.now = 1000 + 11 * 60 * 1000
  deps.save = function() attempts = attempts + 1; return true end
  n = route_identity.apply(lg, cache, deps)
  assert_eq(n, 1, 'nach 10 min wieder, diesmal mit Erfolg')
end

do -- busy: der Betreiber bearbeitet gerade, oder eine Lieferung laeuft
  local lg, attempts = fresh_lg(), 0
  local n, _, reason = route_identity.apply(lg, cache, {
    busy = function() return true end,
    save = function() attempts = attempts + 1; return true end,
  })
  assert_eq(reason, 'busy', 'busy wartet')
  assert_eq(attempts + n, 0, 'nichts geschrieben')
end

-- ══ 3. router_ui ══════════════════════════════════════════════════════════
do
  local router_ui = require('nodes.fuel.router_ui')
  local disk = {}
  local real_fs, real_dofile = rawget(_G, 'fs'), dofile
  _G.fs = {
    exists = function(p) return disk[p] ~= nil end,
    getDir = function(p) return (p:match('^(.*)/[^/]*$') or '') end,
    makeDir = function(p) disk[p] = '<dir>' end,
    delete = function(p) disk[p] = nil end,
    move = function(a, b) disk[b] = disk[a]; disk[a] = nil end,
    open = function(p, mode)
      if mode == 'r' then
        if disk[p] == nil then return nil end
        return { readAll = function() return disk[p] end, close = function() end }
      end
      local lines = {}
      return { writeLine = function(l) lines[#lines + 1] = l end, write = function(t) lines[#lines + 1] = t end,
        close = function() disk[p] = table.concat(lines, '\n') .. '\n' end }
    end,
  }
  _G.dofile = function(p)
    if disk[p] then return assert(load(disk[p], '=' .. p))() end
    return real_dofile(p)
  end
  local snapshot = { export_chest = 'chest_0', reactors = {
    router_ui.copy_route({ reactor_id = 'rt-2:REACTOR-A', label = 'Reaktor 3', path = { 'v1' } }) } }
  local ok, err = router_ui.save_routes(snapshot, '/xreactor_config/fuel_routes.lua')
  assert_true(ok, 'Speichern muss gelingen: ' .. tostring(err))
  local loaded = dofile('/xreactor_config/fuel_routes.lua')
  assert_eq(loaded.reactors[1].reactor_id, 'rt-2:REACTOR-A', 'gespeicherte Kennung')
  assert_eq(loaded.reactors[1].path[1], 'v1', 'gespeicherter Pfad')
  ok = router_ui.save_routes({ reactors = { { label = 'ohne Kennung' } } }, '/xreactor_config/fuel_routes.lua')
  assert_true(not ok, 'eine Route ohne Kennung wird wie beim SPEICHERN abgelehnt')
  assert_eq(dofile('/xreactor_config/fuel_routes.lua').reactors[1].reactor_id, 'rt-2:REACTOR-A',
    'die alte Datei bleibt dabei unangetastet')

  assert_eq(router_ui.copy_route({ reactor_port = 'REACTOR-B', label = 'alt' }).reactor_id, 'REACTOR-B',
    'ein Eintrag mit dem alten Feldnamen behaelt beim Kopieren seine Kennung')

  local lg = { export_chest = 'chest_0', reactors = { { reactor_id = 'REACTOR-A', label = 'Reaktor 3', path = {} } } }
  local page = router_ui.new({ config = { logistics = lg } })
  assert_true(not page:is_editing(), 'Liste ohne Aenderungen: nicht in Bearbeitung')
  page._ui.dirty = true
  assert_true(page:is_editing(), 'ungespeicherte Aenderungen: in Bearbeitung')
  page._ui.dirty = false
  page._ui.mode = 'edit'
  assert_true(page:is_editing(), 'Formular offen: in Bearbeitung')
  page._ui.mode = 'list'
  lg.reactors[1].reactor_id = 'rt-2:REACTOR-A'
  page:reload_from_config()
  assert_eq(page._ui.reactors[1].reactor_id, 'rt-2:REACTOR-A', 'die Seite zeigt die neue Kennung')
  _G.fs, _G.dofile = real_fs, real_dofile
end

-- ══ 4. Ende zu Ende ═══════════════════════════════════════════════════════
do
  local plant = require('support.plant_nodes')
  local bus_lib = require('support.node_message_bus')
  local boot = require('support.cc_node_boot')

  -- Zwei RT-Knoten; auf beiden heisst der Reaktor "BigReactors-Reactor_1",
  -- also dieselbe kurze Kennung. Verschiedene Klarnamen und Fuellstaende.
  local rt1 = plant.new_rt({ computer_id = 101, node_id = 'rt-1', turbines = 1,
    reactor_aliases = { 'Reaktor 1' }, reactor = { fuel = 1000, fuel_max = 4000 } })
  local rt2 = plant.new_rt({ computer_id = 102, node_id = 'rt-2', turbines = 1,
    reactor_aliases = { 'Reaktor 3' }, reactor = { fuel = 3000, fuel_max = 4000 } })
  local master = plant.new_master({ computer_id = 1, node_id = 'master-1' })
  plant.boot_all({
    { name = 'RT1', env = rt1, main = 'nodes/rt/main.lua' },
    { name = 'RT2', env = rt2, main = 'nodes/rt/main.lua' },
    { name = 'MASTER', env = master, main = 'master/main.lua' },
  })
  local learn = bus_lib.new()
  learn:attach('RT1', rt1)
  learn:attach('RT2', rt2)
  learn:attach('MASTER', master)
  learn:run(80)

  local short1 = learn:last_message_from('RT1', 'STATUS').payload.reactors[1].id
  local short2 = learn:last_message_from('RT2', 'STATUS').payload.reactors[1].id
  local global2 = learn:last_message_from('RT2', 'STATUS').payload.reactors[1].global_id
  assert_eq(short1, short2, 'Voraussetzung: beide Reaktoren haben dieselbe kurze Kennung')
  assert_true(global2 ~= nil and global2 ~= short2, 'Voraussetzung: RT-2 sendet eine globale Kennung')

  -- Eine alte Route: kurze Kennung, Name von RT-2s Reaktor. Dazu eine, die
  -- sich nicht zuordnen laesst. Logistik AUS -- hier geht es um die
  -- Zuordnung, nicht ums Liefern.
  local routes = string.format([[return {
  export_chest = "chest_0",
  reactors = {
    { reactor_id = %q, label = "Reaktor 3", path = { "valve-1" }, request_below = 0.1, fill_amount = 64 },
    { reactor_id = %q, label = "Reaktor 99", path = { "valve-2" }, request_below = 0.1, fill_amount = 64 },
  },
}]], short2, short2)
  boot.reset_module_cache()
  local fuel = plant.new_fuel({ node_id = 'fuel-1', routes = routes, enabled = false })
  fuel:activate()
  fuel:boot('nodes/fuel/main.lua')

  local net = bus_lib.new()
  net:attach('RT1', rt1)
  net:attach('RT2', rt2)
  net:attach('MASTER', master)
  net:attach('FUEL', fuel)
  net:run(900)

  -- Die Datei traegt jetzt die globale Kennung -- nur bei der Route, die
  -- sich eindeutig zuordnen liess.
  local saved = assert(load(fuel.files['/xreactor_config/fuel_routes.lua'], '=fuel_routes'))()
  assert_eq(saved.reactors[1].reactor_id, global2,
    'Route "Reaktor 3" muss auf die globale Kennung von RT-2 umgestellt sein')
  assert_eq(saved.reactors[1].path[1], 'valve-1', 'ihr Ventilweg bleibt')
  assert_eq(saved.reactors[2].reactor_id, short2, 'Route "Reaktor 99" bleibt unveraendert')

  -- Und FUEL kennt jetzt den Fuellstand des RICHTIGEN Reaktors (RT-2: 75 %).
  local status = net:last_message_from('FUEL', 'STATUS')
  local reactors = status and status.payload and status.payload.logistics
    and status.payload.logistics.reactors or {}
  local by_label = {}
  for _, r in ipairs(reactors) do by_label[r.label] = r end
  assert_true(by_label['Reaktor 3'] ~= nil, 'Route "Reaktor 3" im Betriebszustand')
  assert_eq(by_label['Reaktor 3'].reactor_id, global2, 'mit der globalen Kennung')
  assert_eq(by_label['Reaktor 3'].fuel_pct, 75, 'und dem Fuellstand von RT-2s Reaktor (3000/4000)')
  assert_eq(by_label['Reaktor 99'].fuel_pct, nil, 'die nicht zuordenbare Route bekommt keinen Fuellstand')

  -- Gemeldet wurde die nicht zuordenbare Route -- und die Umstellung. Die
  -- Logzeilen der FUEL-Node gehen als LOG_EVENT_BATCH ueber Funk
  -- (core/utils.lua -> Log-Collector); dort werden sie gesucht.
  local function sent_log_lines(needle)
    local found = {}
    local function walk(value, depth)
      if depth > 6 then return end
      if type(value) == 'string' then
        if value:find(needle, 1, true) then found[#found + 1] = value end
      elseif type(value) == 'table' then
        for _, v in pairs(value) do walk(v, depth + 1) end
      end
    end
    for _, record in ipairs(net:messages_from('FUEL', 'LOG_EVENT_BATCH')) do
      if record.to == 'MASTER' then walk(record.message.entries, 0) end
    end
    return found
  end
  local warned = sent_log_lines("FUEL-Route 'Reaktor 99'")
  assert_true(#warned >= 1 and warned[1]:find('neu einlernen', 1, true) ~= nil,
    'die nicht zuordenbare Route muss mit Handlungsanweisung gemeldet werden')
  assert_eq(#sent_log_lines('Route(n) auf globale Reaktor-Kennung umgestellt'), 1,
    'die Umstellung steht genau einmal im Log')
end

print('ok fuel_route_global_id_upgrade_test')
