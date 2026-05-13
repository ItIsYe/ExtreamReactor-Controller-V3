local M = {}

local function normalize_status(raw)
  local s = tostring(raw or "OFFLINE"):upper()
  if s == "CRITICAL" then return "EMERGENCY" end
  if s == "WARN" then return "WARNING" end
  if s == "INFO" then return "LIMITED" end
  return s
end

function M.new(opts)
  local c = opts
  local function pick_number(...)
    for i = 1, select('#', ...) do
      local v = select(i, ...)
      if type(v) == "number" then return v end
    end
    return 0
  end
  local function first_nonempty(...)
    for i = 1, select('#', ...) do
      local v = select(i, ...)
      if v ~= nil and tostring(v) ~= "" and tostring(v) ~= "-" then return v end
    end
  end
  local function normalize_rt_display(rt_node)
    local assign = tostring(rt_node.assignment_state or "UNASSIGNED"):upper()
    local reason = tostring(rt_node.assignment_reason or "-")
    local control = tostring(rt_node.control_source or ""):upper()
    if assign == "ASSIGNED" or assign == "MASTER" then
      control = "MASTER"
      rt_node.display_mode = "Master-gefuehrt"
    elseif assign == "UNASSIGNED" then
      control = (control == "MASTER") and "MASTER" or "LOCAL"
      rt_node.display_mode = (control == "MASTER") and "Master-Zuordnung unklar" or "Lokal/Fallback (nicht zugeordnet)"
      if reason == "-" and tostring(rt_node.node_mode or rt_node.mode or "-"):upper() == "AUTONOM" then
        reason = "Node ohne Master-Zuordnung"
      end
    else
      control = (control == "MASTER") and "MASTER" or "LOCAL"
      rt_node.display_mode = (control == "MASTER") and "Master-gefuehrt" or "Lokal/Fallback"
    end
    rt_node.assignment_state = assign
    rt_node.assignment_reason = reason
    rt_node.control_source = control
    return rt_node
  end
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
    for i, a in ipairs(top) do if i > 4 then break end overview.alert_rows[#overview.alert_rows+1] = { title = tostring(a.title or a.code or 'Alert'), text = tostring(a.message or a.detail or 'Keine Details'), status = normalize_status(a.severity or 'WARNING') } end

    local rt = { rt_nodes = {}, queue = c.sequencer.queue or {}, ramp_profile = c.sequencer.ramp_profile, sequence_state = c.sequencer.state, rt_global_off_hold = overview.rt_global_off_hold, rt_active = 0, rt_startup = 0, rt_shutdown = 0 }
    local energy = { stored = 0, capacity = 0, input = 0, output = 0, matrices = {}, resources = {}, support_nodes = {}, status = 'OFFLINE' }

    for _, node in pairs(c.nodes or {}) do
      local age = node.last_seen_age or (node.last_seen and math.max(0, math.floor((now - node.last_seen) / 1000)) or -1)
      local stale = age >= 0 and age > 15
      local freshness_note = stale and 'stale' or 'live'
      local node_status = stale and 'OFFLINE' or normalize_status(node.status or 'OFFLINE')
      local node_mode = node.mode or (node.rt and node.rt.mode) or '-'
      overview.nodes[#overview.nodes+1] = { id = node.id, role = node.role or '-', status = node_status, last_seen_age = age, mode = node_mode, note = node.bindings_summary or node.note or (node.rt and node.rt.assignment_reason) or freshness_note, freshness = freshness_note }
      overview.nodes_total = (overview.nodes_total or 0) + 1
      if stale then overview.nodes_stale = (overview.nodes_stale or 0) + 1 else overview.nodes_live = (overview.nodes_live or 0) + 1 end
      if node.role == c.constants.roles.RT_NODE then
        if not stale then overview.rt_online = overview.rt_online + 1 end
        local rt_node = node.rt or { id = node.id, status = normalize_status(node.status), mode = node.mode, assignment_state = node.assignment_state }
        rt_node.status = stale and 'OFFLINE' or normalize_status(rt_node.status)
        rt_node.last_seen_age = age
        rt_node.freshness = freshness_note
        rt_node.node_status = node_status
        rt_node.node_mode = node_mode
        rt_node.assignment_state = rt_node.assignment_state or node.assignment_state or node.bindings_state or "UNASSIGNED"
        rt_node.assignment_reason = rt_node.assignment_reason or node.assignment_reason or node.bindings_summary or "-"
        rt_node.control_source = rt_node.control_source or node.control_source or ((rt_node.assignment_state == "ASSIGNED" or rt_node.assignment_state == "MASTER") and "MASTER" or "LOCAL")
        rt_node = normalize_rt_display(rt_node)
        if stale then rt.rt_stale = (rt.rt_stale or 0) + 1 end
        rt.rt_nodes[#rt.rt_nodes+1] = rt_node
        overview.power_actual = overview.power_actual + (rt_node.actual_output or rt_node.output or 0)
        local state = tostring(rt_node.state or '')
        if state == 'RUNNING' then rt.rt_active = rt.rt_active + 1 elseif state == 'STARTUP' then rt.rt_startup = rt.rt_startup + 1 elseif state == 'SHUTDOWN' then rt.rt_shutdown = rt.rt_shutdown + 1 end
      elseif node.role == c.constants.roles.ENERGY_NODE then
        local e = node.energy or node or {}
        energy.stored = energy.stored + pick_number(e.aggregate_stored, e.stored, e.matrix_energy, e.total and e.total.stored, 0)
        energy.capacity = energy.capacity + pick_number(e.aggregate_capacity, e.capacity, e.matrix_capacity, e.total and e.total.capacity, 0)
        energy.input = energy.input + pick_number(e.aggregate_input, e.input, e.matrix_in, e.total and e.total.input, 0)
        energy.output = energy.output + pick_number(e.aggregate_output, e.output, e.matrix_out, e.total and e.total.output, 0)
        energy.support_nodes[#energy.support_nodes + 1] = { id = node.id, role = node.role or '-', status = stale and 'OFFLINE' or normalize_status(node.status or 'OK'), last_seen_age = age, note = e.note or node.bindings_summary or "Energy-Node", freshness = freshness_note }
        if stale then energy.support_stale = (energy.support_stale or 0) + 1 else energy.support_online = (energy.support_online or 0) + 1 end
        local matrices = e.matrices or (e.total and e.total.matrices) or {}
        for _, m in ipairs(matrices) do
          local copy = {}
          for k,v in pairs(m) do copy[k]=v end
          copy.last_seen_age = age
          copy.status = stale and 'OFFLINE' or normalize_status(copy.status or node.status or 'OK')
          copy.percent = pick_number(copy.percent, copy.fill, copy.level, 0)
          copy.input = pick_number(copy.input, copy.inflow, copy.rate_in, 0)
          copy.output = pick_number(copy.output, copy.outflow, copy.rate_out, 0)
          copy.id = first_nonempty(copy.id, copy.label, copy.name, node.id .. "-matrix")
          energy.matrices[#energy.matrices+1] = copy
        end
      else
        energy.support_nodes[#energy.support_nodes+1] = { id = node.id, role = node.role or '-', status = stale and 'OFFLINE' or normalize_status(node.status or 'OFFLINE'), last_seen_age = age, note = node.bindings_summary or node.note or '', freshness = freshness_note }
        if stale then energy.support_stale = (energy.support_stale or 0) + 1 else energy.support_online = (energy.support_online or 0) + 1 end
      end
      if node.role == c.constants.roles.FUEL_NODE then energy.resources.fuel_total = (energy.resources.fuel_total or 0) + ((node.fuel and node.fuel.amount) or 0); energy.resources.fuel_sources = (energy.resources.fuel_sources or 0) + 1 end
      if node.role == c.constants.roles.WATER_NODE then energy.resources.water_total = (energy.resources.water_total or 0) + ((node.water and node.water.total) or 0) end
      if node.role == c.constants.roles.REPROCESSOR_NODE then energy.resources.reprocessing_state = (node.reprocessor and (node.reprocessor.state or node.reprocessor.mode)) or '-' end
    end
    table.sort(overview.nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    table.sort(rt.rt_nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    table.sort(energy.support_nodes, function(a,b) return tostring(a.id or '') < tostring(b.id or '') end)
    local pct = energy.capacity > 0 and (energy.stored / energy.capacity) * 100 or 0
    energy.status = pct < 15 and 'EMERGENCY' or (pct < 30 and 'WARNING' or 'OK')
    overview.energy_overview = { percent = pct, status = energy.status, trend = (pct > 70 and 'Trend stabil') or (pct > 35 and 'Trend sinkt') or 'Trend kritisch' }
    overview.nodes_total = overview.nodes_total or 0
    overview.nodes_live = overview.nodes_live or 0
    overview.nodes_stale = overview.nodes_stale or 0
    overview.peer_summary = string.format('Peers live=%d stale=%d rt=%d', overview.nodes_live, overview.nodes_stale, overview.rt_online or 0)
    energy.matrix_count = #energy.matrices
    overview.clock_label = os.date('!%H:%M UTC')
    rt.rt_global_off_hold = overview.rt_global_off_hold
    return { overview = overview, rt = rt, energy = energy, resources = {} }
  end

  local controller = {}
  controller.draw = function()
      local models = build_models()
      controller._last_models = models
      local monitors = c.state.monitor_cache.list or {}
      local rendered = c.view_manager:render(monitors, models) or {}
      c.state.last_ui_model_stats = {
        overview_nodes = #(models.overview and models.overview.nodes or {}),
        rt_nodes = #(models.rt and models.rt.rt_nodes or {}),
        support_nodes = #(models.energy and models.energy.support_nodes or {}),
        matrices = #(models.energy and models.energy.matrices or {})
      }
      if models.overview and models.overview.ui_errors and c.log then
        for _, msg in ipairs(models.overview.ui_errors) do
          c.log("Overview section fallback triggered: " .. tostring(msg), "ERROR")
        end
      end
      local ov_meta = models.overview and models.overview._overview_render_meta
      c.state.last_overview_render_meta = ov_meta
      if ov_meta and c.log then
        if ov_meta.cache_unchanged then
          c.log("Overview render executed with unchanged model (cache bypass blackscreen guard active)", "DEBUG")
        else
          c.log("Overview render executed with updated model", "DEBUG")
        end
      end

      for _, r in ipairs(rendered) do
        if c.log then
          if r.ok then
            c.log(("UI render ok view=%s monitor=%s role=%s"):format(tostring(r.view), tostring(r.monitor), tostring(r.role)), "DEBUG")
          else
            c.log(("UI render failed view=%s monitor=%s role=%s error=%s"):format(
              tostring(r.view), tostring(r.monitor), tostring(r.role), tostring(r.error)
            ), "ERROR")
          end
        end
      end
    end
  controller.handle_input = function(event)
      if event[1] == 'monitor_touch' then c.view_manager:handle_input(event[2], event[3], event[4]) end
    end
  controller.handle_action = function(action)
      if action.type == 'profile' then c.calc.apply_profile(action.name)
      elseif action.type == 'auto' then c.calc.set_auto_profile(not (c.calc.get_auto_profile and c.calc.get_auto_profile()))
      elseif action.type == 'rt_hold' then c.calc.set_rt_global_off_hold(not (c.calc.get_rt_global_off_hold and c.calc.get_rt_global_off_hold())) end
    end
  return controller
end

return M
