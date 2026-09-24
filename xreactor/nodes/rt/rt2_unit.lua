-- RT rewrite, step 13: EINE Einheit = ein Reaktor mit seinen Turbinen.
--
-- Bis hierher kannte v2 genau einen Reaktor, und der Orchestrator hielt
-- dessen Zustand direkt. Eine Anlage mit zwei Reaktoren, die jeweils ihre
-- eigenen Turbinen speisen, ist damit nicht abbildbar: Der Dampftank, aus
-- dem der Reaktor regelt, gehoert zu SEINEN Turbinen -- regelte man ihn
-- gegen die Gesamtflotte, zoege die Last der anderen Gruppe mit, und beide
-- Regler arbeiteten gegeneinander.
--
-- Deshalb ist die Einheit jetzt die Klammer: eigener Dampftank, eigene
-- Turbinen, eigenes Einlernen, eigene Sicherheitsbewertung, eigenes
-- Anlagenprofil. Was zwischen Einheiten geteilt wird, bleibt beim
-- Orchestrator -- der Betriebszustand (einer fuer den ganzen Knoten) und
-- die MASTER-Verbindung.
--
-- Die Entscheidungen selbst liegen weiterhin in den reinen Funktionen
-- (rt2_reactor, rt2_turbine, rt2_capacity, rt2_tuning); diese Datei
-- sequenziert sie nur fuer eine Einheit und haelt deren Zustand.

local rt2_capacity = require('nodes.rt.rt2_capacity')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_reactor = require('nodes.rt.rt2_reactor')
local rt2_tuning = require('nodes.rt.rt2_tuning')
local rt2_state = require('nodes.rt.rt2_state')

local M = {}

M.ROTATE_INTERVAL_MS = 300000 -- 5 min: wie oft der AUS/PUFFER-Platz wandert

