-- nodes/rt/reactor_control.lua
--
-- Reaktor-Regelung: Steam-Margin-Regler, Rod-Steuerung, Coolant-Überwachung.
-- Ausgelagert aus nodes/rt/main.lua (RT-Node Rewrite, schrittweise).
--
-- SCHNITTSTELLE: Alle öffentlichen Funktionen nehmen ctx als ersten Parameter.
-- ctx bündelt den gesamten mutable State, den der Reaktor-Regler braucht.
-- Damit sind alle Abhängigkeiten einer Funktion am Funktionskopf sichtbar
-- (kein versteckter Zugriff über main.lua-Closures mehr).
--
-- ctx-Felder die dieser Modul liest/schreibt:
--   ctx.reactor_ctrl      -- { [name] = { last_applied, last_known_rods, ... } }
--   ctx.autonom_state     -- { pending_rod_direction, ... }
--   ctx.peripherals       -- { reactors = { [name] = peripheral } }
--   ctx.warned            -- { [key] = true } einmalige Warn-Flags
--   ctx.capacity_learning -- learning-State (wird beim Init aus Cache geladen)
--   ctx.last_reactor_tick        -- os.clock() Zeitstempel
--   ctx.last_reactor_debug_log   -- os.clock() Zeitstempel
--   ctx.last_applied_rods        -- letzter angewandter Rod-Level
--   ctx.last_rod_apply_ts        -- os.clock() wann zuletzt angewendet
--   ctx.last_rod_change_ts       -- os.clock() wann sich Richtung geändert hat
--   ctx.last_rod_direction       -- "UP" | "DOWN" | nil
--   ctx.last_reactor_demand      -- letzter Steam-Margin-Wert
--   ctx.steam_tank_name          -- gecachter Name des Steam-Tanks
--   ctx.reactor_rails_state      -- rails EMA-State für Reaktor-Regler
--   ctx.reactor_steam_guard_state-- Steam-Guard EMA-State
--   ctx.config     -- node config (reactors, turbines, rails, safety, autonom)
--   ctx.CONFIG     -- Konstanten (ROD_MIN, ROD_MAX, etc.)
--   ctx.adapters   -- { reactor = ..., turbine }
--   ctx.safety     -- safety-Modul
--   ctx.rails      -- rails-Modul
--   ctx.fluid      -- fluid-Modul
--   ctx.reactor_steam_guard -- reactor_steam_guard-Modul
--   ctx.utils      -- utils-Modul
--   ctx.log        -- function(level, msg)
--   ctx.warn_once  -- function(key, msg) — einmalige Warnungen
--   ctx.load_capacity_cache -- function() -> cache | nil
--   ctx.current_state      -- function() -> STATE.*
--   ctx.STATE      -- { INIT, AUTONOM, MASTER, SAFE }

local M = {}

-- ── Rod-Grenzen und Clamping ────────────────────────────────────────────────

function M.get_effective_regulator_rod_caps(ctx)
  local rod_rails = ctx.config.rails and ctx.config.rails.reactor_rods or {}
  local cfg_min = type(rod_rails.min) == "number" and rod_rails.min or ctx.CONFIG.ROD_MIN
  local cfg_max = type(rod_rails.max) == "number" and rod_rails.max or ctx.CONFIG.ROD_MAX
  cfg_min = ctx.safety.clamp(cfg_min, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)
  cfg_max = ctx.safety.clamp(cfg_max, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)
  if cfg_min > cfg_max then cfg_min, cfg_max = cfg_max, cfg_min end
  return cfg_min, cfg_max
end

function M.clamp_rods(ctx, level, allow_overmax)
  if type(level) ~= "number" then level = ctx.CONFIG.ROD_MAX end
  local max_limit = allow_overmax and 100 or ctx.CONFIG.ROD_MAX
  return ctx.safety.clamp(level, ctx.CONFIG.ROD_MIN, max_limit)
end

-- ── Steam-Quellen-Erkennung und -Messung ────────────────────────────────────

function M.resolve_steam_tank_name(ctx)
  if ctx.steam_tank_name and peripheral.isPresent(ctx.steam_tank_name) then
    return ctx.steam_tank_name
  end
  for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    if ptype and string.find(ptype, "ultimate_fluid_tank") then
      ctx.steam_tank_name = name
      return ctx.steam_tank_name
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if string.find(string.lower(name), "steam") then
      local tank = ctx.utils.safe_wrap(name)
      if tank and (tank.tanks or tank.getFluidAmount) then
        ctx.steam_tank_name = name
        return ctx.steam_tank_name
      end
    end
  end
  return nil
