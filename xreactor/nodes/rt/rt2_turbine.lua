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
-- opts.max_active: wieviele Turbinen ueberhaupt laufen duerfen.
--
-- Das ist der eine Begriff, der in JEDEM Zustand gilt -- waehrend des
-- Einlernens die aktuell freigegebene Stufe (rt2_capacity staffelt sie
-- hoch), danach die gelernte tragbare Anzahl. Ohne ihn setzt jeder Zustand
-- ausser MASTER alle Turbinen auf das volle Ziel, und eine dampfbegrenzte
-- Anlage reisst sich dabei selbst den Dampf weg: keine Turbine erreicht
-- die Zieldrehzahl, weil alle gleichzeitig daran ziehen.
--
-- nil bedeutet "keine Grenze bekannt" -- dann verhaelt sich alles wie
-- frueher und jede Turbine bekommt ihr volles Ziel.
local function active_limit(opts, turbine_count)
  local limit = tonumber(opts.max_active)
  if not limit then return turbine_count end
  if limit < 0 then return 0 end
  if limit > turbine_count then return turbine_count end
  return math.floor(limit)
end

function M.compute_target_rpm(state, opts)
  opts = opts or {}
  if state == "SAFE" then
    return 0
  end

  local n = tonumber(opts.turbine_count) or 0
  local slot_index = tonumber(opts.slot_index) or 1

  if state == "LEARNING" or state == "AUTONOM" then
    if n > 0 and slot_index > active_limit(opts, n) then return 0 end
    return M.FULL_TARGET_RPM
  end

  if state == "MASTER" then
    if n <= 0 then return M.FULL_TARGET_RPM end
    local max_active = active_limit(opts, n)
    -- Jenseits der tragbaren Anzahl bleibt eine Turbine immer aus -- die
    -- Leistungsvorgabe wird NUR auf den tragbaren Teil der Flotte verteilt.
    -- Sonst bedeutet "100 %" wieder "alle 25 gleichzeitig", was diese
    -- Anlage gerade nicht kann, und die Vorgabe liesse sich nie erfuellen.
    if max_active <= 0 or slot_index > max_active then return 0 end

    local percent = clamp(tonumber(opts.power_percent) or 100, 0, 100)
    local exact = percent / 100 * max_active
    local full = math.floor(exact)
    local remainder = exact - full
    local has_partial = remainder > 0.001 and full < max_active
    local partial_rpm = has_partial and math.max(1, math.floor(M.FULL_TARGET_RPM * remainder + 0.5)) or 0
    local off_count = max_active - full - (has_partial and 1 or 0)

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
--
-- FIXED 2026-09-23: the overspeed cut used to fire at target+RPM_BAND,
-- which is the EXACT same condition as the RAMP_DOWN branch below
-- (error_rpm < -band  <=>  rpm > target + band). The cut came first, so
-- RAMP_DOWN was unreachable dead code -- proven by sweeping rpm 0..3000 at
-- target 900: RAMP_DOWN was hit zero times while 2060 of 3001 samples
-- slammed the flow to 0. The turbine therefore had no proportional
-- downward control at all: below the band it ramped +TRIM_STEP, inside it
-- trimmed by 1, and one RPM above the band it dropped straight to zero and
-- had to climb all the way back. That bang-bang sawtooth is both the
-- "controller too aggressive" behaviour reported from the plant and a
-- plausible reason capacity learning struggled to catch every turbine
-- inside its 900 +/- 15 measurement window at the same moment.
--
-- Now the two cases are actually distinct: OVERSPEED_RPM marks a real
-- runaway worth cutting to zero for, and everything between the band and
-- that limit ramps down proportionally like any normal controller.
function M.compute_flow_decision(input)
  local rpm = tonumber(input.rpm) or 0
  local target_rpm = tonumber(input.target_rpm) or 0
  local current_flow = tonumber(input.current_flow) or 0
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

  local error_rpm = target_rpm - rpm
  if error_rpm > band then
    -- well under target: open up, but never overshoot straight to max in
    -- one step (the physical rotor takes time to respond).
    return { flow = clamp(current_flow + M.TRIM_STEP, min_flow, max_flow), reason = "RAMP_UP" }
  end
  if error_rpm < -band then
    return { flow = clamp(current_flow - M.TRIM_STEP, min_flow, max_flow), reason = "RAMP_DOWN" }
  end
  -- Inside the band: trim toward the exact target, proportionally.
  --
  -- FIXED 2026-09-23: this used to be a flat +/-1 per tick regardless of
  -- how far off the turbine actually was -- 35x weaker than the RAMP
  -- branches it takes over from, with a cliff right at the band edge. That
  -- matters most at exactly the wrong moment: when the coil engages, the
  -- load step needs a LARGE flow correction, and a 1-unit trim takes
  -- hundreds of ticks to deliver it. The rotor sagged out of the band,
  -- RAMP_UP slammed +35 back in, and the turbine sawtoothed across the
  -- 900 +/- 15 measurement window instead of settling inside it.
  --
  -- The step now scales with the error, so it joins the ramp branches
  -- continuously (at |error| == band it is exactly TRIM_STEP) and shrinks
  -- to 1 right at the target. Simulated over a 25-turbine fleet this cut
  -- the time to complete capacity learning from 126 to 77 ticks.
  if band > 0 and error_rpm ~= 0 then
    local step = math.max(1, math.floor(M.TRIM_STEP * math.abs(error_rpm) / band + 0.5))
    if error_rpm > 0 and current_flow < max_flow then
      return { flow = clamp(current_flow + step, min_flow, max_flow), reason = "HOLD_TRIM_UP" }
    end
    if error_rpm < 0 and current_flow > min_flow then
      return { flow = clamp(current_flow - step, min_flow, max_flow), reason = "HOLD_TRIM_DOWN" }
    end
  end
  return { flow = current_flow, reason = "HOLD" }
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
