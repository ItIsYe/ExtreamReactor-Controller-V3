package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb gemeldet: Logistik AN, Uran im ME, alle Reaktoren
-- konfiguriert -- und trotzdem wurde nichts losgeschickt, kein Ventil
-- gestellt, waehrend der Status "verbunden/wird beliefert" zeigte.
--
-- _run_supply() hatte fuenf Ausstiege. Zwei davon waren VOELLIG still
-- (keine ME-Bridge, Lieferung laeuft noch), der Rest ging ueber
-- warn_once()/DEBUG in den Log-Collector -- also nie auf den Schirm des
-- Rechners, und warn_once() ausserdem nur ein einziges Mal ueberhaupt.
--
-- Diese Datei haelt fest, dass jeder dieser Faelle einen ablesbaren Grund
-- hinterlaesst, und dass ein stillgelegter Eintrag uebersprungen wird,
-- ohne die uebrigen mitzunehmen.

local router_lib = require('nodes.fuel.logistics_router')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local function new_router(logistics)
  local printed = {}
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  local r = router_lib.new({
    config = { logistics = logistics },
    log = function() end,
    warn_once = function() end,
  })
  _G.print = real_print
  return r, printed
end

local function supply(router)
  local printed = {}
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  local exported, errors = router:_run_supply({})
  _G.print = real_print
  return exported, errors, printed
end

-- ══ 1. Ohne ME-Bridge: frueher voellig still ════════════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = nil
  local exported, _, printed = supply(router)
  assert_eq(exported, 0)
  local block = router:get_summary().supply_block
  assert_true(block ~= nil, 'ohne ME-Bridge muss ein Grund hinterlegt sein')
  assert_eq(block.code, 'KEINE_ME_BRIDGE')
  assert_true(#printed > 0,
    'und er muss am Rechner selbst stehen -- utils.log() routet zum Log-Collector,'
      .. ' nicht auf den Bildschirm')
  assert_true(tostring(printed[1]):find('FUEL', 1, true) ~= nil)
end

-- ══ 2. Ohne Uebergabepunkt ══════════════════════════════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = nil
  supply(router)
  assert_eq(router:get_summary().supply_block.code, 'KEIN_UEBERGABEPUNKT')
end

-- ══ 3. Niemand fordert an -- auch das ist ein Grund ═════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.reactors = {}
  supply(router)
  local block = router:get_summary().supply_block
  assert_true(block ~= nil, 'auch "nichts zu tun" muss ablesbar sein')
  assert_eq(block.code, 'NIEMAND_FORDERT_AN')
end

