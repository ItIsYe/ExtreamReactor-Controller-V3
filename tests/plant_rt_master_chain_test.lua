package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- RT und MASTER, beide ECHT gebootet, reden ueber ein echtes Funknetz.
--
-- WOFUER. Was in dieser Anlage kaputtgeht, liegt fast nie in einer Funktion,
-- sondern ZWISCHEN zwei Rollen. Die bisherigen Kettentests pruefen diese
-- Naehte mit HANDGESCHRIEBENEN Daten -- und genau die Handschrift ist das
-- Problem: sie bleibt richtig, waehrend die echte Nachricht sich aendert.
--
-- Hier laeuft beides wirklich: nodes/rt/main.lua und master/main.lua booten
-- in einem Prozess (jede mit eigenem Modulgraphen, siehe
-- support/cc_node_boot.lua), und was die eine ueber modem.transmit() rausgibt,
-- stellt support/node_message_bus.lua der anderen als modem_message zu.
--
-- Was damit abgesichert ist -- die Kette, die in diesem Projekt zweimal
-- gerissen ist:
--
--   RT lernt seine Leistung ein -> meldet sie im Status -> MASTER rechnet
--   daraus einen Prozentsatz -> schickt ihn als SET_SETPOINTS -> RT nimmt ihn
--   an und regelt danach.
--
-- Riss 1: das Einlernen endete nie, capacity_ready blieb false, MASTER
-- behandelte das als "keine Kapazitaet" und schickte dauerhaft 0 % --
-- waehrend die Node auf 100 % regelte ("Master 0 %, Turbinen trotzdem
-- 100 %"). Riss 2: die erste Vorgabe nach einem Reconnect wurde mit
-- INVALID_STATE abgelehnt.
--
-- Beide waeren hier aufgefallen. Kein Modultest konnte sie sehen.

local plant = require('support.plant_nodes')
local bus_lib = require('support.node_message_bus')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

-- ── Die Anlage: ein Reaktor, drei Turbinen, ein MASTER ───────────────────

local rt = plant.new_rt({ turbines = 3, node_id = 'node-101' })
local master = plant.new_master({ node_id = 'master-1' })

plant.boot_all({
  { name = 'RT', env = rt, main = 'nodes/rt/main.lua' },
  { name = 'MASTER', env = master, main = 'master/main.lua' },
})

assert_true(#rt:find_prints('REGLER AKTIV') > 0,
  'die RT-Node muss ihren Regler melden -- prints: '
    .. table.concat(rt.prints, ' | '):sub(1, 300))

local net = bus_lib.new()
net:attach('RT', rt)
net:attach('MASTER', master)
net:run(220)

-- ── 1. Die beiden finden sich ueberhaupt ─────────────────────────────────
--
-- Ohne diese Vorbedingung ist jede weitere Zusicherung wertlos: dann ist der
-- Test gruen, weil nichts passiert ist.
do
  assert_true(#net:messages_from('RT', 'HELLO') >= 1,
    'RT muss sich anmelden -- Verkehr: ' .. net:traffic_summary())
  assert_true(#net:messages_from('RT', 'STATUS') >= 1,
    'RT muss Status senden -- Verkehr: ' .. net:traffic_summary())
  assert_true(#net:messages_from('MASTER', 'COMMAND') >= 1,
    'MASTER muss die Node ansteuern -- Verkehr: ' .. net:traffic_summary())
  assert_eq(#net.dropped, 0, 'keine Nachricht darf ohne Empfaenger bleiben')
end

-- ── 2. RT kommt in den Zustand MASTER ────────────────────────────────────
do
  local status = net:last_message_from('RT', 'STATUS')
  assert_true(status ~= nil and type(status.payload) == 'table',
    'es muss ein Status-Payload vorliegen')
  assert_eq(status.payload.mode, 'MASTER',
    'mit verbundenem MASTER muss die Node im Zustand MASTER sein')
  assert_eq(status.payload.state, 'RUNNING',
    'und als RUNNING gemeldet werden (rt2_projection)')
end

-- ── 3. Das Einlernen ENDET und die Leistung erreicht MASTER ──────────────
--
-- Der Kern. Ohne capacity_ready = true behandelt
-- master/runtime_ops_profile.lua die Node als "keine Kapazitaet" und schickt
-- dauerhaft 0 %.
do
  local status = net:last_message_from('RT', 'STATUS')
  local p = status.payload
  assert_eq(p.capacity_ready, true,
    'das Einlernen muss zu einem Ergebnis kommen -- sonst bleibt MASTERs Vorgabe wirkungslos')
  assert_true((tonumber(p.capacity_max) or 0) > 0, string.format(
    'die gemeldete Leistung muss groesser 0 sein, sie ist %s', tostring(p.capacity_max)))

  -- Drei Turbinen a 24000 FE/t, abzueglich 5 % Reserve: 68400.
  assert_eq(p.capacity_max, 68400,
    'die gemessene Leistung muss der Flotte entsprechen (3 x 24000 minus 5 % Reserve)')
  assert_eq(p.capacity_total_turbines, 3, 'alle drei Turbinen muessen gezaehlt werden')
  -- Wie viele Turbinen liefen, ALS der Hoechstwert floss. Nicht
  -- capacity_stable_turbines pruefen: das ist der Zaehler des AKTUELLEN Takts
  -- und schwankt im Normalbetrieb staendig (eine Turbine faellt kurz aus dem
  -- Band, eine andere kommt hinein) -- eine Zusicherung darauf waere nur
  -- scheinbar streng und in Wahrheit zufallsabhaengig.
  assert_eq(p.capacity_sustainable_turbines, 3,
    'der Hoechstwert muss mit der ganzen Flotte gemessen worden sein')
end

-- ── 4. MASTER schickt am Ende eine WIRKSAME Vorgabe ──────────────────────
--
-- Genau der Riss: beim Start schickt MASTER 0 %, weil noch keine Kapazitaet
-- gemeldet ist. Das ist richtig. Falsch war, dass es dabei BLIEB.
do
  local commands = net:messages_from('MASTER', 'COMMAND')
  local setpoints = {}
  for _, record in ipairs(commands) do
    local command = record.message.payload and record.message.payload.command
    if command and command.target == 'SET_SETPOINTS' then
      setpoints[#setpoints + 1] = tonumber(command.value and command.value.power_target_percent)
    end
  end
  assert_true(#setpoints >= 1, 'MASTER muss eine Leistungsvorgabe schicken')

  local last = setpoints[#setpoints]
  assert_true((last or 0) > 0, string.format(
    'die LETZTE Vorgabe muss groesser 0 %% sein, sie war %s -- Folge: %s',
    tostring(last), table.concat((function()
      local out = {}
      for _, v in ipairs(setpoints) do out[#out + 1] = tostring(v) end
      return out
    end)(), ',')))
end

-- ── 5. RT nimmt die Vorgaben an -- keine INVALID_STATE-Dauerschleife ─────
--
-- Der zweite Riss: die erste Vorgabe nach einem Reconnect traf noch auf den
-- Zustand des vorigen Takts und wurde abgelehnt. MASTER liest ein
-- INVALID_STATE als Modus-Desync und schickt SET_MODE nach -- eine Runde
-- verloren, eine WARN-Zeile fuer einen normalen Vorgang.
do
  local acks = net:messages_from('RT', 'ACK_APPLIED')
  assert_true(#acks >= 1, 'RT muss die Kommandos quittieren')

  local rejected, accepted = {}, 0
  for _, record in ipairs(acks) do
    local result = record.message.payload and record.message.payload.result
    if result then
      if result.ok == true then accepted = accepted + 1
      else rejected[#rejected + 1] = tostring(result.reason_code or result.error or '?') end
    end
  end
  assert_true(accepted >= 1, 'mindestens eine Quittung muss ok melden')
  assert_eq(#rejected, 0,
    'kein Kommando darf abgelehnt werden -- abgelehnt: ' .. table.concat(rejected, ', '))
end

-- ── 6. Der Reaktor-Schnappschuss traegt, was FUEL braucht ────────────────
--
-- FUEL hat keinen eigenen Zugriff auf die Reaktoren; der Fuellstand kommt
-- ueber RT -> MASTER -> FUEL (master/fuel_relay.lua). Bricht hier ein
-- Feldname, verhungert die Anlage, ohne dass jemand einen Fehler sieht.
do
  local status = net:last_message_from('RT', 'STATUS')
  local reactors = status.payload.reactors or {}
  assert_eq(#reactors, 1, 'der eine Reaktor muss im Payload stehen')

  local reactor = reactors[1]
  assert_true(reactor.id ~= nil, 'mit einer Kennung')
  assert_eq(reactor.fuel_amount, 3000, 'mit dem Brennstoff-Fuellstand')
  assert_eq(reactor.fuel_capacity, 4000, 'und seiner Kapazitaet')
  assert_true(reactor.rods_level ~= nil, 'und der Stabstellung')
end

-- ── 7. Die Turbinen stehen einzeln im Payload ────────────────────────────
do
  local status = net:last_message_from('RT', 'STATUS')
  local turbines = status.payload.turbines or {}
  assert_eq(#turbines, 3, 'alle drei Turbinen muessen gemeldet werden')
  for index, turbine in ipairs(turbines) do
    assert_true(turbine.id ~= nil, 'Turbine ' .. index .. ' braucht eine Kennung')
    assert_true(tonumber(turbine.rpm) ~= nil, 'Turbine ' .. index .. ' braucht eine Drehzahl')
  end
end

-- ── 8. Der Regler hat die Hardware wirklich angefasst ────────────────────
--
-- Sonst waere alles oben nur Buchhaltung. Die Turbinen muessen gekuppelt und
-- auf Durchfluss stehen.
do
  for index = 1, 3 do
    local turbine = rt.plant.turbines[index]
    assert_true(turbine.coil == true,
      'Turbine ' .. index .. ' muss gekuppelt sein')
    assert_true(turbine.flow > 0,
      'Turbine ' .. index .. ' muss Durchfluss haben, sie hat ' .. tostring(turbine.flow))
  end
end

print('ok plant_rt_master_chain_test')
