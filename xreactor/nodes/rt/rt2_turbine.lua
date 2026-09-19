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
M.COIL_ENGAGE_RPM = 900
M.COIL_DISENGAGE_RPM = 850
M.MIN_FLOW = 0
M.MAX_FLOW = 32000
M.TRIM_STEP = 35

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ── Target RPM ───────────────────────────────────────────────────────────
--
-- Spec (confirmed with the operator, 2026-09-18):
--   - LEARNING: every turbine targets the fixed FULL_TARGET_RPM,
--     unconditionally -- this must never depend on MASTER presence.
--   - AUTONOM (capacity known, no MASTER): turbines still target the
--     fixed FULL_TARGET_RPM. The reactor -- not the turbines -- is what
--     regulates independently from the steam tank in this mode (see
--     rt2_reactor.lua).
--   - MASTER: split the fleet by the master-requested power percentage
--     into VOLLAST (full target) / PUFFER (one partial-RPM turbine) / AUS
--     (0 RPM) slots, rotating which slots are AUS/PUFFER over time so no
--     turbine sits cold forever (rotation is the caller's job -- this
--     function takes the already-rotated slot_index).
--   - SAFE: 0 for everyone.
function M.compute_target_rpm(state, opts)
  opts = opts or {}
  if state == "SAFE" then
    return 0
  end
  if state == "LEARNING" or state == "AUTONOM" then
    return M.FULL_TARGET_RPM
  end
  if state == "MASTER" then
    local n = tonumber(opts.turbine_count) or 0
    if n <= 0 then return M.FULL_TARGET_RPM end
    local slot_index = tonumber(opts.slot_index) or 1
    local percent = clamp(tonumber(opts.power_percent) or 100, 0, 100)

    local exact = percent / 100 * n
    local full = math.floor(exact)
    local remainder = exact - full
    local has_partial = remainder > 0.001 and full < n
    local partial_rpm = has_partial and math.max(1, math.floor(M.FULL_TARGET_RPM * remainder + 0.5)) or 0
    local off_count = n - full - (has_partial and 1 or 0)

    if slot_index <= off_count then
      return 0
    elseif has_partial and slot_index == off_count + 1 then
      return partial_rpm
    else
      return M.FULL_TARGET_RPM
    end
  end
  return M.FULL_TARGET_RPM
end

-- ── Flow decision ────────────────────────────────────────────────────────
--
-- target_rpm <= 0 (AUS slot, or SAFE) and genuine overspeed (rpm far above
-- target) are handled by the SAME "cut flow to zero now" rule -- the old
-- code treated target<=0 as a reason to skip protection entirely, which is
-- exactly what let an AUS-slot turbine spin at thousands of RPM on full
-- flow (reported 2026-09-18, node-101/102/103 screenshots).
function M.compute_flow_decision(input)
  local rpm = tonumber(input.rpm) or 0
  local target_rpm = tonumber(input.target_rpm) or 0
  local current_flow = tonumber(input.current_flow) or 0
  local min_flow = tonumber(input.min_flow) or M.MIN_FLOW
  local max_flow = tonumber(input.max_flow) or M.MAX_FLOW
  local band = tonumber(input.band) or M.RPM_BAND

  if target_rpm <= 0 then
    return { flow = 0, reason = "TARGET_ZERO" }
  end
  if rpm > target_rpm + band then
    return { flow = 0, reason = "OVERSPEED" }
  end

  local error_rpm = target_rpm - rpm
  if error_rpm > band then
    -- well under target: open up, but never overshoot straight to max in
    -- one step (the physical rotor takes time to respond).
    return { flow = clamp(current_flow + M.TRIM_STEP, min_flow, max_flow), reason = "RAMP_UP" }
  end
  if error_rpm < -band then
    return { flow = clamp(current_flow - M.TRIM_STEP, min_flow, max_flow), reason = "RAMP_DOWN" }
  end
  -- Inside the band: hold, with a small trim toward the exact target so a
  -- turbine that entered the band already at max/min flow doesn't get
  -- stuck there once it doesn't need to be.
  if error_rpm > 0 and current_flow < max_flow then
    return { flow = clamp(current_flow + 1, min_flow, max_flow), reason = "HOLD_TRIM_UP" }
  end
  if error_rpm < 0 and current_flow > min_flow then
    return { flow = clamp(current_flow - 1, min_flow, max_flow), reason = "HOLD_TRIM_DOWN" }
  end
  return { flow = current_flow, reason = "HOLD" }
end

-- ── Coil decision ────────────────────────────────────────────────────────
--
-- One hysteresis rule, scaled to the CURRENT target (a PUFFER-slot turbine
-- at 450 RPM must engage/disengage around 450, not around the full 900).
-- target_rpm<=0 (AUS/SAFE) always disengages -- there is nothing to
-- extract energy from a turbine that is supposed to be off.
function M.compute_coil_decision(input)
  local rpm = tonumber(input.rpm) or 0
  local target_rpm = tonumber(input.target_rpm) or 0
  local currently_engaged = input.currently_engaged == true

  if target_rpm <= 0 then
    return { engaged = false, reason = "TARGET_ZERO" }
  end

  local scale = target_rpm / M.FULL_TARGET_RPM
  local engage_rpm = M.COIL_ENGAGE_RPM * scale
  local disengage_rpm = M.COIL_DISENGAGE_RPM * scale

  if not currently_engaged and rpm >= engage_rpm then
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
