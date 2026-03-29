local M = {}

function M.build(ctx)
  local function assert_fn(name)
    if type(ctx[name]) ~= "function" then
      error("state handler context missing function: " .. tostring(name), 2)
    end
    return ctx[name]
  end

  local adjust_reactors = assert_fn("adjust_reactors")
  local adjust_turbines = assert_fn("adjust_turbines")

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
    ctx.targets.power = ctx.targets.power * 0.5
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
    ctx.add_alarm(ctx.comms.network.id, "EMERGENCY", "SCRAM triggered")
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

return M