end

function M.read_steam_tank_amount(ctx)
  local name = M.resolve_steam_tank_name(ctx)
  if not name then return nil end
  local tank, err = ctx.utils.safe_wrap(name)
  if not tank then
    ctx.warn_once("steam_tank_wrap:" .. name,
      "Steam tank wrap failed for " .. name .. ": " .. tostring(err))
    return nil
  end
  local amount, read_err = ctx.fluid.read_amount(tank, { "getFluidAmount" })
  if type(amount) == "number" then return amount end
  ctx.warn_once("steam_tank_read:" .. tostring(name),
    "Steam tank read failed for " .. tostring(name) .. ": " .. tostring(read_err))
  return nil
end

function M.read_reactor_steam_amount(ctx)
  local total, found = 0, false
  for _, name in ipairs(ctx.config.reactors or {}) do
    local reactor = ctx.peripherals.reactors[name]
    if not reactor then
      local wrapped, err = ctx.utils.safe_wrap(name)
      if wrapped then reactor = wrapped
      else ctx.warn_once("reactor_wrap:" .. name,
        "Reactor wrap failed for " .. name .. ": " .. tostring(err)) end
    end
    if reactor then
      local amount = ctx.fluid.read_amount(reactor,
        { "getHotFluidAmount", "getSteamAmount", "getSteam" })
      if type(amount) == "number" then total = total + amount; found = true end
    end
  end
  return found and total or nil
end

function M.read_reactor_internal_steam_fill_ratio(ctx)
  local total_amount, total_capacity, found = 0, 0, false
  for _, name in ipairs(ctx.config.reactors or {}) do
    local reactor = ctx.peripherals.reactors[name]
    if not reactor then
      local wrapped = ctx.utils.safe_wrap(name)
      if wrapped then reactor = wrapped end
    end
    if reactor then
      local amount = ctx.fluid.read_amount(reactor,
        { "getHotFluidAmount", "getSteamAmount", "getSteam" })
      if type(amount) == "number" then
        local capacity = ctx.fluid.read_capacity(reactor,
          { "getHotFluidAmountMax", "getSteamAmountMax",
            "getHotFluidCapacity", "getSteamCapacity" })
        if type(capacity) == "number" and capacity > 0 then
          total_amount = total_amount + amount
          total_capacity = total_capacity + capacity
          found = true
        end
      end
    end
  end
  if found and total_capacity > 0 then
    return ctx.safety.clamp(total_amount / total_capacity, 0, 1),
           total_amount, total_capacity
  end
  return nil, nil, nil
end

-- Feature (2026-07-06): echte Pro-Reaktor-Variante fuer unabhaengige
-- Regelung mehrerer Reaktoren an einem RT-Node. Liest NUR den internen
-- Dampf-Fuellstand des angegebenen Reaktors, nicht die Summe aller.
-- Grund fuer diesen Ansatz statt Turbinen-Zuordnung: es gibt keine
-- explizite Turbinen-zu-Reaktor-Zuordnung im System (rein gemeinsamer
-- Datenbus), aber jeder Reaktor hat seinen EIGENEN internen Dampf-
-- Speicher, unabhaengig davon welche Turbinen tatsaechlich daran haengen.
-- Sinkt der Fuellstand eines Reaktors (er liefert weniger Dampf als seine
-- angeschlossenen Turbinen verbrauchen), muss dieser Reaktor individuell
-- hochgeregelt werden — unabhaengig vom Zustand des anderen Reaktors.
function M.read_reactor_internal_steam_fill_ratio_for(ctx, name)
  local reactor = ctx.peripherals.reactors[name]
  if not reactor then
    local wrapped = ctx.utils.safe_wrap(name)
    if wrapped then reactor = wrapped end
  end
  if not reactor then return nil, nil, nil end
  local amount = ctx.fluid.read_amount(reactor,
    { "getHotFluidAmount", "getSteamAmount", "getSteam" })
  if type(amount) ~= "number" then return nil, nil, nil end
  local capacity = ctx.fluid.read_capacity(reactor,
    { "getHotFluidAmountMax", "getSteamAmountMax",
      "getHotFluidCapacity", "getSteamCapacity" })
  if type(capacity) ~= "number" or capacity <= 0 then return nil, nil, nil end
  return ctx.safety.clamp(amount / capacity, 0, 1), amount, capacity