-- opts.name            -- Peripheriename des Reaktors (Schluessel fuer Cache/Diagnose)
-- opts.initial_capacity -- aus dem Cache geladene Kapazitaet dieser Einheit
-- opts.tuning_profile   -- gemessenes Anlagenprofil dieser Einheit
function M.new(opts)
  opts = opts or {}
  local self = {
    name = opts.name,
    capacity = opts.initial_capacity or rt2_capacity.new_state(),
    tuning_state = rt2_tuning.new_state(),
    tuning_profile = opts.tuning_profile,
    rotation_offset = 0,
    last_rotate_ms = 0,
    last_rod_change_ms = 0,
    last_rod_fill = nil,
    -- Eine ausgeloeste Einheit faehrt ihre eigenen Staebe ein und stellt
    -- ihre eigenen Turbinen ab -- der Rest der Anlage laeuft weiter
    -- (bestaetigte Vorgabe). Nur wenn ALLE Einheiten ausgeloest haben,
    -- geht auch der Knoten als Ganzes auf SAFE.
    safety_tripped = false,
  }

  -- Die Rotation existiert nur dafuer, dass unter MASTER nicht immer
  -- dieselben Turbinen im AUS-Platz sitzen. In jedem anderen Zustand
  -- verdreht sie nur die Zuordnung und bleibt deshalb aus.
  local function rotated_slot(index, count, now_ms, node_state)
    if count <= 1 then return index end
    if node_state ~= rt2_state.states.MASTER then return index end
    if (now_ms or 0) - self.last_rotate_ms >= M.ROTATE_INTERVAL_MS then
      self.rotation_offset = (self.rotation_offset + 1) % count
      self.last_rotate_ms = now_ms or self.last_rotate_ms
    end
    return ((index - 1 + self.rotation_offset) % count) + 1
  end

  -- MESSEN. Laeuft fuer alle Einheiten, BEVOR der Betriebszustand
  -- entschieden wird -- sonst verliesse eine fertig eingelernte Anlage
  -- die Lernphase einen Takt zu spaet (dieselbe Reihenfolge-Zusage wie
  -- im Ein-Reaktor-Entwurf, siehe rt2_engine.tick()).
  --
  -- input: now_ms, safety_tripped (DIESER Einheit), reactor, turbines
  function self.observe(input)
    input = input or {}
    local now_ms = input.now_ms
    self.safety_tripped = input.safety_tripped == true

    -- Eine ausgeloeste Einheit misst nicht: ihre Staebe sind eingefahren,
    -- was dort gemessen wuerde, beschriebe keine Regelung.
    if self.safety_tripped then return self end

    self.capacity = rt2_capacity.update(self.capacity, input.turbines, { now_ms = now_ms })

    local reactor_fill = input.reactor and input.reactor.fill_ratio or nil
    if reactor_fill then
      self.tuning_state = rt2_tuning.observe(self.tuning_state, {
        now_ms = now_ms, fill = reactor_fill,
        rods = input.reactor and input.reactor.current_rods or nil,
      })
      if not self.tuning_profile then
        local profile = rt2_tuning.derive(self.tuning_state,
          { proportional_band = rt2_reactor.PROPORTIONAL_BAND })
        if profile then self.tuning_profile = profile end
      end
    end

    return self
  end

  -- ENTSCHEIDEN. Braucht den inzwischen feststehenden Betriebszustand.
  function self.decide(input)
    input = input or {}
    local now_ms = input.now_ms
    local node_state = input.node_state or rt2_state.states.INIT
    local override = self.safety_tripped or node_state == rt2_state.states.SAFE
    local reactor_fill = input.reactor and input.reactor.fill_ratio or nil

    local tuned_interval = self.tuning_profile and self.tuning_profile.min_adjust_interval_ms
      or rt2_reactor.MIN_ADJUST_INTERVAL_MS
    local adjust_due = (now_ms or 0) - self.last_rod_change_ms >= tuned_interval

    local reactor_decision = rt2_reactor.compute_rod_level({
      fill_ratio = reactor_fill,
      target_fill = input.reactor and input.reactor.target_fill or nil,
      current_rods = input.reactor and input.reactor.current_rods or nil,
      safety_override = override,
      previous_fill = adjust_due and self.last_rod_fill or nil,
      max_step = self.tuning_profile and self.tuning_profile.max_step or nil,
    })

    -- Nur die gewoehnliche Tankregelung wird verzoegert; eine Ausloesung
    -- und jeder andere Sicherheitspfad wirkt sofort.
    if not adjust_due
        and (reactor_decision.reason == "TANK_FULL_INSERT" or reactor_decision.reason == "TANK_LOW_WITHDRAW") then
      local current_rods = tonumber(input.reactor and input.reactor.current_rods)
      if current_rods then
        reactor_decision = { rods = current_rods, reason = "RATE_LIMITED" }
      end
    end

    if adjust_due then
      self.last_rod_change_ms = now_ms or self.last_rod_change_ms
      self.last_rod_fill = reactor_fill
    end

    -- Einen ausgeloesten Reaktor NICHT wieder einschalten -- sonst
    -- kaempfte die Einschaltlogik gegen die Sicherheitsabschaltung.
    reactor_decision.activate = (not override)
      and rt2_reactor.compute_active_decision(input.reactor and input.reactor.active)
      or false

    -- Eine ausgeloeste Einheit stellt ihre Turbinen ab; sonst gilt der
    -- Zustand des Knotens.
    local turbine_state = override and rt2_state.states.SAFE or node_state
    local count = #(input.turbines or {})
    local max_active
    if turbine_state ~= rt2_state.states.LEARNING
        and self.capacity.ready and (self.capacity.sustainable_turbines or 0) > 0 then
      max_active = self.capacity.sustainable_turbines
    end

    local results = {}
    for index, t in ipairs(input.turbines or {}) do
      local target_rpm = rt2_turbine.compute_target_rpm(turbine_state, {
        turbine_count = count,
        slot_index = rotated_slot(index, count, now_ms, turbine_state),
        power_percent = input.master_percent,
        max_active = max_active,
      })
      results[#results + 1] = {
        name = t.name,
        unit = self.name,
        target_rpm = target_rpm,
        flow_decision = rt2_turbine.compute_flow_decision({
          rpm = t.rpm, target_rpm = target_rpm, current_flow = t.current_flow,
        }),
        coil_decision = rt2_turbine.compute_coil_decision({
          rpm = t.rpm, target_rpm = target_rpm, currently_engaged = t.coil_engaged,
        }),
        -- Eine ausgeloeste Einheit schaltet ihre Turbinen nicht wieder ein.
        activate = (not override) and rt2_turbine.compute_active_decision(t.active) or false,
        rpm = t.rpm,
        coil_engaged = t.coil_engaged == true,
      }
    end

    return {
      name = self.name,
      reactor_decision = reactor_decision,
      turbines = results,
      capacity = self.capacity,
      max_active = max_active,
      safety_tripped = self.safety_tripped,
      tuning = self.tuning_profile,
      tuning_samples = self.tuning_state.n,
    }
  end

  return self
end

return M
