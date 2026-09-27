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
-- Frueher lief dafuer eine eigene Lernphase (rt2_capacity): ein Suchlauf,
-- der Turbinen stufenweise freigab, auf einen tragenden Betriebspunkt
-- wartete, einen Hoechstwert mit Sicherheitsabschlag bildete und ihn in
-- einer eigenen Datei ablegte -- mit einem eigenen Zustand im
-- Zustandsautomaten davor und mehreren Wegen, auf denen er haengenblieb.
--
-- Gemessen wird jetzt nur noch MITGESCHRIEBEN: der hoechste Gesamtausstoss,
-- den diese Flotte in diesem Lauf schon geliefert hat. Das ist immer eine
-- Zahl, die wirklich geflossen ist -- sie verspricht MASTER also nie zu
-- viel. Zu WENIG darf sie behaupten, und das korrigiert sich von selbst:
-- teilt MASTER gegen eine zu kleine Kapazitaet auf, fordert er einen
-- hoeheren Prozentsatz, es laufen mehr Turbinen, der Ausstoss steigt --
-- und damit der mitgeschriebene Hoechstwert.
--
-- Der Hoechstwert verfaellt nicht von allein, aber eine geaenderte
-- Turbinenzahl setzt ihn zurueck: eine abgebaute Turbine darf nicht in
-- einer Zahl weiterleben, die MASTER fuer belastbar haelt.
function M.new_output_state()
  return { max_output = 0, at_target = 0, total_turbines = 0, ready = false, reason = "NO_TURBINES" }
end

local function observe_output(previous, turbines)
  local sum, at_target, count = 0, 0, 0
  for _, t in ipairs(turbines or {}) do
    count = count + 1
    sum = sum + (tonumber(t.energy) or 0)
    local rpm = tonumber(t.rpm)
    if rpm and math.abs(rpm - rt2_turbine.FULL_TARGET_RPM) <= rt2_turbine.RPM_BAND then
      at_target = at_target + 1
    end
  end

  local peak = tonumber(previous and previous.max_output) or 0
  if count ~= (tonumber(previous and previous.total_turbines) or 0) then peak = 0 end
  if sum > peak then peak = sum end

  local reason = "OBSERVED"
  if count == 0 then
    reason = "NO_TURBINES"
  elseif peak <= 0 then
    reason = "NO_OUTPUT"
  end

  return {
    max_output = peak,
    at_target = at_target,
    total_turbines = count,
    ready = peak > 0,
    reason = reason,
  }
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

    -- Leistungsmeldung mitschreiben. Waehrend SAFE nicht: der Durchfluss
    -- ist dort erzwungen 0, was die Flotte dann liefert, beschreibt ihre
    -- Leistung nicht.
    if state ~= rt2_state.states.SAFE then
      self.capacity = observe_output(self.capacity, input.turbines)
    end

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

    -- Solange der Knoten noch keine Leistung gemeldet hat, gilt die
    -- Vorgabe von MASTER NICHT -- die ganze Flotte laeuft.
    --
    -- Sonst schliesst sich ein Kreis, aus dem der Knoten nicht mehr
    -- herauskommt: MASTER teilt seinen Bedarf gegen capacity_max auf, das
    -- ist beim Start 0, also kommt eine Vorgabe von 0 % an, also laeuft
    -- keine Turbine, also fliesst kein Ausstoss, also bleibt capacity_max
    -- 0. Frueher hielt die Lernphase diesen Kreis auf; die ist weg, also
    -- steht die Bedingung jetzt hier -- an der einen Stelle, die sie
    -- braucht.
    local percent = input.master_percent or self.master_percent
    if not self.capacity.ready then percent = 100 end

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
      })
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