end

function M.get_available_steam(ctx)
  local tank_amount = M.read_steam_tank_amount(ctx)
  if type(tank_amount) == "number" then return tank_amount end
  return M.read_reactor_steam_amount(ctx)
end

-- ── Gesamt-Dampfbedarf aller Turbinen ───────────────────────────────────────
-- Hinweis: greift auf ctx.turbine_ctrl_store zu (vom Turbinen-Modul befüllt).
-- Dadurch gibt es eine leichte Kopplung zwischen Reaktor- und Turbinen-Modul —
-- bewusst akzeptiert, da der Steam-Margin-Regler genau diesen Gesamtbedarf
-- der Turbinen kennen muss, um den Reaktor korrekt zu steuern.
function M.get_total_steam_demand(ctx)
  local total = 0
  local learning_ready = ctx.capacity_learning and ctx.capacity_learning.ready == true
  for _, name in ipairs(ctx.config.turbines or {}) do
    local ctrl = ctx.get_turbine_ctrl(name)
    local rpm = ctrl.rpm
    if type(rpm) ~= "number" then
      local turbine = ctx.peripherals.turbines[name]
      if not turbine then
        local wrapped, err = ctx.utils.safe_wrap(name)
        if wrapped then turbine = wrapped
        else ctx.warn_once("turbine_wrap:" .. name,
          "Turbine wrap failed for " .. name .. ": " .. tostring(err)) end
      end
      if turbine and turbine.getRotorSpeed then
        local ok, value = ctx.safe_wrapped_call(turbine, "getRotorSpeed")
        if ok and type(value) == "number" then rpm = value end
      end
    end
    local requested = ctrl.confirmed_flow or ctrl.requested_flow or ctrl.flow or 0
    local rpm_active = type(rpm) == "number" and rpm > ctx.CONFIG.MIN_ACTIVE_RPM
    local learning_startup_demand = not learning_ready and requested > 0
    if rpm_active or learning_startup_demand then
      total = total + requested
    end
  end
  return total
end

-- ── Coolant-Prüfung ─────────────────────────────────────────────────────────

function M.evaluate_reactor_coolant(ctx, reactor, state)
  local sample = ctx.fluid.read_coolant_sample(reactor, ctx.safe_wrapped_call)
  return ctx.safety.evaluate_coolant_limit({
    coolant_amount             = sample.coolant_amount,
    coolant_amount_max         = sample.coolant_amount_max,
    coolant_ratio              = sample.coolant_ratio,
    source                     = sample.source,
    source_method              = sample.source_method,
    measurement_state          = sample.measurement_state,
    min_water                  = ctx.config.safety.min_water,
    hysteresis                 = ctx.config.safety.coolant_hysteresis,
    trip_samples               = ctx.config.safety.coolant_trip_samples,
    invalid_grace_samples      = ctx.config.safety.coolant_invalid_grace_samples,
    zero_glitch_grace_samples  = ctx.config.safety.coolant_zero_glitch_grace_samples,
    state                      = state
  })
end

-- ── Ramp-Hilfsfunktion (auch von Lifecycle genutzt) ─────────────────────────

function M.ramp_towards(current, target, step)
  if current == nil then return target end
  local delta = target - current
  if math.abs(delta) <= step then return target end
  return current + (delta > 0 and step or -step)
end

-- ── Reaktor-Control-State-Verwaltung ────────────────────────────────────────

function M.ensure_reactor_ctrl(ctx, name)
  local ctrl = ctx.reactor_ctrl[name]
  if not ctrl then
    ctrl = { last_steam_pct = nil, last_applied = nil,
             last_adjust = 0, initialized = false }
    ctx.reactor_ctrl[name] = ctrl
  end
  return ctrl
end

function M.init_reactor_ctrl(ctx)
  ctx.reactor_ctrl = {}
  ctx.reactor_steam_guard_state = {}
  for _, name in ipairs(ctx.config.reactors or {}) do
    ctx.reactor_ctrl[name] = {
      last_steam_pct = nil, last_applied = nil,
      last_adjust = 0, initialized = false
    }
  end
end

-- ── Rod-Ansteuerung ─────────────────────────────────────────────────────────

-- Prüft ob ein Reaktor-Peripheral einen Rod-Write-Pfad hat.
-- Wird von turbine_control.updateControl() genutzt um zu entscheiden
-- ob ein Reaktor gesteuert werden kann.
function M.has_reactor_rod_write_path(caps)
  return caps and (
    caps.setAllControlRodLevels or
    caps.setControlRodsLevels   or
    caps.setControlRodLevel     or
    caps.getControlRods
  ) and true or false
