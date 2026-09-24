package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die FUEL-Node hat keinen eigenen Zugriff auf die Reaktoren. Ihre Zahlen
-- kommen ueber eine Kette:
--
--   RT-Knoten (status_snapshot.build_status_payload -> reactors[])
--     -> MASTER (fuel_relay.collect_reactor_fuel)
--       -> FUEL
--
-- Unter v2 uebersteuert main.lua nur Modus- und Kapazitaetsfelder dieses
-- Payloads; die Reaktor-Momentaufnahme wird weiter vom echten Adapter
-- gelesen. Diese Datei sichert genau das ab -- dass der Umbau der
-- RT-Regelung der FUEL-Node nicht die Datengrundlage wegnimmt.

local status_snapshot = require('nodes.rt.status_snapshot')
local fuel_relay = require('master.fuel_relay')
local constants = require('shared.constants')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a)) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local NOW = 1700000000000
os.epoch = function() return NOW end

-- ── Ein RT-Knoten mit einem Reaktor, so wie ihn der Adapter liefert ──────

local REACTOR = { name = 'reactor_0', id = 'reactor:reactor_0' }
local reactor_adapter = {
  inspect = function()
    return {
      active = true, temperature = 950, control_rod_level = 85,
      fuel = 3200, fuel_max = 4000,              -- <- worauf es FUEL ankommt
      steam = 18000, coolant_amount = 9000, coolant_amount_max = 10000,
      coolant_ratio = 0.9, steam_fill_ratio = 0.18,
    }
  end,
}
local turbine_adapter = { inspect = function() return nil end }

local registry = {
  node_id = 'node-101',
  get_bound_devices = function(_, kind)
    if kind == 'reactor' then return { { id = REACTOR.id, name = REACTOR.name, alias = 'Reaktor A' } } end
    return {}
  end,
  get_summary = function() return {} end,
  get_devices_by_kind = function() return {} end,
  get_diagnostics = function() return {} end,
}

-- Modulzustaende kommen unter v2 aus rt2_projection -- hier der Wert, den
-- ein laufender Reaktor bekommt.
local modules = { [REACTOR.id] = { id = REACTOR.id, type = 'reactor', name = REACTOR.name, state = 'STABLE' } }

local ctx_snap = {
  registry = registry,
  reactor_adapter = reactor_adapter,
  turbine_adapter = turbine_adapter,
  modules = modules,
  log_prefix = 'RT',
  status_level = 'OK',
  targets = { power = 0, power_percent = 0 },
  node_state_machine = { state = function() return 'OFF' end },  -- unter v2 eingefroren
  current_state = 'INIT',
  build_health_payload = function() return { status = 'OK', capabilities = {}, bindings = {} } end,
  devices = { registry_summary = {} },
  capacity_learning = nil,
  config = {},
  log = function() end,
}

-- ── 1. Der RT-Payload traegt die Brennstoffwerte ─────────────────────────

