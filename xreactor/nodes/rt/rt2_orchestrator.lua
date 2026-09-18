-- RT rewrite, step 6: the orchestrator that ties rt2_state/rt2_capacity/
-- rt2_master_link/rt2_turbine/rt2_reactor together into one tick.
--
-- This is still hardware-free: M.tick() takes plain reading tables in and
-- returns plain decision tables out. Peripheral I/O (reading real rpm/
-- flow/coil state, writing setFluidFlowRate/setInductorEngaged/rod
-- levels) is a thin adapter that main.lua wires in during the actual
-- cutover -- deliberately kept out of this module so the full per-tick
-- decision sequence stays testable exactly like the pieces it calls.

local rt2_state = require('nodes.rt.rt2_state')
local rt2_capacity = require('nodes.rt.rt2_capacity')
local rt2_master_link = require('nodes.rt.rt2_master_link')
local rt2_turbine = require('nodes.rt.rt2_turbine')
local rt2_reactor = require('nodes.rt.rt2_reactor')
local rt2_command_handler = require('nodes.rt.rt2_command_handler')

local M = {}

M.ROTATE_INTERVAL_MS = 300000 -- 5 min: how often the AUS/PUFFER slot rotates

function M.new(opts)
  opts = opts or {}
  local self = {
    machine = rt2_state.new(opts.initial_state),
    -- A caller that already loaded a persisted capacity (see
    -- rt2_capacity.load()) passes it in here so a restart doesn't have
    -- to relearn from zero -- see rt2_engine.lua's init().
    capacity = opts.initial_capacity or rt2_capacity.new_state(),
    master_link = rt2_master_link.new({ timeout_ms = opts.master_timeout_ms }),
    rotation_offset = 0,
    last_rotate_ms = 0,
    manual_safety_trip = false,
    master_percent = 100,
  }

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
      if type(result.effects.master_percent) == "number" then
        self.master_percent = result.effects.master_percent
      end
    end
    return result
  end

  function self.clear_manual_safety_trip()
    self.manual_safety_trip = false
  end

  local function rotated_slot(turbine_index, turbine_count, now_ms)
    if turbine_count <= 1 then return turbine_index end
    if (now_ms or 0) - self.last_rotate_ms >= M.ROTATE_INTERVAL_MS then
      self.rotation_offset = (self.rotation_offset + 1) % turbine_count
      self.last_rotate_ms = now_ms or self.last_rotate_ms
    end
    return ((turbine_index - 1 + self.rotation_offset) % turbine_count) + 1
  end

  -- input:
  --   now_ms          -- current epoch ms
  --   hardware_ready  -- discovery has found at least one reactor+turbine
  --   safety_tripped  -- true while any active safety condition holds
  --   reactor         -- { fill_ratio }
  --   turbines        -- array of { name, rpm, energy, coil_engaged, current_flow }
  --   master_percent  -- MASTER's requested power percentage (only used in MASTER state)
  --
  -- returns:
  --   state             -- the resulting rt2_state after this tick
  --   reactor_decision  -- { rods, reason } from rt2_reactor
  --   turbines          -- array of { name, target_rpm, flow_decision, coil_decision }
  --   capacity          -- the updated capacity state
  function self.tick(input)
    input = input or {}
    local now_ms = input.now_ms

    -- Capacity learning is measured BEFORE the state decision, using this
    -- same tick's turbine readings -- so a fleet that reaches target RPM
    -- moves out of LEARNING on the very same tick, not one tick late.
    -- Runs whenever the node isn't SAFE (also kept warm during AUTONOM/
    -- MASTER so a later topology change is picked up without forcing a
    -- full LEARNING replay; rt2_state only re-enters LEARNING from INIT).
    local current_state = self.machine.current()
    if current_state ~= rt2_state.states.SAFE then
      self.capacity = rt2_capacity.update(self.capacity, input.turbines)
    end

    local state = self.machine.tick({
      hardware_ready   = input.hardware_ready,
      capacity_ready   = self.capacity.ready,
      master_connected = self.master_link.is_connected(now_ms),
      safety_tripped   = input.safety_tripped or self.manual_safety_trip,
    })

    local safety_override = (state == rt2_state.states.SAFE)
    local reactor_decision = rt2_reactor.compute_rod_level({
      fill_ratio = input.reactor and input.reactor.fill_ratio or nil,
      target_fill = input.reactor and input.reactor.target_fill or nil,
      current_rods = input.reactor and input.reactor.current_rods or nil,
      safety_override = safety_override,
    })

    local turbine_count = #(input.turbines or {})
    local turbine_results = {}
    for index, t in ipairs(input.turbines or {}) do
      local slot_index = rotated_slot(index, turbine_count, now_ms)
      local target_rpm = rt2_turbine.compute_target_rpm(state, {
        turbine_count = turbine_count,
        slot_index = slot_index,
        power_percent = input.master_percent or self.master_percent,
      })
      local flow_decision = rt2_turbine.compute_flow_decision({
        rpm = t.rpm, target_rpm = target_rpm, current_flow = t.current_flow,
      })
      local coil_decision = rt2_turbine.compute_coil_decision({
        rpm = t.rpm, target_rpm = target_rpm, currently_engaged = t.coil_engaged,
      })
      turbine_results[#turbine_results + 1] = {
        name = t.name,
        target_rpm = target_rpm,
        flow_decision = flow_decision,
        coil_decision = coil_decision,
      }
    end

    return {
      state = state,
      reactor_decision = reactor_decision,
      turbines = turbine_results,
      capacity = self.capacity,
    }
  end

  return self
end

return M
