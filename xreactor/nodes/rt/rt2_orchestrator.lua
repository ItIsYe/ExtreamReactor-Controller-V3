-- RT rewrite, step 6: der Orchestrator -- ein Takt fuer den ganzen Knoten.
--
-- Der Knoten fasst seine Anlage als EIN System auf: eine Turbinenflotte
-- an einem gemeinsamen Dampfnetz, eine Leistungsvorgabe. Mehrere
-- Reaktoren speisen dasselbe Netz und regeln
-- sich unabhaengig voneinander aus ihrem JEWEILIGEN Dampftank (siehe
-- rt2_unit.lua) -- sie stimmen sich nicht ab und brauchen es auch nicht:
-- zieht die Flotte mehr, fallen alle Taenke, alle fahren die Staebe aus.
--
-- Hier liegt deshalb alles, wovon es pro Knoten eines gibt: der
-- Betriebszustand, die MASTER-Verbindung, der Hand-Riegel, die
-- Leistungsvorgabe und die Slot-Rotation der Flotte.
--
-- Hardware-frei wie bisher: M.tick() nimmt schlichte Messwert-Tabellen
-- und gibt schlichte Entscheidungs-Tabellen zurueck.

local rt2_state = require('nodes.rt.rt2_state')
local rt2_master_link = require('nodes.rt.rt2_master_link')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_command_handler = require('nodes.rt.rt2_command_handler')
local rt2_unit = require('nodes.rt.rt2_unit')

local M = {}

M.ROTATE_INTERVAL_MS = 300000 -- 5 min: wie oft der AUS/PUFFER-Platz wandert

-- Was der Knoten MASTER ueber seine Leistung meldet.
--
-- ── Das Einlernen ───────────────────────────────────────────────────────
--
-- Zurueckgeholtes Originalverfahren aus rt2_capacity.lua (bis v768), auf
-- Wunsch des Betreibers. Es war nie das Verfahren, das im Feld haengen
-- blieb -- haengen blieb der ZUSTAND davor und der gestaffelte Suchlauf
-- (v754-v757), der Turbinen stufenweise freigab. Beides kommt nicht
-- zurueck; das Messverfahren selbst schon, unveraendert:
--
--   Gemessen wird der hoechste Gesamtausstoss, den diese Anlage jemals
--   nachweislich GLEICHZEITIG geliefert hat.
--
--   * Ein Takt zaehlt nur, wenn mindestens 80 % der Flotte gleichzeitig
--     im Zielband stehen (900 +/- 15 RPM), gekuppelt sind und wirklich
--     liefern. Eine Summe aus drei zufaellig laufenden Turbinen
--     beschreibt die Anlage nicht.
--   * Von den tauglichen Takten gilt der HOECHSTWERT -- nicht der erste.
--     Damit entscheidet nicht ein einzelner Augenblick, und ein Takt
--     mitten im Hochlauf friert nichts ein.
--   * Steigt der Hoechstwert eine Weile nicht mehr (STABLE_MS), ist die
--     Anlage ausgemessen.
--   * Gemeldet wird der Hoechstwert abzueglich einer Sicherheitsreserve.
--
-- Waehrend des Einlernens faehrt die GANZE Flotte auf Zieldrehzahl, die
-- MASTER-Vorgabe ist uebersteuert (Betreibervorgabe 2026-09-28). Nur so
-- entsteht ein Hoechstwert, der die ganze Anlage beschreibt -- und genau
-- diese Zahl braucht MASTER, weil er den Prozentsatz als Anteil der
-- LEISTUNG rechnet (assigned_power = capacity * pct / 100), waehrend der
-- Knoten ihn als Anteil der TURBINEN umsetzt. Beides deckt sich nur, wenn
-- capacity_max fuer die volle Flotte gilt.
--
-- Sobald das Einlernen durch ist, gilt wieder ganz normale Regelung.
M.TARGET_RPM             = 900
M.LEARN_TOLERANCE_RPM    = 15      -- Zielband
M.LEARN_MIN_FRACTION     = 0.8     -- so viel der Flotte muss gleichzeitig drin stehen
M.LEARN_SAFETY_MARGIN    = 0.05    -- gemeldet wird 95 % des gemessenen Hoechstwerts
M.LEARN_STABLE_MS        = 6000    -- so lange darf er sich nicht mehr verbessern
M.TOPOLOGY_DEBOUNCE_MS   = 3000    -- so lange muss eine geaenderte Turbinenzahl anhalten
M.SATURATION_FRACTION    = 0.95    -- ab hier gilt der Durchfluss als am Anschlag

