-- RT rewrite, step 2: turbine target/flow/coil decisions.
--
-- Every decision here is a PURE function: same inputs -> same outputs,
-- no peripheral access, no ctx, no global state. The old implementation
-- spread this same job across three call sites (module_lifecycle.lua's
-- startup ramp, turbine_control.lua's main tick, and a target_rpm<=0
-- special case bolted on afterwards) that drifted out of sync -- that is
-- exactly the bug class this rewrite exists to remove. There is now one
-- function that decides the flow, and one that decides the coil, full
-- stop; the caller (whatever orchestrates I/O) never re-implements either.

local M = {}

M.FULL_TARGET_RPM = 900
M.RPM_BAND = 40          -- +/- RPM around target considered "on target"
-- Absolute hard-cut speed: above this the flow drops to zero immediately
-- instead of being ramped down. Deliberately an ABSOLUTE rpm and not a
-- margin on top of the target, because overspeed protection guards the
-- MACHINE, not whatever setpoint it currently happens to hold -- a
-- PUFFER-slot turbine running a 450 target has exactly the same physical
-- limit as one at full load. Regulating back down to the target is the
-- RAMP_DOWN branch's job, not this one's.
--
-- 1300 for this plant (operator-specified, standard target 900): normal
-- overshoot -- the flow is a little sluggish, so turbines routinely settle
-- slightly above 900 -- is ramped down, while a real runaway such as the
-- 2866 RPM turbine from the original report is cut instantly. Must stay
-- comfortably above FULL_TARGET_RPM + RPM_BAND, otherwise the hard cut
-- swallows the RAMP_DOWN branch again (see compute_flow_decision's header).
M.OVERSPEED_RPM = 1300
M.COIL_ENGAGE_RPM = 900
M.COIL_DISENGAGE_RPM = 850
-- A parked turbine keeps braking through its coil until it has practically
-- stopped; below this it releases, because there is nothing left to harvest
-- and an engaged coil on a standing rotor serves no purpose.
M.COIL_BRAKE_RELEASE_RPM = 50
M.MIN_FLOW = 0
-- Gegen den Mod-Quellcode verifiziert (Extreme Reactors 2.4.27, MC 1.21.1 /
-- ATM10): TurbineVariant setzt setMaxPermittedFlow(1000) fuer Basic und
-- (2000) fuer Reinforced, und TurbineData.setMaxIntakeRate() klemmt jeden
-- Schreibwert auf min(maxPermittedFlow, max(0, rate)). Der vorherige Wert
-- 32000 stammte aus der Big-Reactors-Aera und war damit 16-32x zu hoch --
-- ohne Absturz, weil der Mod klemmt und wir den geklemmten Wert
-- zurueckgelesen haben, aber die Rampenrechnung lief gegen eine Grenze,
-- die es nie gab. 2000 entspricht der hier verbauten Reinforced-Turbine
-- und deckt sich mit config.lua's autonom.max_flow, das v1 schon nutzt.
M.MAX_FLOW = 2000
M.TRIM_STEP = 35

-- Groesster Bremsschritt. Beschleunigen und Bremsen sind NICHT symmetrisch:
--
-- Der Schritt wird als TRIM_STEP * Abweichung / RPM_BAND gerechnet und war
-- danach in BEIDE Richtungen auf TRIM_STEP gedeckelt. Damit war er fuer
-- jede Abweichung ab Bandbreite derselbe -- 35, egal ob die Turbine 40 oder
-- 350 Umdrehungen zu schnell dreht. Aus dem Regelgesetz wurde so ausserhalb
-- des Bands ein fester Schritt, und die Verstaerkung, die der Kommentar
-- unten beschreibt, gab es nur INNERHALB des Bands.
--
-- Nachgemessen am 2026-09-29, Ziel 900, Durchfluss 2000: bei 1000 und bei
-- 1250 U/min kam derselbe Schritt heraus (35), und den Durchfluss von 2000
-- auf 0 zurueckzunehmen brauchte 58 Takte -- rund 35 Sekunden. In dieser
-- Zeit bekommt der Rotor fast vollen Dampf und dreht weiter hoch. Genau das
-- war die Betriebsmeldung "geht in Overspeed" und "der Regler hat reagiert,
-- aber sehr spaet": gerettet hat am Ende nur die harte Abschaltung bei
-- OVERSPEED_RPM.
--
-- Warum nur nach unten: zu viel Dampf endet in Ueberdrehzahl, zu wenig
-- Dampf kostet kurz Leistung. Die eine Richtung schuetzt die Maschine, die
-- andere nicht -- und ein ebenso schneller Schritt nach OBEN wuerde das
-- Ueberschwingen vergroessern, das ueberhaupt erst in diese Lage fuehrt.
-- Nach oben bleibt deshalb alles wie es war.
M.MAX_TRIM_STEP_DOWN = 400

-- So lange bleibt eine Durchflussvorgabe stehen, bevor die naechste kommt.
--
-- Der Regler lief bisher in jedem Takt -- mehrmals pro Sekunde -- gegen
-- einen Rotor, der Sekunden braucht, um auf eine Verstellung zu antworten.
-- Er hat also immer wieder auf eine Drehzahl reagiert, die seine vorherige
-- Verstellung noch gar nicht enthielt, und entsprechend ueberzogen: hoch,
-- drueber, runter, drunter. Ein Regler, der schneller stellt als die
-- Strecke antwortet, kann nicht stabil werden -- unabhaengig von der
-- Schrittweite.
--
-- Schutzentscheidungen (fehlende Drehzahl, Ueberdrehzahl, AUS-Platz)
-- warten NICHT darauf -- sie greifen im selben Takt.
M.MIN_ADJUST_INTERVAL_MS = 600

-- Innerhalb dieser Abweichung wird gar nicht mehr gestellt. Ein Regler
-- ohne Ruhezone stellt auch dann noch, wenn er am Ziel ist, und pendelt
-- dadurch um genau diesen Rest.
M.SETTLE_BAND_RPM = 4

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ── Target RPM ───────────────────────────────────────────────────────────
--
-- Vorgabe (bestaetigt):
--   - AUTONOM (kein MASTER): jede Turbine faehrt die feste
--     FULL_TARGET_RPM. Geregelt wird in diesem Zustand der REAKTOR aus
--     seinem Dampftank, nicht die Turbine (siehe rt2_reactor.lua).
--   - MASTER: die Leistungsvorgabe in Prozent bestimmt, WIEVIELE Turbinen
--     laufen. Die laufen dann auf der festen FULL_TARGET_RPM, der Rest
--     steht. Welche Plaetze stehen, wandert mit der Zeit, damit keine
--     Turbine dauerhaft kalt bleibt (das Drehen ist Sache des Aufrufers --
--     diese Funktion bekommt den bereits gedrehten slot_index).
--   - SAFE: 0 fuer alle.
-- Wieviele Turbinen laufen bei dieser Leistungsvorgabe?
--
-- Ohne Kapazitaetsmessung ist die Rechnung so einfach wie moeglich: die
-- Vorgabe ist ein Anteil der FLOTTE, nicht eines gelernten Wertes. 60 % von
-- 50 Turbinen heisst 30 Turbinen auf Zieldrehzahl, 20 aus. Kein Teillast-
-- Platz mit krummer Zieldrehzahl mehr: eine Turbine laeuft oder sie steht.
--
-- Das ist bewusst grob. Eine Turbine ausserhalb ihres Auslegungspunkts
-- liefert unverhaeltnismaessig wenig, deshalb ist "weniger Turbinen, alle
-- auf 900" die bessere Aufteilung als "alle Turbinen, alle zu langsam".
local function running_count(percent, turbine_count)
  if turbine_count <= 0 then return 0 end
  local pct = clamp(tonumber(percent) or 100, 0, 100)
  if pct <= 0 then return 0 end
  local count = math.floor(pct / 100 * turbine_count + 0.5)
  if count < 1 then count = 1 end          -- ueber 0 % laeuft mindestens eine
  if count > turbine_count then count = turbine_count end
  return count
end

function M.compute_target_rpm(state, opts)
  opts = opts or {}
  if state == "SAFE" then return 0 end

  local n = tonumber(opts.turbine_count) or 0
  local slot_index = tonumber(opts.slot_index) or 1

  -- Ohne Master-Vorgabe faehrt die ganze Flotte auf Zieldrehzahl.
  if state ~= "MASTER" then
    return M.FULL_TARGET_RPM
  end

  if n <= 0 then return M.FULL_TARGET_RPM end
  if slot_index > running_count(opts.power_percent, n) then return 0 end
  return M.FULL_TARGET_RPM
end

-- ── Flow decision ────────────────────────────────────────────────────────
--
-- Ein einziges Regelgesetz: Drehzahl-Abweichung -> Durchfluss-Schritt.
--
-- Vorher lagen hier vier Verfahren nebeneinander -- Rampe, Feintrimmung,
-- Streckenmodell aus gelernten Kennlinien und eine Vorausschau auf die
-- Rotor-Beschleunigung. Sie haben sich gegenseitig abgeloest, und welches
-- gerade griff, war von aussen nicht zu sehen. Eine Feldaufzeichnung vom
-- 2026-09-27 zeigte 26 von 40 Turbinen oberhalb des Zielbands mit
-- Durchfluss 0 im Auslauf, waehrend keine einzige Kennlinie in Gebrauch war.
--
-- Was bleibt:
--   1. Keine Drehzahlmessung  -> Dampf aus. Unbekannt ist nicht "0 RPM".
--   2. Ziel 0 (Turbine steht) -> Dampf aus.
--   3. Echte Ueberdrehzahl    -> Dampf aus.
--   4. Nah genug am Ziel      -> nichts stellen (Ruhezone).
--   5. Stellintervall nicht um-> nichts stellen (die letzte Verstellung
--                                muss erst wirken koennen).
--   6. sonst: Schritt proportional zur Abweichung, gedeckelt auf TRIM_STEP.
--
-- Die Verstaerkung ist so gewaehlt, dass genau am Rand des Zielbands ein
-- voller TRIM_STEP herauskommt und der Schritt mit der Abweichung gegen
-- null geht. Damit gibt es keine Kante zwischen "weit weg" und "fast da" --
-- und genau diese Kante war das alte Sprungverhalten.
function M.compute_flow_decision(input)
  -- Keine Drehzahlmessung -> kein Dampf. Ein fehlender Wert wie "0 RPM" zu
  -- behandeln ist die falsche Richtung: der Regler haelt die Turbine dann
  -- fuer stehend, faehrt den Durchfluss hoch und laesst die Spule getrennt
  -- -- volle Foerderung ohne Last, also genau der Zustand, gegen den die
  -- Ueberdrehzahl-Abschaltung schuetzen soll.
  if tonumber(input.rpm) == nil then
    return { flow = 0, reason = "NO_RPM_READING" }
  end
  local rpm = tonumber(input.rpm) or 0
  local target_rpm = tonumber(input.target_rpm) or 0

  -- Der Rueckmesswert darf NICHT auf 0 vorbelegt werden.
  --
  -- adapters/turbine.lua liefert ausdruecklich nil, wenn der Durchfluss
  -- nicht lesbar ist -- daraus hier wieder eine 0 zu machen hiesse, jeden
  -- Halte-Zweig 0 entscheiden zu lassen. Die Oberflaeche zeigt die
  -- ENTSCHEIDUNG, nicht den Messwert; so stand dort "FLOW 0.0", waehrend
  -- Drehzahl, Reaktor und MASTER in Ordnung waren. Was der Regler
  -- stattdessen nimmt: seinen EIGENEN zuletzt gestellten Wert.
  local readback = tonumber(input.current_flow)
  local last_commanded = tonumber(input.last_commanded_flow)
  local current_flow = readback or last_commanded or 0
  local flow_known = readback ~= nil or last_commanded ~= nil

  -- Jeder Zweig, der "so lassen wie es ist" bedeutet, geht hier durch. Ist
  -- der Durchfluss UNBEKANNT, gibt es nichts zu halten -- die richtige
  -- Antwort ist dann nicht "0 stellen", sondern GAR NICHT stellen.
  -- Schutzentscheidungen liegen oberhalb und sind davon nicht beruehrt:
  -- eine Bremsung darf nie unterbleiben.
  local function hold(reason)
    return { flow = current_flow, reason = reason, unchanged = (not flow_known) or nil }
  end

  local min_flow = tonumber(input.min_flow) or M.MIN_FLOW
  local max_flow = tonumber(input.max_flow) or M.MAX_FLOW
  local band = tonumber(input.band) or M.RPM_BAND
  local overspeed_rpm = tonumber(input.overspeed_rpm) or M.OVERSPEED_RPM

  if target_rpm <= 0 then
    return { flow = 0, reason = "TARGET_ZERO" }
  end
  if rpm > overspeed_rpm then
    return { flow = 0, reason = "OVERSPEED" }
  end

  -- ── Ab hier wird geregelt, nicht mehr geschuetzt ──────────────────────
  local error_rpm = target_rpm - rpm

  -- Ruhezone: nah genug am Ziel wird gar nicht gestellt. Ohne sie stellt
  -- der Regler auch dann noch, wenn er angekommen ist -- die kleinste
  -- Schrittweite ist auf einer grossen Turbine schon mehr als die
  -- verbleibende Abweichung, und das Ergebnis ist ein endloses +1/-1.
  local settle_band = tonumber(input.settle_band_rpm) or M.SETTLE_BAND_RPM
  if math.abs(error_rpm) <= settle_band then
    return hold("SETTLED")
  end

  -- Stellintervall: erst nachsehen, ob die letzte Verstellung ueberhaupt
  -- schon wirken konnte. Der Rotor haengt der Vorgabe um Sekunden
  -- hinterher; ohne diese Sperre stapelt der Regler Schritte auf eine
  -- Wirkung, die noch gar nicht eingetreten ist. Ohne Uhrangabe
  -- (Modultests, Altaufrufer) entfaellt die Sperre.
  --
  -- Die Sperre gilt nur VORWAERTS. Liegt die gemerkte Zeit in der ZUKUNFT,
  -- ist die Uhr zurueckgesprungen -- und dann darf sie nicht greifen, sonst
  -- sperrt sie die Turbine fuer immer aus:
  --
  --   SETTLING gibt den unveraenderten Durchfluss zurueck. Der ist damit
  --   gleich dem Rueckmesswert, also setzt rt2_orchestrator unchanged=true
  --   und schreibt nicht -- und weil es nicht schreibt, schreibt es auch
  --   last_change_ms NICHT fort. Die gemerkte Zeit bleibt in der Zukunft,
  --   der naechste Takt entscheidet wieder SETTLING, und so weiter. Der
  --   Regler kommt aus eigener Kraft nie mehr heraus, waehrend die
  --   Drehzahl weiter sauber gelesen wird und die Anzeige gesund aussieht.
  --   Nur ein Neustart der Node hat das geloest.
  --
  -- Mit dieser Bedingung faellt ein Ruecksprung sofort durch auf den
  -- Regelschritt unten; der stellt einen anderen Wert als den
  -- Rueckmesswert, der Orchestrator schreibt wieder, und dabei wird
  -- last_change_ms auf die neue Zeit gesetzt. Der Fehler heilt sich in
  -- einem einzigen Takt.
  --
  -- Ausserhalb des Bands nach OBEN gilt sie nicht. Oberhalb von
  -- target+band bremst schon die Spule (compute_coil_decision's
  -- BRAKE_TO_TARGET) -- dieselbe Schwelle, dieselbe Begruendung: dort wird
  -- nicht mehr fein geregelt, sondern Dampf weggenommen, und das ist eine
  -- Schutzentscheidung. Die Stellsperre wuerde jeden zweiten Takt
  -- verschenken, waehrend der Rotor weiter hochlaeuft.
  local now_ms = tonumber(input.now_ms)
  local last_change_ms = tonumber(input.last_change_ms)
  local interval_ms = tonumber(input.min_adjust_interval_ms) or M.MIN_ADJUST_INTERVAL_MS
  local braking = rpm > target_rpm + band
  if now_ms and last_change_ms and not braking then
    local since = now_ms - last_change_ms
    if since >= 0 and since < interval_ms then
      return hold("SETTLING")
    end
  end

  -- Proportionalschritt. Am Bandrand genau TRIM_STEP, naeher am Ziel
  -- entsprechend weniger, mindestens aber 1 -- sonst bliebe eine kleine
  -- Abweichung ewig stehen. Weiter weg waechst er mit der Abweichung; nur
  -- die Deckelung unterscheidet die Richtungen (siehe MAX_TRIM_STEP_DOWN).
  local step = M.TRIM_STEP * math.abs(error_rpm) / band

  if error_rpm > 0 then
    -- Zu langsam: gemaechlich nachlegen. Ein grosser Schritt hier erzeugt
    -- genau das Ueberschwingen, das die Turbine ueber das Band traegt.
    local up = math.max(1, math.min(M.TRIM_STEP, math.floor(step + 0.5)))
    return { flow = clamp(current_flow + up, min_flow, max_flow), reason = "TRIM_UP" }
  end

  -- Zu schnell: mit der Abweichung wachsend zuruecknehmen. Je weiter die
  -- Turbine ueber dem Ziel steht, desto entschiedener wird der Dampf
  -- weggenommen -- und weil die Drehzahl bei zu viel Dampf weiter steigt,
  -- verstaerkt sich die Bremsung von selbst, statt bei 35 stehenzubleiben.
  local down = math.max(1, math.min(M.MAX_TRIM_STEP_DOWN, math.floor(step + 0.5)))
  return { flow = clamp(current_flow - down, min_flow, max_flow), reason = "TRIM_DOWN" }
end

-- ── Coil decision ────────────────────────────────────────────────────────
--
-- The coil IS the brake: engaging the inductor extracts energy from the
-- rotor and slows it down. So the rule is not "couple once we are at
-- speed", it is "couple whenever we are at or above where we want to be".
-- That covers three cases with one idea:
--   - holding the target      -> hysteresis around the scaled target
--   - genuine overspeed       -> couple, the load brakes it
--   - target lowered (VOLLAST -> PUFFER, or parked) -> couple, same reason
--
-- The hysteresis is scaled to the CURRENT target, so a PUFFER-slot turbine
-- at a 450 RPM target engages/disengages around 450, not around 900.
--
-- FIXED 2026-09-23: target_rpm<=0 used to uncouple unconditionally, on the
-- reasoning that there is nothing to harvest from a turbine that is meant
-- to be off. That got it backwards for a rotor that is still spinning: an
-- AUS-slot turbine at 900 RPM was left to coast down with no load at all,
-- so it braked slowly AND threw away the rotational energy instead of
-- recovering it. A parked turbine now brakes through the coil for as long
-- as it still turns, and only releases once it has essentially stopped.
function M.compute_coil_decision(input)
  -- Ohne Drehzahl laesst sich nicht entscheiden, ob gekuppelt werden soll
  -- -- also nichts veraendern. Vorher wurde der fehlende Wert als 0 RPM
  -- gelesen und die Spule geloest, womit ausgerechnet ein womoeglich noch
  -- drehender Rotor seine Bremse verloren haette.
  if tonumber(input.rpm) == nil then
    return { engaged = input.currently_engaged == true, reason = "HOLD_NO_RPM" }
  end
  local rpm = tonumber(input.rpm) or 0
  local target_rpm = tonumber(input.target_rpm) or 0
  local currently_engaged = input.currently_engaged == true
  local band = tonumber(input.band) or M.RPM_BAND

  -- Parked (AUS slot or SAFE): no target to hold, but braking a spinning
  -- rotor is still the right thing to do -- and it harvests on the way down.
  if target_rpm <= 0 then
    if rpm > M.COIL_BRAKE_RELEASE_RPM then
      return { engaged = true, reason = "BRAKE_TO_STOP" }
    end
    return { engaged = false, reason = "STOPPED" }
  end

  -- Above the band: overspeed, or a target that was just lowered. Couple
  -- regardless of the hysteresis -- waiting for the threshold here would
  -- mean coasting exactly when braking is wanted.
  if rpm > target_rpm + band then
    return { engaged = true, reason = "BRAKE_TO_TARGET" }
  end

  local scale = target_rpm / M.FULL_TARGET_RPM
  local engage_rpm = M.COIL_ENGAGE_RPM * scale
  local disengage_rpm = M.COIL_DISENGAGE_RPM * scale

  -- Angekommen heisst gekuppelt -- auch wenn die Schwelle oben noch ein
  -- paar Drehzahlen weiter liegt.
  --
  -- Der Regler hat eine Ruhezone um das Ziel (SETTLE_BAND_RPM): bei 897
  -- gegen ein Ziel von 900 stellt er nichts mehr. Die Kupplungsschwelle lag
  -- aber genau AUF 900. Eine Turbine, die dort einschwang, kuppelte also
  -- nie ein -- und eine ungekuppelte Turbine liefert nichts. Der Rotor
  -- drehte, der Reaktor lieferte Dampf, die Anzeige sah gesund aus, und der
  -- Knoten meldete dauerhaft 0 RF/t. Im Zwillingstest blieb die ganze
  -- Flotte so bei 897 RPM stehen.
  --
  -- Die Ruhezone des Reglers und die Kupplungsschwelle muessen sich also
  -- ueberlappen: was der Regler als "am Ziel" ansieht, gilt hier auch so.
  local settle_band = tonumber(input.settle_band_rpm) or M.SETTLE_BAND_RPM
  if not currently_engaged and (rpm >= engage_rpm or rpm >= target_rpm - settle_band) then
    return { engaged = true, reason = "ENGAGE_THRESHOLD" }
  end
  if currently_engaged and rpm <= disengage_rpm then
    return { engaged = false, reason = "DISENGAGE_THRESHOLD" }
  end
  return { engaged = currently_engaged, reason = "HOLD" }
end

-- ── Active decision ──────────────────────────────────────────────────────
--
-- Confirmed spec (2026-09-19): same as the reactor -- if a turbine reads
-- OFF (e.g. never switched on after a fresh multiblock assembly, or
-- manually toggled), v2 must turn it back on itself. Only ever turns it
-- ON; an AUS/PUFFER-slot turbine already reaches zero output through
-- flow=0/coil disengaged above, so there is no case where v2 needs to
-- switch a turbine off itself.
--
-- current_active: the last read `active` state (true/false), or nil/
-- anything non-boolean if unknown -- treated the same as false so an
-- unreadable state fails toward "make sure it's on".
function M.compute_active_decision(current_active)
  return current_active ~= true
end

return M
