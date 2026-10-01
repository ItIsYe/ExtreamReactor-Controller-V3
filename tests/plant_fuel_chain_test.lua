package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Brennstoffkette ueber DREI echt gebootete Rollen.
--
--   RT (liest den Reaktor)  ->  MASTER (fuel_relay)  ->  FUEL (liefert nach)
--
-- FUEL hat keinen eigenen Zugriff auf die Reaktoren. Bricht irgendwo in
-- dieser Kette ein Feldname oder eine Kennung, verhungert die Anlage --
-- und zwar OHNE Fehlermeldung: FUEL zeigt dann einfach keinen Fuellstand.
-- Genau diese Lage wurde mehrfach gemeldet.
--
-- Der heikelste Teil ist die KENNUNG. RT bildet sie aus der Reaktor-
-- Identitaet (core/reactor_identity.lua) und sendet sie als
-- reactors[].id/.global_id. FUEL muss in fuel_routes.lua genau diese
-- Kennung stehen haben. Steht dort eine andere -- von Hand getippt, oder
-- gelernt bevor das Multiblock neu gebaut wurde -- passt nichts mehr
-- zusammen, und nichts sagt es.
--
-- Darum nimmt dieser Test die Kennung NICHT aus einer Konstante, sondern
-- aus dem, was RT wirklich sendet. Genauso macht es das Einlernen am
-- Router-Schirm.

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')
local boot = require('support.cc_node_boot')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

-- ══ Schritt 1: RT und MASTER laufen, die Kennung wird gelernt ═══════════

local FUEL_AMOUNT, FUEL_CAPACITY = 1800, 4000

local rt = plant.new_rt({
  turbines = 3, node_id = 'node-101',
  reactor = { fuel = FUEL_AMOUNT, fuel_max = FUEL_CAPACITY },
})
local master = plant.new_master({ node_id = 'master-1' })