-- Eine Notbremse auf Zeit gibt es NICHT (Betreibervorgabe 2026-09-29: "das
-- Learning muss diese Zeit raus, es muss so lange gewartet werden, bis die
-- erforderlichen Turbinen da sind"). Sie war eine Zugabe von mir, im
-- Original stand sie nicht: nach drei Minuten galt der hoechste bis dahin
-- geflossene Ausstoss, auch wenn die 80 % nie erreicht waren.
--
-- Das war der falsche Tausch. Der Messwert ist die Grundlage, auf der
-- MASTER die ganze Anlage aufteilt -- eine zu kleine Zahl dort ist kein
-- "etwas ungenau", sondern eine dauerhaft zu klein ausgelegte Anlage, und
-- sie sieht von aussen genauso aus wie eine richtige. Lieber wartet das
-- Einlernen sichtbar weiter (der Knoten sagt in jedem Takt, wie viele
-- Turbinen noch fehlen), als still mit einer falschen Zahl weiterzulaufen.
--
-- Endlos ist das nicht im Sinne von "haengt": sobald die geforderten
-- Turbinen EINMAL gemeinsam im Zielband waren, laeuft die Messung ueber
-- LEARN_STABLE_MS in ihr Ergebnis -- auch wenn die Flotte danach wieder
-- darunter faellt (siehe settle_measured() unten).

M.LEARNING = "LEARNING"
M.MEASURED = "MEASURED"
M.OBSERVED = "OBSERVED"

function M.new_output_state()
  return {
    max_output = 0, best_output = 0, observed = 0,
    at_target = 0, required_at_target = 0, saturated = 0, total_turbines = 0,
    sustainable_turbines = 0,
    learning = true, learn_started_ms = nil, last_improved_ms = nil,
    pending_total = nil, pending_since_ms = nil,
    ready = false, reason = "NO_TURBINES",
  }
end

local function copy_state(t)
  local out = {}
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

-- Summiert den Ausstoss aller Turbinen, die GERADE im Zielband und
-- gekuppelt sind, und zaehlt nebenbei, wieviele bei voller Foerderung
-- trotzdem zu langsam sind (Saettigung -- reine Diagnose).
local function measure(turbines)
  local total = #(turbines or {})
  if total == 0 then return 0, 0, 0, 0 end
  local max_flow = rt2_turbine.MAX_FLOW
  local at_target, output, saturated, sum_all = 0, 0, 0, 0
  for index = 1, total do
    local t = turbines[index]
    local rpm = tonumber(t.rpm)
    local energy = tonumber(t.energy) or 0
    sum_all = sum_all + energy
    if rpm and t.coil_engaged ~= false
        and math.abs(rpm - M.TARGET_RPM) <= M.LEARN_TOLERANCE_RPM
        and energy > 0 then
      at_target = at_target + 1
      output = output + energy
    elseif rpm and rpm < M.TARGET_RPM - M.LEARN_TOLERANCE_RPM then
      local flow = tonumber(t.current_flow)
      if flow and flow >= max_flow * M.SATURATION_FRACTION then
        saturated = saturated + 1
      end
    end
  end
  return output, at_target, saturated, sum_all
end

local function measure_capacity(previous, turbines, now_ms)
  local state = copy_state(previous or M.new_output_state())
  now_ms = tonumber(now_ms) or 0
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
    -- Die Turbinen-ANZAHL ist das einzige Signal, dem dieses Verfahren als
    -- echter Umbau traut. Eine blosse Umbenennung (gleiche Anzahl) kommt
    -- hier nie an und kann einen gelernten Wert daher nicht verwerfen.
    -- Und erst, wenn die neue Anzahl auch anhaelt: ein Peripheral, das
    -- einen Takt lang nicht antwortet, sieht sonst aus wie eine abgebaute
    -- Turbine.
    if state.pending_total ~= total then
      state.pending_total = total
      state.pending_since_ms = now_ms
    end
    -- Die Entprellung gilt AUCH waehrend des Einlernens. Vorher stand hier
    -- "not state.learning", und das hiess: jede Schwankung der
    -- Turbinenzahl setzte das laufende Einlernen sofort zurueck --
    -- best_output, last_improved_ms, alles. Ein Peripheral, das einen Takt
    -- lang nicht antwortet, sieht aber genauso aus wie eine abgebaute
    -- Turbine. Flackert die Zahl, faengt das Einlernen endlos von vorn an,
    -- und seit es keinen Abbruch auf Zeit mehr gibt, faellt das auch
    -- niemandem mehr durch ein Ende auf.
    --
    -- Der Grund, aus dem die Entprellung beim Einlernen ausgenommen war --
    -- ein echter Umbau soll sofort neu vermessen werden -- bleibt gewahrt:
    -- nach TOPOLOGY_DEBOUNCE_MS wird auch hier zurueckgesetzt.
    -- Nicht beim ERSTEN Erkennen: der Sprung von "noch keine Turbine
    -- bekannt" auf N ist kein Umbau, sondern die erste Messung ueberhaupt.
    -- Ihn zu entprellen wuerde den Knoten nach jedem Start drei Sekunden
    -- lang behaupten lassen, die Anlage schwanke.
    if (state.total_turbines or 0) > 0
        and (now_ms - (state.pending_since_ms or now_ms)) < M.TOPOLOGY_DEBOUNCE_MS then
      state.at_target, state.saturated = 0, 0
      state.reason = "TOPOLOGY_PENDING"
      return state
    end
    state.pending_total, state.pending_since_ms = nil, nil
    state.learning = true
    state.ready = false
    state.max_output, state.best_output, state.observed = 0, 0, 0
    state.sustainable_turbines = 0
    state.last_improved_ms = now_ms
    state.learn_started_ms = now_ms
    state.total_turbines = total
    state.at_target, state.saturated = 0, 0
    -- Schon hier mitfuehren, sonst meldet der erste Takt "0 von 0" und die
    -- Anzeige sieht aus, als waere nichts zu tun.
    state.required_at_target = math.max(1, math.ceil(total * M.LEARN_MIN_FRACTION))
    state.reason = "TOPOLOGY_CHANGED"
    return state
  end
  state.pending_total, state.pending_since_ms = nil, nil

  local output, at_target, saturated, sum_all = measure(turbines)
  state.at_target, state.saturated = at_target, saturated
  state.required_at_target = math.max(1, math.ceil(total * M.LEARN_MIN_FRACTION))
  if sum_all > (state.observed or 0) then state.observed = sum_all end

  -- Ist die Anlage ausgemessen, wird nichts mehr veraendert. Der gelernte
  -- Wert beschreibt, was sie geliefert HAT -- ein schwacher Takt spaeter
  -- widerlegt das nicht.
  if not state.learning then
    state.reason = state.reason == M.OBSERVED and M.OBSERVED or M.MEASURED
    return state
  end

  if state.learn_started_ms == nil then state.learn_started_ms = now_ms end
  if state.last_improved_ms == nil then state.last_improved_ms = now_ms end

  local function settle_measured()
    state.learning = false
    state.ready = true
    state.reason = M.MEASURED
    return state
  end

  -- Zu wenige Turbinen im Zielband: dieser Takt taugt nicht als Messwert.
  if at_target < state.required_at_target then
    if (state.best_output or 0) > 0 and now_ms - state.last_improved_ms >= M.LEARN_STABLE_MS then
      return settle_measured()
    end
    -- Kein Abbruch auf Zeit. Es wird gewartet, bis die geforderten
    -- Turbinen da sind.
    state.reason = M.LEARNING
    return state
  end

  if output > (state.best_output or 0) then
    state.best_output = output
    -- Ganzzahlig: RF/t mit acht Nachkommastellen ist nicht nur unsinnig zu
    -- lesen, der Wert ueberlebt auch eine Serialisierung nicht unveraendert.
    state.max_output = math.floor(output * (1 - M.LEARN_SAFETY_MARGIN))
    -- Wieviele Turbinen liefen, als dieser Hoechstwert floss.
    state.sustainable_turbines = at_target
    state.last_improved_ms = now_ms
    state.reason = M.LEARNING
    return state
  end

  if now_ms - state.last_improved_ms >= M.LEARN_STABLE_MS then
    return settle_measured()
  end

  state.reason = M.LEARNING
  return state
end

function M.new(opts)
  opts = opts or {}
  local self = {
    machine = rt2_state.new(opts.initial_state),
    master_link = rt2_master_link.new({ timeout_ms = opts.master_timeout_ms }),
    manual_safety_trip = false,
    master_percent = 100,
    -- EINE Leistungsmeldung fuer den ganzen Knoten: die Turbinen haengen
    -- alle am selben Dampfnetz, also ist ihre Summe die Leistung dieses
    -- Knotens -- egal, wie viele Reaktoren sie speisen.
    capacity = M.new_output_state(),
    rotation_offset = 0,
    last_rotate_ms = 0,
    reactors = {},
    -- Je Turbine, nach NAME (die Reihenfolge der Flotte ist nicht stabil):
    -- wann zuletzt gestellt wurde.
    turbine_last_change_ms = {},
    -- Was zuletzt WIRKLICH gestellt wurde. Ohne das ist der Regler auf
    -- den Rueckmesswert der Hardware angewiesen -- und wenn der fehlt,
    -- hat er gar keinen Bezugspunkt mehr (siehe rt2_turbine.lua).
    turbine_last_flow = {},
    -- Die vorige Drehzahlmessung je Turbine, mit ihrem Zeitstempel. Daraus
    -- rechnet rt2_turbine.compute_flow_decision() die Aenderungsrate und
    -- damit seinen Vorhalt (siehe dort). Zwei Zahlen je Turbine, ueber
    -- genau einen Takt -- kein Speicher, keine Kennlinie, kein Lernen.
    turbine_last_rpm = {},
    turbine_last_rpm_ms = {},
    -- Einheiten nach Name, damit ein Reaktor bei einer geaenderten
    -- Reihenfolge seinen Messzustand behaelt.
    reactors_by_name = {},
  }

  -- opts.reactors: { { name = <Peripheriename> }, ... }
  local function add_unit(spec)
    local unit = rt2_unit.new(spec)
    self.reactors[#self.reactors + 1] = unit
    if spec.name then self.reactors_by_name[spec.name] = unit end
    return unit
  end

  for _, spec in ipairs(opts.reactors or {}) do add_unit(spec) end
  if #self.reactors == 0 then
    add_unit({ name = opts.reactor_name })
  end

  -- Die Einheitenliste an die Reaktoren angleichen, die dieser Takt
  -- tatsaechlich mitbringt.
  --
  -- Warum das noetig ist: die Liste entstand bisher EINMAL beim Start aus
  -- opts.reactors. Bindet die Discovery den zweiten Reaktor erst spaeter
  -- -- und das ist der Normalfall, sie laeuft nach init() weiter --, dann
  -- brachte jeder Takt zwar zwei Messwerte, aber es gab nur EINE Einheit.
  -- "for index, unit in ipairs(self.reactors)" lief einmal, es entstand
  -- eine Entscheidung, und der zweite Reaktor wurde nie angefasst. Genau
  -- so im Spiel beobachtet: einer geregelt, einer nicht, waehrend die
  -- Turbinen sauber liefen (die werden ohnehin je Takt frisch aus
  -- input.turbines aufgebaut).
  --
  -- Nach NAME, nicht nach Position: ein Reaktor behaelt damit seinen
  -- Messzustand (Stellrate, Anlagenprofil, Sicherheitslage), auch wenn
  -- sich die Reihenfolge der Discovery aendert.
  local function reconcile(reactor_inputs)
    local named = 0
    for _, ri in ipairs(reactor_inputs or {}) do
      if ri.name then named = named + 1 end
    end
    -- Ein-Reaktor-Aufruf ohne Namen (Alt-Form): nichts anzugleichen.
    if named == 0 then return end

    local seen, ordered = {}, {}
    for _, ri in ipairs(reactor_inputs) do
      if ri.name then
        local unit = self.reactors_by_name[ri.name]
        if not unit then
          unit = rt2_unit.new({ name = ri.name })
          self.reactors_by_name[ri.name] = unit
        end
        seen[ri.name] = true
        ordered[#ordered + 1] = unit
      end
    end
    -- Verschwundene Reaktoren verlieren ihre Einheit -- sonst bekaeme ein
    -- abgebauter Reaktor weiter Entscheidungen, die ins Leere gehen.
    for name in pairs(self.reactors_by_name) do
      if not seen[name] then self.reactors_by_name[name] = nil end
    end
    self.reactors = ordered
  end

  function self.current_state()
    return self.machine.current()
  end

  function self.note_master_seen(now_ms)
    self.master_link.note_seen(now_ms)
  end

  -- Applies rt2_command_handler.M.handle()'s result to this orchestrator's
  -- own state and returns it unchanged so the caller (comms layer) can
  -- ACK it. A manual SCRAM latches until explicitly cleared -- exactly
  -- like the old module_lifecycle.scram()'s "manual reset required"
  -- behaviour, just with one obvious place that owns the latch instead of
  -- being spread across ctx.setState()/node_state_machine:transition()
  -- calls that could (and once did) fall out of sync.
  function self.handle_command(command)
    local result = rt2_command_handler.handle(command, { state = self.machine.current() })
    if result.ok and result.effects then
      if result.effects.manual_safety_trip then
        self.manual_safety_trip = true
      end
      -- Releases the manual latch only. A physical trip condition is
      -- re-evaluated from the live reading every tick (input.safety_tripped),
      -- so this cannot acknowledge away a reactor that is still over limit.
      if result.effects.clear_safety_trip then
        self.manual_safety_trip = false
      end
      if type(result.effects.master_percent) == "number" then
        self.master_percent = result.effects.master_percent
      end
    end
    return result
  end

  function self.clear_manual_safety_trip()
    self.manual_safety_trip = false
  end

  -- Die Rotation existiert einzig dafuer, dass unter MASTER nicht immer
  -- dieselben Turbinen im AUS-Slot sitzen. In jedem anderen Zustand
  -- verdreht sie nur die Zuordnung.
  local function rotated_slot(index, count, now_ms, state)
    if count <= 1 then return index end
    -- Die Rotation existiert nur dafuer, dass unter MASTER nicht immer
    -- dieselben Turbinen im AUS-Platz sitzen. In jedem anderen Zustand
    -- verdreht sie nur die Zuordnung.
    if state ~= rt2_state.states.MASTER then return index end
    if (now_ms or 0) - self.last_rotate_ms >= M.ROTATE_INTERVAL_MS then
      self.rotation_offset = (self.rotation_offset + 1) % count
      self.last_rotate_ms = now_ms or self.last_rotate_ms
    end
    return ((index - 1 + self.rotation_offset) % count) + 1
  end

  -- input:
  --   now_ms          -- aktuelle Epochenzeit in ms
  --   hardware_ready  -- Discovery hat Reaktor(en) UND Turbine(n)
  --   master_percent  -- Leistungsvorgabe (nur im Zustand MASTER genutzt)
  --   turbines        -- die GANZE Flotte: { { name, rpm, energy, coil_engaged, current_flow, active }, ... }
  --   reactors        -- je Reaktor { name, safety_tripped, reactor = { fill_ratio, current_rods, active } }
  --
  -- Der Ein-Reaktor-Aufruf von frueher (input.reactor/input.safety_tripped
  -- ohne reactors) wird weiter angenommen.
  function self.tick(input)
    input = input or {}
    local now_ms = input.now_ms

    local reactor_inputs = input.reactors
    if not reactor_inputs then
      reactor_inputs = { { reactor = input.reactor, safety_tripped = input.safety_tripped } }
    end

    reconcile(reactor_inputs)

    -- Erst messen, DANN den Zustand entscheiden -- mit den Messwerten
    -- desselben Takts.
    local tripped = 0
    for index, unit in ipairs(self.reactors) do
      local ri = reactor_inputs[index] or {}
      unit.observe({ now_ms = now_ms, safety_tripped = ri.safety_tripped, reactor = ri.reactor })
      if unit.safety_tripped then tripped = tripped + 1 end
    end

    -- Ein einzelner ausgeloester Reaktor faehrt nur SEINE Staebe ein; die
    -- Flotte laeuft auf dem Dampf der uebrigen weiter (bestaetigte
    -- Vorgabe). Erst wenn kein Reaktor mehr regelbar ist, geht der Knoten
    -- als Ganzes auf SAFE und stellt auch die Turbinen ab.
    local all_tripped = #self.reactors > 0 and tripped == #self.reactors

    local state = self.machine.tick({
      hardware_ready   = input.hardware_ready,
      master_connected = self.master_link.is_connected(now_ms),
      safety_tripped   = all_tripped or self.manual_safety_trip,
    })

    local reactor_decisions = {}
    for index, unit in ipairs(self.reactors) do
      local ri = reactor_inputs[index] or {}
      reactor_decisions[#reactor_decisions + 1] = unit.decide({
        now_ms = now_ms, node_state = state, reactor = ri.reactor,
      })
    end

    -- Die Flotte: EINE Entscheidung je Turbine, aus dem Zustand des
    -- Knotens. Ein ausgeloester Einzelreaktor aendert daran nichts.
    local count = #(input.turbines or {})

    -- WAEHREND DES EINLERNENS gilt die Vorgabe von MASTER nicht: die ganze
    -- Flotte faehrt auf die feste Zieldrehzahl (Betreibervorgabe, siehe
    -- oben). Nur so entsteht der Messpunkt -- und nur so kommt der Knoten
    -- ueberhaupt aus dem Stand heraus: MASTER teilt seinen Bedarf gegen
    -- capacity_max auf, das ist beim Start 0, also kaeme eine Vorgabe von
    -- 0 % zurueck, also liefe keine Turbine, also floesse nichts, also
    -- bliebe capacity_max 0.
    --
    -- Danach -- und das ist die zweite Haelfte der Vorgabe -- gilt wieder
    -- ganz normale Regelung nach MASTERs Prozentsatz.
    --
    -- Gemessen wird am ENDE des Takts (siehe unten), also gilt hier die
    -- Messung des vorigen -- ein Takt Verzug, der nichts ausmacht.
    local percent = input.master_percent or self.master_percent
    if self.capacity.learning then percent = 100 end

    local turbine_results = {}
    for index, t in ipairs(input.turbines or {}) do
      local target_rpm = rt2_turbine.compute_target_rpm(state, {
        turbine_count = count,
        slot_index = rotated_slot(index, count, now_ms, state),
        power_percent = percent,
      })
      local name = t.name
      local flow_decision = rt2_turbine.compute_flow_decision({
        rpm = t.rpm, target_rpm = target_rpm, current_flow = t.current_flow,
        coil_engaged = t.coil_engaged == true,
        -- Das Stellintervall braucht beide Zeiten; ohne sie faellt
        -- compute_flow_decision auf sein altes Verhalten zurueck.
        now_ms = now_ms,
        last_change_ms = name and self.turbine_last_change_ms[name] or nil,
        last_commanded_flow = name and self.turbine_last_flow[name] or nil,
        last_rpm = name and self.turbine_last_rpm[name] or nil,
        last_rpm_ms = name and self.turbine_last_rpm_ms[name] or nil,
      })

      -- Den Messpunkt fuer den naechsten Takt merken, BEVOR die Entscheidung
      -- weiterverarbeitet wird -- und nur, wenn wirklich gemessen wurde.
      -- Eine ausgefallene Messung darf den letzten gueltigen Punkt nicht
      -- ueberschreiben, sonst waere die Rate danach aus einer Luecke
      -- gerechnet.
      if name and tonumber(t.rpm) ~= nil then
        self.turbine_last_rpm[name] = tonumber(t.rpm)
        self.turbine_last_rpm_ms[name] = now_ms
      end
      -- Steht die Vorgabe schon so an, muss sie nicht erneut geschrieben
      -- werden. Das ist der Normalfall -- eine eingeschwungene Turbine
      -- wird gar nicht mehr verstellt -- und spart je Takt einen
      -- Peripherieaufruf pro Turbine.
      --
      -- Zwei Bedingungen muessen dafuer erfuellt sein, und beide fehlten
      -- im ersten Anlauf (Livetest node-101: 25 Turbinen bei vollem
      -- Durchfluss, geloester Spule und ohne jede Reaktion):
      --
      --   1. Es muss ein ECHTER Rueckmesswert vorliegen. Ist der
      --      Durchfluss nicht lesbar, ist er unbekannt -- und unbekannt
      --      ist nie ein Grund, das Schreiben zu unterlassen. Vorher kam
      --      hier eine vom Adapter erfundene 0 an, die zufaellig genau
      --      dem entsprach, was der Regler bei fehlender Drehzahl setzen
      --      wollte: die Vorgabe galt als erledigt und ging nie raus.
      --   2. Es darf keine SCHUTZentscheidung sein. Fehlende Drehzahl,
      --      Ueberdrehzahl und ein abgewaehlter Slot fahren den Dampf auf
      --      null -- solche Entscheidungen werden geschrieben, immer,
      --      auch wenn der Rueckmesswert behauptet, es staende schon so
      --      an. Eine Bremsung darf nicht an einer Ersparnis scheitern.
      local readback = tonumber(t.current_flow)
      local protective = flow_decision.reason == "NO_RPM_READING"
        or flow_decision.reason == "OVERSPEED"
        or flow_decision.reason == "TARGET_ZERO"
      if readback ~= nil and readback == flow_decision.flow and not protective then
        flow_decision.unchanged = true
      elseif name then
        self.turbine_last_change_ms[name] = now_ms
      end
      if name and flow_decision.unchanged ~= true then
        self.turbine_last_flow[name] = flow_decision.flow
      end
      turbine_results[#turbine_results + 1] = {
        name = name,
        target_rpm = target_rpm,
        flow_decision = flow_decision,
        coil_decision = rt2_turbine.compute_coil_decision({
          rpm = t.rpm, target_rpm = target_rpm, currently_engaged = t.coil_engaged,
        }),
        activate = rt2_turbine.compute_active_decision(t.active),
        rpm = t.rpm,
        coil_engaged = t.coil_engaged == true,
      }
    end

    -- Waehrend SAFE wird nicht gemessen: der Durchfluss ist dort erzwungen
    -- 0, was die Flotte dann liefert, beschreibt ihre Leistung nicht.
    if state ~= rt2_state.states.SAFE then
      self.capacity = measure_capacity(self.capacity, input.turbines, now_ms)
    end

    local first = reactor_decisions[1]
    return {
      state = state,
      -- Die tatsaechlich wirksame Leistungsvorgabe. Ohne sie kann keine
      -- Anzeige sagen, WARUM eine Turbine gerade steht -- die RT-eigene
      -- Oberflaeche zeigte stattdessen v1's nie gefuellten Sollwert (also
      -- dauerhaft 0 %), waehrend der Knoten in Wahrheit auf 100 % regelte.
      master_percent = input.master_percent or self.master_percent,
      -- Was in DIESEM Takt wirklich gegolten hat. Weicht es von
      -- master_percent ab, laeuft die Flotte voll, weil noch keine
      -- Leistung gemeldet ist (siehe oben).
      effective_percent = percent,
      reactors = reactor_decisions,
      -- Ein-Reaktor-Sicht, unveraendert fuer alle bestehenden Leser.
      reactor_decision = first,
      turbines = turbine_results,
      capacity = self.capacity,
      tripped_reactors = tripped,
    }
  end

  return self
end

return M