end

function M.setReactorActive(ctx, reactor, caps, active)
  if caps.setActive then reactor.setActive(active); return true end
  return false
end

function M.read_current_rods(ctx)
  for _, name in ipairs(ctx.config.reactors or {}) do
    local current_rods = ctx.adapters.reactor.read_control_rods(
      name, ctx.CONFIG.LOG_PREFIX)
    if type(current_rods) == "number" then
      local ctrl = M.ensure_reactor_ctrl(ctx, name)
      ctrl.last_known_rods = current_rods
      return current_rods
    end
    local ctrl = ctx.reactor_ctrl[name]
    if ctrl and type(ctrl.last_known_rods) == "number" then
      return ctrl.last_known_rods
    end
  end
  return nil
end

-- Feature (2026-07-06): Pro-Reaktor-Variante, liest NUR den Rod-Wert des
-- angegebenen Reaktors (nicht "irgendeinen ersten gefundenen" wie
-- M.read_current_rods oben, das fuer die individuelle Regelung mehrerer
-- Reaktoren ungeeignet ist).
function M.read_current_rods_for(ctx, name)
  local current_rods = ctx.adapters.reactor.read_control_rods(name, ctx.CONFIG.LOG_PREFIX)
  local ctrl = M.ensure_reactor_ctrl(ctx, name)
  if type(current_rods) == "number" then
    ctrl.last_known_rods = current_rods
    return current_rods
  end
  if type(ctrl.last_known_rods) == "number" then
    return ctrl.last_known_rods
  end
  return nil
end

-- Feature (2026-07-06): echte Pro-Reaktor-Variante fuer unabhaengige
-- Regelung. Nutzt EIGENES Rate-Limiting (ctrl.last_rod_apply_ts) statt des
-- globalen ctx.last_rod_apply_ts/ctx.last_applied_rods — sonst wuerde ein
-- Rod-Write auf Reaktor A das Rate-Limit fuer Reaktor B ebenfalls
-- auslösen, obwohl beide unabhaengig regeln sollen. Schreibt NUR auf den
-- angegebenen Reaktor, nicht auf alle in ctx.reactor_ctrl.
function M.applyReactorRodsFor(ctx, name, target, allow_overmax, source)
  local ctrl = M.ensure_reactor_ctrl(ctx, name)
  local now = os.clock()
  if now - (ctrl.last_rod_apply_ts or 0) < ctx.CONFIG.MIN_APPLY_INTERVAL then
    return false
  end
  if type(target) ~= "number" then return false end
  source = source or "UNSPECIFIED"

  local clamped = M.clamp_rods(ctx, target, allow_overmax)
  if not allow_overmax and ctx.current_state() ~= ctx.STATE.SAFE then
    local cfg_min, cfg_max = M.get_effective_regulator_rod_caps(ctx)
    local cap_clamped, _cap_reason = ctx.rails.clamp_with_reason(clamped, cfg_min, cfg_max)
    clamped = cap_clamped
  end

  if ctrl.last_applied == clamped then
    ctrl.pending_rod_direction = nil
    return false
  end

  local ok_apply, err_apply = ctx.adapters.reactor.apply_rod_level(name, clamped, ctx.CONFIG.LOG_PREFIX)
  if not ok_apply then
    ctx.warn_once("reactor_rods:" .. name,
      "Reactor control rod write failed for " .. tostring(name) .. ": " .. tostring(err_apply))
    return false
  end

  ctrl.last_applied = clamped
  ctrl.last_known_rods = clamped
  ctrl.last_rod_apply_ts = now
  return true, clamped
end

