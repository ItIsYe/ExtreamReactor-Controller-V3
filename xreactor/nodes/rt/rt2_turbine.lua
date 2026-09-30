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
-- Nur noch die Notbremse gegen einen Hochlauf, den die Spule selbst
-- verhindert (siehe compute_coil_decision): Rotor unter diesem Anteil der
-- Zieldrehzahl UND Dampf schon am Anschlag. Bewusst weit weg von der
-- Regelgegend, damit daraus kein zweites Flattern werden kann.
M.COIL_STALL_RPM_FRACTION = 0.5
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

-- ── Feinzone ─────────────────────────────────────────────────────────────
--
-- Betreibervorgabe (2026-09-29): "wenn die Turbine nah dem Zielbereich ist,
-- dass der feiner regelt."
--
-- Innerhalb von FINE_BAND_RPM um das Ziel wird der Schritt zusaetzlich auf
-- FINE_TRIM_STEP gedeckelt. Weiter draussen bleibt alles wie gehabt --
-- dort SOLL entschieden gestellt werden.
--
-- Was nah am Ziel grob macht, ist nicht die Verstaerkung -- der Schritt
-- waechst ohnehin mit der Abweichung und ist dort schon klein. Es ist der
-- VORHALT: er rechnet die Aenderungsrate hoch, und die Rate wird aus zwei
-- Messwerten gebildet. Die Drehzahlmessung rauscht um ein paar
-- Umdrehungen, und aus +/-6 U/min Rauschen je halbem Takt werden 24 U/min/s
-- Scheinrate -- bei einer Sekunde Vorhalt also 24 U/min Scheinabweichung.
-- Weit weg geht das im echten Fehler unter; nah am Ziel IST es der ganze
-- Fehler, und der Regler stellt Rauschen nach.
--
-- Nachgemessen am 2026-09-29 (Rotor lag=0.04, Messrauschen +/-6 U/min,
-- Spanne des Durchflusses in der Ruhelage ueber 100 Takte):
--
--   ohne Feinzone                 Spanne 77, im Band nach 36,5 s
--   nur Schrittdeckel 6           Spanne 45, im Band nach 47,0 s
--   nur kurzer Vorhalt 0,25 s     Spanne 42, im Band nach 38,0 s
--   beides                        Spanne 41, im Band nach 45,5 s
--
-- Der Vorhalt bringt fast die ganze Ruhe und kostet anderthalb Sekunden;
-- der Schrittdeckel kostet zehn und bringt kaum mehr.
--
-- Zweiter Durchgang, Betreiberwunsch "bei fine noch feiner" -- dieselbe
-- Messung, jetzt auch die mittlere SCHRITTWEITE je Verstellung, weil genau
-- die "feiner" ausmacht (Rotor lag=0.04):
--
--   Vorhalt 0,25 s, Deckel 20     Spanne 49, Schritt 6,4, im Band nach 38,0 s
--   Vorhalt AUS,    Deckel 20     Spanne 41, Schritt 4,4, im Band nach 38,0 s
--   Vorhalt AUS,    Deckel 10     Spanne 41, Schritt 4,4, im Band nach 38,0 s
--   Vorhalt AUS,    Deckel 6      Spanne 37, Schritt 4,2, im Band nach 46,5 s
--   Vorhalt AUS,    Deckel 3      Spanne 24, Schritt 2,9, im Band nach 59,0 s
--
-- In der Feinzone ist die hochgerechnete Rate fast nur noch Rauschen --
-- auch die verbliebenen 0,25 s davon. Ganz abzuschalten macht den Schritt
-- um ein Drittel kleiner und kostet NICHTS. Darunter wird es teuer: Deckel
-- 6 kostet achteinhalb Sekunden, Deckel 3 kostet einundzwanzig.
--
-- Der Vorhalt ist deshalb in der Feinzone aus -- aber nicht bedingungslos.
-- Ihn dort einfach abzuschalten hat einen Fall mitgenommen, fuer den er
-- gerade gebraucht wird: eine Turbine, die mit +100 U/min/s mitten durch
-- das Ziel beschleunigt, wurde dann nur noch gehalten statt gebremst (sie
-- faellt erst 15 Umdrehungen spaeter aus der Feinzone und wird dort
-- gefangen -- zu spaet, und der Sinn der Ratenpruefung war, genau das zu
-- verhindern).
--
-- Also ein Tor statt eines Schalters: in der Feinzone zaehlt die Rate erst
-- ab FINE_RATE_GATE_RPM_PER_S. Darunter ist sie Rauschen und wird
-- vollstaendig ignoriert; darueber gilt der volle Vorhalt, und es wird
-- gebremst wie ausserhalb.
--
-- Der Wert liegt ueber dem, was Messrauschen erzeugen kann: +/-6 U/min
-- Lesefehler auf einen halben Takt sind bis zu 24 U/min/s. Eine echte
-- Durchfahrt liegt um ein Vielfaches darueber.
--
-- Die Feinzone wird am GEMESSENEN Abstand festgemacht, nicht am
-- vorhergesagten: "nah am Zielbereich" ist eine Aussage darueber, wo die
-- Turbine steht. Eine, die noch 200 entfernt ist und schnell darauf
-- zulaeuft, gehoert nicht hinein -- die soll weiter kraeftig
-- zurueckgenommen werden duerfen.
M.FINE_BAND_RPM = 15
M.FINE_RATE_GATE_RPM_PER_S = 40
M.FINE_TRIM_STEP = 10

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

