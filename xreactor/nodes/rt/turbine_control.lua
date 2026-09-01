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
--   ctx.modules              -- optional: modules_registry (see cached_rotor_rpm())

local M = {}

-- module_lifecycle.update_module_states() always runs before updateControl()
-- in the same control_tick() (safety-first ordering, see main.lua), and
-- unconditionally refreshes every turbine module's .last_rotor_rpm every
-- tick -- so if a module for this turbine name exists, its cached RPM is
-- guaranteed fresh for THIS tick and can be reused instead of calling
-- getRotorSpeed() a second time. Returns (rpm, true) when reused, or
-- (nil, false) when no module was found -- callers fall back to a direct
-- read in that case, exactly like before this optimization existed.
local function cached_rotor_rpm(ctx, name)
  local modules = ctx.modules
  if type(modules) ~= "table" then return nil, false end
  for _, module in pairs(modules) do
    if module.type == "turbine" and module.name == name then
      return module.last_rotor_rpm, true
    end
  end
  return nil, false
end

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

-- Der Rest der RT-Discovery/Binding-Logik verwendet SINGULAR
-- ("reactor"/"turbine"), waehrend ctx.capability_cache intern PLURAL
-- ("reactors"/"turbines") als Cache-Schluessel erwartet -- normalize_kind()
-- macht get_device_caps() robust gegen beide Schreibweisen, sonst wuerde
-- ein Singular-Aufruf still einen separaten, nie befuellten Cache-
-- Namensraum erzeugen.
local KIND_TO_CACHE_KEY = {
  reactor = "reactors", reactors = "reactors",
  turbine = "turbines", turbines = "turbines",
}

local function normalize_kind(kind)
  return KIND_TO_CACHE_KEY[kind] or kind
end

function M.get_device_caps(ctx, kind, name)
  -- Baut den Cache nur bei komplett fehlendem Eintrag neu auf --
  -- discovery_runtime.lua schreibt ihn bereits gezielt bei echten
  -- Attach-/Detach-/Rebind-Ereignissen neu, ein zusaetzlicher "ist gerade
  -- angeschlossen"-Check hier wuerde peripheral.getMethods() unnoetig oft
  -- erneut aufrufen.
  kind = normalize_kind(kind)
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

