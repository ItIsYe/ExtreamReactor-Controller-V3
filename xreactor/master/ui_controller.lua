local M = {}

function M.new(opts)
  local controller = {
    constants = assert(opts.constants, "constants required"),
    health = assert(opts.health, "health required"),
    config = assert(opts.config, "config required"),
    nodes = assert(opts.nodes, "nodes required"),
    alarms = assert(opts.alarms, "alarms required"),
    comms = assert(opts.comms, "comms required"),
    sequencer = assert(opts.sequencer, "sequencer required"),
    alert_service = opts.alert_service,
    view_manager = opts.view_manager,
    trends = assert(opts.trends, "trends required"),
    trend_cache = assert(opts.trend_cache, "trend_cache required"),
    state = assert(opts.state, "state required"),
    calc = assert(opts.calc, "calc required")
  }

  local function handle_action(action)
    if not action then return end
    if action.type == "profile" then
      controller.calc.apply_profile(action.name)
    elseif action.type == "auto" then
      local next_value = not (controller.calc.get_auto_profile and controller.calc.get_auto_profile() or controller.state.auto_profile)
      if controller.calc.set_auto_profile then
        controller.calc.set_auto_profile(next_value)
      end
      controller.state.auto_profile = next_value
    elseif action.type == "rt_hold" then
      local current = (controller.calc.get_rt_global_off_hold and controller.calc.get_rt_global_off_hold()) or controller.state.rt_global_off_hold
      local next_value = not current
      if controller.calc.set_rt_global_off_hold then
        controller.calc.set_rt_global_off_hold(next_value)
      end
      controller.state.rt_global_off_hold = next_value
    elseif controller.alert_service then
      if action.type == "alert_ack" then controller.alert_service:ack(action.id)
      elseif action.type == "alert_unack" then controller.alert_service:unack(action.id)
      elseif action.type == "alert_ack_visible" then controller.alert_service:ack_visible(action.ids)
      elseif action.type == "alert_ack_all" then controller.alert_service:ack_all()
      elseif action.type == "alert_mute_rule" then controller.alert_service:mute_rule(action.code, action.minutes)
      elseif action.type == "alert_unmute_rule" then controller.alert_service:unmute_rule(action.code)
      elseif action.type == "alert_mute_node" then controller.alert_service:mute_node(action.node_id, action.minutes)
      elseif action.type == "alert_unmute_node" then controller.alert_service:unmute_node(action.node_id)
      end
    end
  end

  local function compute_system_status()
    local status = controller.constants.status_levels.OK
    if controller.alert_service then
      local counts = controller.alert_service:get_counts() or {}
      if (counts.CRITICAL or 0) > 0 then
        return controller.constants.status_levels.EMERGENCY
      elseif (counts.WARN or 0) > 0 then
        status = controller.constants.status_levels.WARNING
      end
    end
    for _, node in pairs(controller.nodes) do
      if node.status == controller.constants.status_levels.EMERGENCY then
        return controller.constants.status_levels.EMERGENCY
      elseif node.status == controller.constants.status_levels.LIMITED then
        status = controller.constants.status_levels.LIMITED
      elseif node.status == controller.constants.status_levels.WARNING then
        status = controller.constants.status_levels.WARNING
      end
    end
    for _, alarm in ipairs(controller.alarms) do
      if alarm.severity == controller.constants.status_levels.EMERGENCY then
        return controller.constants.status_levels.EMERGENCY
      elseif alarm.severity == controller.constants.status_levels.WARNING then
        status = controller.constants.status_levels.WARNING
      end
    end
    return status
  end

  local function draw()
    local now = os.epoch("utc")
    if now - controller.state.last_draw < 400 then return end
    controller.state.last_draw = now

    local alert_counts = controller.alert_service and controller.alert_service:get_counts() or { INFO = 0, WARN = 0, CRITICAL = 0 }
    local alert_summary = controller.alert_service and controller.alert_service:get_summary() or ""
    local alert_active = controller.alert_service and controller.alert_service:get_active() or {}
    local alert_history = controller.alert_service and controller.alert_service:get_history() or {}
    local alert_top = controller.alert_service and controller.alert_service:get_top_critical(3) or {}
    local alert_metrics = controller.alert_service and controller.alert_service:get_metrics() or {}
    local alert_mutes = controller.alert_service and controller.alert_service:get_mutes() or {}

    local overview_data = {
      nodes = {}, power_target = (controller.calc.get_power_target and controller.calc.get_power_target()) or controller.state.power_target, alarms = controller.alarms, tiles = {},
      system_status = compute_system_status(), profile_list = { "BASELOAD", "PEAK", "IDLE" },
      active_profile = (controller.calc.get_active_profile and controller.calc.get_active_profile()) or controller.state.active_profile,
      auto_profile = (controller.calc.get_auto_profile and controller.calc.get_auto_profile()) or controller.state.auto_profile,
      rt_global_off_hold = (controller.calc.get_rt_global_off_hold and controller.calc.get_rt_global_off_hold()) or controller.state.rt_global_off_hold,
      alert_counts = alert_counts, alert_summary = alert_summary, alert_top = alert_top
    }
    local rt_data = {
      rt_nodes = {}, ramp_profile = controller.sequencer.ramp_profile, sequence_state = controller.sequencer.state,
      queue = controller.sequencer.queue, active_step = controller.sequencer.active, control_mode = nil,
      alert_counts = alert_counts, alert_top = alert_top,
      rt_global_off_hold = overview_data.rt_global_off_hold
    }
    local energy_data = {
      stored = 0, capacity = 0, input = 0, output = 0, stores = {}, nodes = {}, matrices = {}, top_matrices = {},
      trend_values = controller.trend_cache.energy, trend_arrow = controller.trend_cache.energy_arrow,
      trend_dirty = controller.trends:is_dirty("energy"), now_ms = now, alert_counts = alert_counts, alert_top = alert_top
    }
    local resource_data = {
      fuel = { reserve = 0, minimum = 0, sources = {}, total = 0 },
      water = { total = 0, buffers = {}, target = nil }, reprocessor = {}, node_details = {},
      comms = controller.comms:get_diagnostics() or {}
    }

    for _, node in pairs(controller.nodes) do
      local reasons = node.health and node.health.reasons or {}
      local reason_list = type(reasons) == "table" and (#reasons > 0 and reasons or controller.health.reasons_list({ reasons = reasons })) or {}
      local reason_text = type(reason_list) == "table" and table.concat(reason_list, ",") or nil
      local bindings_summary = node.bindings_summary
      if not bindings_summary and node.health and type(node.health.bindings) == "table" then
        bindings_summary = controller.health.summarize_bindings(node.health.bindings)
      end
      local age = node.last_seen_age or (node.last_seen and math.max(0, math.floor((now - node.last_seen) / 1000)) or nil)
      overview_data.nodes[#overview_data.nodes + 1] = {
        id = node.id, role = node.role, status = node.status or controller.constants.status_levels.OFFLINE,
        node_role_map = ("%s = %s"):format(tostring(node.id or "UNKNOWN"), tostring(node.role or "UNKNOWN")),
        last_seen = node.last_seen_str, last_seen_age = age, mode = node.mode, reasons = reason_text, bindings = bindings_summary,
        managed = node.managed ~= false, stale = node.stale == true
      }
      resource_data.node_details[#resource_data.node_details + 1] = {
        id = node.id, role = node.role, status = node.status or controller.constants.status_levels.OFFLINE,
        reasons = reason_text, bindings = bindings_summary, last_seen_age = age, down_since = node.down_since,
        registry = node.registry, last_error = node.last_error, last_error_ts = node.last_error_ts,
        last_command_result = node.last_command_result, last_command_error = node.last_command_error
      }
      if node.role == controller.constants.roles.RT_NODE then
        rt_data.rt_nodes[#rt_data.rt_nodes + 1] = {
          id = node.id,
          state = node.state or controller.constants.node_states.OFF,
          output = node.output,
          modules = node.modules or {},
          limits = node.limits,
          status = node.status,
          mode = node.mode,
          hold = overview_data.rt_global_off_hold == true,
          target = node.last_setpoints and node.last_setpoints.power_target or nil,
          target_rpm = node.last_setpoints and node.last_setpoints.target_rpm or nil,
          steam_target = node.last_setpoints and node.last_setpoints.steam_target or nil,
          assignment_reason = node.last_setpoints and node.last_setpoints.assignment_reason or nil,
          assignment_rank = node.last_setpoints and node.last_setpoints.assignment_rank or nil,
          controllable = node.last_setpoints and node.last_setpoints.controllable or false,
          startup_active = controller.sequencer.active and controller.sequencer.active.node_id == node.id or false
        }
      elseif node.role == controller.constants.roles.ENERGY_NODE then
        energy_data.stored = energy_data.stored + (node.aggregate_stored or node.stored or 0)
        energy_data.capacity = energy_data.capacity + (node.aggregate_capacity or node.capacity or 0)
        energy_data.input = energy_data.input + (node.aggregate_input or node.input or 0)
        energy_data.output = energy_data.output + (node.aggregate_output or node.output or 0)
        energy_data.stores[#energy_data.stores + 1] = { id = node.id, stored = node.aggregate_stored or node.stored, capacity = node.aggregate_capacity or node.capacity, input = node.aggregate_input or node.input, output = node.aggregate_output or node.output }
        energy_data.nodes[#energy_data.nodes + 1] = {
          id = node.id, monitor_bound = node.monitor_bound, storage_bound_count = node.storage_bound_count,
          bound_storage_names = node.bound_storage_names,
          degraded_reason = node.health and node.health.reasons and table.concat(node.health.reasons, ",") or node.degraded_reason,
          last_scan_ts = node.last_scan_ts, last_scan_result = node.last_scan_result, status = node.status,
          bindings_summary = node.bindings_summary, registry = node.registry
        }
        for _, matrix in ipairs(node.matrices or {}) do
          local percent = matrix.capacity and matrix.capacity > 0 and (matrix.stored or 0) / matrix.capacity or (matrix.percent or 0)
          energy_data.matrices[#energy_data.matrices + 1] = {
            id = matrix.id or matrix.name or (node.id .. ":matrix"), label = matrix.label or matrix.name or matrix.alias,
            stored = matrix.stored, capacity = matrix.capacity, percent = percent,
            input = matrix.input, output = matrix.output, status = matrix.status or node.status, node_id = node.id
          }
        end
      elseif node.role == controller.constants.roles.FUEL_NODE then
        resource_data.fuel.reserve = node.reserve or resource_data.fuel.reserve
        resource_data.fuel.minimum = node.minimum_reserve or resource_data.fuel.minimum
        resource_data.fuel.sources = node.sources or resource_data.fuel.sources
      elseif node.role == controller.constants.roles.WATER_NODE then
        resource_data.water.total = node.total_water or resource_data.water.total
        resource_data.water.buffers = node.buffers or resource_data.water.buffers
        resource_data.water.state = node.state
      elseif node.role == controller.constants.roles.REPROCESSOR_NODE then
        resource_data.reprocessor = node.reprocessor or {}
      end
    end

    table.sort(rt_data.rt_nodes, function(a, b) return (a.id or "") < (b.id or "") end)
    table.sort(energy_data.stores, function(a, b) return (a.id or "") < (b.id or "") end)
    table.sort(energy_data.nodes, function(a, b) return (a.id or "") < (b.id or "") end)
    table.sort(energy_data.matrices, function(a, b) return (a.percent or 0) > (b.percent or 0) end)
    table.sort(resource_data.fuel.sources, function(a, b) return (a.id or "") < (b.id or "") end)

    local fuel_total = 0
    for _, src in ipairs(resource_data.fuel.sources or {}) do fuel_total = fuel_total + (src.amount or 0) end
    resource_data.fuel.total = fuel_total
    resource_data.fuel.mix_status = (#(resource_data.fuel.sources or {}) > 1) and "MIXED" or "SINGLE"
    if energy_data.capacity > 0 then
      local pct = (energy_data.stored / energy_data.capacity) * 100
      if pct <= controller.config.energy_crit_pct then energy_data.status = "EMERGENCY"
      elseif pct <= controller.config.energy_warn_pct then energy_data.status = "WARNING"
      else energy_data.status = "OK" end
    else
      energy_data.status = "OFFLINE"
    end
    for i = 1, math.min(3, #energy_data.matrices) do energy_data.top_matrices[#energy_data.top_matrices + 1] = energy_data.matrices[i] end

    local modes, mode_list = {}, {}
    for _, rt in ipairs(rt_data.rt_nodes) do if rt.mode then modes[rt.mode] = true end end
    for mode in pairs(modes) do mode_list[#mode_list + 1] = mode end
    table.sort(mode_list)
    if #mode_list == 1 then rt_data.control_mode = mode_list[1] elseif #mode_list > 1 then rt_data.control_mode = "MIXED" end

    local tile_map = {
      { label = "RT", role = controller.constants.roles.RT_NODE },
      { label = "ENERGY", role = controller.constants.roles.ENERGY_NODE },
      { label = "FUEL", role = controller.constants.roles.FUEL_NODE },
      { label = "WATER", role = controller.constants.roles.WATER_NODE },
      { label = "REPROCESSOR", role = controller.constants.roles.REPROCESSOR_NODE }
    }
    local status_rank = {
      [controller.constants.status_levels.EMERGENCY] = 1,
      [controller.constants.status_levels.WARNING] = 2,
      [controller.constants.status_levels.LIMITED] = 3,
      [controller.constants.status_levels.OK] = 4,
      [controller.constants.status_levels.OFFLINE] = 5,
      [controller.constants.status_levels.MANUAL] = 6
    }
    for _, entry in ipairs(tile_map) do
      local tile_status = controller.constants.status_levels.OFFLINE
      for _, node in pairs(controller.nodes) do
        if node.role == entry.role then
          local node_status = node.status or controller.constants.status_levels.OFFLINE
          if (status_rank[node_status] or 99) < (status_rank[tile_status] or 99) then tile_status = node_status end
        end
      end
      overview_data.tiles[#overview_data.tiles + 1] = { label = entry.label, status = tile_status, detail = entry.role }
    end

    local rendered_views = {}
    if controller.view_manager then
      rendered_views = controller.view_manager:render(controller.state.monitor_cache.list or {}, {
        overview = overview_data,
        rt = rt_data,
        energy = energy_data,
        resources = resource_data,
        alarms = { alarms = controller.alarms, header_blink = now < ((controller.calc.get_critical_blink_until and controller.calc.get_critical_blink_until()) or controller.state.critical_blink_until) and math.floor(now / 400) % 2 == 0 },
        alerts = {
          counts = alert_counts, summary = alert_summary, active = alert_active, history = alert_history,
          metrics = alert_metrics, mutes = alert_mutes,
          config = { mute_default_minutes = controller.config.alert_mute_default_minutes, mute_durations = controller.config.alert_mute_durations },
          now_ms = now
        }
      }) or {}
    end
    if rendered_views.energy and controller.trends:is_dirty("energy") then
      controller.trends:clear_dirty("energy")
    end
  end

  local function handle_input(event)
    if event[1] == "monitor_touch" then
      if controller.view_manager then controller.view_manager:handle_input(event[2], event[3], event[4]) end
    elseif event[1] == "key" then
      if controller.view_manager then controller.view_manager:handle_key(event[2]) end
    elseif event[1] == "char" then
      if controller.view_manager then controller.view_manager:handle_char(event[2]) end
    end
  end

  return {
    draw = draw,
    handle_input = handle_input,
    handle_action = handle_action,
    compute_system_status = compute_system_status
  }
end

return M