-- ── Vorhalt ──────────────────────────────────────────────────────────────
--
-- Betreibervorgabe: "der Regler muss fast instant reagieren koennen, aber
-- trotzdem nicht ueberschwingen."
--
-- Mit einem Regler, der nur die IST-Drehzahl sieht, ist das nicht zu haben:
-- schnell heisst grosse Verstaerkung, und grosse Verstaerkung heisst
-- Ueberschwingen -- der Rotor braucht Sekunden, um auf eine Verstellung zu
-- antworten, und in dieser Zeit stellt ein schneller Regler weiter gegen
-- eine Wirkung, die noch aussteht.
--
-- Was beides zusammenbringt, ist die AENDERUNGSRATE. Geregelt wird nicht
-- auf die Drehzahl, die jetzt anliegt, sondern auf die, die in
-- LOOKAHEAD_S Sekunden anliegen wird, wenn es so weitergeht:
--
--   Vorhersage = Drehzahl + Rate * LOOKAHEAD_S
--
-- Eine Turbine bei 700 mit +120 U/min/s ist damit nicht "200 zu langsam",
-- sondern (bei 2 s Vorhalt) "40 zu schnell" -- der Regler nimmt zurueck,
-- WAEHREND sie noch steigt, und trifft die 900 ohne darueber zu schiessen.
-- Umgekehrt darf er weit weg viel entschiedener zupacken, weil ihn die
-- Rate rechtzeitig wieder einbremst.
--
-- Das ist ausdruecklich KEIN Lernen: nichts wird gespeichert, nichts ueber
-- Takte hinaus gemittelt, keine Kennlinie gebildet. Es sind zwei Messwerte
-- aus zwei aufeinanderfolgenden Takten -- mehr nicht. Der Vorhalt ersetzt
-- die alte Stellsperre, die dasselbe Problem mit Warten geloest hat.
-- 1.0 s, nicht laenger. Ein Vorhalt, der ueber der Zeitkonstante der
-- Strecke liegt, sagt mehr voraus, als die Strecke einloest, und faengt an
-- zu schwingen. Nachgemessen am 2026-09-29 gegen drei Rotortraegheiten
-- (Zeitkonstante 1.4 s / 5 s / 12.5 s), Anfahrt aus dem Stand auf 900:
--
--   Vorhalt   Spitze (1.4s / 5s / 12.5s)   im Band nach
--   aus       1049 / 999 / 969             10.0s / 27.0s / 58.5s
--   1.0s       899 / 962 / 954              7.0s / 14.5s / 37.0s
--   2.0s       898 / 919 / 938             12.0s / 13.0s / 28.0s
--
-- 2 s ist bei traegen Rotoren besser, beim schnellen aber wieder
-- schlechter als 1 s -- genau das erwartete Aufschwingen. 1 s verbessert
-- jeden der drei Faelle und verschlechtert keinen.
M.LOOKAHEAD_S = 1.0

