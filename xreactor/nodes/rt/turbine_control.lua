-- nodes/rt/turbine_control.lua
--
-- Turbinen-Regelung: Flow-Steuerung, Induktor/Coil, Overspeed-Schutz,
-- Turbinen-Rotation, Capability-Discovery.
-- Ausgelagert aus nodes/rt/main.lua (RT-Node Rewrite, Schritt 2/N).
--
-- SCHNITTSTELLE: Alle öffentlichen Funktionen nehmen ctx als ersten Parameter.
--
-- ctx-Felder die dieses Modul liest/schreibt:
--   ctx.turbine_ctrl_store   -- { [name] = ctrl-Objekt } (interner State)
--   ctx.autonom_state        -- { partial_turbine_index, partial_turbine_last_rotate,
--                                 turbines = {}, ... }
--   ctx.autonom_control_logged -- einmaliges Log-Flag
--   ctx.peripherals          -- { turbines = { [name] = peripheral } }
--   ctx.capability_cache     -- { reactors = {}, turbines = {} }
--   ctx.reactor_ctrl         -- wird für setReactorActive genutzt (cross-ref)
--   ctx.warned               -- { [key] = true } einmalige Warn-Flags
--   ctx.capacity_learning    -- für get_turbine_target_rpm cap_ready-Check
--   ctx.targets              -- { rpm, power, power_percent, ... }
--   ctx.config               -- rails, turbines, reactors, ...
--   ctx.CONFIG               -- TARGET_RPM, MIN_FLOW, MAX_FLOW, START_FLOW, ...
--   ctx.turbine_regulator    -- turbine_regulator-Modul
--   ctx.flow_apply_helpers   -- flow_apply_helpers-Modul
--   ctx.rails                -- rails-Modul
--   ctx.safety               -- safety-Modul
--   ctx.utils                -- utils-Modul
--   ctx.binding              -- binding-Modul
--   ctx.adapters             -- { reactor, turbine }
--   ctx.runtime_config       -- { configured_reactors, configured_turbines }
--   ctx.log                  -- function(level, msg)
--   ctx.warn_once            -- function(key, msg)
--   ctx.current_state        -- function() -> STATE.*
--   ctx.STATE                -- { INIT, AUTONOM, MASTER, SAFE }
--   ctx.safe_wrapped_call    -- function(obj, method, ...) -> ok, result
--   ctx.reactor_control      -- reactor_control-Modul (für setReactorActive,
--                               has_reactor_rod_write_path, ensure_reactor_ctrl)

local M = {}

-- ── Interne Turbinen-Ctrl-Verwaltung ────────────────────────────────────────
-- Ersetzt ensure_turbine_ctrl (war ein Modul mit reset()-Methode).
-- ctx.turbine_ctrl_store wird in init_turbine_ctrl geleert.

local function get_turbine_ctrl(ctx, name)
  ctx.turbine_ctrl_store = ctx.turbine_ctrl_store or {}
  local ctrl = ctx.turbine_ctrl_store[name]
  if not ctrl then
    ctrl = {}
    ctx.turbine_ctrl_store[name] = ctrl
  end
  return ctrl
end
-- Exportiert damit andere Module (Reaktor-Regler, Status-Snapshot) drauf zugreifen
M.get_turbine_ctrl = get_turbine_ctrl

-- ── Capability-Discovery ────────────────────────────────────────────────────

local function has_method(methods, method)
  for _, name in ipairs(methods or {}) do
    if name == method then return true end
  end
  return false
end