-- ══ 4. Der Grund wird nur bei AENDERUNG gemeldet ════════════════════════
--
-- Sonst ist der Bildschirm nach einer Minute zugemuellt.

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = nil
  local _, _, first = supply(router)
  local _, _, second = supply(router)
  assert_true(#first > 0, 'der erste Zyklus meldet')
  assert_eq(#second, 0, 'der zweite mit demselben Grund schweigt')
end

-- ══ 5. Ein stillgelegter Eintrag nimmt die uebrigen nicht mit ═══════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.reactors = {
    { label = 'A', disabled_reason = 'ohne reactor_id', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
    { label = 'B', reactor_id = 'node-1:REACTOR-bbbb', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
  }
  supply(router)

  local summary = router:get_summary()
  local by_label = {}
  for _, entry in ipairs(summary.reactors) do by_label[entry.label] = entry end

  assert_true(by_label.A.disabled_reason ~= nil,
    'der stillgelegte Eintrag muss seinen Grund im Status tragen')
  assert_true(by_label.B.disabled_reason == nil,
    'der gute Eintrag bleibt unangetastet')

  -- Ein Eintrag OHNE reactor_id wuerde sonst in den Always-Supply-Modus
  -- fallen und ohne bekannten Fuellstand beliefert -- genau das darf die
  -- Stilllegung verhindern.
  assert_true(summary.supply_block == nil or summary.supply_block.code ~= 'ALWAYS_SUPPLY',
    'ein stillgelegter Eintrag darf nie in Always-Supply laufen')
end

-- ══ 6. "verbunden" heisst nicht "wird beliefert" ════════════════════════

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.reactors = {
    { label = 'B', reactor_id = 'node-1:REACTOR-bbbb', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
  }
  local entry = router:get_summary().reactors[1]
  assert_eq(entry.identity_known, true,
    'die Kennung ist bekannt -- das ist alles, was das alte Feld je aussagte')
  assert_eq(entry.supplied, false,
    'aber geliefert wurde nie etwas, und genau das muss getrennt ablesbar sein')
  assert_eq(entry.last_export_ts, nil)
end

-- ══ 7. "Niemand fordert an" hat drei Ursachen -- sie muessen getrennt sein ═
--
-- Aus dem Betrieb: "16 Eintrag/Eintraege geprueft, keiner unter seiner
-- Schwelle (oder Abklingzeit/stillgelegt)". Das trifft auf drei voellig
-- verschiedene Lagen zu, mit drei verschiedenen Massnahmen:
--   * kein Fuellstand bekannt  -> die RT-Meldung fehlt (Knoten aus, Reaktor
--     nicht eingelernt, Master-Relay stumm) -- die Logistik ist unschuldig
--   * ueber der Schwelle       -> der Reaktor ist satt, alles in Ordnung
--   * Abklingzeit              -> die letzte Lieferung zaehlt noch
-- Die Pauschalmeldung zwang zum Raten. Die Aufschluesselung muss jede
-- Teilmenge beziffern und den knappsten bekannten Fuellstand nennen.

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  local now = os.epoch('utc')
  router.fuel_status = {
    master_relay = {
      ['node-2:REACTOR-satt'] = { ts = now, fuel_amount = 600, fuel_capacity = 1000 },
      ['node-3:REACTOR-kalt'] = { ts = now, fuel_amount = 10,  fuel_capacity = 1000 },
    },
    direct_heard = {},
  }
  router._state.last_export_ts['node-3:REACTOR-kalt'] = now
  router._state.reactors = {
    -- kein Eintrag im fuel_status: RT meldet nichts
    { label = 'Stumm', reactor_id = 'node-1:REACTOR-stumm', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
    { label = 'Satt', reactor_id = 'node-2:REACTOR-satt', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
    -- unter der Schwelle, aber gerade beliefert
    { label = 'Kalt', reactor_id = 'node-3:REACTOR-kalt', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30, path = {} },
    { label = 'Kaputt', disabled_reason = 'ohne reactor_id', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
  }
  supply(router)

  local block = router:get_summary().supply_block
  assert_eq(block.code, 'NIEMAND_FORDERT_AN')
  local d = tostring(block.detail)
  assert_true(d:find('1 ohne Fuellstand-Daten', 1, true) ~= nil,
    'die fehlende RT-Meldung muss beziffert sein, nicht in einem Sammelsatz verschwinden: ' .. d)
  assert_true(d:find('1 ueber der Schwelle', 1, true) ~= nil, d)
  assert_true(d:find('1 in Abklingzeit', 1, true) ~= nil, d)
  assert_true(d:find('1 stillgelegt', 1, true) ~= nil, d)
  -- Der knappste bekannte Fuellstand beantwortet die eigentliche Frage des
  -- Betreibers: "wie weit ist der naechste Reaktor von einer Lieferung weg?"
  assert_true(d:find('Satt', 1, true) ~= nil and d:find('60%', 1, true) ~= nil,
    'der knappste bekannte Fuellstand und seine Schwelle gehoeren in die Meldung: ' .. d)
  assert_true(d:find('Schwelle 25%', 1, true) ~= nil, d)
end

-- ══ 8. Eine laufende Lieferung flutet den Bildschirm nicht ═════════════
--
-- Aus dem Betrieb: derselbe Satz Zeile fuer Zeile, nur mit anderem
-- Sekundenzaehler ("seit 4s", "seit 5s", "seit 6s") und wechselnder Phase
-- (OPENING/EXPORTING/FINAL_BLOCK), bis nichts anderes mehr lesbar war.
--
-- Ursache: der Entprellungs-Schluessel war der Meldungstext selbst -- und
-- der aendert sich per Konstruktion in JEDEM Zyklus. Damit galt jede
-- Sekunde als neuer Grund.
--
-- Zweitens ist eine laufende Lieferung ueberhaupt kein Missstand: sie ist
-- genau das, was passieren soll. Gemeldet wird sie erst, wenn sie haengt --
-- dann allerdings ist sie der wichtigste Hinweis, weil sie jede weitere
-- Lieferung sperrt.

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  local started = os.epoch('utc')
  router._state.current_request =
    { label = 'Reaktor 14', phase = 'OPENING', started_ts = started }

  local lines = 0
  for _, phase in ipairs({ 'OPENING', 'OPENING', 'EXPORTING', 'FINAL_BLOCK', 'OPENING' }) do
    router._state.current_request.phase = phase
    local _, _, printed = supply(router)
    lines = lines + #printed
  end
  assert_eq(lines, 0,
    'eine frisch laufende Lieferung schreibt keine einzige Zeile -- sie ist kein Ausfall')

  -- Der Zustand steht trotzdem fuer die UI bereit.
  local block = router:get_summary().supply_block
  assert_eq(block.code, 'LIEFERUNG_LAEUFT')
  assert_true(tostring(block.detail):find('Reaktor 14', 1, true) ~= nil)

  -- Haengt sie dagegen, wird genau EINMAL gemeldet. Ein laufender
  -- Ventil-Router haelt sie dabei am Leben -- sie ist haengend, nicht
  -- verwaist.
  router._state.rs_router = {
    get_active_transaction = function() return { transaction_id = 'tx-1', phase = 'BLOCKING' } end,
    valve_count = function() return 4 end,
    get_routing_state = function() return 'ROUTING_VALID' end,
  }
  router._state.current_request.started_ts = started - 35000
  local _, _, first = supply(router)
  local _, _, second = supply(router)
  assert_eq(#first, 1, 'eine haengende Lieferung muss gemeldet werden')
  assert_eq(#second, 0, 'aber nicht in jedem Zyklus erneut')
  assert_true(tostring(first[1]):find('Ventile bekannt: 4', 1, true) ~= nil,
    'und sie muss sagen, was der Ventil-Router selbst sieht: ' .. tostring(first[1]))
end

-- ══ 15. Eine verwaiste Lieferung legt den Knoten nicht dauerhaft lahm ══
--
-- Aus dem Betrieb: "Reaktor 14 seit 33s in Phase BLOCKING". BLOCKING hat
-- im Ventil-Router eine Frist von 15s -- die Phase konnte also gar nicht
-- mehr aktuell sein. Sie stammte aus der Vorbelegung beim Start und wurde
-- nur in get_summary() nachgezogen.
--
-- Dahinter steckt ein echter Defekt: _run_supply() steigt bei gesetztem
-- current_request GANZ OBEN aus. Kam der Abschluss-Rueckruf des Routers
-- nie an, blieb der Knoten fuer immer stehen und lieferte nie wieder --
-- ohne dass irgendetwas kaputt gewesen waere.

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  -- Der Router fuehrt KEINE Transaktion mehr.
  router._state.rs_router = {
    get_active_transaction = function() return nil end,
    valve_count = function() return 4 end,
    get_routing_state = function() return 'ROUTING_VALID' end,
  }
  router._state.current_request =
    { label = 'Reaktor 14', phase = 'BLOCKING', started_ts = os.epoch('utc') - 60000 }

  local _, _, printed = supply(router)
  assert_true(router._state.current_request == nil,
    'die verwaiste Lieferung muss freigegeben werden, sonst liefert der Knoten nie wieder')
  local block = router:get_summary().supply_block
  assert_eq(block.code, 'LIEFERUNG_VERWAIST')
  assert_true(#printed > 0, 'und das gehoert angesagt, nicht stillschweigend repariert')

  -- Und der naechste Zyklus laeuft wieder normal durch.
  router._state.reactors = {}
  supply(router)
  assert_eq(router:get_summary().supply_block.code, 'NIEMAND_FORDERT_AN')
end

-- Eine echte, noch laufende Transaktion wird NIE freigegeben -- auch nicht
-- nach langer Zeit. Sonst koennte der Knoten eine zweite Lieferung starten,
-- waehrend die erste noch Ventile offen haelt.

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.rs_router = {
    get_active_transaction = function() return { transaction_id = 'tx-9', phase = 'HOLDING' } end,
    valve_count = function() return 4 end,
    get_routing_state = function() return 'ROUTING_VALID' end,
  }
  router._state.current_request =
    { label = 'Reaktor 14', phase = 'BLOCKING', started_ts = os.epoch('utc') - 120000 }

  supply(router)
  assert_true(router._state.current_request ~= nil,
    'solange der Router wirklich faehrt, wird nichts freigegeben')
  local block = router:get_summary().supply_block
  assert_eq(block.code, 'LIEFERUNG_LAEUFT')
  assert_true(tostring(block.detail):find('HOLDING', 1, true) ~= nil,
    'und die Phase kommt live vom Router, nicht aus der Vorbelegung: ' .. tostring(block.detail))
end

-- ══ 9. Der stillste Ausfall: Erfolg gemeldet, null Stueck bewegt ═══════
--
-- Aus dem Betrieb: die Transaktion lief sauber durch (OPENING → EXPORTING
-- → FINAL_BLOCK), Ventile wurden gestellt, das Protokoll zeigte Lieferung
-- um Lieferung -- und am Reaktor kam nie etwas an, ohne ein einziges Wort.
--
-- exportItemToPeripheral() meldet in diesem Fall Erfolg und bewegt null
-- Stueck (volle Uebergabekiste, unbekannter Ziel-Name, reservierter
-- Bestand). Der Code fragte nur "moved > 0" und schwieg sonst -- und weil
-- record_export() ebenfalls nur bei moved > 0 laeuft, wurde auch keine
-- Abklingzeit gesetzt: derselbe Reaktor lief sofort wieder los. Genau das
-- endlose Wiederholen war im Betrieb zu sehen.

do
  local router = new_router({ enabled = true, reactors = {} })
  router.config.reserve_items =
    { { element = 'uranium', item = 'xr:uranium_ingot', unit_multiplier = 1 } }
  local exported_calls = {}
  router._state.bridge = { name = 'meBridge_0', wrapped = {
    getItem = function(_) return { amount = 512 } end,
    -- Erfolg gemeldet, nichts bewegt.
    exportItemToPeripheral = function(_, _) exported_calls[#exported_calls + 1] = true; return 0 end,
  } }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router.fuel_status = {
    master_relay = { ['node-14:REACTOR-x'] = { ts = os.epoch('utc'), fuel_amount = 10, fuel_capacity = 1000 } },
    direct_heard = {},
  }
  router._state.reactors = {
    { label = 'Reaktor 14', reactor_id = 'node-14:REACTOR-x', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30, path = {} },
  }

  local exported, _, printed = supply(router)
  assert_eq(exported, 0)
  assert_true(#exported_calls > 0, 'der Export wurde versucht')

  local block = router:get_summary().supply_block
  assert_true(block ~= nil, 'null bewegte Stueck duerfen nicht laut- und spurlos bleiben')
  assert_eq(block.code, 'EXPORT_BEWEGTE_NICHTS')
  assert_true(tostring(block.detail):find('Reaktor 14', 1, true) ~= nil, tostring(block.detail))
  assert_true(tostring(block.detail):find('chest_0', 1, true) ~= nil, tostring(block.detail))
  assert_true(#printed > 0, 'und der Grund muss am Rechner selbst stehen')
end

-- Auch eine Antwort, die gar keine Zahl ist, wurde bisher wortlos zu "0".

do
  local router = new_router({ enabled = true, reactors = {} })
  router.config.reserve_items =
    { { element = 'uranium', item = 'xr:uranium_ingot', unit_multiplier = 1 } }
  router._state.bridge = { name = 'meBridge_0', wrapped = {
    getItem = function(_) return { amount = 512 } end,
    exportItemToPeripheral = function(_, _) return { ok = false } end,
  } }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router.fuel_status = {
    master_relay = { ['node-14:REACTOR-x'] = { ts = os.epoch('utc'), fuel_amount = 10, fuel_capacity = 1000 } },
    direct_heard = {},
  }
  router._state.reactors = {
    { label = 'Reaktor 14', reactor_id = 'node-14:REACTOR-x', request_below = 0.25,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30, path = {} },
  }
  supply(router)
  local block = router:get_summary().supply_block
  assert_eq(block.code, 'EXPORT_BEWEGTE_NICHTS')
  assert_true(tostring(block.detail):find('kein Zahlwert', 1, true) ~= nil,
    'die Form der Antwort gehoert in die Meldung -- sie sagt, WAS die Bridge stattdessen lieferte: '
      .. tostring(block.detail))
end

-- ══ 10. "ohne Fuellstand-Daten" muss die Eintraege benennen ════════════
--
-- Aus dem Betrieb ein direkter Widerspruch: die Meldung zaehlte "15 ohne
-- Fuellstand-Daten, 1 ueber der Schwelle", waehrend die Oberflaeche im
-- selben Moment ZWEI Reaktoren mit frischem Fuellstand zeigte -- einen
-- davon (Reaktor 14, 51% bei Schwelle 65%) sogar als ANFORDERUNG.
--
-- Mit blossen Anzahlen ist so ein Widerspruch nicht aufloesbar. Die
-- Meldung nennt die Eintraege jetzt beim Namen und sagt dazu, ob ihre
-- juengste Probe zu alt oder ueberhaupt nie eingetroffen ist -- das sind
-- zwei verschiedene Fehler (Einlernen gegen RT/Funk).

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  local now = os.epoch('utc')
  router.fuel_status = {
    -- zu alt fuer die Frischepruefung (>30s), aber gehoert
    master_relay = { ['node-9:REACTOR-alt'] = { ts = now - 90000, fuel_amount = 10, fuel_capacity = 1000 } },
    direct_heard = {},
  }
  router._state.reactors = {
    { label = 'Reaktor 9', reactor_id = 'node-9:REACTOR-alt', request_below = 0.65,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
    { label = 'Reaktor 13', reactor_id = 'node-13:REACTOR-nie', request_below = 0.65,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
  }
  supply(router)

  local d = tostring(router:get_summary().supply_block.detail)
  assert_true(d:find('Reaktor 9', 1, true) ~= nil, 'der Eintrag muss benannt sein: ' .. d)
  assert_true(d:find('90s alt', 1, true) ~= nil,
    'gehoert, aber veraltet -- das ist ein RT-/Funkproblem: ' .. d)
  assert_true(d:find('Reaktor 13', 1, true) ~= nil, d)
  assert_true(d:find('nie gehoert', 1, true) ~= nil,
    'nie gehoert -- das ist ein Einlern-Problem, ein anderer Fehler: ' .. d)
end

-- ══ 11. Eine geroutete Lieferung raeumt den Grund weg ══════════════════
--
-- Sie kehrt sofort zurueck (der Rest laeuft asynchron), erreicht also das
-- "exported > 0" am Ende von _run_supply() nie. Der letzte Grund blieb
-- dadurch fuer immer in der Oberflaeche stehen -- auch waehrend laengst
-- alles lief. Genau das zeigte das Betriebsbild: ein Banner "keine
-- Lieferung", darunter ein Reaktor in ANFORDERUNG.

do
  local router = new_router({ enabled = true, reactors = {} })
  router.config.reserve_items =
    { { element = 'uranium', item = 'xr:uranium_ingot', unit_multiplier = 1 } }
  router._state.bridge = { name = 'meBridge_0', wrapped = {
    getItem = function(_) return { amount = 512 } end,
    exportItemToPeripheral = function(_, _) return 64 end,
  } }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router.fuel_status = {
    master_relay = { ['node-14:REACTOR-x'] = { ts = os.epoch('utc'), fuel_amount = 510, fuel_capacity = 1000 } },
    direct_heard = {},
  }
  router._state.reactors = {
    { label = 'Reaktor 14', reactor_id = 'node-14:REACTOR-x', request_below = 0.65,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30, path = { 'v1' } },
  }

  -- Ein Router, der so tut, als sei Routing eingerichtet: er fuehrt den
  -- Export sofort aus und laesst die Transaktion danach offen weiterlaufen.
  router._state.rs_router = {
    get_routing_state = function() return 'ROUTING_VALID' end,
    begin_transaction = function(_, _, do_export, _, _)
      do_export()
      return true, nil, 'tx-1'
    end,
    get_active_transaction = function() return { transaction_id = 'tx-1', phase = 'OPENING' } end,
  }

  -- Erst ein Grund aus einem frueheren Zyklus ...
  router._state.supply_block = { code = 'NIEMAND_FORDERT_AN', detail = 'alt' }
  router._state.supply_block_key = 'NIEMAND_FORDERT_AN|alt'

  supply(router)
  local summary = router:get_summary()
  assert_true(summary.supply_block == nil or summary.supply_block.code == 'LIEFERUNG_LAEUFT',
    'sobald wirklich etwas bewegt wurde, darf kein alter "liefert nicht"-Grund stehen bleiben: '
      .. tostring(summary.supply_block and summary.supply_block.code))
end

-- ══ 12. Jeder Ausstieg aus der Kandidatenschleife hinterlaesst einen Grund

-- Aus dem Betrieb: "es passiert weiterhin nichts, es sieht so aus, als
-- wuerde nichts aus der ME Bridge rausgenommen". Genau dieser Fall war
-- spurlos: die Schleife sprang ueber jeden Kandidaten (Mindestreserve,
-- keine lieferbare Form, kein stellbarer Ventilweg) und _run_supply()
-- endete ohne ein einziges Wort -- die Oberflaeche zeigte weiter den
-- Grund des VORIGEN Zyklus.

do
  local router = new_router({ enabled = true, reactors = {} })
  -- 100 Barren im ME, aber min_in_me haelt 500 zurueck.
  router.config.reserve_items =
    { { element = 'uranium', item = 'xr:uranium_ingot', unit_multiplier = 1 } }
  local exported_calls = 0
  router._state.bridge = { name = 'meBridge_0', wrapped = {
    getItem = function(_) return { amount = 100 } end,
    exportItemToPeripheral = function(_, _) exported_calls = exported_calls + 1; return 64 end,
  } }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router.fuel_status = {
    master_relay = { ['node-14:REACTOR-x'] = { ts = os.epoch('utc'), fuel_amount = 10, fuel_capacity = 1000 } },
    direct_heard = {},
  }
  router._state.reactors = {
    { label = 'Reaktor 14', reactor_id = 'node-14:REACTOR-x', request_below = 0.65,
      fill_amount = 64, min_in_me = 500, resupply_cooldown_s = 0, path = {} },
  }

  local _, _, printed = supply(router)
  assert_eq(exported_calls, 0, 'die Mindestreserve verhindert den Export -- richtig so')

  local block = router:get_summary().supply_block
  assert_true(block ~= nil, 'aber wortlos darf das nicht passieren')
  assert_eq(block.code, 'KEIN_KANDIDAT_BEDIENBAR')
  local d = tostring(block.detail)
  assert_true(d:find('Reaktor 14', 1, true) ~= nil, d)
  assert_true(d:find('min_in_me=500', 1, true) ~= nil,
    'der Grund muss die Stellschraube benennen, an der der Betreiber drehen kann: ' .. d)
  assert_true(#printed > 0, 'und am Rechner selbst stehen')
end

-- ══ 13. Ein abgelehnter Export ist nicht nur eine Zeile im Log ═════════
--
-- Lehnt die ME Bridge ab (unbekannter Ziel-Name, unbekannter Gegenstand),
-- lief das bisher ausschliesslich ueber warn_once() -- also in den
-- Log-Collector und dort genau ein einziges Mal. Es ist aber der
-- direkteste Grund dafuer, dass nichts aus dem ME herauskommt.

do
  local router = new_router({ enabled = true, reactors = {} })
  router.config.reserve_items =
    { { element = 'uranium', item = 'xr:uranium_ingot', unit_multiplier = 1 } }
  router._state.bridge = { name = 'meBridge_0', wrapped = {
    getItem = function(_) return { amount = 512 } end,
    exportItemToPeripheral = function(_, _) error('No such container chest_0', 0) end,
  } }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router.fuel_status = {
    master_relay = { ['node-14:REACTOR-x'] = { ts = os.epoch('utc'), fuel_amount = 10, fuel_capacity = 1000 } },
    direct_heard = {},
  }
  router._state.reactors = {
    { label = 'Reaktor 14', reactor_id = 'node-14:REACTOR-x', request_below = 0.65,
      fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 0, path = {} },
  }

  local _, _, printed = supply(router)
  local block = router:get_summary().supply_block
  assert_eq(block.code, 'EXPORT_FEHLER')
  assert_true(tostring(block.detail):find('No such container', 1, true) ~= nil,
    'der Wortlaut der Bridge gehoert in die Meldung -- er benennt das Problem: '
      .. tostring(block.detail))
  assert_true(#printed > 0, 'und er muss am Rechner stehen, nicht nur im Log-Collector')
end

-- ══ 14. Ob ueberhaupt Ventile gestellt werden, muss ablesbar sein ══════
--
-- Aus dem Betrieb: "die Valves, weiss ich nicht, ob die gestellt werden".
-- Ohne eingerichtetes Routing wird NIE ein Ventil gestellt -- dann geht
-- alles direkt in die Uebergabekiste und die Verrohrung entscheidet
-- allein. Das ist ein voellig anderer Betrieb, und er war nirgends
-- angesagt.

do
  local router = new_router({ enabled = true, reactors = {} })
  router._state.bridge = { name = 'meBridge_0', wrapped = {} }
  router._state.export_chest = { name = 'chest_0', wrapped = {} }
  router._state.reactors = {}
  local _, _, printed = supply(router)
  local said = table.concat(printed, ' | ')
  assert_true(said:find('Ventilsteuerung NICHT eingerichtet', 1, true) ~= nil,
    'ohne Routing muss der Knoten genau das sagen: ' .. said)

  -- und nur bei Aenderung, nicht in jedem Zyklus
  local _, _, again = supply(router)
  local repeated = table.concat(again, ' | ')
  assert_true(repeated:find('Ventilsteuerung', 1, true) == nil,
    'aber nicht in jedem Zyklus erneut: ' .. repeated)
end

print('fuel_supply_block_reason_test.lua: ok')
