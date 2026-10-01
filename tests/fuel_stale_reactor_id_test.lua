package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Eine Route, deren reactor_id es im Netz nicht gibt.
--
-- Der praktisch haeufigste FUEL-Fehler, und der am schwersten zu findende:
-- die Kennung in fuel_routes.lua haengt an der Reaktor-Identitaet
-- (core/reactor_identity.lua). Wird das Multiblock neu gebaut oder der
-- Peripheriename nach einem Modem-Reconnect anders vergeben, passt die
-- gespeicherte Route nicht mehr -- und nichts sagt es: fuel_pct bleibt leer,
-- FUEL fordert nie Brennstoff an, die Anlage tut nichts.
--
-- Auf dem Schirm stand dafuer bisher "Reaktordaten fehlen -- reactor_id und
-- RT-Status pruefen". Dieselbe Meldung erscheint aber auch, wenn RT oder
-- MASTER gar nicht liefern -- zwei Lagen mit VERSCHIEDENEN Handlungen:
--
--   Kennung falsch  -> Route neu einlernen. An RT/MASTER zu pruefen ist
--                      verlorene Zeit, die liefern ja.
--   Keine Daten     -> Verbindung pruefen.
--
-- Unterschieden wird an network_reactor_count: wie viele Reaktoren das Netz
-- UEBERHAUPT meldet.

local fuel_status_network = require('nodes.fuel.fuel_status_network')
local operational_summary = require('nodes.fuel.operational_summary')
local ui_completion = require('nodes.fuel.ui_completion')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local NOW = 1700000000000
os.epoch = function() return NOW end

-- ── 1. known_reactor_count zaehlt, was das Netz kennt ────────────────────
do
  local cache = fuel_status_network.new()
  assert_eq(fuel_status_network.known_reactor_count(cache), 0,
    'ein leerer Zwischenspeicher kennt keine Reaktoren')
  assert_eq(fuel_status_network.known_reactor_count(nil), 0,
    'und nil ebenso nicht')

  fuel_status_network.ingest_master_relay(cache, {
    ['node-101:R-AAA'] = { fuel_amount = 1800, fuel_capacity = 4000,
      source_node = 'node-101', local_reactor_id = 'R-AAA',
      global_reactor_id = 'node-101:R-AAA' },
    ['node-101:R-BBB'] = { fuel_amount = 900, fuel_capacity = 4000,
      source_node = 'node-101', local_reactor_id = 'R-BBB',
      global_reactor_id = 'node-101:R-BBB' },
  })
  assert_eq(fuel_status_network.known_reactor_count(cache), 2,
    'zwei gemeldete Reaktoren muessen als zwei gezaehlt werden')
end

-- ── 2. Die kurze Kennung als Alias zaehlt NICHT doppelt ──────────────────
--
-- master/fuel_relay.lua legt jeden Reaktor zusaetzlich unter seiner kurzen
-- Kennung ab (Rolling-Upgrade). Gezaehlt werden globale Kennungen, sonst
-- meldete der Schirm die doppelte Anzahl.
do
  local cache = fuel_status_network.new()
  fuel_status_network.ingest_master_relay(cache, {
    ['node-101:R-AAA'] = { fuel_amount = 1800, fuel_capacity = 4000,
      source_node = 'node-101', local_reactor_id = 'R-AAA',
      global_reactor_id = 'node-101:R-AAA' },
    ['R-AAA'] = { fuel_amount = 1800, fuel_capacity = 4000,
      source_node = 'node-101', local_reactor_id = 'R-AAA',
      global_reactor_id = 'node-101:R-AAA' },
  })
  assert_eq(fuel_status_network.known_reactor_count(cache), 1,
    'ein Reaktor mit Alias bleibt EIN Reaktor')
end

-- ── 3. enrich fuehrt die Zahl mit ────────────────────────────────────────
do
  local cache = fuel_status_network.new()
  fuel_status_network.ingest_master_relay(cache, {
    ['node-101:R-AAA'] = { fuel_amount = 1800, fuel_capacity = 4000,
      source_node = 'node-101', local_reactor_id = 'R-AAA',
      global_reactor_id = 'node-101:R-AAA' },
  })

  local summary = operational_summary.enrich({
    enabled = true, bridge = 'meBridge_0', export_chest = 'chest_0',
    reactors = {
      { reactor_id = 'node-101:R-VERALTET', label = 'Reaktor A', connected = true },
    },
  }, { fuel_status = cache, now_ms = NOW })

  assert_eq(summary.network_reactor_count, 1,
    'die Zahl der im Netz bekannten Reaktoren muss im Payload stehen')
  assert_eq(summary.reactors[1].fuel_data_state, 'MISSING',
    'fuer die veraltete Kennung liegen keine Daten vor')
end

-- ── 4. Der Schirm nennt die Kennung als Ursache ──────────────────────────
do
  local view = ui_completion.compute_view_state({ payload = {
    logistics = {
      enabled = true, bridge = 'meBridge_0', configured_reactor_count = 1,
      network_reactor_count = 2,
      reactors = { { label = 'Reaktor A', fuel_data_state = 'MISSING' } },
    },
    bindings = { storage = 1 },
    valve_summary = { offline = 0, stale = 0 },
    master_connected = true,
  } }, {}, 100, 10)

  assert_eq(view.code, 'REACTOR_ID_UNKNOWN',
    'meldet das Netz Reaktoren, aber nicht den konfigurierten, ist die Kennung die Ursache')
  assert_true(view.detail:find('Reaktor A', 1, true) ~= nil,
    'mit dem Namen der betroffenen Route')
  assert_true(view.detail:find('2', 1, true) ~= nil,
    'und der Zahl der tatsaechlich gemeldeten Reaktoren -- Detail war: ' .. view.detail)
  assert_true(view.action:find('EINLERNEN', 1, true) ~= nil,
    'die Handlung muss zum Einlernen fuehren, nicht zur Verbindungspruefung')
end

-- ── 5. Ohne JEDE Reaktormeldung bleibt es die Verbindung ─────────────────
do
  local view = ui_completion.compute_view_state({ payload = {
    logistics = {
      enabled = true, bridge = 'meBridge_0', configured_reactor_count = 1,
      network_reactor_count = 0,
      reactors = { { label = 'Reaktor A', fuel_data_state = 'MISSING' } },
    },
    bindings = { storage = 1 },
    valve_summary = { offline = 0, stale = 0 },
    master_connected = true,
  } }, {}, 100, 10)

  assert_eq(view.code, 'DATA_MISSING',
    'meldet das Netz gar keine Reaktoren, ist die Verbindung die Spur')
  assert_true(view.action:find('Verbindung', 1, true) ~= nil,
    'und die Handlung muss dorthin fuehren')
end

-- ── 6. Alte Payloads ohne das Feld verhalten sich wie zuvor ──────────────
do
  local view = ui_completion.compute_view_state({ payload = {
    logistics = {
      enabled = true, bridge = 'meBridge_0', configured_reactor_count = 1,
      reactors = { { label = 'Reaktor A', fuel_data_state = 'MISSING' } },
    },
    bindings = { storage = 1 },
    valve_summary = { offline = 0, stale = 0 },
    master_connected = true,
  } }, {}, 100, 10)

  assert_eq(view.code, 'DATA_MISSING',
    'ohne network_reactor_count bleibt das alte Verhalten')
end

print('ok fuel_stale_reactor_id_test')
