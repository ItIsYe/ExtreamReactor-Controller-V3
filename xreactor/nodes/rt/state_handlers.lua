local M = {}

-- Fallback for callers that omit ctx.constants (e.g. main.lua's apply_mode
-- closure previously did -- production crash: "attempt to index a nil
-- value" at the (ctx.constants or constants).node_states lookups below,
-- since this module never required its own constants and the bare name
-- was simply an undefined global). Callers should still pass ctx.constants
-- explicitly where practical; this is the safety net, not the primary path.
local constants = require("shared.constants")

local function has_off_modules(modules, kind)
  for _, module in pairs(modules or {}) do
    if module.type == kind and module.state == "OFF" then
      return true
    end
  end
  return false
end

function M.build(ctx)
  local function assert_fn(name)
    if type(ctx[name]) ~= "function" then
      error("state handler context missing function: " .. tostring(name), 2)
    end
    return ctx[name]
  end

  local adjust_reactors = assert_fn("adjust_reactors")
  local adjust_turbines = assert_fn("adjust_turbines")
  assert_fn("is_master_connected")

  local constants = ctx.constants
  local STATE = ctx.STATE

  local function off_on_enter()
    ctx.reset_startup_watchdog()
    ctx.scram()
    ctx.targets.power, ctx.targets.steam, ctx.targets.rpm = 0, 0, 0
  end

  local function off_on_tick()
    ctx.monitor_master()
  end

  local function startup_on_enter()
    ctx.set_startup_started_ms(os.epoch("utc"))
    ctx.set_startup_watchdog_tripped(false)
    ctx.targets.steam = 0
    ctx.targets.rpm = ctx.get_target_rpm()
    local queue = {}
    for _, entry in ipairs(ctx.devices.turbines or {}) do
      local module = ctx.modules[entry.id]
      if module and module.state == "OFF" and ctx.targets.enable_turbines ~= false then
        table.insert(queue, entry.id)
      end
    end
    for _, entry in ipairs(ctx.devices.reactors or {}) do
      local module = ctx.modules[entry.id]
      if module and module.state == "OFF" and ctx.targets.enable_reactors ~= false then
        table.insert(queue, entry.id)
      end
    end
    ctx.set_startup_queue(queue)
  end

  local function startup_on_tick()
    local startup_started_ms = ctx.get_startup_started_ms()
    if startup_started_ms and not ctx.get_startup_watchdog_tripped() then
      local now = os.epoch("utc")
      if now - startup_started_ms >= (ctx.config.startup_watchdog_s or 60) * 1000 then
        ctx.handle_startup_timeout()
      end
    end
    if not ctx.get_active_startup() and #ctx.get_startup_queue() > 0 then
      local next_id = table.remove(ctx.get_startup_queue(), 1)
      local module = ctx.modules[next_id]
      if module then
        ctx.start_module(module.id, module.type, "NORMAL")
      end
    end
    adjust_turbines()
    adjust_reactors()
    ctx.monitor_master()
    if not ctx.get_active_startup() and #ctx.get_startup_queue() == 0 then
      ctx.get_node_state_machine():transition(constants.node_states.RUNNING)
    end
  end

  local function running_on_enter()
    ctx.reset_startup_watchdog()
  end

  local function running_on_tick()
    adjust_turbines()
    adjust_reactors()
    ctx.monitor_master()
  end

  local function limited_on_enter()
    ctx.reset_startup_watchdog()
  end

  local function limited_on_tick()
    -- Fix #9: ctx.targets.power * 0.5 war ein Bug -- halbierte den Power-Target
    -- jeden einzelnen Tick (~alle 0.2s), was den Wert innerhalb von Sekunden
    -- auf null reduziert hätte. Im LIMITED-State laufen Reactor/Turbine normal weiter;
    -- die Leistungsreduzierung wird vom Master via SET_SETPOINTS gesteuert.
    adjust_reactors()
    adjust_turbines()
    ctx.monitor_master()
  end

  local function autonom_on_enter()
    ctx.reset_startup_watchdog()
    ctx.set_active_startup(nil)
    ctx.set_startup_queue({})
    ctx.clamp_autonom_targets()
  end

  local function autonom_on_tick()
    ctx.clamp_autonom_targets()
    adjust_reactors()
    adjust_turbines()
    if ctx.get_current_state() == STATE.MASTER then
      ctx.get_node_state_machine():transition(constants.node_states.RUNNING)
    end
  end

  local function manual_on_enter()
    ctx.reset_startup_watchdog()
  end

  local function manual_on_tick()
    ctx.monitor_master()
  end

  local function emergency_on_enter()
    ctx.reset_startup_watchdog()
    ctx.scram()
    ctx.targets.power, ctx.targets.steam, ctx.targets.rpm = 0, 0, 0
    local _alarm_id = ctx.comms and ctx.comms.network and ctx.comms.network.id or "RT"
    ctx.add_alarm(_alarm_id, "EMERGENCY", "Emergency stop active")
  end

  local function emergency_on_tick()
    ctx.monitor_master()
  end

  return {
    [constants.node_states.OFF] = {
      on_enter = off_on_enter,
      on_tick = off_on_tick
    },
    [constants.node_states.STARTUP] = {
      on_enter = startup_on_enter,
      on_tick = startup_on_tick
    },
    [constants.node_states.RUNNING] = {
      on_enter = running_on_enter,
      on_tick = running_on_tick
    },
    [constants.node_states.LIMITED] = {
      on_enter = limited_on_enter,
      on_tick = limited_on_tick
    },
    [constants.node_states.AUTONOM] = {
      on_enter = autonom_on_enter,
      on_tick = autonom_on_tick
    },
    [constants.node_states.MANUAL] = {
      on_enter = manual_on_enter,
      on_tick = manual_on_tick
    },
    [constants.node_states.EMERGENCY] = {
      on_enter = emergency_on_enter,
      on_tick = emergency_on_tick
    }
  }