function M.applyReactorRods(ctx, target, allow_overmax, source)
  local now = os.clock()
  if now - ctx.last_rod_apply_ts < ctx.CONFIG.MIN_APPLY_INTERVAL then
    return false
  end
  if type(target) ~= "number" then return false end
  source = source or "UNSPECIFIED"

  local clamped = M.clamp_rods(ctx, target, allow_overmax)
  if not allow_overmax and ctx.current_state() ~= ctx.STATE.SAFE then
    local cfg_min, cfg_max = M.get_effective_regulator_rod_caps(ctx)
    local cap_clamped, cap_reason = ctx.rails.clamp_with_reason(
      clamped, cfg_min, cfg_max)
    if cap_reason == "MIN" then
    elseif cap_reason == "MAX" then
    end
    clamped = cap_clamped
  elseif allow_overmax then
  end

  if ctx.last_applied_rods == clamped then
    ctx.autonom_state.pending_rod_direction = nil
    return false
  end

  local applied = false
  for name, ctrl in pairs(ctx.reactor_ctrl) do
    local ok_apply, err_apply = ctx.adapters.reactor.apply_rod_level(
      name, clamped, ctx.CONFIG.LOG_PREFIX)
    if ok_apply then
      ctrl.last_applied = clamped
      ctrl.last_known_rods = clamped
      applied = true
    else
      ctx.warn_once("reactor_rods:" .. name,
        "Reactor control rod write failed for " .. tostring(name)
        .. ": " .. tostring(err_apply))
    end
  end
  if not applied then return false end

  local previous_applied = ctx.last_applied_rods
  ctx.last_applied_rods = clamped
  ctx.last_rod_apply_ts = now

  local applied_direction = ctx.autonom_state.pending_rod_direction
  if applied_direction == nil and type(previous_applied) == "number" then
    if clamped < previous_applied then applied_direction = "DOWN"
    elseif clamped > previous_applied then applied_direction = "UP" end
  end
  if applied_direction ~= nil then
    ctx.last_rod_change_ts = now
    ctx.last_rod_direction = applied_direction
  end
  ctx.autonom_state.pending_rod_direction = nil
  return true
end

function M.apply_initial_reactor_rods(ctx)
  for name, ctrl in pairs(ctx.reactor_ctrl) do
    ctrl.last_applied = nil
    ctx.log("INFO", "Reactor " .. name .. " initial rods set to "
      .. tostring(ctx.CONFIG.INITIAL_ROD_LEVEL) .. "%")
  end
  local cached = ctx.load_capacity_cache()
  if cached then
    ctx.capacity_learning = cached
    ctx.log("INFO", string.format(
      "Capacity loaded from cache: max_output=%.2f reason=%s",
      cached.max_output, tostring(cached.reason)))
  end
  M.applyReactorRods(ctx, ctx.CONFIG.INITIAL_ROD_LEVEL, false, "STARTUP_INIT")
end

-- ── Diagnose-Logging ────────────────────────────────────────────────────────

function M.log_reactor_control_state(ctx)
  local now = os.clock()
  if now - ctx.last_reactor_debug_log < 5 then return end
  ctx.last_reactor_debug_log = now
  local sample_rods = M.read_current_rods(ctx) or ctx.last_applied_rods or "n/a"
  local tick_age = now - ctx.last_reactor_tick
end

function M.log_reactor_control_tick(ctx)
  local sample_demand = ctx.last_reactor_demand
  local age = os.clock() - ctx.last_rod_change_ts
end

-- ── Kernregler: Steam-Margin → Rod-Niveau ───────────────────────────────────