-- Groesster Schritt nach OBEN, aber nur solange eine Rate vorliegt. Ohne
-- Vorhalt bleibt es bei TRIM_STEP: der grosse Schritt ist ueberhaupt nur
-- deshalb vertretbar, weil die Vorhersage rechtzeitig wieder einbremst.
-- Faellt die Rate weg (fehlender Messpunkt, Uhrsprung), faellt auch er weg
-- -- die Vorsicht muss mit der Grundlage verschwinden, nicht ohne sie
-- bestehen bleiben.
M.MAX_TRIM_STEP_UP = 400

-- Groesste Rate, die noch als "steht" durchgeht. Die Drehzahlmessung
-- rauscht um ein paar Umdrehungen; ohne diese Schwelle wuerde daraus bei
-- 2 s Vorhalt eine zweistellige Scheinabweichung, und eine eingeschwungene
-- Turbine faenge an zu zappeln.
M.SETTLE_RATE_RPM_PER_S = 12

-- Aelter als das darf der vorige Messpunkt nicht sein, sonst ist die daraus
-- gerechnete Rate nichts wert (verpasste Takte, Neustart, Uhrsprung).
M.MAX_RATE_AGE_MS = 3000

-- Und JUENGER als das darf er auch nicht sein.
--
-- Der Regeltakt liegt bei 100 ms (nodes/rt/main.lua's RECEIVE_TIMEOUT). In
-- dieser Zeit bewegt sich der Rotor kaum -- die Differenz zweier
-- aufeinanderfolgender Messungen ist zu einem grossen Teil Messrauschen,
-- und mit einer Sekunde Vorhalt hochgerechnet stellt der Regler dieses
-- Rauschen nach. Der Bezugspunkt ist deshalb der juengste Messwert, der
-- mindestens so alt ist (gehalten von rt2_orchestrator.lua's
-- rate_reference(); diese Funktion bleibt rein).
--
-- Nachgemessen am 2026-09-30 am echten Takt, Anfahrt auf 900, Rauschen
-- +/-4 U/min, Spanne des Durchflusses in der Ruhelage:
--
--   Rotor tau      2 s        5 s        12 s
--   je Takt        38         63         80
--   >= 150 ms      20         27         58
--
-- Das Zappeln geht also um 30-55 % zurueck. Die Spitze bleibt praktisch
-- gleich (909/922/927 gegen 912/925/928), das Einschwingen wird bei traegen
-- Rotoren etwas langsamer (9,7 -> 12,1 s bei tau=5 s). Es geht hier NICHT
-- um Ueberschwingen oder Geschwindigkeit, sondern allein um die Ruhe der
-- Stellgroesse.
--
-- WARUM NICHT LAENGER -- das ist der teuer bezahlte Teil:
--
-- 500 ms waren der erste Ansatz, und fuer eine EINZELNE Turbine ist das
-- ueber tau = 0,3 bis 12 s stabil. Im gekoppelten Betrieb aber nicht: in
-- tests/rt2_engine_integration_test.lua (25 Turbinen an EINEM Reaktor,
-- gemeinsames Dampfbudget) faengt die Flotte damit an zu schwingen -- die
-- Spule klappt im Sekundentakt ein und aus, die Drehzahl bricht zeitweise
-- bis auf 27 U/min ein, waehrend der Durchfluss auf Anschlag steht. Ein
-- isoliertes Streckenmodell zeigt das nicht, weil dort der gemeinsame
-- Dampf fehlt.
--
-- Ausgemessen liegt die Kippgrenze zwischen 200 ms (stabil) und 300 ms
-- (schwingt). 150 ms verhaelt sich beim 100-ms-Takt identisch zu 200 ms --
-- der gefundene Punkt ist so oder so 200 ms alt -- laesst aber Reserve,
-- wenn die Schleife schneller oder langsamer laeuft.
M.MIN_RATE_WINDOW_MS = 150

-- ── Schrittweite und Taktzeit ────────────────────────────────────────────
--
-- Der Schritt war bisher ein fester Betrag JE TAKT. Damit haengt die
-- wirksame Verstaerkung davon ab, wie oft die Schleife zufaellig laeuft:
-- bei 100 ms sind es zehn Verstellungen je Sekunde, bei 500 ms nur zwei --
-- derselbe Regler, fuenffach unterschiedliche Wirkung.
--
-- Und die Taktzeit ist nicht fest. Sie ergibt sich daraus, wie lange ein
-- Durchgang ueber ALLE Turbinen braucht (nodes/rt/main.lua's control_tick
-- liest je Turbine Drehzahl, Durchfluss, Spule, Aktivzustand und
-- Ausstoss). Mit 50 Turbinen dauert das laenger als mit 25 -- der Regler
-- wurde also ausgerechnet in der groesseren Anlage schwaecher.
--
-- Der Schritt wird deshalb auf die tatsaechlich verstrichene Zeit bezogen.
-- Bezugsgroesse ist der HEUTIGE Takt (100 ms), damit sich am eingefahrenen
-- Verhalten nichts aendert: bei 100 ms ist der Faktor genau 1. Laeuft die
-- Schleife langsamer, waechst der Schritt entsprechend, und die Bewegung
-- je Sekunde bleibt dieselbe.
M.NOMINAL_STEP_INTERVAL_MS = 100

-- Grenzen des Faktors. Ein Wert weit ausserhalb heisst nicht "sehr traege
-- Schleife", sondern "die Zeitangabe stimmt nicht" (Uhrsprung, erster Takt
-- nach dem Start, haengengebliebener Peripherie-Aufruf). Dann wird
-- lieber nicht verstaerkt.
M.MIN_STEP_SCALE = 0.25
M.MAX_STEP_SCALE = 4.0

