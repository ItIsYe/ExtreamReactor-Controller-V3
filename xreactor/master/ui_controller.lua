local M = {}

function M.new(opts)
  local c = opts
  local function build_models()
    local now = os.epoch('utc')
    local counts = c.alert_service and c.alert_service:get_counts() or { INFO = 0, WARN = 0, CRITICAL = 0 }
    local top = c.alert_service and c.alert_service:get_top_critical(3) or {}
    local summary = c.alert_service and c.alert_service:get_summary() or 'Keine aktiven Meldungen'

    local overview = {
      system_status = 'OK', profile_list = { 'BASELOAD', 'PEAK', 'IDLE' },
      active_profile = c.calc.get_active_profile and c.calc.get_active_profile() or c.state.active_profile,
      auto_profile = c.calc.get_auto_profile and c.calc.get_auto_profile() or c.state.auto_profile,
      rt_global_off_hold = c.calc.get_rt_global_off_hold and c.calc.get_rt_global_off_hold() or c.state.rt_global_off_hold,
      power_target = c.calc.get_power_target and c.calc.get_power_target() or c.state.power_target,
      nodes = {}, alert_rows = {}, alert_summary = summary, alert_counts = counts, energy_overview = { percent = 0, status = 'OFFLINE', trend = 'Trend stabil' }, rt_online = 0, power_actual = 0, clock_label = ''
    }
    if (counts.CRITICAL or 0) > 0 then overview.system_status = 'EMERGENCY' elseif (counts.WARN or 0) > 0 then overview.system_status = 'WARNING' end
    for i, a in ipairs(top) do if i > 4 then break end overview.alert_rows[#overview.alert_rows+1] = { title = tostring(a.title or a.code or 'Alert'), text = tostring(a.message or a.detail or 'Keine Details'), status = tostring(a.severity or 'WARNING') } end

    local rt = { rt_nodes = {}, queue = c.sequencer.queue or {}, ramp_profile = c.sequencer.ramp_profile, sequence_state = c.sequencer.state, rt_global_off_hold = overview.rt_global_off_hold, rt_active = 0, rt_startup = 0, rt_shutdown = 0 }
    local energy = { stored = 0, capacity = 0, input = 0, output = 0, matrices = {}, resources = {}, support_nodes = {}, status = 'OFFLINE' }

    for _, node in pairs(c.nodes or {}) do
      local age = node.last_seen_age or (node.last_seen and math.max(0, math.floor((now - node.last_seen) / 1000)) or -1)
      local stale = age >= 0 and age > 15
      overview.nodes[#overview.nodes+1] = { id = node.id, role = node.role or '-', status = stale and 'OFFLINE' or (node.status or 'OFFLINE'), last_seen_age = age, mode = node.mode or (node.rt and node.rt.mode) or '-', note = node.bindings_summary or node.note or (node.rt and node.rt.assignment_reason) or '' }
      if node.role == c.constants.roles.RT_NODE then
        overview.rt_online = overview.rt_online + 1
        local rt_node = node.rt or { id = node.id, status = node.status, mode = node.mode, assignment_state = node.assignment_state }
        rt.rt_nodes[#rt.rt_nodes+1] = rt_node
        overview.power_actual = overview.power_actual + (rt_node.actual_output or rt_node.output or 0)
        local state = tostring(rt_node.state or '')
        if state == 'RUNNING' then rt.rt_active = rt.rt_active + 1 elseif state == 'STARTUP' then rt.rt_startup = rt.rt_startup + 1 elseif state == 'SHUTDOWN' then rt.rt_shutdown = rt.rt_shutdown + 1 end
      elseif node.role == c.constants.roles.ENERGY_NODE then
        local e = node.energy or {}
        energy.stored = energy.stored + (e.stored or 0); energy.capacity = energy.capacity + (e.capacity or 0); energy.input = energy.input + (e.input or 0); energy.output = energy.output + (e.output or 0)
        for _, m in ipairs(e.matrices or {}) do energy.matrices[#energy.matrices+1] = m end
      else
        energy.support_nodes[#energy.support_nodes+1] = { id = node.id, role = node.role or '-', status = stale and 'OFFLINE' or (node.status or 'OFFLINE'), last_seen_age = age, note = node.bindings_summary or node.note or '' }
      end
      if node.role == c.constants.roles.FUEL_NODE then energy.resources.fuel_total = (energy.resources.fuel_total or 0) + ((node.fuel and node.fuel.amount) or 0); energy.resources.fuel_sources = (energy.resources.fuel_sources or 0) + 1 end
      if node.role == c.constants.roles.WATER_NODE then energy.resources.water_total = (energy.resources.water_total or 0) + ((node.water and node.water.total) or 0) end
      if node.role == c.constants.roles.REPROCESSOR_NODE then energy.resources.reprocessing_state = (node.reprocessor and (node.reprocessor.state or node.reprocessor.mode)) or '-' end
    end
    table.sort(overview.nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    table.sort(rt.rt_nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    local pct = energy.capacity > 0 and (energy.stored / energy.capacity) * 100 or 0
    energy.status = pct < 15 and 'EMERGENCY' or (pct < 30 and 'WARNING' or 'OK')
    overview.energy_overview = { percent = pct, status = energy.status, trend = (pct > 70 and 'Trend stabil') or (pct > 35 and 'Trend sinkt') or 'Trend kritisch' }
    overview.clock_label = os.date('!%H:%M UTC')
    rt.rt_global_off_hold = overview.rt_global_off_hold
    return { overview = overview, rt = rt, energy = energy, resources = {} }
  end

  return {
    draw = function()
      local models = build_models()
      local monitors = c.state.monitor_cache.list or {}
      local rendered = c.view_manager:render(monitors, models) or {}
      for _, r in ipairs(rendered) do
        if not r.ok and c.log then
          c.log(("UI render failed view=%s monitor=%s role=%s error=%s"):format(
            tostring(r.view), tostring(r.monitor), tostring(r.role), tostring(r.error)
          ), "ERROR")
        end
      end
    end,
    handle_input = function(event)
      if event[1] == 'monitor_touch' then c.view_manager:handle_input(event[2], event[3], event[4]) end
    end,
    handle_action = function(action)
      if action.type == 'profile' then c.calc.apply_profile(action.name)
      elseif action.type == 'auto' then c.calc.set_auto_profile(not (c.calc.get_auto_profile and c.calc.get_auto_profile()))
      elseif action.type == 'rt_hold' then c.calc.set_rt_global_off_hold(not (c.calc.get_rt_global_off_hold and c.calc.get_rt_global_off_hold())) end
    end
  }
end

return M
