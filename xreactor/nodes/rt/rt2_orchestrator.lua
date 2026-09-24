-- RT rewrite, step 6: der Orchestrator -- jetzt Koordinator ueber
-- EINHEITEN (je ein Reaktor mit seinen Turbinen, siehe rt2_unit.lua).
--
-- Was hier bleibt, ist genau das, wovon es pro KNOTEN nur eines gibt:
-- der Betriebszustand, die MASTER-Verbindung, der Hand-Riegel und die
-- Leistungsvorgabe. Alles, was zu einem Reaktor und seinen Turbinen
-- gehoert -- Tankregelung, Einlernen, Selbstvermessung, Sicherheitslage,
-- Slot-Rotation -- liegt in der Einheit, weil zwei Reaktoren mit eigenen
-- Turbinen sonst gegeneinander regeln wuerden.
--
-- Hardware-frei wie bisher: M.tick() nimmt schlichte Messwert-Tabellen
-- und gibt schlichte Entscheidungs-Tabellen zurueck.

local rt2_state = require('nodes.rt.rt2_state')
local rt2_capacity = require('nodes.rt.rt2_capacity')
local rt2_master_link = require('nodes.rt.rt2_master_link')
local rt2_command_handler = require('nodes.rt.rt2_command_handler')
local rt2_unit = require('nodes.rt.rt2_unit')

local M = {}

M.ROTATE_INTERVAL_MS = rt2_unit.ROTATE_INTERVAL_MS

function M.new(opts)
  opts = opts or {}
  local self = {
    machine = rt2_state.new(opts.initial_state),
    master_link = rt2_master_link.new({ timeout_ms = opts.master_timeout_ms }),
    manual_safety_trip = false,
    master_percent = 100,
    units = {},
    units_by_name = {},
  }

  -- opts.units: { { name = <Reaktorname>, initial_capacity = ..., tuning_profile = ... }, ... }
  -- Fehlt die Liste, wird die erste Einheit beim ersten Takt angelegt --
  -- so bleibt der Ein-Reaktor-Fall ohne Konfiguration lauffaehig.
  for _, spec in ipairs(opts.units or {}) do
    local unit = rt2_unit.new(spec)
    self.units[#self.units + 1] = unit
    if spec.name then self.units_by_name[spec.name] = unit end
  end
  if #self.units == 0 then
    local unit = rt2_unit.new({
      name = opts.unit_name,
      initial_capacity = opts.initial_capacity,
      tuning_profile = opts.tuning_profile,
    })
    self.units[1] = unit
    if opts.unit_name then self.units_by_name[opts.unit_name] = unit end
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

  -- input:
  --   now_ms          -- aktuelle Epochenzeit in ms
  --   hardware_ready  -- Discovery hat je Einheit Reaktor UND Turbine(n)
  --   master_percent  -- Leistungsvorgabe (nur im Zustand MASTER genutzt)
  --   units           -- je Einheit { name, safety_tripped, reactor, turbines }
  --
  -- Der Ein-Reaktor-Aufruf von frueher (input.reactor/input.turbines/
  -- input.safety_tripped ohne units) wird weiter angenommen und auf eine
  -- einzelne Einheit abgebildet.
  function self.tick(input)
    input = input or {}
    local now_ms = input.now_ms

    local unit_inputs = input.units
    if not unit_inputs then
      unit_inputs = { {
        reactor = input.reactor,
        turbines = input.turbines,
        safety_tripped = input.safety_tripped,
      } }
    end

    -- Eine Ausloesung an EINER Einheit faehrt nur deren Reaktor ein. Der
    -- Knoten als Ganzes geht erst auf SAFE, wenn keine Einheit mehr
    -- regelbar ist -- oder wenn von Hand abgeschaltet wurde (bestaetigte
    -- Vorgabe: die beiden Reaktoren sind unabhaengig gesteuert).
    local tripped_units = 0
    for index in ipairs(unit_inputs) do
      if unit_inputs[index].safety_tripped then tripped_units = tripped_units + 1 end
    end
    local all_tripped = #unit_inputs > 0 and tripped_units == #unit_inputs

    -- Erst messen, DANN den Zustand entscheiden -- mit den Messwerten
    -- desselben Takts. Andersherum verliesse eine fertig eingelernte
    -- Anlage die Lernphase einen Takt zu spaet.
    local capacity_ready_units = 0
    for index, unit in ipairs(self.units) do
      local ui = unit_inputs[index] or {}
      unit.observe({
        now_ms = now_ms, safety_tripped = ui.safety_tripped,
        reactor = ui.reactor, turbines = ui.turbines,
      })
      if unit.capacity.ready then capacity_ready_units = capacity_ready_units + 1 end
    end

    local state = self.machine.tick({
      hardware_ready   = input.hardware_ready,
      capacity_ready   = capacity_ready_units >= #self.units and #self.units > 0,
      master_connected = self.master_link.is_connected(now_ms),
      safety_tripped   = all_tripped or self.manual_safety_trip,
    })

    local unit_results, turbines = {}, {}
    local total_max_output, total_at_target, total_turbines, total_saturated = 0, 0, 0, 0
    local all_ready, any_ready = #self.units > 0, false
    local sustainable_total = 0

    for index, unit in ipairs(self.units) do
      local ui = unit_inputs[index] or {}
      local result = unit.decide({
        now_ms = now_ms,
        node_state = state,
        reactor = ui.reactor,
        turbines = ui.turbines,
        -- Die Vorgabe gilt fuer JEDE Einheit gleich: MASTER fordert einen
        -- Anteil der Knotenleistung, und jede Einheit steuert ihren Anteil
        -- ihrer eigenen Kapazitaet bei. Damit bleibt die Summe richtig,
        -- ohne dass eine Einheit die andere mitziehen muss.
        master_percent = input.master_percent or self.master_percent,
      })
      unit_results[#unit_results + 1] = result
      for _, t in ipairs(result.turbines) do turbines[#turbines + 1] = t end

      local cap = result.capacity
      total_max_output = total_max_output + (cap.max_output or 0)
      total_at_target = total_at_target + (cap.at_target or 0)
      total_turbines = total_turbines + (cap.total_turbines or 0)
      total_saturated = total_saturated + (cap.saturated or 0)
      sustainable_total = sustainable_total + (cap.sustainable_turbines or 0)
      if cap.ready then any_ready = true else all_ready = false end
    end

    -- Was MASTER liest, ist die SUMME ueber die Einheiten: er teilt seinen
    -- Bedarf gegen die Leistung des ganzen Knotens auf, nicht gegen die
    -- eines einzelnen Reaktors.
    local capacity = {
      ready = all_ready,
      max_output = total_max_output,
      at_target = total_at_target,
      total_turbines = total_turbines,
      saturated = total_saturated,
      sustainable_turbines = sustainable_total,
      required_at_target = nil,
      reason = all_ready and "MEASURED" or (any_ready and "PARTIAL" or "MEASURING"),
    }
    if #self.units == 1 then
      -- Ein-Reaktor-Knoten: unveraendert die Kapazitaet der Einheit selbst
      -- durchreichen, damit Diagnose und Gruende erhalten bleiben.
      capacity = unit_results[1].capacity
    end

    local first = unit_results[1] or {}
    return {
      state = state,
      units = unit_results,
      -- Ein-Reaktor-Sicht, unveraendert fuer alle bestehenden Leser.
      reactor_decision = first.reactor_decision,
      turbines = turbines,
      capacity = capacity,
      max_active = first.max_active,
      tuning = first.tuning,
      tuning_samples = first.tuning_samples,
    }
  end

  return self
end

return M