-- Analog zu reactor_control.lua's setReactorActive(): optionaler ctrl-
-- Parameter (turbine_ctrl_store[name]-Eintrag) unterdrueckt identische
-- Writes statt setActive() bei jedem Tick redundant aufzurufen, ruecklauf-
-- kompatibel ohne ctrl (module_lifecycle.lua's Start-Rampe).
function M.setTurbineActive(ctx, turbine, caps, active, ctrl)
  -- A cached value is not a live hardware observation. Reconcile getActive()
  -- first so an externally stopped/reset turbine is actively restored.
  if caps.getActive and type(turbine.getActive) == "function" then
    local ok_read, actual = pcall(turbine.getActive)
    if ok_read and type(actual) == "boolean" then
      if ctrl then ctrl.active_state = actual end
      if actual == active then return true end
    end
  elseif ctrl and ctrl.active_state == active then
    return true
  end
  if caps.setActive then
    local result = turbine.setActive(active)
    if result == false then return false end
    if ctrl then ctrl.active_state = active end
    if caps.getActive and type(turbine.getActive) == "function" then
      local ok_read, actual = pcall(turbine.getActive)
      if not ok_read or type(actual) ~= "boolean" or actual ~= active then
        if ctrl and ok_read and type(actual) == "boolean" then ctrl.active_state = actual end
        return false
      end
    end
    return true
  end
  return false
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
    -- Desired state is not a confirmed hardware state. Keep the last
    -- confirmed/read-back value so the next control tick continues trying.
    return false, false, "inductor-write-unavailable"
  end

  local ok, applied = pcall(setInductor, turbine, caps, engaged)
  if ok and applied then
    ctrl.inductor_engaged = engaged
    state.last_change_ts = now
    local reason = is_overspeed and "OVERSPEED_BRAKE" or "TARGET_TRACKING"
    if ctrl.mode == "OVERSPEED_BRAKE" then reason = "OVERSPEED_BRAKE" end
    ctrl.last_coil_reason = reason
  end
  return ok, applied, measured_api
end

-- Explicit update-safe turbine state: flow limit 0, inactive, and coil
-- engaged where supported. A fresh flow readback is mandatory; optional
-- active/inductor readbacks are mandatory when the corresponding getter exists.
function M.apply_update_quiesce(ctx)
  local result = { ok = true, turbines = {} }
  for _, name in ipairs(ctx.config.turbines or {}) do
    local item = { name = name }
    local turbine = ctx.peripherals and ctx.peripherals.turbines and ctx.peripherals.turbines[name] or nil
    if not turbine and ctx.utils and type(ctx.utils.safe_wrap) == "function" then
      turbine = select(1, ctx.utils.safe_wrap(name))
    end
    item.present = turbine ~= nil
    if not turbine then
      item.ok = false
      result.ok = false
      result.turbines[#result.turbines + 1] = item
      goto continue
    end

    local caps = M.get_device_caps(ctx, "turbines", name)
    local ok_flow, flow_applied = pcall(setTurbineFlow, ctx, turbine, caps, 0)
    item.flow_write = ok_flow and flow_applied == true
    local flow, flow_source = M.read_turbine_flow(ctx, turbine, caps)
    item.flow = flow
    item.flow_source = flow_source
    item.flow_safe = type(flow) == "number" and math.abs(flow) <= 0.01

    item.active_safe = true
    if type(turbine.setActive) == "function" then
      local ok_set, set_result = pcall(turbine.setActive, false)
      item.active_write = ok_set and set_result ~= false
      if type(turbine.getActive) == "function" then
        local ok_read, active = pcall(turbine.getActive)
        item.active_readback = ok_read and type(active) == "boolean"
        item.active = active
        item.active_safe = ok_read and active == false
      else
        item.active_safe = item.active_write
      end
    end

    item.inductor_safe = true
    if type(turbine.setInductorEngaged) == "function" then
      local ok_set, set_result = pcall(turbine.setInductorEngaged, true)
      item.inductor_write = ok_set and set_result ~= false
      if type(turbine.getInductorEngaged) == "function" then
        local ok_read, engaged = pcall(turbine.getInductorEngaged)
        item.inductor_readback = ok_read and type(engaged) == "boolean"
        item.inductor_engaged = engaged
        item.inductor_safe = ok_read and engaged == true
      else
        item.inductor_safe = item.inductor_write
      end
    end

    item.ok = item.flow_write and item.flow_safe and item.active_safe and item.inductor_safe
    if item.ok then
      local ctrl = get_turbine_ctrl(ctx, name)
      ctrl.flow = 0
      ctrl.requested_flow = 0
      ctrl.confirmed_flow = 0
      ctrl.active_state = false
      if item.inductor_write then ctrl.inductor_engaged = true end
    else
      result.ok = false
    end
    result.turbines[#result.turbines + 1] = item
    ::continue::
  end
  return result.ok, result
end

-- ── Overspeed-Brake-Coil ────────────────────────────────────────────────────

local function enforce_overspeed_brake_coil(ctx, name, turbine, caps, ctrl, decision)
  if type(decision) ~= "table" or decision.overspeed_brake ~= true then
    return true, "not-required"
  end
  if ctrl.inductor_engaged == true then return true, "already-engaged" end
  if not (caps and caps.setInductorEngaged) then
    -- Do not mark the brake as engaged without a successful actuator write.
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

local function apply_turbine_flow_write(ctx, turbine, caps, requested_flow)
  local ok, applied, setter = pcall(setTurbineFlow, ctx, turbine, caps, requested_flow)
  local write_state  = ok and applied and "WRITE_ACCEPTED"
    or (ok and "WRITE_REJECTED" or "WRITE_FAILED")
  return {
    ok = ok, applied = applied, setter = setter,
    write_state = write_state, write_detail = tostring(setter or applied)
  }
end

local function finalize_turbine_flow_apply(ctx, name, ctrl, requested_flow,
    decision, confirmed_flow, flow_tolerance, readback_state, readback_detail)
  if not ctrl.logged then ctrl.logged = true end
  if decision and decision.overspeed_brake and requested_flow == 0
      and type(confirmed_flow) == "number"
      and confirmed_flow > (flow_tolerance or 0) then
    local now_ms = os.epoch and os.epoch("utc") or (os.clock() * 1000)
    local last_log = ctrl.last_overspeed_log_ms or 0
    if (now_ms - last_log) >= 5000 then
      ctrl.last_overspeed_log_ms = now_ms
      ctx.log("WARN", ("Overspeed brake pending name=%s requested_flow=0"
        .. " confirmed_flow=%s readback_state=%s detail=%s retries=%s"):format(
        tostring(name), tostring(confirmed_flow), tostring(readback_state),
        tostring(readback_detail), tostring(ctrl.pending_retries)))
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

  local startup_observed_flow = M.read_turbine_flow(ctx, turbine, caps)
  if type(startup_observed_flow) == "number" then
    local synced = M.clamp_turbine_flow(ctx, startup_observed_flow)
    ctrl.confirmed_flow = synced
    if not ctrl.startup_synced
        and ctx.turbine_regulator.sync_startup_state(ctrl, synced) then
      return true, false, "startup-sync-hold", "STARTUP_SYNC"
    end
  end

  local requested_flow, _, decision =
    M.update_turbine_flow_state(ctx, rpm, target_rpm, ctrl)

  local now_ts = os.clock()
  -- Analog zu reactor_control.lua's Rod-Write-Schutz: setFluidFlowRate()
  -- wird uebersprungen, wenn requested_flow exakt dem zuletzt erfolgreich
  -- geschriebenen Wert entspricht. Overspeed bleibt sofort wirksam, da der
  -- Overspeed-Zielwert bereits VOR dieser Stelle in requested_flow einfliesst
  -- (siehe update_turbine_flow_state()/overspeed_brake oben).
  local write
  if requested_flow == ctrl.last_written_flow then
    write = { ok = true, applied = true, setter = ctrl.last_write_setter,
      write_state = "WRITE_SKIPPED_UNCHANGED", write_detail = "unchanged" }
  else
    write = apply_turbine_flow_write(ctx, turbine, caps, requested_flow)
    if write.ok and write.applied then
      ctrl.last_written_flow = requested_flow
      ctrl.last_write_setter = write.setter
    end
  end
  local _, brake_detail = enforce_overspeed_brake_coil(ctx, name, turbine, caps, ctrl, decision)

  -- Nothing physically changed since startup_observed_flow was read above
  -- (no flow write, no fresh brake actuation) -- reuse it below instead of
  -- an identical fresh read.
  local reuse_flow = nil
  if write.write_state == "WRITE_SKIPPED_UNCHANGED"
      and brake_detail ~= "overspeed-coil-engaged"
      and type(startup_observed_flow) == "number" then
    reuse_flow = startup_observed_flow
  end

  local rail_cfg = ctx.config.rails and ctx.config.rails.turbine_flow or {}
  local flow_tolerance = ctx.flow_apply_helpers.capture_turbine_flow_readback(
    turbine, caps, ctrl, requested_flow, rail_cfg,
    function(t, c) return M.read_turbine_flow(ctx, t, c) end,
    function(rate) return M.clamp_turbine_flow(ctx, rate) end,
    reuse_flow)

  local confirmed_flow = ctrl.confirmed_flow
  local _, readback_state, readback_detail =
    ctx.flow_apply_helpers.update_turbine_flow_tracking(
      ctrl, requested_flow, confirmed_flow, flow_tolerance,
      rail_cfg, now_ts, decision, write.write_state, ctx.turbine_regulator)

  ctrl.last_requested_flow = requested_flow
  finalize_turbine_flow_apply(ctx, name, ctrl, requested_flow, decision,
    confirmed_flow, flow_tolerance, readback_state, readback_detail)

  if not write.ok then return false, write.applied, write.setter, "FLOW_SET_CALL_FAILED" end
  if not write.applied then return true, false, write.setter, "FLOW_SET_SKIPPED" end
  return true, true, write.setter, "FLOW_SET_OK"
end

-- ── Haupt-Tick ───────────────────────────────────────────────────────────────

function M.updateControl(ctx)
  if ctx.current_state() == ctx.STATE.INIT then return end

  -- Reaktoren aktiv halten (delegiert an reactor_control)
  for _, name in ipairs(ctx.config.reactors or {}) do
    -- Discovery-Cache verwenden statt peripheral.wrap() (teuer, Methoden-
    -- introspektion) bei jedem Regelzyklus neu aufzurufen. Fallback auf
    -- direkten Wrap bleibt fuer den Fall, dass ein Geraet noch nicht im
    -- Discovery-Cache steht.
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
      local reactor_ctrl = ctx.reactor_control.ensure_reactor_ctrl(ctx, name)
      local ok_active, active_result = pcall(
        ctx.reactor_control.setReactorActive, ctx, reactor, caps, true, reactor_ctrl)
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
      if not ctx.autonom_control_logged then
        ctx.autonom_control_logged = true
      end
      ::continue_control_reactor::
    end
  end

  local turbine_index = 0

  for _, name in ipairs(ctx.config.turbines or {}) do
    local ctrl = get_turbine_ctrl(ctx, name)
    turbine_index = turbine_index + 1

    -- Gleiches Discovery-Cache-Muster wie oben bei Reaktoren.
    local turbine = ctx.peripherals and ctx.peripherals.turbines and ctx.peripherals.turbines[name]
    local ok = turbine ~= nil
    if not ok then
      ok, turbine = pcall(peripheral.wrap, name)
    end
    if not ok or not turbine then
      ctx.warn_once("turbine_wrap:" .. name,
        "Turbine wrap failed for " .. name .. ": " .. tostring(turbine))
      goto continue_control_turbine
    end

    local caps = M.get_device_caps(ctx, "turbines", name)
    local has_flow_api, flow_api_reason = turbine_has_flow_setter(ctx, turbine, caps)
    if not has_flow_api then
      ctrl.flow_api_missing_ticks = (ctrl.flow_api_missing_ticks or 0) + 1
      if ctrl.flow_api_missing_ticks >= 5 then
        warn_unsupported(ctx, name, flow_api_reason)
      end
      goto continue_control_turbine
    end
    ctrl.flow_api_missing_ticks = 0

    local ok_active, active_result = pcall(M.setTurbineActive, ctx, turbine, caps, true, ctrl)
    if not ok_active then
      ctx.warn_once("turbine_active:" .. name,
        "Turbine activate failed for " .. name .. ": " .. tostring(active_result))
    elseif not active_result then
      ctx.warn_once("turbine_set_active_unavailable:" .. name,
        "Turbine active API unavailable for " .. name .. " (continuing with flow control)")
    end

    local rpm, rpm_cached = cached_rotor_rpm(ctx, name)
    if not rpm_cached then
      rpm = nil
      if turbine.getRotorSpeed then
        local rpm_ok, value = ctx.safe_wrapped_call(turbine, "getRotorSpeed")
        if rpm_ok and type(value) == "number" then rpm = value end
      end
    end

    local effective_target = M.get_turbine_target_rpm(ctx, turbine_index)
    local ok_inductor, inductor_result = M.update_inductor_for_rpm(
      ctx, name, turbine, caps, rpm, effective_target)
    if not ok_inductor then
      ctx.warn_once("turbine_inductor:" .. name,
        "Turbine inductor update failed for " .. name .. ": " .. tostring(inductor_result))
    end

    local set_ok, result, _, apply_reason =
      M.apply_turbine_flow(ctx, name, turbine, caps, rpm, effective_target)
    if not set_ok then
      ctx.warn_once("turbine_flow:" .. name,
        "Turbine flow update failed for " .. name .. ": " .. tostring(result)
        .. " reason=" .. tostring(apply_reason))
      goto continue_control_turbine
    end
    if not result then
      goto continue_control_turbine
    end

    if not ctx.autonom_control_logged then
      ctx.autonom_control_logged = true
    end
    ::continue_control_turbine::
  end
end

return M