plant.boot_all({
  { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
  { name = 'MASTER', env = master, main = 'master/main.lua' },
})

local learn = bus_lib.new()
learn:attach('RT', rt)
learn:attach('MASTER', master)
learn:run(80)

local reactor_id, global_id
do
  local status = learn:last_message_from('RT', 'STATUS')
  assert_true(status ~= nil, 'RT muss Status senden -- Verkehr: ' .. learn:traffic_summary())
  local reactor = (status.payload.reactors or {})[1]
  assert_true(reactor ~= nil, 'der Reaktor muss im Status stehen')
  reactor_id, global_id = reactor.id, reactor.global_id
  assert_true(reactor_id ~= nil, 'der Reaktor braucht eine Kennung')
  assert_true(global_id ~= nil, 'und eine knotenweite Kennung')
  assert_eq(reactor.fuel_amount, FUEL_AMOUNT, 'mit dem gelesenen Fuellstand')
  assert_eq(reactor.fuel_capacity, FUEL_CAPACITY, 'und der Kapazitaet')
end

-- ══ Schritt 2: FUEL mit GENAU dieser Kennung booten ════════════════════
--
-- Wie das Einlernen am Router-Schirm: die Kennung kommt aus der
-- RT-Meldung, nicht aus der Tastatur.

local routes = string.format([[return {
  export_chest = "chest_0",
  reactors = {
    { reactor_id = %q, label = "Reaktor A", path = { "valve-1" },
      request_below = 0.9, fill_amount = 64 },
  },
}]], global_id)

boot.reset_module_cache()
local fuel = plant.new_fuel({ node_id = 'fuel-1', routes = routes, enabled = true })
fuel:activate()
fuel:boot('nodes/fuel/main.lua')

local net = bus_lib.new()
net:attach('RT', rt)
net:attach('MASTER', master)
net:attach('FUEL', fuel)
net:run(300)

-- ── 1. Alle drei reden ───────────────────────────────────────────────────
do
  assert_true(#net:messages_from('FUEL', 'HELLO') >= 1,
    'FUEL muss sich anmelden -- Verkehr: ' .. net:traffic_summary())
  assert_eq(#net.dropped, 0, 'keine Nachricht darf ohne Empfaenger bleiben')
end

-- ── 2. MASTER relais den Fuellstand ueberhaupt ───────────────────────────
--
-- Als COMMAND mit target FUEL_STATUS (master/fuel_relay.lua). Geprueft wird
-- die LETZTE: die ersten gehen raus, bevor MASTER ueberhaupt RT-Daten hat,
-- und sind zu Recht leer.
local relayed
do
  local count = 0
  for _, record in ipairs(net:messages_from('MASTER', 'COMMAND')) do
    local command = record.message.payload and record.message.payload.command
    if command and command.target == 'FUEL_STATUS' then
      count = count + 1
      relayed = command.value
    end
  end
  assert_true(count >= 1, 'MASTER muss den Fuellstand weitergeben')
  assert_true(type(relayed) == 'table', 'mit einem Inhalt')

  local entries = 0
  for _ in pairs(relayed) do entries = entries + 1 end
  assert_true(entries >= 1, string.format(
    'die letzte Weitergabe darf nicht leer sein -- %d Pakete gesendet', count))
end

-- ── 3. Der Fuellstand kommt unter der Kennung an, die RT gesendet hat ────
--
-- Der Kern. Hier bricht es, wenn eine der drei Seiten die Kennung anders
-- bildet.
do
  local entry = relayed[global_id]
  assert_true(entry ~= nil, string.format(
    'der Fuellstand muss unter der knotenweiten Kennung %q liegen -- vorhanden: %s',
    tostring(global_id), (function()
      local keys = {}
      for key in pairs(relayed) do keys[#keys + 1] = tostring(key) end
      table.sort(keys)
      return table.concat(keys, ', ')
    end)()))
  assert_eq(entry.fuel_amount, FUEL_AMOUNT, 'mit dem Fuellstand, den RT gelesen hat')
  assert_eq(entry.fuel_capacity, FUEL_CAPACITY, 'und der Kapazitaet')
  assert_eq(entry.source_node, 'node-101', 'und dem Knoten, von dem er kommt')

  -- Die kurze Kennung bleibt als Alias erhalten (Rolling-Upgrade, siehe
  -- fuel_relay.lua) -- eine Route, die noch die alte Form traegt, laeuft
  -- weiter.
  assert_true(relayed[reactor_id] ~= nil,
    'die kurze Kennung muss als Alias erhalten bleiben')
end

-- ── 4. FUEL kennt den Reaktor und SEINEN Fuellstand ──────────────────────
--
-- Das Ende der Kette. fuel_pct = nil heisst: die Route ist konfiguriert,
-- aber FUEL weiss nichts ueber diesen Reaktor -- genau das Bild "FUEL tut
-- nichts", ohne dass ein Fehler zu sehen waere.
do
  local status = net:last_message_from('FUEL', 'STATUS')
  assert_true(status ~= nil and type(status.payload) == 'table',
    'FUEL muss Status senden -- Verkehr: ' .. net:traffic_summary())

  local logistics = status.payload.logistics or {}
  assert_eq(logistics.enabled, true, 'die Logistik muss laufen')
  assert_eq(logistics.configured_reactor_count, 1, 'eine Route ist konfiguriert')

  local reactors = logistics.reactors or {}
  assert_eq(#reactors, 1, 'und sie muss im Betriebszustand auftauchen')

  local entry = reactors[1]
  assert_eq(entry.reactor_id, global_id, 'mit der Kennung aus der Route')
  assert_true(entry.disabled_reason == nil,
    'nicht stillgelegt, Grund waere: ' .. tostring(entry.disabled_reason))

  local expected_pct = math.floor(FUEL_AMOUNT / FUEL_CAPACITY * 100)
  assert_eq(entry.fuel_pct, expected_pct, string.format(
    'FUEL muss den Fuellstand kennen (%d %% aus %d/%d)',
    expected_pct, FUEL_AMOUNT, FUEL_CAPACITY))
end

-- ── 5. Eine FALSCHE Kennung faellt auf ───────────────────────────────────
--
-- Der Gegenbeweis, und der praktisch wichtigste Fall: steht in der Route
-- eine Kennung, die es im Netz nicht gibt (von Hand getippt, oder gelernt
-- bevor das Multiblock neu gebaut wurde), dann bleibt der Fuellstand leer.
-- Dieser Test haelt fest, dass genau das passiert -- damit niemand spaeter
-- glaubt, eine beliebige Kennung genuege.
do
  assert_true(relayed['node-199:GIBT-ES-NICHT'] == nil,
    'eine erfundene Kennung darf im Relais nicht auftauchen')
end

print('ok plant_fuel_chain_test')