end

function M.request_startup_if_needed(ctx, reason)
  if ctx.get_current_state() ~= ctx.STATE.MASTER then
    return false
  end
  local machine_state = ctx.get_node_state_machine() and ctx.get_node_state_machine().state and ctx.get_node_state_machine():state() or nil
  if machine_state ~= (ctx.constants or constants).node_states.RUNNING and machine_state ~= (ctx.constants or constants).node_states.OFF then
    return false
  end
  local needs_turbine = ctx.targets.enable_turbines ~= false and has_off_modules(ctx.modules, "turbine")
  local needs_reactor = ctx.targets.enable_reactors ~= false and has_off_modules(ctx.modules, "reactor")
  if not needs_turbine and not needs_reactor then
    return false
  end
  if ctx.get_active_startup() then
    return false
  end
  ctx.log("INFO", ("Startup requested reason=%s turbines_off=%s reactors_off=%s"):format(
    tostring(reason or "unknown"),
    tostring(needs_turbine),
    tostring(needs_reactor)
  ))
  ctx.get_node_state_machine():transition((ctx.constants or constants).node_states.STARTUP)
  return true
end

-- Counterpart to request_startup_if_needed() that is NOT gated on a MASTER
-- having sent SET_SETPOINTS. Without that command, start_module() (which
-- actually calls setActive(true)/engages inductors) is NEVER invoked -- the
-- node state machine boots straight into RUNNING (main.lua), and RUNNING's
-- on_tick happily runs the rod/flow regulator loop every cycle, but that
-- loop only adjusts an ALREADY-ACTIVE reactor/turbine; it never activates
-- one from cold. Reported symptom: rods sit at 100% (0% power) forever
-- until a master both connects AND issues setpoints -- capacity_learning.lua
-- can then never collect a single sample either, since turbines never spin
-- up. This must work whether no master is connected at all (AUTONOM) OR a
-- master is connected but simply hasn't requested anything yet (MASTER) --
-- only SAFE (an explicit safety state) must never auto-start.
--
-- This function starts the reactor/turbines ONLY to let capacity learning
-- measure real output once -- never as a general "run forever regardless
-- of the master" mode. Caller (main.lua's monitor_master()) is responsible
-- for idling back down once ctx.capacity_learning.ready becomes true, but
-- only when no master is there to take over regulation; with a master
-- connected, the normal control loop simply keeps running and master
-- setpoints take over on their own on the next tick.
function M.request_capacity_learning_startup_if_needed(ctx, reason)
  if ctx.get_current_state() == ctx.STATE.SAFE then
    return false
  end
  local learning = ctx.capacity_learning
  if learning and learning.ready == true then
    return false
  end
  local ns = (ctx.constants or constants).node_states
  local machine_state = ctx.get_node_state_machine() and ctx.get_node_state_machine().state and ctx.get_node_state_machine():state() or nil
  -- LIMITED zaehlt jetzt auch: genau dort parkt MASTER einen Knoten, dessen
  -- Kapazitaet noch unbekannt ist (node_capacity() liefert 0 solange
  -- capacity_ready~=true, siehe master/rt_sync.lua -- der proportionale
  -- Planer sortiert 0-Kapazitaet immer ans Ende und weist "standby"/"shed"
  -- zu, was hier zu LIMITED wird). Ohne LIMITED hier blieb ein einmal so
  -- geparkter Knoten fuer immer unklassifiziert: er erreichte nie wieder
  -- RUNNING/OFF von selbst, um erneut zu lernen -- ein Deadlock, bestaetigt
  -- 2026-09-17 ("Node in Kapazitaet-lernen, Reaktor aus").
  if machine_state ~= ns.RUNNING and machine_state ~= ns.OFF and machine_state ~= ns.LIMITED then
    return false
  end
  if ctx.get_active_startup() then
    return false
  end
  -- KEIN has_off_modules()-Gate mehr (anders als request_startup_if_needed()
  -- oben, von dem dieses Gate urspruenglich kopiert wurde): module.state
  -- geht nach dem allerersten erfolgreichen Start NIE wieder auf "OFF"
  -- zurueck (STARTING -> STABLE/RUNNING bleibt so, auch nach einem
  -- scram() -- der setzt nur die Regelstaebe, nicht module.state, siehe
  -- module_lifecycle.lua). Das Gate war also nach dem ersten Boot dauerhaft
  -- false und blockierte jede weitere Lern-Anfrage fuer den Rest der
  -- Laufzeit. learning.ready==false (oben bereits geprueft) ist bereits der
  -- vollstaendige Grund, den Regelkreislauf (STARTUP -> adjust_reactors()/
  -- adjust_turbines() auf jedem Tick) wieder anzustossen -- ob dabei ein
  -- Modul per start_module() aus "OFF" hochgefahren wird oder ein bereits
  -- aktives Modul einfach wieder Leistung bekommt, entscheiden startup_
  -- on_enter()/on_tick() ohnehin unabhaengig davon selbst.
  ctx.log("INFO", ("Autonomous capacity-learning startup requested reason=%s machine_state=%s"):format(
    tostring(reason or "unknown"),
    tostring(machine_state)
  ))
  ctx.get_node_state_machine():transition(ns.STARTUP)
  return true