-- ── Individuelle Pro-Reaktor-Regelung (Feature, 2026-07-06) ─────────────────
--
-- Ersatz fuer M.controlReactor() bei Setups mit mehreren Reaktoren an einem
-- RT-Node (z.B. 2 Reaktoren + gemeinsamer 50-Turbinen-Pool an einem
-- Datenbus, ohne explizite Turbinen-zu-Reaktor-Zuordnung). Da nicht
-- bekannt ist, welche Turbine zu welchem Reaktor Dampf liefert, wird
-- stattdessen der EIGENE interne Dampf-Fuellstand jedes Reaktors als
-- Regelgroesse genutzt: sinkt der Fuellstand (der Reaktor liefert weniger
-- Dampf als seine tatsaechlich angeschlossenen Turbinen verbrauchen),
-- werden seine Rods individuell hochgeregelt — unabhaengig vom Zustand
-- des anderen Reaktors. Jeder Reaktor bekommt dafuer einen eigenen
-- EMA-/Rails-State (ctrl.rails_state) und eigenen Steam-Guard-State
-- (ctrl.steam_guard_state), statt der bisherigen globalen ctx.reactor_
-- rails_state/ctx.reactor_steam_guard_state, die alle Reaktoren zwang,
-- exakt denselben Rod-Wert zu bekommen.
--
-- Zielwert der Regelung: internal_fill_ratio soll um einen konfigurierten
-- Sollwert (Default 50%, ctx.config.rails.reactor_fill_target) stabil
-- bleiben — sinkt er, braucht der Reaktor mehr Leistung (Rods runter,
-- mehr Reaktion, mehr Dampf); steigt er ueber den Zielwert, kann der
-- Reaktor gedrosselt werden (Rods hoch).
function M.controlReactorsIndividually(ctx)
  local reactors = ctx.config.reactors or {}
  if #reactors == 0 then return end

  local rod_cfg = ctx.config.rails and ctx.config.rails.reactor_rods or {}
  local steam_guard_cfg = ctx.config.rails and ctx.config.rails.reactor_steam_guard or {}
  local fill_target = (ctx.config.rails and ctx.config.rails.reactor_fill_target) or 0.5

  for _, name in ipairs(reactors) do
    local ctrl = M.ensure_reactor_ctrl(ctx, name)
    ctrl.rails_state = ctrl.rails_state or ctx.rails.new_state()
    ctrl.steam_guard_state = ctrl.steam_guard_state or {}

    local current_rods = M.read_current_rods_for(ctx, name)
    if type(current_rods) ~= "number" then
      ctx.warn_once("reactor_rods_unreadable:" .. name,
        "Reactor control rods unreadable for " .. tostring(name))
      goto continue_reactor
    end

    local fill_ratio, fill_amount, fill_capacity =
      M.read_reactor_internal_steam_fill_ratio_for(ctx, name)
    if type(fill_ratio) ~= "number" then
      -- Kein lesbarer interner Dampf-Speicher fuer diesen Reaktor (z.B.
      -- Peripheral kurzzeitig nicht erreichbar) — diesen Tick fuer DIESEN
      -- Reaktor uebergehen, der andere Reaktor ist davon nicht betroffen.
      goto continue_reactor
    end

    -- Fuellstand UNTER dem Zielwert = positive Margin (mehr Leistung
    -- noetig, Rods sollen sinken); darueber = negative Margin (drosseln).
    -- Vorzeichen so gewaehlt, dass dieselbe rails.step()-Logik wie beim
    -- alten, globalen steam_margin-Regler weiterverwendet werden kann.
    local fill_margin = (fill_target - fill_ratio) * (fill_capacity or 1)

    local smoothed_margin = ctx.rails.smooth(
      ctrl.rails_state, "steam_margin", fill_margin, rod_cfg.ema_alpha)
    local target_rods, direction = ctx.rails.step(
      current_rods, smoothed_margin, ctrl.rails_state, rod_cfg, os.clock())
    target_rods = ctx.safety.clamp(target_rods, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)

    local cfg_min, cfg_max = M.get_effective_regulator_rod_caps(ctx)
    local clamped_target, _clamp_reason = ctx.rails.clamp_with_reason(target_rods, cfg_min, cfg_max)
    target_rods = clamped_target

    local guard_target = target_rods
    local guard_diag = { unavailable = true, high_active = false, critical_active = false,
      blocked_opening = false, forced_closing = false }
    if steam_guard_cfg.enabled ~= false then
      guard_target, guard_diag = ctx.reactor_steam_guard.apply(
        current_rods, target_rods, fill_ratio, steam_guard_cfg, ctrl.steam_guard_state)
      if type(guard_target) == "number" then target_rods = guard_target end
    end

    local reactor = ctx.peripherals.reactors[name]
    local coolant_sample = reactor and ctx.fluid.read_coolant_sample(reactor, ctx.safe_wrapped_call) or nil
    local coolant_ratio = coolant_sample and coolant_sample.coolant_ratio or nil

    local applied_rods, ramp_diag = ctx.rails.ramp_target(
      current_rods, target_rods, rod_cfg, {
        state             = ctrl.rails_state,
        now               = os.clock(),
        coolant_ratio     = coolant_ratio,
        safety_min_water  = ctx.config.safety and ctx.config.safety.min_water
      })
    applied_rods = ctx.safety.clamp(applied_rods, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)

    if applied_rods == current_rods then
      goto continue_reactor
    end

    if direction ~= 0 then
      ctrl.pending_rod_direction = direction > 0 and "UP" or "DOWN"
    end

    local applied, clamped_applied = M.applyReactorRodsFor(ctx, name, applied_rods, false, "AUTO_REGULATOR_INDIVIDUAL")
    if applied then
      ctx.log("INFO", string.format(
        "ReactorCtrl[%s] fill=%.1f%% margin=%.1f rods_current=%.1f rods_target=%.1f applied=%.1f"
        .. " ramp_reason=%s coolant_ratio=%s steam_guard_high=%s steam_guard_critical=%s",
        tostring(name), fill_ratio * 100, fill_margin, current_rods, target_rods, clamped_applied or applied_rods,
        tostring(ramp_diag and ramp_diag.reason or "n/a"),
        tostring(coolant_ratio),
        tostring(guard_diag and guard_diag.high_active == true),
        tostring(guard_diag and guard_diag.critical_active == true)))
    end

    ::continue_reactor::
  end