local function build_capabilities(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then methods = {} end
  return {
    getActive              = has_method(methods, "getActive"),
    setActive              = has_method(methods, "setActive"),
    setFluidFlowRate       = has_method(methods, "setFluidFlowRate"),
    setFluidFlowRateMax    = has_method(methods, "setFluidFlowRateMax"),
    getFluidFlowRate       = has_method(methods, "getFluidFlowRate"),
    getFluidFlowRateMax    = has_method(methods, "getFluidFlowRateMax"),
    getFluidFlowRateMaxMax = has_method(methods, "getFluidFlowRateMaxMax"),
    getRotorSpeed          = has_method(methods, "getRotorSpeed"),
    getRotorRPM            = has_method(methods, "getRotorRPM"),
    getControlRods         = has_method(methods, "getControlRods"),
    getControlRodLevel     = has_method(methods, "getControlRodLevel"),
    getControlRodLevels    = has_method(methods, "getControlRodLevels"),
    getControlRodsLevels   = has_method(methods, "getControlRodsLevels"),
    getInductorEngaged     = has_method(methods, "getInductorEngaged"),
    setInductorEngaged     = has_method(methods, "setInductorEngaged"),
    setAllControlRodLevels = has_method(methods, "setAllControlRodLevels"),
    setControlRodsLevels   = has_method(methods, "setControlRodsLevels"),
    setControlRodLevel     = has_method(methods, "setControlRodLevel"),
    isActivelyCooled       = has_method(methods, "isActivelyCooled"),
  }
end

function M.get_device_caps(ctx, kind, name)
  -- Fix (2026-07-13): CRITICAL (RT-P0.3, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md). "or peripheral.isPresent(name)"
  -- machte diese Bedingung im Normalbetrieb praktisch IMMER wahr (ein
  -- angeschlossenes Peripheral IST fast immer "present") -- build_
  -- capabilities() (ruft peripheral.getMethods() auf, ein echter
  -- Peripherie-Methodenscan) lief dadurch bei praktisch JEDEM Aufruf im
  -- Control-/UI-/Statuspfad erneut, statt nur einmal. discovery_runtime.
  -- lua schreibt den Cache bereits separat und gezielt bei echten
  -- Attach-/Detach-/Rebind-Ereignissen neu (siehe dortige capability_
  -- cache[kind][name] = build_capabilities(name)-Aufrufe) -- diese
  -- Funktion hier muss daher nur noch bei komplett FEHLENDEM Cache-
  -- Eintrag neu aufbauen, nicht bei jedem "ist gerade angeschlossen"-Check.
  ctx.capability_cache[kind] = ctx.capability_cache[kind] or {}
  if not ctx.capability_cache[kind][name] then
    ctx.capability_cache[kind][name] = build_capabilities(name)
  end
  return ctx.capability_cache[kind][name]
end

-- ── Flow-Clamping ────────────────────────────────────────────────────────────

function M.clamp_turbine_flow(ctx, rate)
  return ctx.safety.clamp(
    type(rate) == "number" and rate or ctx.CONFIG.MIN_FLOW,
    ctx.CONFIG.MIN_FLOW, ctx.CONFIG.MAX_FLOW)
end

-- ── Ziel-RPM-Berechnung ─────────────────────────────────────────────────────

function M.get_target_rpm(ctx)
  local master_rpm = ctx.targets and ctx.targets.rpm
  if ctx.current_state() == ctx.STATE.MASTER
      and type(master_rpm) == "number" and master_rpm > 0 then
    return master_rpm
  end
  return ctx.CONFIG.TARGET_RPM
end

local function get_rotation_offset(ctx)
  local n = #(ctx.config.turbines or {})
  if n <= 1 then return 0 end
  local autonom = ctx.autonom_state
  local now = os.clock()
  local rotate_interval = ctx.config.autonom and ctx.config.autonom.rotate_interval or 300
  if now - (autonom.partial_turbine_last_rotate or 0) >= rotate_interval then
    autonom.partial_turbine_index = (autonom.partial_turbine_index or 1) % n + 1
    autonom.partial_turbine_last_rotate = now
  end
  return autonom.partial_turbine_index or 0
end

-- Ziel-RPM für eine einzelne Turbine basierend auf dem Prozent-Sollwert.
--
-- 3-Zustands-Modell:
--   VOLLAST   = base RPM (900)         — Coil bei base_engage einrastet
--   PUFFER    = base × Fraktionsanteil — Coil skaliert mit (scale = puffer/base)
--   AUS       = 0                      — Flow=0, Turbine läuft aus
--
-- Beispiel 50%, n=25:
--   full      = floor(0.5 × 25) = 12  → 12 Turbinen auf 900 RPM
--   remainder = 0.5 × 25 - 12 = 0.5  → 1 Pufferturbine auf 450 RPM
--   off       = 25 - 12 - 1   = 12   → 12 Turbinen auf 0 (aus)
--   Ist-Leistung: (12 × 900 + 450) / (25 × 900) = 50% ✅
--
-- Beispiel 83%, n=25:
--   full = 20, remainder = 0.75, puffer = 675 RPM, off = 4
--   Ist-Leistung: (20 × 900 + 675) / 22500 = 83% ✅
--
-- Die Pufferturbine und AUS-Turbinen rotieren (partial_turbine_index),
-- damit keine Turbine dauerhaft kalt bleibt.
-- Der Coil in update_inductor_for_rpm skaliert seine Schwellwerte
-- proportional zu target_rpm — bei 450 RPM Ziel rastet er bei ~450 ein.
function M.get_turbine_target_rpm(ctx, turbine_index)
  local base = M.get_target_rpm(ctx)
  local cap_ready = ctx.capacity_learning and ctx.capacity_learning.ready == true
  if not cap_ready then return base end
  if ctx.current_state() ~= ctx.STATE.MASTER then return base end

  local n = #(ctx.config.turbines or {})
  if n <= 1 then return base end

  local power_pct = ctx.targets and ctx.targets.power_percent or 100
  if type(power_pct) ~= "number" then power_pct = 100 end
  power_pct = ctx.safety.clamp(power_pct, 0, 100)

  local exact     = power_pct / 100 * n
  local full      = math.floor(exact)       -- Anzahl Vollast-Turbinen
  local remainder = exact - full            -- Fraktionsanteil 0..1
  local has_partial = remainder > 0.001 and full < n
  local partial_rpm = has_partial and math.max(1, math.floor(base * remainder + 0.5)) or 0

  -- Slot-Zuweisung nach Rotation:
  --   Slots 1..off_count          → AUS (0 RPM)
  --   Slot  off_count+1           → PUFFER (partial_rpm), nur wenn has_partial
  --   Slots off_count+2..n (oder off_count+1 wenn kein Puffer) → VOLLAST
  local off_count = n - full - (has_partial and 1 or 0)

  local offset     = get_rotation_offset(ctx)
  local slot_index = ((turbine_index - 1 + offset) % n) + 1

  if slot_index <= off_count then
    return 0             -- AUS
  elseif has_partial and slot_index == off_count + 1 then
    return partial_rpm   -- PUFFER
  else
    return base          -- VOLLAST
  end
end

-- ── Turbinen-Initialisierung ─────────────────────────────────────────────────

function M.init_turbine_ctrl(ctx)
  ctx.flow_apply_helpers.reset_log_state()
  ctx.turbine_ctrl_store = {}
  ctx.autonom_state.turbines = {}
  local turbines = ctx.config.turbines or {}
  ctx.log("INFO", "Detected " .. tostring(#turbines) .. " turbines")
  if #turbines < 1 then
    ctx.log("ERROR", ctx.binding.missing_devices_message(
      "turbine", ctx.binding.build_policy(
        ctx.runtime_config.configured_reactors,
        ctx.runtime_config.configured_turbines)))
    return
  end
  for _, name in ipairs(turbines) do
    local ctrl = get_turbine_ctrl(ctx, name)
    ctrl.flow                = M.clamp_turbine_flow(ctx, ctx.CONFIG.START_FLOW)
    ctrl.requested_flow      = ctrl.flow
    ctrl.confirmed_flow      = ctrl.flow
    ctrl.pending_flow_since  = 0
    ctrl.pending_expected_flow = ctrl.flow
    ctrl.pending_retries     = 0
    ctrl.effective_min_hits  = 0
    ctrl.effective_min_flow  = nil
    ctrl.effective_max_flow  = nil
    ctrl.startup_synced      = false
    ctrl.mode                = ctx.CONFIG.TURBINE_MODE_RAMP or "RAMP"
    ctrl.logged              = false
    ctx.log("INFO", "Controlling turbine: " .. name)
  end
end

-- ── Peripherie-Zugriff ───────────────────────────────────────────────────────

function M.read_turbine_rpm(ctx, turbine, caps)
  if not turbine then return nil, "NO_TURBINE" end
  if caps and caps.getRotorSpeed and turbine.getRotorSpeed then
    local ok, value = ctx.safe_wrapped_call(turbine, "getRotorSpeed")
    if ok and type(value) == "number" then return value, "getRotorSpeed" end
  end
  if caps and caps.getRotorRPM and turbine.getRotorRPM then
    local ok, value = ctx.safe_wrapped_call(turbine, "getRotorRPM")
    if ok and type(value) == "number" then return value, "getRotorRPM" end
  end
  return nil, "RPM_UNAVAILABLE"
end

function M.read_turbine_flow(ctx, turbine, caps)
  if not turbine then return nil, "NO_TURBINE" end
  if caps and caps.getFluidFlowRateMax and turbine.getFluidFlowRateMax then
    local ok, value = ctx.safe_wrapped_call(turbine, "getFluidFlowRateMax")
    if ok and type(value) == "number" then return value, "getFluidFlowRateMax" end
  end
  if caps and caps.getFluidFlowRate and turbine.getFluidFlowRate then
    local ok, value = ctx.safe_wrapped_call(turbine, "getFluidFlowRate")
    if ok and type(value) == "number" then return value, "getFluidFlowRate" end
  end
  return nil, "FLOW_UNAVAILABLE"
end

local function read_turbine_inductor_state(ctx, turbine, caps)
  if turbine and caps and caps.getInductorEngaged and turbine.getInductorEngaged then
    local ok, value = ctx.safe_wrapped_call(turbine, "getInductorEngaged")
    if ok and type(value) == "boolean" then return value, "getInductorEngaged" end
  end
  return nil, "INDUCTOR_UNAVAILABLE"
end

local function turbine_has_flow_setter(ctx, turbine, caps)
  if caps and (caps.setFluidFlowRate or caps.setFluidFlowRateMax) then
    return true, "capability-cache"
  end
  if turbine and type(turbine.setFluidFlowRate) == "function" then
    if caps then caps.setFluidFlowRate = true end
    return true, "runtime-probe:setFluidFlowRate"
  end
  if turbine and type(turbine.setFluidFlowRateMax) == "function" then
    if caps then caps.setFluidFlowRateMax = true end
    return true, "runtime-probe:setFluidFlowRateMax"
  end
  return false, "missing-flow-setter"
end

-- ── Actuator-Writes ──────────────────────────────────────────────────────────

local function setTurbineFlow(ctx, turbine, caps, rate)
  local clamped = M.clamp_turbine_flow(ctx, rate)
  if caps.setFluidFlowRate or type(turbine.setFluidFlowRate) == "function" then
    caps.setFluidFlowRate = true
    turbine.setFluidFlowRate(clamped)
    return true, "setFluidFlowRate"
  elseif caps.setFluidFlowRateMax or type(turbine.setFluidFlowRateMax) == "function" then
    caps.setFluidFlowRateMax = true
    turbine.setFluidFlowRateMax(clamped)
    return true, "setFluidFlowRateMax"
  end
  return false, "NO_FLOW_API"
end

local function setInductor(turbine, caps, engaged)
  if caps.setInductorEngaged then turbine.setInductorEngaged(engaged); return true end
  return false
end

function M.setTurbineActive(ctx, turbine, caps, active)
  if caps.setActive then turbine.setActive(active); return true end
  return true  -- keine API = trotzdem weitermachen
end

local function warn_unsupported(ctx, name, reason)
  local suffix = reason and (" (" .. tostring(reason) .. ")") or ""
  ctx.warn_once("device_unsupported:" .. name .. ":" .. tostring(reason or "generic"),
    "Device unsupported by API: " .. name .. suffix)
end

-- ── Induktor/Coil-Steuerung ──────────────────────────────────────────────────

function M.update_inductor_for_rpm(ctx, name, turbine, caps, rpm, target_rpm)
  local ctrl = get_turbine_ctrl(ctx, name)
  local measured_inductor, measured_api = read_turbine_inductor_state(ctx, turbine, caps)
  if type(measured_inductor) == "boolean" then
    ctrl.inductor_engaged  = measured_inductor
    ctrl.inductor_state_api = measured_api
  elseif ctrl.inductor_engaged == nil then
    ctrl.inductor_engaged = false
  end

  local coil_cfg = ctx.config.rails and ctx.config.rails.coil or {}
  local state = ctrl.rails and ctrl.rails.coil or ctx.rails.new_state()
  if ctrl.rails then ctrl.rails.coil = state end

  local smoothed_rpm = ctx.rails.smooth(state, "rpm", rpm, coil_cfg.ema_alpha)
  local engaged = ctrl.inductor_engaged or false
  local now = os.clock()
  local cooldown = coil_cfg.cooldown_s or 0
  if cooldown > 0 and now - (state.last_change_ts or 0) < cooldown then
    return true, true
  end

  local base_engage    = coil_cfg.engage_rpm    or ctx.CONFIG.COIL_ENGAGE_RPM
  local base_disengage = coil_cfg.disengage_rpm or ctx.CONFIG.COIL_DISENGAGE_RPM
  local base_target    = ctx.CONFIG.TARGET_RPM

  local engage_rpm, disengage_rpm
  if type(target_rpm) == "number" and target_rpm > 0 and base_target > 0 then
    local scale = target_rpm / base_target
    engage_rpm    = math.floor(base_engage    * scale + 0.5)
    disengage_rpm = math.floor(base_disengage * scale + 0.5)
  elseif type(target_rpm) == "number" and target_rpm <= 0 then
    engage_rpm    = base_engage
    disengage_rpm = base_disengage
  else
    engage_rpm    = base_engage
    disengage_rpm = base_disengage
  end

  local overspeed_band = coil_cfg.overspeed_band or 20
  local is_overspeed = type(smoothed_rpm) == "number"
    and type(target_rpm) == "number" and target_rpm > 0
    and smoothed_rpm > (target_rpm + overspeed_band)

  if is_overspeed and not engaged then
    engaged = true
  elseif not is_overspeed then
    if smoothed_rpm and smoothed_rpm >= engage_rpm and not engaged then
      engaged = true
    elseif (not smoothed_rpm or smoothed_rpm <= disengage_rpm) and engaged then
      engaged = false
    end
  end

  if engaged == ctrl.inductor_engaged then return true, true, measured_api end
  if not caps.setInductorEngaged then
    ctrl.inductor_engaged = engaged
    return true, true, "inductor-write-unavailable"
  end

  ctrl.inductor_engaged = engaged
  state.last_change_ts = now
  local ok, applied = pcall(setInductor, turbine, caps, engaged)
  if ok and applied then
    local reason = is_overspeed and "OVERSPEED_BRAKE" or "TARGET_TRACKING"
    if ctrl.mode == "OVERSPEED_BRAKE" then reason = "OVERSPEED_BRAKE" end
    ctrl.last_coil_reason = reason
  end
  return ok, applied, measured_api
end

-- ── Overspeed-Brake-Coil ────────────────────────────────────────────────────

local function enforce_overspeed_brake_coil(ctx, name, turbine, caps, ctrl, decision)
  if type(decision) ~= "table" or decision.overspeed_brake ~= true then
    return true, "not-required"
  end
  if ctrl.inductor_engaged == true then return true, "already-engaged" end
  if not (caps and caps.setInductorEngaged) then
    ctrl.inductor_engaged = true
    return false, "inductor-write-unavailable"
  end
  local ok, applied = pcall(setInductor, turbine, caps, true)
  if ok and applied then ctrl.inductor_engaged = true; return true, "overspeed-coil-engaged" end
  return false, "overspeed-coil-set-failed:" .. tostring(applied)
end

-- ── Flow-Regelung ────────────────────────────────────────────────────────────

function M.update_turbine_flow_state(ctx, rpm, target_rpm, ctrl)
  local rail_cfg = ctx.config.rails and ctx.config.rails.turbine_flow or {}
  local flow_state = ctrl.rails and ctrl.rails.flow or ctx.rails.new_state()
  if ctrl.rails then ctrl.rails.flow = flow_state end

  local now_ts = os.clock()
  local smoothed_rpm = ctx.rails.smooth(flow_state, "rpm", rpm, rail_cfg.ema_alpha)
  local target = target_rpm or ctx.CONFIG.TARGET_RPM
  local error_val = target - (smoothed_rpm or target)
  rail_cfg.ramp_profile = ctrl.ramp_profile or rail_cfg.ramp_profile or "NORMAL"
  local base_flow = ctrl.requested_flow or ctrl.flow or 0
  local flow_cfg = rail_cfg

  local min_flow, min_from_effective = ctx.turbine_regulator.resolve_min_flow(
    rail_cfg.min or ctx.CONFIG.MIN_FLOW, ctrl.effective_min_flow)
  local max_flow = rail_cfg.max or ctx.CONFIG.MAX_FLOW
  if type(ctrl.effective_max_flow) == "number" then
    max_flow = math.min(max_flow, ctrl.effective_max_flow)
  end
  if min_from_effective then
    flow_cfg = ctx.utils.deep_copy(flow_cfg); flow_cfg.min = min_flow
  end
  if max_flow ~= (rail_cfg.max or ctx.CONFIG.MAX_FLOW) then
    if flow_cfg == rail_cfg then flow_cfg = ctx.utils.deep_copy(flow_cfg) end
    flow_cfg.max = max_flow
  end

  local pending_requested_flow = ctrl.pending_expected_flow
  if type(pending_requested_flow) ~= "number" then pending_requested_flow = ctrl.requested_flow end

  local defer_cooldown, defer_reason = ctx.turbine_regulator.should_defer_cooldown(
    pending_requested_flow, ctrl.confirmed_flow, ctrl.pending_flow_since, now_ts,
    rail_cfg.settle_timeout_s, rail_cfg.confirm_tolerance,
    ctrl.pending_retries, rail_cfg.readback_retry_cap)
  if defer_cooldown then
    flow_cfg = ctx.utils.deep_copy(rail_cfg); flow_cfg.cooldown_s = 0
  end

  local next_flow, direction, decision = ctx.rails.step(
    base_flow, error_val, flow_state, flow_cfg, now_ts)
  local hold_band    = rail_cfg.target_hold_band_rpm or rail_cfg.deadband_up or
                       (ctx.CONFIG.RPM_TOLERANCE or 15)
  local trim_trigger = math.max(0, rail_cfg.target_trim_trigger_rpm or 6)

  local overspeed_state = ctx.turbine_regulator.overspeed_brake_state({
    rpm = smoothed_rpm or rpm or target, live_rpm = rpm, target_rpm = target,
    requested_flow = base_flow, max_flow = max_flow, band_rpm = hold_band
  })
  if overspeed_state.active then
    next_flow = 0; direction = -1
    decision = {
      reason = "OVERSPEED_BRAKE_FLOW_ZERO", step = math.abs(base_flow),
      min = 0, max = max_flow, overspeed_brake = true,
      overspeed_rpm = overspeed_state.overspeed_rpm,
      overspeed_threshold_rpm = overspeed_state.threshold_rpm,
      target_band = false, target_band_mode = "OVERSPEED_BRAKE"
    }
  end

  local target_band = ctx.turbine_regulator.target_band_state({
    rpm = smoothed_rpm or rpm or target, live_rpm = rpm, target_rpm = target,
    requested_flow = base_flow, confirmed_flow = ctrl.confirmed_flow,
    min_flow = min_flow, max_flow = max_flow, coil_engaged = ctrl.inductor_engaged,
    band_rpm = hold_band, trim_trigger_rpm = trim_trigger,
    trim_up_step   = rail_cfg.target_trim_step_up   or 50,
    trim_down_step = rail_cfg.target_trim_step_down  or 75
  })

  if (not overspeed_state.active) and target_band and target_band.in_band then
    next_flow = target_band.flow; direction = target_band.direction or 0
    decision = {
      reason = target_band.reason,
      step   = math.abs((target_band.flow or base_flow) - base_flow),
      min = min_flow, max = max_flow, target_band = true,
      target_band_mode           = target_band.mode,
      target_band_error          = target_band.error,
      target_band_live_error     = target_band.live_error,
      target_band_smoothed_error = target_band.smoothed_error,
      target_band_at_min_limit   = target_band.at_min_limit == true,
      target_band_at_max_limit   = target_band.at_max_limit == true
    }
    local confirmed_at_max = type(ctrl.confirmed_flow) == "number"
      and ctrl.confirmed_flow >= (max_flow - 1)
    local requested_at_max = type(base_flow) == "number" and base_flow >= (max_flow - 1)
    local trimmed_flow = ctx.turbine_regulator.clamp_flow(
      base_flow - math.max(1, rail_cfg.target_trim_step_down or 50), min_flow, max_flow)
    local can_force_trim = (requested_at_max or confirmed_at_max)
      and direction == 0 and (target_band.error or 0) <= trim_trigger
      and trimmed_flow < base_flow
    if can_force_trim then
      next_flow = trimmed_flow; direction = -1
      decision.reason = "TARGET_TRIM_DOWN"
      decision.step = math.abs(next_flow - base_flow)
      decision.target_band_mode = "TARGET_TRIM_DOWN"
      decision.target_band_at_min_limit = next_flow <= min_flow
      decision.target_band_at_max_limit = next_flow >= max_flow
    end
  elseif (not overspeed_state.active) and decision
      and decision.reason == "DEADBAND" and base_flow >= (max_flow - 1) then
    local emergency_trim = math.max(1, rail_cfg.target_trim_step_down or 50)
    local live_error = target - (rpm or target)
    local can_trim = math.abs(live_error) <= hold_band
      or (live_error <= trim_trigger and live_error >= (-hold_band))
    next_flow = can_trim and ctx.turbine_regulator.clamp_flow(
      base_flow - emergency_trim, min_flow, max_flow) or base_flow
    direction = next_flow < base_flow and -1 or 0
    decision = {
      reason = next_flow < base_flow and "TARGET_TRIM_DOWN" or "MAX_LIMIT_UNDERSPEED",
      step = math.abs(next_flow - base_flow), min = min_flow, max = max_flow,
      target_band = true,
      target_band_mode = next_flow < base_flow and "TARGET_TRIM_DOWN" or "MAX_LIMIT_UNDERSPEED",
      target_band_error = live_error, target_band_live_error = live_error,
      target_band_smoothed_error = target - (smoothed_rpm or target),
      target_band_at_min_limit = next_flow <= min_flow,
      target_band_at_max_limit = next_flow >= max_flow
    }
  end

  local hold_for_readback_lag, hold_reason = ctx.turbine_regulator.should_hold_readback_settle({
    pending_expected_flow = pending_requested_flow,
    confirmed_flow = ctrl.confirmed_flow, current_flow = base_flow,
    candidate_flow = next_flow, tolerance = rail_cfg.confirm_tolerance,
    pending_since = ctrl.pending_flow_since, now_ts = now_ts,
    settle_timeout_s = rail_cfg.settle_timeout_s,
    pending_retries = ctrl.pending_retries,
    readback_retry_cap = rail_cfg.readback_retry_cap
  })
  if (not overspeed_state.active) and hold_for_readback_lag then
    next_flow = base_flow; direction = 0
    decision = {
      reason = "READBACK_SETTLING_HOLD", step = 0, min = min_flow, max = max_flow,
      target_band = target_band and target_band.in_band or false,
      target_band_mode = hold_reason
    }
  end

  ctrl.requested_flow = M.clamp_turbine_flow(ctx, next_flow)
  ctrl.flow = ctrl.requested_flow
  if defer_cooldown and decision then
    decision.defer_cooldown = true; decision.defer_reason = defer_reason
  end

  local hold_sample_target = math.max(1, rail_cfg.target_trim_hold_samples or 2)
  if (not overspeed_state.active) and target_band and target_band.in_band
      and target_band.mode == "HOLDING_TARGET_ACTIVE" then
    ctrl.target_hold_hits = (ctrl.target_hold_hits or 0) + 1
  else
    ctrl.target_hold_hits = 0
  end
  ctrl.target_holding_active = (not overspeed_state.active) and target_band
    and target_band.in_band and target_band.mode == "HOLDING_TARGET_ACTIVE"
    and ctrl.target_hold_hits >= hold_sample_target or false
  ctrl.target_trim_active = (not overspeed_state.active) and target_band
    and target_band.in_band
    and not (decision and decision.reason == "READBACK_SETTLING_HOLD")
    and (target_band.mode == "TARGET_TRIM_UP" or target_band.mode == "TARGET_TRIM_DOWN")
    or false
  ctrl.in_target_band = (not overspeed_state.active) and target_band
    and target_band.in_band or false
  ctrl.target_band_status = overspeed_state.active and "OVERSPEED_BRAKE"
    or (target_band and target_band.mode or "TRACKING")

  if ctrl.target_holding_active and type(ctrl.target_band_status) == "string" then
    ctrl.mode = ctrl.target_band_status
  elseif overspeed_state.active then ctrl.mode = "OVERSPEED_BRAKE"
  elseif direction > 0 then ctrl.mode = "UP"
  elseif direction < 0 then ctrl.mode = "DOWN"
  elseif decision and decision.reason == "DEADBAND" then ctrl.mode = "TRACKING_DEADBAND"
  else ctrl.mode = "TRACKING_STABLE" end

  return ctrl.requested_flow, ctrl.mode, decision, smoothed_rpm
end

-- ── Flow-Apply ───────────────────────────────────────────────────────────────

local function resolve_turbine_target_state(ctx, ctrl, decision, reason, readback_state)
  local target_action = ctx.flow_apply_helpers.resolve_target_action(reason, decision)
  if ctrl.target_holding_active then
    target_action = "TARGET_HOLD_STABLE"
  elseif ctrl.target_trim_active then
    target_action = decision and decision.target_band_mode or target_action
  end
  local active_trim = ctrl.target_trim_active
    or target_action == "TARGET_TRIM_UP" or target_action == "TARGET_TRIM_DOWN"
  local hold_active = ctrl.target_holding_active and target_action == "TARGET_HOLD_STABLE"
  if active_trim and readback_state == "READBACK_LAG" then
    target_action = "ACTIVE_TRIM_WITH_READBACK_LAG"
  elseif active_trim and readback_state == "PENDING_MISMATCH" then
    target_action = "TRIM_PENDING_CONFIRMATION"
  elseif hold_active and readback_state == "CONFIRMED_MATCH" then
    target_action = "HOLD_CONFIRMED"
  end
  local down_limited = tostring(reason):find("MIN_LIMIT_OVERSPEED", 1, true) ~= nil
  local up_limited   = tostring(reason):find("MAX_LIMIT_UNDERSPEED", 1, true) ~= nil
  ctrl.target_trim_state = active_trim
    and (decision and decision.target_band_mode or "ACTIVE_TRIM") or "NONE"
  if down_limited or (decision and decision.target_band_at_min_limit) then
    ctrl.flow_limit_state = "MIN_LIMIT"
  elseif up_limited or (decision and decision.target_band_at_max_limit) then
    ctrl.flow_limit_state = "MAX_LIMIT"
  else
    ctrl.flow_limit_state = "NONE"
  end
  return {
    target_action = target_action, active_trim = active_trim,
    hold_active = hold_active, down_limited = down_limited, up_limited = up_limited
  }
end

local function apply_turbine_flow_write(ctx, turbine, caps, requested_flow)
  local ok, applied, setter = pcall(setTurbineFlow, ctx, turbine, caps, requested_flow)
  local write_state  = ok and applied and "WRITE_ACCEPTED"
    or (ok and "WRITE_REJECTED" or "WRITE_FAILED")
  return {
    ok = ok, applied = applied, setter = setter,
    write_state = write_state, write_detail = tostring(setter or applied)
  }
end

local function finalize_turbine_flow_apply(ctx, name, ctrl, ap)
  local pending_age_s = 0
  if type(ctrl.pending_flow_since) == "number" and ctrl.pending_flow_since > 0 then
    pending_age_s = math.max(0, ap.now_ts - ctrl.pending_flow_since)
  end
  local target_zone_state = ctrl.in_target_band and "IN_TARGET_BAND" or "OUTSIDE_TARGET_BAND"
  local at_max_limit = ap.requested_flow == (ctrl.effective_max_flow or ctx.CONFIG.MAX_FLOW)
  local at_min_limit = type(ap.applied_min) == "number"
    and ap.requested_flow <= ap.applied_min
  local target_state = resolve_turbine_target_state(
    ctx, ctrl, ap.decision, ap.reason, ap.readback_state)
  local bottleneck, bottleneck_detail = ctx.turbine_regulator.classify_bottleneck({
    requested_flow = ap.requested_flow, confirmed_flow = ap.confirmed_flow,
    rpm = ap.rpm, target_rpm = ap.target_rpm, min_flow = ap.applied_min,
    max_flow = ctrl.effective_max_flow or ctx.CONFIG.MAX_FLOW,
    inductor_engaged = ctrl.inductor_engaged, steam_input = ap.steam_input,
    readback_state = ap.readback_state, write_state = ap.write.write_state
  })
  ctx.flow_apply_helpers.log_turbine_control_metrics({
    name = name, rpm = ap.rpm, smoothed_rpm = ap.smoothed_rpm,
    target_rpm = ap.target_rpm, old_flow = ap.old_flow,
    requested_flow = ap.requested_flow, confirmed_flow = ap.confirmed_flow,
    direction = ap.mode, reason = ap.reason, step = ap.step,
    applied_min = ap.applied_min, applied_max = ap.applied_max,
    setter = ap.write.setter,
    set_called = ap.write.ok and ap.write.applied, set_ok = ap.write.ok,
    write_state = ap.write.write_state, write_detail = ap.write.write_detail,
    observed_flow = ap.observed_flow, flow_reader = ap.flow_reader,
    attempt = ap.attempt, flow_settled = ap.flow_settled,
    pending_settled = ap.pending_settled,
    pending_retries = ctrl.pending_retries,
    pending_retry_stage = ctrl.pending_retry_stage,
    pending_age_s = pending_age_s,
    settle_timeout_s = ap.rail_cfg.settle_timeout_s or 0,
    pending_flow_since = ctrl.pending_flow_since,
    pending_expected_flow = ctrl.pending_expected_flow,
    cooldown_deferred = ap.decision and ap.decision.defer_cooldown or false,
    cooldown_defer_reason = ap.decision and ap.decision.defer_reason or "n/a",
    effective_min_flow = ap.effective_min_flow,
    effective_min_applied = type(ap.effective_min_flow) == "number"
      and ap.requested_flow == ap.effective_min_flow and ap.requested_flow > 0,
    mode = ap.mode, target_action = target_state.target_action,
    target_zone_state = target_zone_state,
    target_holding_active = ctrl.target_holding_active,
    target_band_status = ctrl.target_band_status,
    target_band_reason = ap.decision and ap.decision.target_band_mode or "n/a",
    target_band_error = ap.decision and ap.decision.target_band_error or "n/a",
    target_band_live_error = ap.decision and ap.decision.target_band_live_error or "n/a",
    target_band_smoothed_error = ap.decision and ap.decision.target_band_smoothed_error or "n/a",
    hold_active = target_state.hold_active, active_trim = target_state.active_trim,
    flow_trim_direction = target_state.active_trim
      and (target_state.target_action == "TARGET_TRIM_UP" and "UP" or "DOWN") or "NONE",
    inductor_engaged = ctrl.inductor_engaged,
    inductor_state_api = ctrl.inductor_state_api or "n/a",
    overspeed_brake = ap.decision and ap.decision.overspeed_brake or false,
    overspeed_rpm = ap.decision and ap.decision.overspeed_rpm or "n/a",
    overspeed_threshold_rpm = ap.decision and ap.decision.overspeed_threshold_rpm or "n/a",
    overspeed_coil_ok = ap.overspeed_coil_ok,
    overspeed_coil_reason = ap.overspeed_coil_reason,
    overspeed_floor_hits = ctrl.overspeed_floor_hits or 0,
    readback_state = ap.readback_state, readback_detail = ap.readback_detail,
    steam_input = ap.steam_input, active_state = ap.active_state,
    max_flow_limit = ctrl.effective_max_flow or ctx.CONFIG.MAX_FLOW,
    at_max_limit = at_max_limit, at_min_limit = at_min_limit,
    down_regulation_limited = target_state.down_limited
      or (ap.decision and ap.decision.target_band_at_min_limit) or false,
    up_regulation_limited = target_state.up_limited
      or (ap.decision and ap.decision.target_band_at_max_limit) or false,
    flow_limit_state = ctrl.flow_limit_state,
    bottleneck = bottleneck, bottleneck_detail = bottleneck_detail
  }, ctx.log)

  if not ctrl.logged then
    ctrl.logged = true
  end
  if ap.requested_flow == 0 and type(ap.effective_min_flow) == "number"
      and ap.effective_min_changed then
  end
  if ap.decision and ap.decision.overspeed_brake and ap.requested_flow == 0
      and type(ap.confirmed_flow) == "number"
      and ap.confirmed_flow > (ap.flow_tolerance or 0) then
    -- Fix (2026-07-01): diese Warnung feuerte bei JEDEM Tick ohne Drosselung,
    -- solange der Overspeed-Bremszustand anhielt (mehrmals pro Sekunde) —
    -- das flutete den Log-Ringpuffer komplett und verdrängte alle anderen,
    -- moeglicherweise wichtigeren Log-Eintraege (SET_SETPOINTS, ReactorCtrl
    -- etc. waren im Ringpuffer kaum noch sichtbar). Jetzt: max. 1x alle 5s
    -- pro Turbine.
    local now_ms = os.epoch and os.epoch("utc") or (os.clock() * 1000)
    local last_log = ctrl.last_overspeed_log_ms or 0
    if (now_ms - last_log) >= 5000 then
      ctrl.last_overspeed_log_ms = now_ms
      ctx.log("WARN", ("Overspeed brake pending name=%s requested_flow=0"
        .. " confirmed_flow=%s readback_state=%s detail=%s retries=%s"):format(
        tostring(name), tostring(ap.confirmed_flow), tostring(ap.readback_state),
        tostring(ap.readback_detail), tostring(ctrl.pending_retries)))
    end
  end
end

function M.apply_turbine_flow(ctx, name, turbine, caps, rpm, target_rpm)
  local ctrl = get_turbine_ctrl(ctx, name)
  if type(rpm) == "number" then ctrl.rpm = rpm end

  if type(ctrl.effective_max_flow) ~= "number"
      and caps and caps.getFluidFlowRateMaxMax
      and turbine.getFluidFlowRateMaxMax then
    local max_ok, max_value = ctx.safe_wrapped_call(turbine, "getFluidFlowRateMaxMax")
    if max_ok and type(max_value) == "number" and max_value > 0 then
      ctrl.effective_max_flow = math.min(ctx.CONFIG.MAX_FLOW,
        math.max(ctx.CONFIG.MIN_FLOW, math.floor(max_value + 0.5)))
    end
  end

  local startup_observed_flow, startup_reader = M.read_turbine_flow(ctx, turbine, caps)
  if type(startup_observed_flow) == "number" then
    local synced = M.clamp_turbine_flow(ctx, startup_observed_flow)
    ctrl.confirmed_flow = synced
    if not ctrl.startup_synced
        and ctx.turbine_regulator.sync_startup_state(ctrl, synced) then
      return true, false, "startup-sync-hold", "STARTUP_SYNC"
    end
  end

  local old_flow = ctrl.confirmed_flow or ctrl.requested_flow or ctrl.flow
  local requested_flow, mode, decision, smoothed_rpm =
    M.update_turbine_flow_state(ctx, rpm, target_rpm, ctrl)
  local steam_input, active_state =
    ctx.flow_apply_helpers.sample_turbine_runtime_metrics(
      turbine, caps, ctx.safe_wrapped_call)
  if false then ctx.flow_apply_helpers.log_turbine_control_metrics({}) end

  local now_ts = os.clock()
  local write = apply_turbine_flow_write(ctx, turbine, caps, requested_flow)
  local overspeed_coil_ok, overspeed_coil_reason =
    enforce_overspeed_brake_coil(ctx, name, turbine, caps, ctrl, decision)

  local rail_cfg = ctx.config.rails and ctx.config.rails.turbine_flow or {}
  local observed_flow, flow_reader, attempt, flow_tolerance =
    ctx.flow_apply_helpers.capture_turbine_flow_readback(
      turbine, caps, ctrl, requested_flow, rail_cfg,
      function(t, c) return M.read_turbine_flow(ctx, t, c) end,
      function(r) return M.clamp_turbine_flow(ctx, r) end)

  local confirmed_flow = ctrl.confirmed_flow
  local flow_settled = ctx.turbine_regulator.flows_match(
    requested_flow, confirmed_flow, flow_tolerance)
  local pending_settled, effective_min_flow, effective_min_changed,
    readback_state, readback_detail =
    ctx.flow_apply_helpers.update_turbine_flow_tracking(
      ctrl, requested_flow, confirmed_flow, flow_tolerance,
      rail_cfg, now_ts, decision, write.write_state, ctx.turbine_regulator)

  ctrl.last_requested_flow = requested_flow
  local reason     = decision and decision.reason or "NONE"
  local step       = decision and decision.step or "nil"
  local applied_min = decision and decision.min or rail_cfg.min
  local applied_max = decision and decision.max or rail_cfg.max

  finalize_turbine_flow_apply(ctx, name, ctrl, {
    rpm = rpm, smoothed_rpm = smoothed_rpm, target_rpm = target_rpm,
    old_flow = old_flow, requested_flow = requested_flow,
    confirmed_flow = confirmed_flow, mode = mode, decision = decision,
    reason = reason, step = step, applied_min = applied_min, applied_max = applied_max,
    write = write, observed_flow = observed_flow, flow_reader = flow_reader,
    attempt = attempt, flow_settled = flow_settled, pending_settled = pending_settled,
    effective_min_flow = effective_min_flow, effective_min_changed = effective_min_changed,
    readback_state = readback_state, readback_detail = readback_detail,
    steam_input = steam_input, active_state = active_state,
    rail_cfg = rail_cfg, flow_tolerance = flow_tolerance,
    overspeed_coil_ok = overspeed_coil_ok, overspeed_coil_reason = overspeed_coil_reason,
    now_ts = now_ts
  })

  if not write.ok then return false, write.applied, write.setter, "FLOW_SET_CALL_FAILED" end
  if not write.applied then return true, false, write.setter, "FLOW_SET_SKIPPED" end
  return true, true, write.setter, "FLOW_SET_OK"
end

-- ── Haupt-Tick ───────────────────────────────────────────────────────────────

function M.updateControl(ctx)
  if ctx.current_state() == ctx.STATE.INIT then return end

  -- Reaktoren aktiv halten (delegiert an reactor_control)
  for _, name in ipairs(ctx.config.reactors or {}) do
    -- Fix (2026-07-13): CRITICAL (RT-P0.4, siehe docs/CODING_AI_OTHER_
    -- NODES_PERFORMANCE_2026-07-12.md). peripheral.wrap() wurde bisher
    -- bei JEDEM Regelzyklus fuer JEDEN Reaktor erneut aufgerufen -- ein
    -- echter Peripherie-Wrap ist teuer (Methodenintrospektion), und die
    -- Discovery (discovery_runtime.lua) haelt bereits einen fertig
    -- gewrappten Cache in ctx.peripherals.reactors[name] bereit, der bei
    -- jedem Discovery-Refresh aktualisiert wird -- reactor_control.lua
    -- nutzt genau diesen Cache bereits an mehreren Stellen, turbine_
    -- control.lua's updateControl() alleine wrappte redundant neu. Fallback
    -- auf einen direkten Wrap bleibt erhalten fuer den (seltenen) Fall,
    -- dass ein Geraet aus irgendeinem Grund noch nicht im Discovery-Cache
    -- steht.
    local reactor = ctx.peripherals and ctx.peripherals.reactors and ctx.peripherals.reactors[name]
    local ok = reactor ~= nil
    if not ok then
      ok, reactor = pcall(peripheral.wrap, name)
    end
    if ok and reactor then
      local caps = M.get_device_caps(ctx, "reactors", name)
      if not ctx.reactor_control.has_reactor_rod_write_path(caps) then
        warn_unsupported(ctx, name); goto continue_control_reactor
      end
      local ok_active, active_result = pcall(
        ctx.reactor_control.setReactorActive, ctx, reactor, caps, true)
      if not ok_active then
        ctx.warn_once("reactor_active:" .. name,
          "Reactor activate failed for " .. name .. ": " .. tostring(active_result))
        goto continue_control_reactor
      end
      if not active_result then
        ctx.warn_once("reactor_set_active_unavailable:" .. name,
          "Reactor active API unavailable for " .. name)
        goto continue_control_reactor
      end
      ctx.reactor_control.ensure_reactor_ctrl(ctx, name)
      if not ctx.autonom_control_logged then
        ctx.autonom_control_logged = true
      end
      ::continue_control_reactor::
    end
  end

  local turbine_index = 0
  local eval_total, eval_decision, eval_skipped = 0, 0, 0
  local skip_reasons = {}
  local function track_skip(reason)
    local key = tostring(reason or "UNKNOWN")
    skip_reasons[key] = (skip_reasons[key] or 0) + 1
    eval_skipped = eval_skipped + 1
  end

  for _, name in ipairs(ctx.config.turbines or {}) do
    local ctrl = get_turbine_ctrl(ctx, name)
    turbine_index = turbine_index + 1
    eval_total = eval_total + 1

    -- Fix (2026-07-13): RT-P0.4. Gleicher Fix wie oben bei Reaktoren --
    -- Discovery-Cache verwenden statt bei jedem Zyklus neu zu wrappen.
    local turbine = ctx.peripherals and ctx.peripherals.turbines and ctx.peripherals.turbines[name]
    local ok = turbine ~= nil
    if not ok then
      ok, turbine = pcall(peripheral.wrap, name)
    end
    if not ok or not turbine then
      track_skip("WRAP_FAILED")
      ctx.warn_once("turbine_wrap:" .. name,
        "Turbine wrap failed for " .. name .. ": " .. tostring(turbine))
      goto continue_control_turbine
    end

    local caps = M.get_device_caps(ctx, "turbines", name)
    local has_flow_api, flow_api_reason = turbine_has_flow_setter(ctx, turbine, caps)
    if not has_flow_api then
      ctrl.flow_api_missing_ticks = (ctrl.flow_api_missing_ticks or 0) + 1
      track_skip(flow_api_reason)
      if ctrl.flow_api_missing_ticks >= 5 then
        warn_unsupported(ctx, name, flow_api_reason)
      else
      end
      goto continue_control_turbine
    end
    ctrl.flow_api_missing_ticks = 0

    local ok_active, active_result = pcall(M.setTurbineActive, ctx, turbine, caps, true)
    if not ok_active then
      ctx.warn_once("turbine_active:" .. name,
        "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
      track_skip("SET_ACTIVE_FAILED_NONFATAL")
    elseif not active_result then
      ctx.warn_once("turbine_set_active_unavailable:" .. name,
        "Turbine active API unavailable for " .. name .. " (continuing with flow control)")
    end

    local rpm = nil
    if turbine.getRotorSpeed then
      local rpm_ok, value = ctx.safe_wrapped_call(turbine, "getRotorSpeed")
      if rpm_ok and type(value) == "number" then rpm = value end
    end

    local effective_target = M.get_turbine_target_rpm(ctx, turbine_index)
    local ok_inductor, inductor_result = M.update_inductor_for_rpm(
      ctx, name, turbine, caps, rpm, effective_target)
    if not ok_inductor then
      ctx.warn_once("turbine_inductor:" .. name,
        "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
      track_skip("INDUCTOR_UPDATE_FAILED_NONFATAL")
    end

    local set_ok, result, _, apply_reason =
      M.apply_turbine_flow(ctx, name, turbine, caps, rpm, effective_target)
    if not set_ok then
      ctx.warn_once("turbine_flow:" .. name,
        "Turbine flow update failed for " .. name .. ": " .. tostring(result)
        .. " reason=" .. tostring(apply_reason))
      track_skip(apply_reason or "FLOW_SET_CALL_FAILED")
      goto continue_control_turbine
    end
    if not result then
      track_skip(apply_reason or "FLOW_SET_SKIPPED")
      goto continue_control_turbine
    end

    eval_decision = eval_decision + 1
    if not ctx.autonom_control_logged then
      ctx.autonom_control_logged = true
    end
    ::continue_control_turbine::
  end

  local reason_parts = {}
  for reason, count in pairs(skip_reasons) do
    reason_parts[#reason_parts + 1] = tostring(reason) .. "=" .. tostring(count)
  end
  table.sort(reason_parts)
  -- TurbineTick nur loggen wenn Entscheidungen getroffen wurden (nicht leere Ticks)
  if eval_decision > 0 then
  end
end

return M
