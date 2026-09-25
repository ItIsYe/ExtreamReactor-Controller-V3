-- RT rewrite, step 6: der Orchestrator -- ein Takt fuer den ganzen Knoten.
--
-- Der Knoten fasst seine Anlage als EIN System auf: eine Turbinenflotte
-- an einem gemeinsamen Dampfnetz, eine gelernte Kapazitaet, eine
-- Leistungsvorgabe. Mehrere Reaktoren speisen dasselbe Netz und regeln
-- sich unabhaengig voneinander aus ihrem JEWEILIGEN Dampftank (siehe
-- rt2_unit.lua) -- sie stimmen sich nicht ab und brauchen es auch nicht:
-- zieht die Flotte mehr, fallen alle Taenke, alle fahren die Staebe aus.
--
-- Hier liegt deshalb alles, wovon es pro Knoten eines gibt: der
-- Betriebszustand, die MASTER-Verbindung, der Hand-Riegel, die
-- Leistungsvorgabe, das Einlernen und die Slot-Rotation der Flotte.
--
-- Hardware-frei wie bisher: M.tick() nimmt schlichte Messwert-Tabellen
-- und gibt schlichte Entscheidungs-Tabellen zurueck.

local rt2_state = require('nodes.rt.rt2_state')
local rt2_capacity = require('nodes.rt.rt2_capacity')
local rt2_master_link = require('nodes.rt.rt2_master_link')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_command_handler = require('nodes.rt.rt2_command_handler')
local rt2_unit = require('nodes.rt.rt2_unit')

local M = {}

M.ROTATE_INTERVAL_MS = 300000 -- 5 min: wie oft der AUS/PUFFER-Platz wandert

function M.new(opts)
  opts = opts or {}
  local self = {
    machine = rt2_state.new(opts.initial_state),
    master_link = rt2_master_link.new({ timeout_ms = opts.master_timeout_ms }),
    manual_safety_trip = false,
    master_percent = 100,
    -- EINE Kapazitaet fuer den ganzen Knoten: die Turbinen haengen alle am
    -- selben Dampfnetz, also ist ihre Summe die Leistung dieses Knotens --
    -- egal, wie viele Reaktoren sie speisen.
    capacity = opts.initial_capacity or rt2_capacity.new_state(),
    rotation_offset = 0,
    last_rotate_ms = 0,
    reactors = {},
  }

  -- opts.reactors: { { name = <Peripheriename>, tuning_profile = ... }, ... }
  for _, spec in ipairs(opts.reactors or {}) do
    self.reactors[#self.reactors + 1] = rt2_unit.new(spec)
  end
  if #self.reactors == 0 then
    self.reactors[1] = rt2_unit.new({ name = opts.reactor_name, tuning_profile = opts.tuning_profile })
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
  -- verdreht sie nur die Zuordnung -- und waehrend des gestaffelten
  -- Einlernens ist das direkt schaedlich: rt2_capacity misst die ersten
  -- `released` Turbinen in LESEREIHENFOLGE, freigegeben wird aber nach
  -- SLOT. Rotiert der Slot, laeuft Turbine 25 und gemessen wird Turbine 1
  -- -- der Suchlauf sieht dann nie eine tragende Stufe und kommt nie vom
  -- Fleck. Ausserdem soll waehrend der Suche ohnehin dieselbe Turbine
  -- oben bleiben, waehrend die naechste dazukommt.
  local function rotated_slot(turbine_index, turbine_count, now_ms, state)
    if turbine_count <= 1 then return turbine_index end
    if state ~= rt2_state.states.MASTER then return turbine_index end
    if (now_ms or 0) - self.last_rotate_ms >= M.ROTATE_INTERVAL_MS then
      self.rotation_offset = (self.rotation_offset + 1) % turbine_count
      self.last_rotate_ms = now_ms or self.last_rotate_ms
    end
    return ((turbine_index - 1 + self.rotation_offset) % turbine_count) + 1
  end

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

    -- Erst messen, DANN den Zustand entscheiden -- mit den Messwerten
    -- desselben Takts. Andersherum verliesse eine fertig eingelernte
    -- Flotte die Lernphase einen Takt zu spaet.
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

    local current_state = self.machine.current()
    if current_state ~= rt2_state.states.SAFE then
      self.capacity = rt2_capacity.update(self.capacity, input.turbines, { now_ms = now_ms })
    end

    local state = self.machine.tick({
      hardware_ready   = input.hardware_ready,
      capacity_ready   = self.capacity.ready,
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
    local max_active
    if state ~= rt2_state.states.LEARNING
        and self.capacity.ready and (self.capacity.sustainable_turbines or 0) > 0 then
      max_active = self.capacity.sustainable_turbines
    end

    local turbine_results = {}
    for index, t in ipairs(input.turbines or {}) do
      local target_rpm = rt2_turbine.compute_target_rpm(state, {
        turbine_count = count,
        slot_index = rotated_slot(index, count, now_ms, state),
        power_percent = input.master_percent or self.master_percent,
        max_active = max_active,
      })
      turbine_results[#turbine_results + 1] = {
        name = t.name,
        target_rpm = target_rpm,
        flow_decision = rt2_turbine.compute_flow_decision({
          rpm = t.rpm, target_rpm = target_rpm, current_flow = t.current_flow,
        }),
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
      reactors = reactor_decisions,
      -- Ein-Reaktor-Sicht, unveraendert fuer alle bestehenden Leser.
      reactor_decision = first,
      turbines = turbine_results,
      capacity = self.capacity,
      max_active = max_active,
      tripped_reactors = tripped,
      tuning = self.reactors[1] and self.reactors[1].tuning_profile or nil,
      tuning_samples = self.reactors[1] and self.reactors[1].tuning_state.n or 0,
    }
  end

  return self
end

return M