end

function M.controlReactor(ctx)
  local turbine_count = #(ctx.config.turbines or {})
  if turbine_count == 0 then return end

  local total_steam_demand = M.get_total_steam_demand(ctx)
  local available_steam = M.get_available_steam(ctx)
  if type(available_steam) ~= "number" then return end

  local steam_margin = available_steam - total_steam_demand
  ctx.last_reactor_demand = steam_margin

  local current_rods = M.read_current_rods(ctx)
  if type(current_rods) ~= "number" then
    ctx.log("ERROR", "Reactor control rods unreadable")
    return
  end

  local rod_cfg = ctx.config.rails and ctx.config.rails.reactor_rods or {}
  local smoothed_margin = ctx.rails.smooth(
    ctx.reactor_rails_state, "steam_margin", steam_margin, rod_cfg.ema_alpha)
  local target_rods, direction = ctx.rails.step(
    current_rods, smoothed_margin, ctx.reactor_rails_state, rod_cfg, os.clock())
  target_rods = ctx.safety.clamp(target_rods, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)

  do
    local cfg_min, cfg_max = M.get_effective_regulator_rod_caps(ctx)
    local clamped_target, clamp_reason = ctx.rails.clamp_with_reason(
      target_rods, cfg_min, cfg_max)
    if clamp_reason == "MIN" then
    elseif clamp_reason == "MAX" then
    end
    target_rods = clamped_target
  end

  local steam_guard_cfg = ctx.config.rails and ctx.config.rails.reactor_steam_guard or {}
  local pre_guard_target_rods = target_rods
  local internal_fill_ratio, internal_amount, internal_capacity =
    M.read_reactor_internal_steam_fill_ratio(ctx)

  local guard_target = target_rods
  local guard_diag = {
    unavailable = true, high_active = false, critical_active = false,
    blocked_opening = false, forced_closing = false
  }
  if steam_guard_cfg.enabled ~= false then
    guard_target, guard_diag = ctx.reactor_steam_guard.apply(
      current_rods, target_rods, internal_fill_ratio,
      steam_guard_cfg, ctx.reactor_steam_guard_state)
    if type(guard_target) == "number" then target_rods = guard_target end
  end

  local min_coolant_ratio
  for _, name in ipairs(ctx.config.reactors or {}) do
    local reactor = ctx.peripherals.reactors[name]
    local sample = reactor and ctx.fluid.read_coolant_sample(
      reactor, ctx.safe_wrapped_call) or nil
    local ratio = sample and sample.coolant_ratio or nil
    if type(ratio) == "number" and (min_coolant_ratio == nil or ratio < min_coolant_ratio) then
      min_coolant_ratio = ratio
    end
  end

  local applied_rods, ramp_diag = ctx.rails.ramp_target(
    current_rods, target_rods, rod_cfg, {
      state             = ctx.reactor_rails_state,
      now               = os.clock(),
      coolant_ratio     = min_coolant_ratio,
      safety_min_water  = ctx.config.safety and ctx.config.safety.min_water
    })
  applied_rods = ctx.safety.clamp(applied_rods, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)

  if applied_rods == current_rods then
    if ramp_diag and ramp_diag.reason == "RAMP_APPLIED" then
    end
    return
  end

  if direction ~= 0 then
    ctx.autonom_state.pending_rod_direction = direction > 0 and "UP" or "DOWN"
  end

  local applied = M.applyReactorRods(ctx, applied_rods, false, "AUTO_REGULATOR")
  if applied then
    local limited = ramp_diag and
      math.abs(tonumber(ramp_diag.applied_delta) or 0) <
      math.abs(tonumber(ramp_diag.requested_delta) or 0)
    ctx.log("INFO", string.format(
      "ReactorCtrl margin=%.1f rods_current=%.1f rods_target=%.1f"
      .. " requested_delta=%.1f applied_delta=%.1f ramp_reason=%s rate_limited=%s"
      .. " coolant_ratio=%s coolant_limited=%s internal_steam_ratio=%s"
      .. " internal_steam_ratio_ema=%s internal_steam_amount=%s internal_steam_capacity=%s"
      .. " steam_guard_high=%s steam_guard_critical=%s steam_guard_block_open=%s"
      .. " steam_guard_force_close=%s steam_guard_unavailable=%s",
      steam_margin, current_rods, target_rods,
      (ramp_diag and ramp_diag.requested_delta) or 0,
      (ramp_diag and ramp_diag.applied_delta) or (applied_rods - current_rods),
      tostring(ramp_diag and ramp_diag.reason or "n/a"),
      tostring(limited),
      tostring(min_coolant_ratio),
      tostring(ramp_diag and ramp_diag.coolant_limited == true),
      tostring(guard_diag and guard_diag.raw_ratio),
      tostring(guard_diag and guard_diag.ema_ratio),
      tostring(internal_amount), tostring(internal_capacity),
      tostring(guard_diag and guard_diag.high_active == true),
      tostring(guard_diag and guard_diag.critical_active == true),
      tostring(guard_diag and guard_diag.blocked_opening == true),
      tostring(guard_diag and guard_diag.forced_closing == true),
      tostring(guard_diag and guard_diag.unavailable == true)))

    if limited then
    end
    if ramp_diag and ramp_diag.coolant_limited then
    end
    if guard_diag and guard_diag.blocked_opening then
    end
    if guard_diag and guard_diag.forced_closing then
    end
  end