-- Soweit darf die Vorhersage die Lage hoechstens verschieben. Sie bleibt
-- eine Schaetzung aus zwei Messpunkten; liegen die dicht beieinander,
-- wird aus einem kleinen Messsprung eine grosse Rate. Der Deckel nimmt
-- ihr nicht die Richtung, nur die Masslosigkeit -- und er sorgt dafuer,
-- dass die echte Abweichung nie voellig von der Schaetzung erschlagen wird.
M.MAX_PREDICT_RPM = 300

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

  -- Aenderungsrate aus zwei aufeinanderfolgenden Messpunkten. Fehlt der
  -- vorige, ist er zu alt oder liegt er in der Zukunft (Uhrsprung), gilt
  -- die Rate als unbekannt -- dann regelt es wie zuvor rein auf den
  -- Istwert. Unbekannt wird NIE als 0 behandelt: "keine Rate" und "dreht
  -- konstant" sind verschiedene Aussagen, und die zweite wuerde hier eine
  -- Vorhersage begruenden, fuer die es keine Grundlage gibt.
  local rate_rpm_per_s = nil
  local prev_rpm = tonumber(input.last_rpm)
  local prev_rpm_ms = tonumber(input.last_rpm_ms)
  local now_for_rate = tonumber(input.now_ms)
  if prev_rpm and prev_rpm_ms and now_for_rate then
    local dt_ms = now_for_rate - prev_rpm_ms
    if dt_ms > 0 and dt_ms <= M.MAX_RATE_AGE_MS then
      rate_rpm_per_s = (rpm - prev_rpm) * 1000 / dt_ms
    end
  end

  local error_rpm = target_rpm - rpm

  -- Der Vorhalt: geregelt wird auf die Drehzahl, die in LOOKAHEAD_S
  -- Sekunden anliegt, wenn es so weitergeht. Ohne Rate bleibt es beim
  -- Istwert.
  -- Nah am Ziel entfaellt der Vorhalt (siehe FINE_BAND_RPM): dort ist die
  -- hochgerechnete Rate fast nur noch Messrauschen, und der Regler wuerde
  -- dieses Rauschen nachstellen. Die Rate selbst wird weiter gebildet --
  -- die Ruhezone unten braucht sie.
  local fine_band = tonumber(input.fine_band_rpm) or M.FINE_BAND_RPM
  local in_fine_zone = math.abs(error_rpm) <= fine_band
  local lookahead_s = tonumber(input.lookahead_s) or M.LOOKAHEAD_S

  -- In der Feinzone zaehlt die Rate erst ab dem Tor: darunter ist sie
  -- Rauschen, und der Regler wuerde Rauschen nachstellen.
  local rate_gate = tonumber(input.fine_rate_gate_rpm_per_s) or M.FINE_RATE_GATE_RPM_PER_S
  local use_rate = rate_rpm_per_s ~= nil
  if use_rate and in_fine_zone and math.abs(rate_rpm_per_s) < rate_gate then
    use_rate = false
  end

  local control_error = error_rpm
  if use_rate then
    -- Die Vorhersage wird begrenzt. Eine aus zwei dicht aufeinander
    -- folgenden Messpunkten gerechnete Rate kann voellig ueberzogen sein
    -- (ein Sprung von 40 Umdrehungen in 100 ms ergibt 400 U/min/s), und
    -- ohne Deckel wuerde daraus eine Scheinabweichung, die jede echte
    -- Abweichung erschlaegt. Der Deckel nimmt der Vorhersage nicht ihre
    -- Richtung, nur ihre Masslosigkeit.
    local predicted_delta = rate_rpm_per_s * lookahead_s
    local max_predict = tonumber(input.max_predict_rpm) or M.MAX_PREDICT_RPM
    if predicted_delta > max_predict then predicted_delta = max_predict end
    if predicted_delta < -max_predict then predicted_delta = -max_predict end
    control_error = target_rpm - (rpm + predicted_delta)
  end

  -- Ruhezone: nah genug am Ziel wird gar nicht gestellt. Ohne sie stellt
  -- der Regler auch dann noch, wenn er angekommen ist -- die kleinste
  -- Schrittweite ist auf einer grossen Turbine schon mehr als die
  -- verbleibende Abweichung, und das Ergebnis ist ein endloses +1/-1.
  --
  -- Mit Vorhalt gehoert die Rate dazu: eine Turbine, die GERADE durch 900
  -- hindurchbeschleunigt, steht nicht am Ziel, auch wenn die Abweichung in
  -- diesem Augenblick null ist. Ohne diese zweite Bedingung wuerde der
  -- Regler genau im entscheidenden Moment die Haende in den Schoss legen.
  local settle_band = tonumber(input.settle_band_rpm) or M.SETTLE_BAND_RPM
  local settle_rate = tonumber(input.settle_rate_rpm_per_s) or M.SETTLE_RATE_RPM_PER_S
  local rate_settled = (rate_rpm_per_s == nil) or (math.abs(rate_rpm_per_s) <= settle_rate)
  if math.abs(error_rpm) <= settle_band and rate_settled then
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
  --
  -- Und sie entfaellt ganz, sobald eine Rate vorliegt: der Vorhalt loest
  -- dasselbe Problem (Rotor antwortet verzoegert) auf dem richtigen Weg.
  -- Er SIEHT die noch ausstehende Wirkung als Rate, statt sie abzuwarten.
  -- Genau das ist "fast instant reagieren, ohne zu ueberschwingen": mit
  -- Wartezeit ist der Regler langsam, ohne Vorhalt schwingt er ueber.
  local braking = rpm > target_rpm + band
  local skip_interval = braking or (rate_rpm_per_s ~= nil)
  if now_ms and last_change_ms and not skip_interval then
    local since = now_ms - last_change_ms
    if since >= 0 and since < interval_ms then
      return hold("SETTLING")
    end
  end

  -- Proportionalschritt. Am Bandrand genau TRIM_STEP, naeher am Ziel
  -- entsprechend weniger, mindestens aber 1 -- sonst bliebe eine kleine
  -- Abweichung ewig stehen. Weiter weg waechst er mit der Abweichung; nur
  -- die Deckelung unterscheidet die Richtungen (siehe MAX_TRIM_STEP_DOWN).
  local step = M.TRIM_STEP * math.abs(control_error) / band

  -- Auf die tatsaechlich verstrichene Zeit beziehen (siehe
  -- NOMINAL_STEP_INTERVAL_MS). Ohne Zeitangabe bleibt alles wie zuvor --
  -- Modultests und Altaufrufer merken davon nichts.
  local dt_ms = tonumber(input.dt_ms)
  if dt_ms and dt_ms > 0 then
    local scale = dt_ms / M.NOMINAL_STEP_INTERVAL_MS
    if scale < M.MIN_STEP_SCALE then scale = M.MIN_STEP_SCALE end
    if scale > M.MAX_STEP_SCALE then scale = M.MAX_STEP_SCALE end
    step = step * scale
  end

  -- Die Vorhersage sagt "kommt hin": nichts tun. Das ist der Kern des
  -- Vorhalts -- die Turbine ist vielleicht noch weit weg, aber sie ist auf
  -- dem Weg, und jede weitere Verstellung jetzt waere genau das
  -- Ueberschwingen. Diese Pruefung steht VOR der Feinzone: auch dort gilt,
  -- dass ein Treffer nicht nachkorrigiert wird.
  if math.abs(control_error) < 1 then
    return hold("ON_PREDICTED_TARGET")
  end

  -- Nah am Ziel wird fein gestellt (siehe FINE_BAND_RPM). Der Deckel gilt
  -- in BEIDE Richtungen -- feiner heisst feiner, nicht "vorsichtig nach
  -- oben und weiterhin grob nach unten".
  local fine_step = tonumber(input.fine_trim_step) or M.FINE_TRIM_STEP
  if in_fine_zone then
    local fine = math.max(1, math.min(fine_step, math.floor(step + 0.5)))
    if control_error > 0 then
      return { flow = clamp(current_flow + fine, min_flow, max_flow), reason = "FINE_UP" }
    end
    return { flow = clamp(current_flow - fine, min_flow, max_flow), reason = "FINE_DOWN" }
  end

  if control_error > 0 then
    -- Zu langsam. Wie entschieden nachgelegt werden darf, haengt daran, ob
    -- eine Rate vorliegt: mit Vorhalt bremst die Vorhersage rechtzeitig
    -- wieder ein, ohne ihn wuerde ein grosser Schritt ueberschwingen.
    local cap = use_rate and M.MAX_TRIM_STEP_UP or M.TRIM_STEP
    local up = math.max(1, math.min(cap, math.floor(step + 0.5)))
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
  -- Eine einmal gekuppelte Turbine bleibt bei positivem Ziel gekuppelt.
  --
  -- Vorher loeste sie unterhalb von COIL_DISENGAGE_RPM wieder. Das sieht
  -- nach gewoehnlicher Hysterese aus, ist hier aber etwas anderes: die
  -- Spule ist kein kleiner Beitrag zur Last, sie IST die Last. Ein- und
  -- Aushaengen aendert die Streckenverstaerkung sprunghaft um ein
  -- Mehrfaches. Der Durchflussregler regelt dann gegen eine Strecke, die
  -- ihre Verstaerkung im Takt wechselt, und beides zusammen schaukelt sich
  -- auf: Spule bremst unter 850 -> loest -> Rotor schiesst hoch -> Spule
  -- greift -> bremst unter 850 -> ... In der Simulation (Rotormodell MIT
  -- Spulenlast, Kupplungslast 2x Grundreibung) ergab das ueber 90 s
  -- rund 875 Umschaltungen, eine mittlere Abweichung von 90 statt 1.8 RPM
  -- und Drehzahlspitzen, die mit sinkender Rotortraegheit monoton wachsen
  -- und ab Traegheit 0.25 die Ueberdrehzahlschwelle reissen -- genau der
  -- gemeldete Fall "einzelne Turbine geht nach einiger Zeit in
  -- Ueberdrehzahl". Mit dieser Regel: EINE Umschaltung, Spitze unter 1100
  -- ueber denselben Traegheitsbereich.
  --
  -- Die Loeseschwelle war fuer den HOCHLAUF gedacht -- und der ist der
  -- Zweig oben (not currently_engaged): eine noch nie gekuppelte Turbine
  -- beschleunigt weiterhin unbelastet. Ist sie einmal am Ziel gewesen, ist
  -- Halten mit Last der richtige Betriebszustand; nur dort liefert sie
  -- ueberhaupt Energie (siehe rt2_orchestrator's measure_capacity, das
  -- energy > 0 verlangt).
  --
  -- Eine Ausnahme bleibt, sonst koennte ein Rotor dauerhaft haengen: wenn
  -- die Spule den Hochlauf nachweislich VERHINDERT -- Drehzahl weit unter
  -- Ziel und Dampf bereits am Anschlag -- wird sie freigegeben. Diese
  -- Schwelle liegt weit unter der Regelgegend, sie kann also nicht wieder
  -- zum Flattern fuehren.
  if currently_engaged then
    local flow = tonumber(input.current_flow)
    local max_flow = tonumber(input.max_flow) or M.MAX_FLOW
    local stall_rpm = target_rpm * (tonumber(input.coil_stall_rpm_fraction)
      or M.COIL_STALL_RPM_FRACTION)
    if rpm <= stall_rpm and flow ~= nil and flow >= max_flow then
      return { engaged = false, reason = "RELEASE_STALLED" }
    end
    return { engaged = true, reason = "HOLD_ENGAGED" }
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