end

function M.set_state(ctx, new_state, transition_reason)
  local current_state = ctx.get_current_state()
  if current_state == new_state then
    return false
  end

  -- Some RT contexts intentionally omit allowed_transitions. Treat a missing
  -- table as permissive instead of crashing on nil indexing. If a table is
  -- provided, keep the strict allow-list behaviour.
  local allowed_transitions = ctx.allowed_transitions
  if type(allowed_transitions) == "table" then
    local from_state = allowed_transitions[current_state]
    if type(from_state) ~= "table" or not from_state[new_state] then
      return false
    end
  end

  ctx.set_current_state(new_state)
  if new_state == ctx.STATE.AUTONOM then
    ctx.log("INFO", "Entering AUTONOM mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
  elseif new_state == ctx.STATE.MASTER then
    if current_state == ctx.STATE.AUTONOM then
      ctx.log("INFO", "Master reconnected reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    else
      ctx.log("INFO", "Entering MASTER mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    end
  elseif new_state == ctx.STATE.SAFE then
    ctx.log("INFO", "Entering SAFE mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
    ctx.apply_safe_controls()
    ctx.set_reactors_active(false, "SAFE_MODE")
    ctx.set_turbines_active(false, "SAFE_MODE")
  else
    ctx.log("INFO", "Entering INIT mode reason=" .. tostring(transition_reason or "STATE_REQUEST"))
  end
  return true
end

function M.apply_mode(ctx, mode)
  if mode == ctx.STATE.AUTONOM then
    if M.set_state(ctx, ctx.STATE.AUTONOM, "MODE_APPLY") then
      ctx.get_node_state_machine():transition((ctx.constants or constants).node_states.AUTONOM)
    end
  elseif mode == ctx.STATE.MASTER then
    if M.set_state(ctx, ctx.STATE.MASTER, "MODE_APPLY") then
      local current = ctx.get_node_state_machine():state()
      local ns = (ctx.constants or constants).node_states
      if current == ns.OFF or current == ns.AUTONOM then
        ctx.get_node_state_machine():transition(ns.STARTUP)
      end
    end
  elseif mode == ctx.STATE.SAFE then
    M.set_state(ctx, ctx.STATE.SAFE, "MODE_APPLY")
    local ns2 = (ctx.constants or constants).node_states
    if ctx.get_node_state_machine():state() ~= ns2.EMERGENCY then
      ctx.get_node_state_machine():transition(ns2.EMERGENCY)
    end
  end
end

function M.monitor_master(ctx)
  local checker = ctx and ctx.is_master_connected
  if type(checker) ~= "function" then
    if type(ctx) == "table" and type(ctx.log) == "function" then
      ctx.log("WARN", "State handler fallback: missing is_master_connected, forcing AUTONOM safety path")
    end
    checker = function() return false end
  end
  local connected = checker()
  if not connected then
    if M.set_state(ctx, ctx.STATE.AUTONOM, "MASTER_TIMEOUT_AUTONOM_FALLBACK") then
      ctx.log("WARN", "Master timeout detected, switching to AUTONOM")
      ctx.get_node_state_machine():transition((ctx.constants or constants).node_states.AUTONOM)
    end
  end
end

function M.clamp_autonom_targets(ctx)
  ctx.targets.power = 0
  ctx.targets.rpm = ctx.ramp_towards(ctx.targets.rpm, ctx.TARGET_RPM, ctx.config.autonom.flow_step)
  ctx.targets.steam = 0
end

return M