end

-- ── Haupt-Tick-Einsprungpunkt ────────────────────────────────────────────────

function M.updateReactorControl(ctx)
  local now = os.clock()
  -- Reactor control tick debug (zu häufig entfernt)
  if ctx.current_state() == ctx.STATE.SAFE then
    M.applyReactorRods(ctx, ctx.CONFIG.ROD_MAX, true, "SAFE_TICK")
    -- SAFE-Exit: Wenn alle Reaktoren unter Limit - Hysterese gekühlt sind
    -- verlassen wir den SAFE-Mode automatisch damit kein Neustart nötig ist.
    local safe_cfg = ctx.config.safety or {}
    local limit       = safe_cfg.max_temperature    or 2000
    local hysteresis  = safe_cfg.temperature_hysteresis or 50
    local recover_at  = limit - hysteresis  -- z.B. 1950°C
    local all_cool    = true
    for _, name in ipairs(ctx.config.reactors or {}) do
      local reactor = ctx.peripherals and ctx.peripherals.reactors and ctx.peripherals.reactors[name]
      if reactor then
        local ok_f, fuel = pcall(function() return reactor.getFuelTemperature() end)
        local ok_c, cas  = pcall(function() return reactor.getCasingTemperature() end)
        local temp = (ok_f and type(fuel) == "number" and fuel > 0 and fuel)
                  or (ok_c and type(cas)  == "number" and cas  > 0 and cas)
                  or recover_at + 1  -- unbekannt → sicher bleiben
        if temp >= recover_at then all_cool = false; break end
      end
    end
    if all_cool and #(ctx.config.reactors or {}) > 0 then
      ctx.log("INFO", string.format(
        "SAFE-Mode Exit: alle Reaktoren unter %.0f°C (limit=%.0f hysteresis=%.0f)",
        recover_at, limit, hysteresis))
      ctx.setState(ctx.STATE.MASTER, "SAFETY_TEMPERATURE_RECOVERED")
    end
    return
  end
  if now - ctx.last_reactor_tick <
      (ctx.config.autonom and ctx.config.autonom.reactor_adjust_interval or 1) then
    return
  end
  ctx.last_reactor_tick = now
  M.log_reactor_control_state(ctx)
  -- Feature (2026-07-06): bei genau einem Reaktor bleibt die bisherige,
  -- global-gemeinsame Regelung (M.controlReactor) unveraendert aktiv —
  -- kein Verhaltenswechsel fuer die grosse Mehrheit der Setups mit nur
  -- einem Reaktor pro RT-Node. Bei mehreren Reaktoren an einem Node (z.B.
  -- 2 Reaktoren + gemeinsamer Turbinen-Pool) wird jeder Reaktor jetzt
  -- individuell anhand seines EIGENEN internen Dampf-Fuellstands
  -- geregelt, siehe M.controlReactorsIndividually().
  if #(ctx.config.reactors or {}) > 1 then
    M.controlReactorsIndividually(ctx)
  else
    M.controlReactor(ctx)
  end
  M.log_reactor_control_tick(ctx)
end

return M