local payload = status_snapshot.build_status_payload(ctx_snap)
assert_true(type(payload.reactors) == 'table', 'der Payload muss eine Reaktorliste enthalten')
assert_eq(#payload.reactors, 1)
local snap = payload.reactors[1]
assert_eq(snap.fuel_amount, 3200, 'FUEL braucht den Fuellstand')
assert_eq(snap.fuel_capacity, 4000, 'und das Fassungsvermoegen')
assert_true(snap.global_id ~= nil, 'und eine eindeutige Reaktorkennung ueber Knotengrenzen hinweg')

-- ── 2. Die v2-Uebersteuerung darf sie nicht wegnehmen ────────────────────
--
-- Genau die Zuweisungen aus main.lua's engine_v2-Zweig, nachgebaut: sie
-- fassen ausschliesslich Modus- und Kapazitaetsfelder an.
local v2 = {
  mode = 'AUTONOM', node_state = 'AUTONOM',
  capacity_ready = true, capacity_max = 108415,
  capacity_at_target = 25, capacity_total_turbines = 25,
  capacity_reason = 'MEASURED', capacity_sustainable_turbines = 25,
}
payload.mode = v2.mode
payload.control_mode = v2.mode
if v2.node_state then payload.state = v2.node_state end
if v2.capacity_ready ~= nil then payload.capacity_ready = v2.capacity_ready end
if v2.capacity_max then payload.capacity_max = v2.capacity_max end
if v2.capacity_at_target then payload.capacity_stable_turbines = v2.capacity_at_target end
if v2.capacity_total_turbines then payload.capacity_total_turbines = v2.capacity_total_turbines end
if v2.capacity_reason then payload.capacity_source = v2.capacity_reason end

assert_eq(payload.reactors[1].fuel_amount, 3200, 'die v2-Uebersteuerung fasst die Reaktorliste nicht an')
assert_eq(payload.reactors[1].fuel_capacity, 4000)
assert_eq(payload.state, 'AUTONOM', 'der gemeldete Zustand kommt dagegen aus v2')
assert_eq(payload.capacity_stable_turbines, 25,
  'und die Lernanzeige, die MASTER liest, wird von main.lua bereits umbenannt')

-- ── 3. MASTER macht daraus einen Eintrag fuer FUEL ───────────────────────

local runtime = {
  libs = { constants = constants },
  state = {
    nodes = {
      ['node-101'] = {
        id = 'node-101', role = constants.roles.RT_NODE,
        last_seen = NOW, stale = false, offline = false,
        rt = { reactors = payload.reactors },
      },
    },
  },
}
local collected = fuel_relay._collect_reactor_fuel(runtime)
assert_true(type(collected) == 'table', 'das Relay muss eine Sammlung liefern')

local entries = collected.reactors or collected
local found
for _, entry in pairs(entries) do
  if type(entry) == 'table' and entry.fuel_amount == 3200 then found = entry end
end
assert_true(found ~= nil,
  'der Reaktor des v2-Knotens muss beim Relay ankommen -- sonst steht die FUEL-Node ohne Zahlen da')
assert_eq(found.fuel_capacity, 4000)
assert_eq(found.source_node, 'node-101', 'mit der Quelle, damit FUEL mehrere RT-Knoten auseinanderhaelt')
assert_true(found.global_reactor_id ~= nil, 'und der knotenuebergreifenden Kennung')

-- ── 4. Ein veralteter oder abgemeldeter Knoten liefert nichts ────────────
--
-- Sonst dosiert FUEL gegen einen Fuellstand von vorgestern.
runtime.state.nodes['node-101'].stale = true
local stale = fuel_relay._collect_reactor_fuel(runtime)
local stale_entries = stale.reactors or stale
local stale_found = false
for _, entry in pairs(stale_entries) do
  if type(entry) == 'table' and entry.fuel_amount == 3200 then stale_found = true end
end
assert_true(not stale_found, 'ein als veraltet markierter Knoten darf nicht mehr einspeisen')

-- ── 5. Der zweite Weg: FUEL hoert RT direkt mit ──────────────────────────
--
-- Neben dem Relay ueber MASTER lauscht die FUEL-Node selbst auf dem
-- STATUS-Kanal. Dieser Weg traegt auch dann, wenn MASTER gerade weg ist --
-- und er liest dasselbe Feld aus demselben Payload, greift also genauso
-- ins Leere, wenn die Reaktorliste fehlt.
do
  local fuel_status_network = require('nodes.fuel.fuel_status_network')
  local protocol = require('core.protocol')

  local cache = fuel_status_network.new()
  local service = fuel_status_network.make_overhear_service(cache, constants)

  local message = {
    type = constants.message_types.STATUS,
    role = constants.roles.RT_NODE,
    sender_id = 'node-101',
    src = 'node-101',
    ts = NOW,
    proto_ver = constants.proto_ver,
    payload = payload,          -- exakt der Payload von oben, inkl. v2-Uebersteuerung
  }
  assert_true(select(1, protocol.validate(message)) == true,
    'Vorbedingung: die nachgebaute Statusmeldung muss gueltig sein')

  service.tick(service, 0, { 'modem_message', 'back', constants.channels.STATUS, 0, message })

  -- Mitgehoerte Werte landen in cache.direct_heard (die vom MASTER
  -- gemeldeten daneben in cache.master_relay -- beide Quellen werden
  -- getrennt gefuehrt, damit sich eine veraltete nicht als frisch ausgibt).
  local heard
  for _, entry in pairs(cache.direct_heard or {}) do
    if type(entry) == 'table' and entry.fuel_amount == 3200 then heard = entry end
  end
  assert_true(heard ~= nil,
    'FUEL muss den Fuellstand auch direkt aus der RT-Statusmeldung lesen koennen')
  assert_eq(heard.fuel_capacity, 4000)
  assert_true(next(cache.master_relay) == nil,
    'und das darf nicht faelschlich als MASTER-Meldung verbucht werden')
end

print('rt2_fuel_chain_test.lua: ok')
