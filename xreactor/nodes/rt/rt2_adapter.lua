-- RT rewrite, step 8: the thin, only-non-pure layer -- maps real
-- peripheral readings to the plain tables rt2_orchestrator expects, and
-- applies its decisions back to hardware.
--
-- Deliberately reuses adapters/turbine.lua and adapters/reactor.lua for
-- the actual peripheral.call()s (inspect/set_flow/set_coils/
-- apply_rod_level) -- those were never part of the bugs this rewrite
-- exists to fix, including apply_rod_level()'s existing safe-readback
-- confirmation for a 100%-insertion write. Re-implementing that here
-- would be exactly the kind of unnecessary risk the "keep core/adapters
-- as-is, rewrite only nodes/rt orchestration" scoping decision was meant
-- to avoid.
--
-- Every function here takes its adapter module as a parameter rather
-- than require()ing adapters/*.lua directly, so tests can pass a fake
-- adapter (plain Lua functions, no CC:Tweaked globals) and this file
-- stays testable exactly like the rest of the rewrite.

local M = {}

local function num_or_nil(v)
  if type(v) == "number" then return v end
  return nil
end

-- turbine_info: the table returned by adapters/turbine.lua's inspect().
-- Returns the plain reading table rt2_orchestrator.tick()'s `turbines`
-- entries need, or nil if the peripheral could not be inspected at all.
function M.read_turbine(name, turbine_info)
  if type(turbine_info) ~= "table" then return nil end
  return {
    name = name,
    rpm = num_or_nil(turbine_info.rpm),
    -- NICHT auf 0 vorbelegen, aus demselben Grund wie beim Durchfluss:
    -- das Einlernen zaehlt eine Turbine nur, wenn sie Leistung MELDET
    -- (rt2_orchestrator.lua's measure()). Eine erfundene 0 heisst dort
    -- "liefert nichts" -- und damit wartet das Einlernen endlos, obwohl
    -- der Wert nur nicht lesbar war.
    energy = num_or_nil(turbine_info.energy),
    coil_engaged = turbine_info.coil_engaged == true,
    -- Ob der Spulenzustand ueberhaupt LESBAR war. coil_engaged allein kann
    -- das nicht sagen: adapters/turbine.lua macht aus einem fehlenden
    -- getInductorEngaged ein false, und "nicht gekuppelt" sieht damit
    -- genauso aus wie "nicht messbar". Fuer den Dirty-Check in
    -- apply_turbine() ist der Unterschied entscheidend -- ein unbekannter
    -- Zustand ist nie ein Grund, das Schreiben zu unterlassen (dieselbe
    -- Regel wie beim Durchfluss, siehe dort).
    coil_known = (type(turbine_info.features) == "table"
      and turbine_info.features.coils == true) or false,
    -- NICHT auf 0 vorbelegen. adapters/turbine.lua's read_number() liefert
    -- bei einem fehlgeschlagenen Peripherieaufruf den String "n/a" -- daraus
    -- eine 0 zu machen heisst, "unbekannt" als "steht auf 0" auszugeben.
    -- Genau darauf ist der Livetest auf node-101 aufgelaufen: der Regler
    -- entschied korrekt auf Durchfluss 0, verglich das gegen diese erfundene
    -- 0, hielt die Vorgabe fuer bereits gesetzt und schrieb nie -- waehrend
    -- im Mod weiter 2000 anstanden und die Rotoren lastfrei hochliefen.
    -- nil heisst jetzt nil, und der Aufrufer muss damit umgehen.
    current_flow = num_or_nil(turbine_info.flow),
    -- Die Bauartgrenze dieser Turbine (Basic 1000 / Reinforced 2000), vom
    -- Geraet erfragt. nil heisst "nicht lesbar"; der Regler nimmt dann
    -- seinen eigenen Default. Siehe adapters/turbine.lua's
    -- MAX_FLOW_METHODS fuer die Fehlerkette, die ein fest verdrahteter
    -- Wert an einer Basic-Turbine ausloest.
    max_flow = num_or_nil(turbine_info.flow_limit),
    active = turbine_info.active == true,
  }
end

-- reactor_info: the table returned by adapters/reactor.lua's inspect().
-- temperature/coolant_* are the inputs rt2_safety.evaluate() needs -- they
-- are read from the SAME inspect() call the control decision already uses,
-- so wiring safety in costs no extra peripheral round-trip per tick.
function M.read_reactor(reactor_info)
  if type(reactor_info) ~= "table" then return nil end
  return {
    fill_ratio = num_or_nil(reactor_info.steam_fill_ratio),
    current_rods = num_or_nil(reactor_info.control_rod_level),
    active = reactor_info.active == true,
    temperature = num_or_nil(reactor_info.temperature),
    coolant_ratio = num_or_nil(reactor_info.coolant_ratio),
    coolant_amount = num_or_nil(reactor_info.coolant_amount),
    coolant_amount_max = num_or_nil(reactor_info.coolant_amount_max),
  }
end

-- Writes one turbine's flow+coil+activation decision to hardware via the
-- given turbine_adapter module (adapters/turbine.lua in production, a fake
-- in tests). Returns a small result table for logging -- never raises.
-- turbine_result.activate is already dirty-checked by
-- rt2_turbine.compute_active_decision() against this tick's own reading
-- (false once the turbine reads active), so this never issues a redundant
-- setActive(true) once the turbine is confirmed on.
function M.apply_turbine(turbine_adapter, name, log_prefix, turbine_result)
  local result = {}
  -- unchanged: die Vorgabe steht bereits genau so an der Turbine (vom
  -- Orchestrator gegen den zurueckgelesenen Wert geprueft). Seit der
  -- Regler eine Ruhezone hat, ist das der Normalfall, und ein Schreiben
  -- je Turbine und Takt waere reine Last ohne Wirkung.
  if turbine_result.flow_decision and turbine_result.flow_decision.unchanged ~= true then
    result.flow_ok, result.flow_err = turbine_adapter.set_flow(name, turbine_result.flow_decision.flow, log_prefix)
  end
  -- Die Spule bekommt denselben Dirty-Check wie der Durchfluss.
  --
  -- Bisher wurde sie BEDINGUNGSLOS in jedem Takt geschrieben. Im
  -- eingeschwungenen Beharrungszustand -- Flotte auf Drehzahl, nichts zu
  -- tun -- waren das am Anlagenmodell gemessen 6,00 Schreibzugriffe je
  -- Takt bei 6 Turbinen, also einer je Turbine und Takt, bei 10 Hz also
  -- 60 je Sekunde, und KEINER davon hat etwas veraendert. Der Durchfluss
  -- kam im selben Fenster auf 0. Bei 50 Turbinen sind das 500
  -- wirkungslose Peripherieaufrufe je Sekunde, und die Taktzeit der
  -- Regelschleife ergibt sich genau aus dieser Summe.
  --
  -- Verglichen wird gegen den MESSWERT, nicht gegen die letzte eigene
  -- Entscheidung: schaltet jemand den Induktor von aussen um (Hand,
  -- Chunk-Reload), weicht der Messwert im naechsten Takt ab und es wird
  -- geschrieben. Ist der Zustand nicht lesbar, wird immer geschrieben --
  -- unbekannt ist kein Grund, es zu lassen.
  if turbine_result.coil_decision then
    local wanted = turbine_result.coil_decision.engaged == true
    local coil_unchanged = turbine_result.coil_known == true
      and turbine_result.coil_engaged == wanted
    if coil_unchanged then
      result.coil_unchanged = true
    else
      result.coil_ok, result.coil_err = turbine_adapter.set_coils(name, wanted, log_prefix)
    end
  end
  if turbine_result.activate and type(turbine_adapter.set_active) == "function" then
    result.active_ok, result.active_err = turbine_adapter.set_active(name, true, log_prefix)
  end
  return result
end

-- Writes the reactor's rod decision (and, if set, an activation request)
-- to hardware via the given reactor_adapter module. Reuses
-- apply_rod_level()'s own safe-readback confirmation -- see module header.
-- reactor_decision.activate is already dirty-checked by
-- rt2_reactor.compute_active_decision() against this tick's own reading
-- (false once the reactor reads active), so this never issues a redundant
-- setActive(true) once the reactor is confirmed on.
-- Die Staebe werden IN JEDEM TAKT geschrieben -- absichtlich, kein
-- Versehen.
--
-- In v808 stand hier ein Dirty-Check wie beim Durchfluss und bei der Spule:
-- steht die gewuenschte Stellung schon an, nicht schreiben. Der war falsch,
-- und zwar aus einem Grund, der im Code nirgends aufgeschrieben war:
--
--   adapters/reactor.lua's control_rod_level ist der MITTELWERT ueber alle
--   Staebe (read_control_rods -> detail.average), nicht die Stellung eines
--   einzelnen.
--
-- Sind die Staebe eines Reaktors NICHT gleich eingestellt -- ein von Hand
-- verstellter Stab, ein zur Haelfte fehlgeschlagener Schreibvorgang, ein
-- frisch zusammengesetztes Multiblock -- kann der Mittelwert genau auf dem
-- Sollwert liegen, waehrend kein einzelner Stab dort steht. Der Dirty-Check
-- hat dann dauerhaft "steht schon richtig" gesagt und nie wieder
-- geschrieben. Der Reaktor blieb mit ungleichen Staeben stehen, und von
-- aussen sah das aus wie ein Regler, der nicht mehr regelt.
--
-- Das bedingungslose Schreiben war genau die Selbstheilung dafuer: es zieht
-- alle Staebe in jedem Takt auf denselben Wert. Diese Eigenschaft hatte
-- niemand aufgeschrieben, also habe ich sie beim Sparen mitentfernt.
--
-- Was es kostet: EIN Schreibzugriff je Reaktor und Takt. Der grosse Posten
-- war die Spule (einer je TURBINE und Takt, bei 20 Turbinen also 20 von 21),
-- und dort greift der Dirty-Check weiter -- die Spule ist ein einzelner
-- Wahrheitswert, der keine Gleichheit ueber mehrere Aktoren behaupten muss.
--
-- Wer das hier wieder sparen will, braucht zuerst die Information, ob die
-- Staebe UNTEREINANDER gleich stehen (read_control_rods_detail liefert
-- min/max/complete) -- der Mittelwert allein genuegt nicht.
function M.apply_reactor(reactor_adapter, name, log_prefix, reactor_decision)
  local ok, err = reactor_adapter.apply_rod_level(name, reactor_decision.rods, log_prefix)
  local result = { ok = ok, err = err }
  if reactor_decision.activate and type(reactor_adapter.set_active) == "function" then
    result.active_ok, result.active_err = reactor_adapter.set_active(name, true, log_prefix)
  end
  return result
end

return M
