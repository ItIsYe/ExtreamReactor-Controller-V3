-- RT rewrite, step 4: capacity learning, fully decoupled from control.
--
-- The old capacity_learning.lua did one thing right (measure turbines at
-- target RPM, apply a safety margin) but got entangled with two things
-- that caused real production bugs this session:
--   1. get_turbine_target_rpm() checked capacity_ready INSIDE the target
--      calculation, so "is capacity known" and "what RPM should this
--      turbine target" were one tangled decision (rt2_turbine.lua's
--      compute_target_rpm() now takes the *state* as an explicit input
--      instead -- rt2_state.lua already decided LEARNING vs MASTER/
--      AUTONOM before this module is even consulted).
--   2. The persisted cache was keyed by an exact per-turbine identity
--      signature (name/registry id) that is NOT stable across a world
--      reload in this pack (BigReactors multiblocks get renamed) -- so a
--      real fix already shipped this session (main.lua v700) reused the
--      registry's own ids consistently, but the underlying fragility
--      (identity-based invalidation) remains a foot-gun. This module
--      instead keys invalidation on turbine COUNT only: a genuine
--      hardware change (added/removed turbine) is the only thing that
--      should ever throw away a learned value. A renamed-but-same-count
--      turbine fleet keeps its learned capacity.
--
-- Pure functions again: M.update() takes the previous state and a plain
-- list of {rpm, energy, coil_engaged} readings and returns a new state --
-- no ctx, no file I/O. Persistence (save/load) is a thin, separate
-- wrapper below so the learning math itself stays trivially testable.

local rt2_turbine = require("nodes.rt.rt2_turbine")

local M = {}

M.TARGET_RPM = 900
M.TOLERANCE_RPM = 15
M.SAFETY_MARGIN = 0.05 -- store max_output as 95% of the measured peak

-- Ein Messwert zaehlt nur, wenn mindestens dieser Anteil der Flotte
-- gleichzeitig im Zielbereich steht (bestaetigte Vorgabe). Eine Summe aus
-- wenigen Turbinen beschreibt die Anlage nicht -- sie waere je nach
-- Augenblick beliebig niedrig.
M.MIN_FRACTION = 0.8

-- Was hier gemessen wird: der hoechste Gesamtausstoss, den dieser Knoten
-- jemals nachweislich GLEICHZEITIG geliefert hat. Genau diese Zahl braucht
-- MASTER, um seinen Leistungsbedarf gegen die Knoten aufzuteilen.
--
-- Zwei Dinge dabei, die sich leicht verwechseln lassen:
--
--   MIN_FRACTION entscheidet, WELCHER Takt als Messwert taugt: mindestens
--   80 % der Flotte muessen gleichzeitig im Zielbereich stehen. Eine Summe
--   aus drei zufaellig gerade laufenden Turbinen beschreibt die Anlage
--   nicht.
--
--   Der HOECHSTWERT entscheidet, welcher der tauglichen Messwerte gilt.
--   Das ist der Unterschied zu frueher: damals wurde der erste taugliche
--   Takt genommen und dann mit
--       (Summe Ausstoss / am Ziel) * GESAMTZAHL
--   auf die ganze Flotte hochgerechnet -- also eine Zahl erfunden fuer
--   Turbinen, die in dem Moment gar nicht lieferten. Jetzt wird einfach
--   ueber die Zeit der beste tatsaechlich geflossene Gesamtausstoss
--   behalten. Laeuft die Flotte irgendwann vollstaendig, steht damit der
--   echte Vollwert da -- ohne Hochrechnung, und ohne dass genau EIN
--   Augenblick alles entscheiden muss.
--
-- Steigt der Hoechstwert eine Weile nicht mehr, ist die Anlage ausgemessen.
M.STABLE_MS = 6000  -- so lange darf sich der Hoechstwert nicht mehr verbessern

-- So lange muss eine geaenderte Turbinenzahl ANHALTEN, bevor sie als
-- Umbau gilt. Ein Peripheral, das einen Takt lang nicht antwortet (Chunk
-- laedt nach, Serverhaenger), faellt sonst aus der Liste und sieht aus
-- wie eine abgebaute Turbine -- der gelernte Wert waere weg und die
-- Messung liefe von vorn los, wegen eines Wimpernschlags.
M.TOPOLOGY_DEBOUNCE_MS = 3000

-- Staffelung waehrend des Einlernens.
--
-- rt2_turbine.lua's active_limit() sagt es seit jeher: "Ohne ihn setzt
-- jeder Zustand ausser MASTER alle Turbinen auf das volle Ziel, und eine
-- dampfbegrenzte Anlage reisst sich dabei selbst den Dampf weg: keine
-- Turbine erreicht die Zieldrehzahl, weil alle gleichzeitig daran ziehen."
-- Drei Kommentare beschreiben die Staffelung als vorhanden -- gebaut war
-- sie nie: dieses Modul kannte den Begriff nicht, und der Orchestrator
-- setzte max_active waehrend LEARNING ausdruecklich auf nil.
--
-- Die Folge skaliert mit der Flottengroesse und erklaert, warum ein
-- kleiner Aufbau laeuft und ein grosser nicht: 25 Turbinen an einem
-- Reaktor erreichen die 80-%-Schwelle noch, 50 nicht mehr. Und weil das
-- Einlernen nie fertig wird, wird auch nie eine tragbare Anzahl gelernt,
-- mit der sich das Problem aufloesen liesse -- eine Selbstsperre.
--
-- Deshalb: erst die ganze Flotte freigeben (unveraendertes Verhalten fuer
-- jede Anlage, die sie traegt). Traegt sie sie NICHT, die Freigabe
-- halbieren und erneut versuchen, bis eine Stufe traegt. Damit misst das
-- Einlernen genau das, was sustainable_turbines behauptet zu sein.
-- Eine Stufe muss BEWEISEN duerfen, dass sie traegt. Ein Rotor braucht vom
-- Stillstand bis 900 RPM ein Vielfaches der alten 8 Sekunden -- in dieser
-- Zeit steht er zwangslaeufig bei vollem Flow unter Zieldrehzahl und sah
-- damit aus wie eine Turbine, der der Dampf fehlt. Die Staffel gab jede
-- Stufe auf, bevor sie ueberhaupt eine Chance hatte, und lief bis ganz
-- nach unten durch.
M.STAGE_TIMEOUT_MS = 30000

-- Und die eigentliche Verwechslung: "voller Flow und unter Ziel" heisst
-- NICHT zwangslaeufig Dampfmangel -- es ist auch genau das Bild einer
-- hochlaufenden Turbine. Der Unterschied ist die Drehzahl-Richtung:
-- steigt sie, fliesst Dampf und verrichtet Arbeit. Erst eine Turbine, die
-- bei vollem Flow NICHT mehr schneller wird, hungert wirklich.
M.RISING_RPM_PER_S = 2

-- Und wieder hinauf. Eine Stufe, die sauber traegt (keine einzige Turbine
-- gesaettigt), ist KEIN Beweis, dass mehr nicht ginge -- sie beweist nur,
-- dass so viel geht. Ohne diesen Weg zurueck waere jede einmal
-- zurueckgenommene Freigabe eine Decke fuer immer.
--
-- Genau so im Betrieb gesehen (node-101, direkt nach dem Einbau der
-- Staffelung): CAP READY, 50 Turbinen aktiv -- und genau EINE lief. In
-- der Dampfknappheit war 1 gelernt worden, und danach durfte die Anlage
-- nie wieder zeigen, dass sie mehr traegt: bei einer Freigabe von 1 kann
-- nie mehr als 1 gleichzeitig am Ziel stehen, der Hoechstwert kann sich
-- also nie verbessern. Eine Selbstsperre, nur eine Ebene hoeher als die
-- vorige.
M.RECLIMB_MS = 15000

local function copy(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

function M.new_state()
  return {
    ready = false,
    max_output = 0,
    -- Wieviele Turbinen diese Anlage nachweislich gleichzeitig auf
    -- Zieldrehzahl halten kann. Deckelt spaeter auch die MASTER-Aufteilung
    -- (rt2_turbine.compute_target_rpm's max_active) -- sonst bedeutete
    -- "100 %" wieder "alle Turbinen", was die Anlage nicht kann.
    sustainable_turbines = 0,
    at_target = 0,
    -- Wieviele im Zielbereich stehen MUESSEN, damit ein Takt als Messwert
    -- zaehlt. Mitgefuehrt, damit die Diagnose beide Zahlen nennen kann --
    -- "18 von 25" allein sieht nach Fortschritt aus.
    required_at_target = 0,
    saturated = 0,
    total_turbines = 0,
    reason = "INIT",
    -- Der rohe Hoechstwert; max_output ist derselbe Wert abzueglich der
    -- Sicherheitsreserve. Getrennt gehalten, damit die Reserve nicht bei
    -- jeder Verbesserung erneut abgezogen wird.
    best_output = 0,
    last_improved_ms = nil,
    -- Eine noch nicht bestaetigte Aenderung der Turbinenzahl.
    pending_total = nil,
    pending_since_ms = nil,
    -- Wieviele Turbinen waehrend des Einlernens ueberhaupt ziehen duerfen.
    -- 0/nil heisst "alle" -- so faengt jede Anlage an.
    released = 0,
    stage_since_ms = nil,
    climb_since_ms = nil,
  }
end

-- A turbine whose flow setting is already pegged at (or just under) the
-- mod's hard limit and which STILL cannot reach the target speed is
-- saturated: no controller action left to take. Either the reactor cannot
-- supply that much steam, or the coil load at this target exceeds what the
-- turbine can carry. Counting these separately is what turns an invisible
-- hang into a diagnosable condition -- see M.update()'s FLOW_SATURATED.
M.SATURATION_FRACTION = 0.95

-- Summiert den Ausstoss aller Turbinen, die GERADE am Ziel und gekuppelt
-- sind, und zaehlt nebenbei, wieviele bei voller Foerderung trotzdem zu
-- langsam sind (Saettigung -- reine Diagnose, keine Regelgroesse).
local function measure(turbines)
  local total = #(turbines or {})
  if total == 0 then return 0, 0, 0, 0 end
  local max_flow = rt2_turbine.MAX_FLOW
  local at_target, output, saturated = 0, 0, 0
  for index = 1, total do
    local t = turbines[index]
    local rpm = tonumber(t.rpm)
    local energy = tonumber(t.energy) or 0
    if rpm and t.coil_engaged ~= false
        and math.abs(rpm - M.TARGET_RPM) <= M.TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      output = output + energy
    elseif rpm and rpm < M.TARGET_RPM - M.TOLERANCE_RPM then
      local flow = tonumber(t.current_flow)
      if flow and flow >= max_flow * M.SATURATION_FRACTION then
        saturated = saturated + 1
      end
    end
  end
  return output, at_target, total, saturated
end

-- previous: a state table from M.new_state()/a prior M.update() call.
-- turbines: array of { rpm, energy, coil_engaged, current_flow }
-- opts.now_ms: the clock -- needed to tell "still climbing" from "done".
--
-- Returns a NEW state table (copy-on-write, same discipline as before).
function M.update(previous, turbines, opts)
  local state = copy(previous or M.new_state())
  opts = type(opts) == "table" and opts or {}
  local now_ms = tonumber(opts.now_ms) or 0
  local total = #(turbines or {})

  -- Gar keine Turbinen gelesen ist KEIN Umbau, sondern eine fehlende
  -- Messung -- ein Discovery-Aussetzer, ein Peripheral-Hickser. Melden,
  -- nichts anfassen.
  if total == 0 then
    state.at_target, state.saturated = 0, 0
    state.reason = "NO_TURBINES"
    return state
  end

  if total ~= state.total_turbines then
    -- Turbine COUNT changed: the only signal this module trusts as a real
    -- hardware change. A rename-only reshuffle (same count) never reaches
    -- this branch, so it can never invalidate a learned value the way the
    -- old identity-signature cache did.
    --
    -- Aber erst, wenn die neue Anzahl auch anhaelt -- siehe
    -- TOPOLOGY_DEBOUNCE_MS. Bis dahin gilt weiter, was gelernt wurde.
    if state.pending_total ~= total then
      state.pending_total = total
      state.pending_since_ms = now_ms
    end
    if state.ready and (now_ms - (state.pending_since_ms or now_ms)) < M.TOPOLOGY_DEBOUNCE_MS then
      state.at_target, state.saturated = 0, 0
      state.reason = "TOPOLOGY_PENDING"
      return state
    end
    state.pending_total, state.pending_since_ms = nil, nil
    state.ready = false
    state.max_output = 0
    state.best_output = 0
    state.sustainable_turbines = 0
    state.last_improved_ms = now_ms
    state.total_turbines = total
    -- Ein Umbau macht jede gemessene Stufe wertlos: von vorn mit der
    -- ganzen Flotte.
    state.released = 0
    state.stage_since_ms = nil
    state.climb_since_ms = nil
    state.reason = "TOPOLOGY_CHANGED"
    return state
  end
  state.pending_total, state.pending_since_ms = nil, nil

  local output, at_target, _, saturated = measure(turbines)
  state.at_target, state.saturated = at_target, saturated
  -- Die Schwelle gilt fuer die FREIGEGEBENE Stufe, nicht fuer die ganze
  -- Flotte -- sonst koennte eine zurueckgenommene Stufe die Schwelle
  -- niemals erreichen und die Staffelung liefe ins Leere.
  local released = (tonumber(state.released) or 0) > 0
    and math.min(state.released, total) or total
  state.required_at_target = math.max(1, math.ceil(released * M.MIN_FRACTION))

  -- Zu wenige Turbinen im Zielbereich: dieser Takt taugt nicht als
  -- Messwert. Ein bereits gelernter Hoechstwert bleibt davon unberuehrt --
  -- er beschreibt ja, was die Anlage schon einmal geliefert hat.
  if at_target < state.required_at_target then
    if state.ready then
      state.reason = "STABLE"
      return state
    end
    if not state.last_improved_ms then state.last_improved_ms = now_ms end
    if (state.best_output or 0) > 0 and now_ms - state.last_improved_ms >= M.STABLE_MS then
      state.ready = true
      state.reason = "MEASURED"
      return state
    end

    -- Die aktuelle Stufe traegt nicht -- aber NUR Saettigung beweist das.
    --
    -- Eine Turbine, die noch Flow-Reserve hat, laeuft schlicht noch hoch;
    -- ihr die Freigabe zu nehmen waere ein Fehler (und war es: der
    -- Lebenszyklus-Test hat genau das gefangen, eine Anlage, die ihre
    -- ganze Flotte traegt, wurde auf 12 heruntergestaffelt, bevor sie
    -- ueberhaupt auf Drehzahl war).
    --
    -- Saettigung dagegen heisst: volle Foerderung und trotzdem zu langsam.
    -- Dann fehlt Dampf, und wie dieser Test es selbst formuliert, aendert
    -- Warten daran nichts. Erst das rechtfertigt den Rueckschritt.
    -- Solange irgendeine Turbine noch Drehzahl AUFBAUT, ist die Stufe
    -- nicht gescheitert -- sie ist noch am Anlaufen. Die Uhr fuer den
    -- Rueckschritt laeuft dann gar nicht erst.
    local rising = tonumber(opts.rising) or 0
    if saturated > 0 and rising == 0 then
      if not state.stage_since_ms then state.stage_since_ms = now_ms end
    else
      state.stage_since_ms = nil
    end
    if saturated > 0 and rising == 0 and released > 1
        and now_ms - (state.stage_since_ms or now_ms) >= M.STAGE_TIMEOUT_MS then
      state.released = math.max(1, math.floor(released / 2))
      state.stage_since_ms = now_ms
      state.climb_since_ms = nil
      -- Die Anlage traegt nachweislich weniger als gedacht: der gemessene
      -- Wert darf das nicht weiter behaupten, sonst verteilt MASTER
      -- weiterhin auf Turbinen, die nie ans Ziel kommen.
      if (state.sustainable_turbines or 0) > state.released then
        state.sustainable_turbines = state.released
      end
      state.reason = "STAGE_DOWN"
      return state
    end

    state.reason = (saturated > 0) and "FLOW_SATURATED" or "BELOW_FRACTION"
    return state
  end

  -- Die Stufe traegt: die Uhr fuer den Rueckschritt laeuft neu.
  state.stage_since_ms = nil
  state.released = released

  -- ... und die fuer den Weg zurueck nach oben laeuft an. Nur solange
  -- KEINE Turbine gesaettigt ist: Saettigung hiesse, der Dampf ist schon
  -- jetzt knapp, dann waere mehr Freigabe das Gegenteil einer Verbesserung.
  if saturated == 0 and released < total then
    if not state.climb_since_ms then state.climb_since_ms = now_ms end
    if now_ms - state.climb_since_ms >= M.RECLIMB_MS then
      state.released = math.min(total, released + math.max(1, math.floor(total * 0.1)))
      -- Auch die gemessene Zahl mitziehen: sie ist es, die im Betrieb
      -- deckelt (rt2_orchestrator). Bliebe sie stehen, duerfte die groessere
      -- Freigabe sich nie zeigen -- es koennten nie mehr Turbinen
      -- gleichzeitig ans Ziel kommen, der Hoechstwert koennte sich nie
      -- verbessern, und die Decke bliebe fuer immer.
      if (state.sustainable_turbines or 0) < state.released then
        state.sustainable_turbines = state.released
      end
      state.climb_since_ms = now_ms
      state.reason = "STAGE_UP"
      return state
    end
  else
    state.climb_since_ms = nil
  end

  if output > (state.best_output or 0) then
    state.best_output = output
    -- Ganzzahlig: RF/t mit acht Nachkommastellen ist nicht nur unsinnig
    -- zu lesen, der Wert ueberlebt auch die Serialisierung in den Cache
    -- nicht unveraendert -- nach einem Neustart stand eine minimal andere
    -- Kapazitaet da als vor dem Herunterfahren.
    state.max_output = math.floor(output * (1 - M.SAFETY_MARGIN))
    -- Wieviele Turbinen liefen, als dieser Hoechstwert floss. Mehr als das
    -- hat diese Anlage nie gleichzeitig getragen -- deshalb deckelt die
    -- Zahl spaeter auch die MASTER-Aufteilung. Traegt die Anlage ihre
    -- ganze Flotte, ist sie schlicht gleich der Flottengroesse und die
    -- Deckelung wirkt nirgends.
    state.sustainable_turbines = at_target
    state.last_improved_ms = now_ms
    state.reason = state.ready and "STABLE" or "MEASURING"
    return state
  end

  if state.ready then
    state.reason = "STABLE"
    return state
  end

  if not state.last_improved_ms then state.last_improved_ms = now_ms end

  if (state.best_output or 0) > 0 and now_ms - state.last_improved_ms >= M.STABLE_MS then
    state.ready = true
    state.reason = "MEASURED"
    return state
  end

  -- Hier unten sind IMMER genug Turbinen im Zielbereich (sonst waere die
  -- Schwellen-Pruefung oben schon zurueckgekehrt), also liegt auch immer
  -- ein Messwert vor. Ein eigener "laeuft noch hoch"-Zweig waere an
  -- dieser Stelle unerreichbar.
  state.reason = "MEASURING"
  return state
end

-- ── Persistence (thin wrapper; not itself pure, kept separate on purpose) ──

function M.save(state, opts)
  if type(state) ~= "table" or state.ready ~= true then return false, "not ready" end
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return false, "no path" end
  if type(opts.write_config) ~= "function" then return false, "no writer" end
  return opts.write_config(opts.path, {
    ready = true,
    max_output = tonumber(state.max_output) or 0,
    turbine_count = tonumber(state.total_turbines) or 0,
    -- Ohne diese Zahl waere der ganze Suchlauf bei jedem Neustart
    -- umsonst: sie deckelt im Betrieb, wieviele Turbinen laufen duerfen.
    sustainable_turbines = tonumber(state.sustainable_turbines) or 0,
  })
end

function M.load(opts)
  opts = opts or {}
  if type(opts.path) ~= "string" or opts.path == "" then return nil end
  if type(opts.read_config) ~= "function" then return nil end
  local data = opts.read_config(opts.path)
  if type(data) ~= "table" or data.ready ~= true
      or type(data.max_output) ~= "number" or data.max_output <= 0 then
    return nil
  end
  if type(opts.turbine_count) == "number"
      and type(data.turbine_count) == "number"
      and data.turbine_count ~= opts.turbine_count then
    return nil, "turbine count changed: cached=" .. tostring(data.turbine_count) .. " current=" .. tostring(opts.turbine_count)
  end
  local sustainable = tonumber(data.sustainable_turbines)
  if not sustainable or sustainable <= 0 then
    -- Aelterer Cache (vor dem gestaffelten Einlernen): er enthaelt nur
    -- eine hochgerechnete Kapazitaet und keine tragbare Anzahl. Dieser
    -- Wert ist auf einer dampfbegrenzten Anlage um ein Vielfaches zu
    -- hoch, also wird er verworfen statt uebernommen -- lieber einmal
    -- neu suchen als dauerhaft gegen eine erfundene Zahl regeln.
    return nil, "alter Cache ohne gemessene Turbinenzahl -- wird neu eingelernt"
  end
  local state = M.new_state()
  state.ready = true
  state.max_output = data.max_output
  state.total_turbines = data.turbine_count
  state.sustainable_turbines = math.min(sustainable, data.turbine_count or sustainable)
  -- Die Stufe MIT wiederherstellen, nicht nur die Zahl.
  --
  -- Ohne sie bezieht sich die 80-%-Schwelle nach einem Neustart wieder auf
  -- die GANZE Flotte, waehrend im Betrieb nur `sustainable` Turbinen
  -- laufen duerfen. Bei 1 von 50 heisst das: 1 am Ziel, 40 noetig -- der
  -- Takt gilt als untauglich, die Pruefung kehrt sofort als "STABLE"
  -- zurueck, und der Weg nach oben (RECLIMB_MS) wird nie erreicht. Eine in
  -- der Knappheit gelernte 1 waere damit ueber jeden Neustart hinweg
  -- endgueltig.
  state.released = state.sustainable_turbines
  state.best_output = data.max_output / (1 - M.SAFETY_MARGIN)
  state.reason = "LOADED_FROM_CACHE"
  return state
end

return M
