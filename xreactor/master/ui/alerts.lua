local ui = require("core.ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")

local cache = {}
local state_cache = setmetatable({}, { __mode = "k" })

local severity_status = {
  INFO = "OK",
  WARN = "WARNING",
  CRITICAL = "EMERGENCY"
}

local severity_rank = {
  CRITICAL = 1,
  WARN = 2,
  INFO = 3
}

local role_filters = {
  { key = constants.roles.MASTER, label = "M" },
  { key = constants.roles.RT_NODE, label = "RT" },
  { key = constants.roles.ENERGY_NODE, label = "EN" },
  { key = constants.roles.FUEL_NODE, label = "FU" },
  { key = constants.roles.WATER_NODE, label = "WA" },
  { key = constants.roles.REPROCESSOR_NODE, label = "RP" }
}

local scope_filters = {
  { key = "SYSTEM", label = "SYS" },
  { key = "NODE", label = "NODE" },
  { key = "DEVICE", label = "DEV" }
}

local function ensure_state(mon)
  local state = state_cache[mon]
  if not state then
    state = {
      page = 1,
      selected_id = nil,
      list_bounds = {},
      buttons = {},
      view = "active",
      group_mode = "flat",
      sort_mode = "severity",
      search = "",
      search_active = false,
      mute_index = 1,
      mute_minutes = nil,
      collapsed = {},
      filters = {
        severity = { INFO = true, WARN = true, CRITICAL = true },
        scope = { SYSTEM = true, NODE = true, DEVICE = true },
        show_acknowledged = true,
        roles = {
          [constants.roles.MASTER] = true,
          [constants.roles.RT_NODE] = true,
          [constants.roles.ENERGY_NODE] = true,
          [constants.roles.FUEL_NODE] = true,
          [constants.roles.WATER_NODE] = true,
          [constants.roles.REPROCESSOR_NODE] = true
        }
      }
    }
    state_cache[mon] = state
  end
  return state
end

local function normalize_text(value)
  return tostring(value or ""):lower()
end

local function alert_matches(alert, state)
  if not alert then
    return false
  end
  local filters = state.filters
  if not filters.severity[alert.severity or "INFO"] then
    return false
  end
  if not filters.scope[alert.scope or "SYSTEM"] then
    return false
  end
  if not filters.show_acknowledged and alert.acknowledged then
    return false
  end
  local role = alert.source and alert.source.role or constants.roles.MASTER
  if not filters.roles[role] then
    return false
  end
  local search = state.search or ""
  if search ~= "" then
    local target = table.concat({
      normalize_text(alert.title),
      normalize_text(alert.message),
      normalize_text(alert.source and alert.source.node_id)
    }, " ")
    if not target:find(search, 1, true) then
      return false
    end
  end
  return true
end

local function sort_alerts(list, mode)
  if mode == "recency" then
    table.sort(list, function(a, b)
      return (a.ts_last or 0) > (b.ts_last or 0)
    end)
    return
  end
  if mode == "node" then
    table.sort(list, function(a, b)
      local a_source = a.source or {}
      local b_source = b.source or {}
      local a_node = tostring(a_source.node_id or "")
      local b_node = tostring(b_source.node_id or "")
      if a_node == b_node then
        local a_role = tostring(a_source.role or "")
        local b_role = tostring(b_source.role or "")
        if a_role == b_role then
          local ar = severity_rank[a.severity] or 99
          local br = severity_rank[b.severity] or 99
          if ar == br then
            return (a.ts_last or 0) > (b.ts_last or 0)
          end
          return ar < br
        end
        return a_role < b_role
      end
      return a_node < b_node
    end)
    return
  end
  table.sort(list, function(a, b)
    local ar = severity_rank[a.severity] or 99
    local br = severity_rank[b.severity] or 99
    if ar == br then
      return (a.ts_last or 0) > (b.ts_last or 0)
    end
    return ar < br
  end)
end

local function build_group_rows(list, state)
  local grouped = {}
  for _, alert in ipairs(list) do
    local source = alert.source or {}
    local node_id = tostring(source.node_id or "SYSTEM")
    grouped[node_id] = grouped[node_id] or { node_id = node_id, alerts = {} }
    table.insert(grouped[node_id].alerts, alert)
  end
  local nodes = {}
  for _, entry in pairs(grouped) do
    table.insert(nodes, entry)
  end
  table.sort(nodes, function(a, b) return a.node_id < b.node_id end)
  local rows = {}
  local entries = {}
  for _, entry in ipairs(nodes) do
    local node_id = entry.node_id
    sort_alerts(entry.alerts, state.sort_mode)
    local collapsed = state.collapsed[node_id]
    local highest = "INFO"
    for _, alert in ipairs(entry.alerts) do
      if severity_rank[alert.severity] < severity_rank[highest] then
        highest = alert.severity
      end
    end
    local caret = collapsed and "▶" or "▼"
    local header = string.format("%s %s (%d)", caret, node_id, #entry.alerts)
    table.insert(rows, { text = header, status = severity_status[highest] or "OK" })
    table.insert(entries, { type = "group", node_id = node_id })
    if not collapsed then
      for _, alert in ipairs(entry.alerts) do
        table.insert(rows, { text = "", status = severity_status[alert.severity] or "OK" })
        table.insert(entries, { type = "alert", alert = alert })
      end
    end
  end
  return rows, entries
end

local function build_flat_rows(list)
  local rows = {}
  local entries = {}
  for _, alert in ipairs(list) do
    table.insert(rows, { text = "", status = severity_status[alert.severity] or "OK" })
    table.insert(entries, { type = "alert", alert = alert })
  end
  return rows, entries
end

local function decorate_rows(rows, entries, state, start_idx, end_idx)
  local visible_ids = {}
  for idx = start_idx, end_idx do
    local row = rows[idx]
    local entry = entries[idx]
    if row and entry and entry.type == "alert" then
      local alert = entry.alert
      local prefix = alert.id == state.selected_id and ">" or " "
      local sev = (alert.severity or "INFO"):sub(1, 1)
      local ack = alert.acknowledged and "A" or " "
      local muted = alert.muted and "M" or " "
      local source = alert.source or {}
      local label = alert.title or source.device_id or source.node_id or "Alert"
      row.text = string.format("%s%s%s%s %s", prefix, sev, ack, muted, tostring(label))
      row.id = alert.id
      table.insert(visible_ids, alert.id)
    elseif row and entry and entry.type == "group" then
      row.text = row.text or ""
    end
  end
  return visible_ids
end

local function select_first_visible(entries)
  for _, entry in ipairs(entries or {}) do
    if entry.type == "alert" then
      return entry.alert.id
    end
  end
  return nil
end

local function find_selected_alert(entries, selected_id)
  if not selected_id then
    return nil
  end
  for _, entry in ipairs(entries or {}) do
    if entry.type == "alert" and entry.alert and entry.alert.id == selected_id then
      return entry.alert
    end
  end
  return nil
end

local function toggle_filter(filters, key)
  filters[key] = not filters[key]
end

local function format_mute(entry, now)
  if type(entry) == "number" then
    return entry
  end
  if type(entry) == "table" then
    return entry.until or 0
  end
  return 0
end

local function render(mon, model)
  local state = ensure_state(mon)
  model = model or {}
  local snapshot = textutils.serialize({
    model = model,
    state = {
      page = state.page,
      selected = state.selected_id,
      view = state.view,
      group_mode = state.group_mode,
      sort_mode = state.sort_mode,
      search = state.search,
      search_active = state.search_active,
      filters = state.filters,
      collapsed = state.collapsed,
      mute_index = state.mute_index
    }
  })
  if cache[mon] == snapshot then
    return
  end
  cache[mon] = snapshot

  local w, h = mon.getSize()
  ui.panel(mon, 1, 1, w, h, "ALERTS", "OK")

  local counts = model.counts or {}
  local metrics = model.metrics or {}
  local muted_counts = metrics.muted_counts or {}
  local crit = counts.CRITICAL or 0
  local warn = counts.WARN or 0
  local info = counts.INFO or 0

  ui.text(mon, 2, 1, "ALERTS", colorset.get("text"), colorset.get("background"))
  ui.badge(mon, 10, 1, "CRIT " .. tostring(crit), crit > 0 and "EMERGENCY" or "OFFLINE")
  ui.badge(mon, 20, 1, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OFFLINE")
  ui.badge(mon, 30, 1, "INFO " .. tostring(info), info > 0 and "OK" or "OFFLINE")
  if muted_counts.rules or muted_counts.nodes then
    local muted_label = string.format("MUTE R:%d N:%d", muted_counts.rules or 0, muted_counts.nodes or 0)
    ui.rightText(mon, 2, 1, w - 3, muted_label, colorset.get("text"), colorset.get("background"))
  end

  ui.text(mon, 2, 2, model.summary or "", colorset.get("text"), colorset.get("background"))

  state.buttons = {}

  local view_y = 3
  local view_active_status = state.view == "active" and "OK" or "OFFLINE"
  local view_hist_status = state.view == "history" and "OK" or "OFFLINE"
  ui.badge(mon, 2, view_y, "ACTIVE", view_active_status)
  ui.badge(mon, 10, view_y, "HISTORY", view_hist_status)
  state.buttons.view_active = { x1 = 2, x2 = 2 + #" ACTIVE " - 1, y = view_y }
  state.buttons.view_history = { x1 = 10, x2 = 10 + #" HISTORY " - 1, y = view_y }

  local sort_x = 20
  local sort_sev_status = state.sort_mode == "severity" and "OK" or "OFFLINE"
  local sort_rec_status = state.sort_mode == "recency" and "OK" or "OFFLINE"
  local sort_node_status = state.sort_mode == "node" and "OK" or "OFFLINE"
  ui.badge(mon, sort_x, view_y, "S+R", sort_sev_status)
  ui.badge(mon, sort_x + 6, view_y, "REC", sort_rec_status)
  ui.badge(mon, sort_x + 12, view_y, "NODE", sort_node_status)
  state.buttons.sort_severity = { x1 = sort_x, x2 = sort_x + #" S+R " - 1, y = view_y }
  state.buttons.sort_recency = { x1 = sort_x + 6, x2 = sort_x + 6 + #" REC " - 1, y = view_y }
  state.buttons.sort_node = { x1 = sort_x + 12, x2 = sort_x + 12 + #" NODE " - 1, y = view_y }

  local group_x = sort_x + 20
  local group_flat_status = state.group_mode == "flat" and "OK" or "OFFLINE"
  local group_node_status = state.group_mode == "node" and "OK" or "OFFLINE"
  ui.badge(mon, group_x, view_y, "FLAT", group_flat_status)
  ui.badge(mon, group_x + 6, view_y, "BY NODE", group_node_status)
  state.buttons.group_flat = { x1 = group_x, x2 = group_x + #" FLAT " - 1, y = view_y }
  state.buttons.group_node = { x1 = group_x + 6, x2 = group_x + 6 + #" BY NODE " - 1, y = view_y }

  local filter_y = 4
  local filter_x = 2
  ui.text(mon, filter_x, filter_y, "Sev", colorset.get("text"), colorset.get("background"))
  filter_x = filter_x + 4
  for _, sev in ipairs({ "INFO", "WARN", "CRITICAL" }) do
    local status = state.filters.severity[sev] and severity_status[sev] or "OFFLINE"
    local label = sev:sub(1, 1)
    ui.badge(mon, filter_x, filter_y, label, status)
    state.buttons["sev_" .. sev] = { x1 = filter_x, x2 = filter_x + #(" " .. label .. " ") - 1, y = filter_y }
    filter_x = filter_x + 4
  end

  ui.text(mon, filter_x + 1, filter_y, "Scope", colorset.get("text"), colorset.get("background"))
  filter_x = filter_x + 7
  for _, entry in ipairs(scope_filters) do
    local status = state.filters.scope[entry.key] and "OK" or "OFFLINE"
    ui.badge(mon, filter_x, filter_y, entry.label, status)
    state.buttons["scope_" .. entry.key] = { x1 = filter_x, x2 = filter_x + #(" " .. entry.label .. " ") - 1, y = filter_y }
    filter_x = filter_x + #(" " .. entry.label .. " ") + 1
  end

  local ack_label = state.filters.show_acknowledged and "ACK" or "NOACK"
  ui.badge(mon, filter_x + 1, filter_y, ack_label, state.filters.show_acknowledged and "OK" or "OFFLINE")
  state.buttons.toggle_ack = { x1 = filter_x + 1, x2 = filter_x + 1 + #(" " .. ack_label .. " ") - 1, y = filter_y }

  local role_y = 5
  local role_x = 2
  ui.text(mon, role_x, role_y, "Role", colorset.get("text"), colorset.get("background"))
  role_x = role_x + 5
  for _, entry in ipairs(role_filters) do
    local status = state.filters.roles[entry.key] and "OK" or "OFFLINE"
    ui.badge(mon, role_x, role_y, entry.label, status)
    state.buttons["role_" .. entry.key] = { x1 = role_x, x2 = role_x + #(" " .. entry.label .. " ") - 1, y = role_y }
    role_x = role_x + #(" " .. entry.label .. " ") + 1
  end

  local search_y = 6
  local search_active = state.search_active and "*" or ""
  local search_text = string.format("Search%s: %s", search_active, state.search ~= "" and state.search or "--")
  ui.text(mon, 2, search_y, search_text, colorset.get("text"), colorset.get("background"))
  local clear_label = "CLR"
  ui.badge(mon, w - (#clear_label + 2), search_y, clear_label, state.search ~= "" and "WARNING" or "OFFLINE")
  state.buttons.search_clear = { x1 = w - (#clear_label + 2), x2 = w - 1, y = search_y }
  state.buttons.search_focus = { x1 = 2, x2 = w - (#clear_label + 4), y = search_y }

  local list_top = 7
  local footer_rows = 4
  local list_height = math.max(3, h - list_top - footer_rows)

  local source_list = state.view == "history" and (model.history or {}) or (model.active or {})
  local filtered = {}
  for _, alert in ipairs(source_list) do
    if alert_matches(alert, state) then
      table.insert(filtered, alert)
    end
  end
  sort_alerts(filtered, state.sort_mode)

  local rows, entries
  if state.group_mode == "node" then
    rows, entries = build_group_rows(filtered, state)
  else
    rows, entries = build_flat_rows(filtered)
  end

  local total_pages = math.max(1, math.ceil(#rows / list_height))
  if state.page > total_pages then
    state.page = total_pages
  end
  local start_idx = (state.page - 1) * list_height + 1
  local end_idx = math.min(#rows, state.page * list_height)

  if not state.selected_id then
    state.selected_id = select_first_visible(entries)
  elseif not find_selected_alert(entries, state.selected_id) then
    state.selected_id = select_first_visible(entries)
  end

  local visible_ids = decorate_rows(rows, entries, state, start_idx, end_idx)
  if state.view ~= "active" then
    visible_ids = {}
  end
  local display_rows = {}
  for idx = start_idx, end_idx do
    table.insert(display_rows, rows[idx])
  end
  ui.list(mon, 2, list_top, w - 3, display_rows, { max_rows = list_height })
  state.list_bounds = {
    x1 = 2,
    x2 = w - 2,
    y1 = list_top,
    y2 = list_top + list_height - 1,
    start_index = start_idx,
    end_index = end_idx,
    rows = rows,
    entries = entries
  }

  local page_y = list_top + list_height
  local range_text = string.format("%d-%d/%d", #rows == 0 and 0 or start_idx, end_idx, #rows)
  local page_text = string.format("< Alerts %d/%d >", state.page, total_pages)
  ui.text(mon, 2, page_y, page_text, colorset.get("text"), colorset.get("background"))
  ui.rightText(mon, 2, page_y, w - 3, range_text, colorset.get("text"), colorset.get("background"))
  state.buttons.prev = { x1 = 2, x2 = 3, y = page_y }
  state.buttons.next = { x1 = 2 + #page_text - 1, x2 = 2 + #page_text, y = page_y }

  local selected = find_selected_alert(entries, state.selected_id)
  local detail_y = page_y + 1
  if detail_y <= h - 2 then
    if selected then
      local source = selected.source or {}
      local role = tostring(source.role or "")
      local node_id = tostring(source.node_id or "SYSTEM")
      local header = string.format("%s (%s) %s", selected.title or "Alert", selected.severity or "INFO", node_id)
      ui.text(mon, 2, detail_y, header, colorset.get("text"), colorset.get("background"))
      if detail_y + 1 <= h - 2 then
        local msg = string.format("%s %s", role, selected.message or "")
        ui.text(mon, 2, detail_y + 1, msg, colorset.get("text"), colorset.get("background"))
      end
    else
      ui.text(mon, 2, detail_y, "No alerts", colorset.get("text"), colorset.get("background"))
    end
  end

  local mute_y = h - 1
  local button_y = h

  local mute_options = (model.config and model.config.mute_durations) or {}
  state.mute_options = mute_options
  if not state.mute_minutes then
    state.mute_minutes = model.config and model.config.mute_default_minutes or 10
  end
  if #mute_options > 0 and not mute_options[state.mute_index] then
    state.mute_index = 1
  end
  local mute_minutes = mute_options[state.mute_index] or state.mute_minutes or 10
  state.mute_minutes = mute_minutes

  local mutes = model.mutes or { rules = {}, nodes = {} }
  state.last_mutes = mutes
  local rule_muted = selected and selected.code and mutes.rules and mutes.rules[selected.code]
  local node_muted = selected and selected.source and selected.source.node_id and mutes.nodes and mutes.nodes[selected.source.node_id]

  local mute_label = string.format("MUTE %dm", mute_minutes)
  ui.badge(mon, 2, mute_y, mute_label, "WARNING")
  state.buttons.mute_cycle = { x1 = 2, x2 = 2 + #(" " .. mute_label .. " ") - 1, y = mute_y }

  local rule_label = rule_muted and "UNMUTE RULE" or "MUTE RULE"
  local node_label = node_muted and "UNMUTE NODE" or "MUTE NODE"
  ui.badge(mon, 2 + #(" " .. mute_label .. " ") + 1, mute_y, rule_label, selected and "WARNING" or "OFFLINE")
  local rule_x = 2 + #(" " .. mute_label .. " ") + 1
  state.buttons.mute_rule = { x1 = rule_x, x2 = rule_x + #(" " .. rule_label .. " ") - 1, y = mute_y }

  local node_x = rule_x + #(" " .. rule_label .. " ") + 1
  ui.badge(mon, node_x, mute_y, node_label, selected and "WARNING" or "OFFLINE")
  state.buttons.mute_node = { x1 = node_x, x2 = node_x + #(" " .. node_label .. " ") - 1, y = mute_y }

  local can_ack = state.view == "active"
  local ack_label = selected and (selected.acknowledged and "UNACK" or "ACK") or "ACK"
  ui.badge(mon, 2, button_y, ack_label, (selected and can_ack) and "WARNING" or "OFFLINE")
  state.buttons.ack = { x1 = 2, x2 = 2 + #(" " .. ack_label .. " ") - 1, y = button_y }

  local ack_vis_label = "ACK VIS"
  ui.badge(mon, 2 + #(" " .. ack_label .. " ") + 1, button_y, ack_vis_label, (#visible_ids > 0 and can_ack) and "WARNING" or "OFFLINE")
  local ack_vis_x = 2 + #(" " .. ack_label .. " ") + 1
  state.buttons.ack_visible = { x1 = ack_vis_x, x2 = ack_vis_x + #(" " .. ack_vis_label .. " ") - 1, y = button_y, ids = visible_ids }

  local ack_all_label = "ACK ALL"
  local ack_all_x = ack_vis_x + #(" " .. ack_vis_label .. " ") + 1
  ui.badge(mon, ack_all_x, button_y, ack_all_label, #rows > 0 and can_ack and "WARNING" or "OFFLINE")
  state.buttons.ack_all = { x1 = ack_all_x, x2 = ack_all_x + #(" " .. ack_all_label .. " ") - 1, y = button_y }

  if rule_muted or node_muted then
    local now = model.now_ms or 0
    local rule_until = rule_muted and format_mute(rule_muted, now) or nil
    local node_until = node_muted and format_mute(node_muted, now) or nil
    local mute_text = "Muted"
    if rule_until or node_until then
      local until = math.max(rule_until or 0, node_until or 0)
      if until > 0 then
        mute_text = string.format("Muted until %s", os.date("!%H:%M:%S", math.floor(until / 1000)))
      end
    end
    ui.rightText(mon, 2, mute_y, w - 3, mute_text, colorset.get("text"), colorset.get("background"))
  end
end

local function hit_test(mon, x, y)
  local state = ensure_state(mon)
  local function hit(bounds)
    return bounds and y == bounds.y and x >= bounds.x1 and x <= bounds.x2
  end
  local can_ack = state.view == "active"

  if hit(state.buttons.prev) then
    state.page = math.max(1, state.page - 1)
    return nil
  end
  if hit(state.buttons.next) then
    state.page = state.page + 1
    return nil
  end
  if hit(state.buttons.view_active) then
    state.view = "active"
    state.page = 1
    return nil
  end
  if hit(state.buttons.view_history) then
    state.view = "history"
    state.page = 1
    return nil
  end
  if hit(state.buttons.sort_severity) then
    state.sort_mode = "severity"
    return nil
  end
  if hit(state.buttons.sort_recency) then
    state.sort_mode = "recency"
    return nil
  end
  if hit(state.buttons.sort_node) then
    state.sort_mode = "node"
    return nil
  end
  if hit(state.buttons.group_flat) then
    state.group_mode = "flat"
    state.page = 1
    return nil
  end
  if hit(state.buttons.group_node) then
    state.group_mode = "node"
    state.page = 1
    return nil
  end
  if hit(state.buttons.toggle_ack) then
    state.filters.show_acknowledged = not state.filters.show_acknowledged
    state.page = 1
    return nil
  end
  if hit(state.buttons.search_clear) then
    state.search = ""
    state.page = 1
    return nil
  end
  if hit(state.buttons.search_focus) then
    state.search_active = not state.search_active
    return nil
  end

  for _, sev in ipairs({ "INFO", "WARN", "CRITICAL" }) do
    if hit(state.buttons["sev_" .. sev]) then
      toggle_filter(state.filters.severity, sev)
      state.page = 1
      return nil
    end
  end
  for _, entry in ipairs(scope_filters) do
    if hit(state.buttons["scope_" .. entry.key]) then
      toggle_filter(state.filters.scope, entry.key)
      state.page = 1
      return nil
    end
  end
  for _, entry in ipairs(role_filters) do
    if hit(state.buttons["role_" .. entry.key]) then
      toggle_filter(state.filters.roles, entry.key)
      state.page = 1
      return nil
    end
  end

  if hit(state.buttons.mute_cycle) then
    local options = state.mute_options or {}
    if #options > 0 then
      state.mute_index = (state.mute_index % #options) + 1
      state.mute_minutes = options[state.mute_index]
    end
    return nil
  end

  if hit(state.buttons.mute_rule) then
    local selected = find_selected_alert(state.list_bounds.entries, state.selected_id)
    if selected and selected.code then
      local mutes = state.last_mutes or {}
      if mutes.rules and mutes.rules[selected.code] then
        return { type = "alert_unmute_rule", code = selected.code }
      end
      return { type = "alert_mute_rule", code = selected.code, minutes = state.mute_minutes }
    end
  end

  if hit(state.buttons.mute_node) then
    local selected = find_selected_alert(state.list_bounds.entries, state.selected_id)
    local node_id = selected and selected.source and selected.source.node_id
    if node_id then
      local mutes = state.last_mutes or {}
      if mutes.nodes and mutes.nodes[node_id] then
        return { type = "alert_unmute_node", node_id = node_id }
      end
      return { type = "alert_mute_node", node_id = node_id, minutes = state.mute_minutes }
    end
  end

  if hit(state.buttons.ack) then
    if state.selected_id and can_ack then
      return { type = "alert_ack", id = state.selected_id }
    end
    return nil
  end
  if hit(state.buttons.ack_visible) then
    if can_ack and state.buttons.ack_visible.ids and #state.buttons.ack_visible.ids > 0 then
      return { type = "alert_ack_visible", ids = state.buttons.ack_visible.ids }
    end
    return nil
  end
  if hit(state.buttons.ack_all) then
    if can_ack then
      return { type = "alert_ack_all" }
    end
    return nil
  end

  local bounds = state.list_bounds
  if bounds and y >= bounds.y1 and y <= bounds.y2 and x >= bounds.x1 and x <= bounds.x2 then
    local index = bounds.start_index + (y - bounds.y1)
    local entry = bounds.entries and bounds.entries[index]
    if entry and entry.type == "group" then
      state.collapsed[entry.node_id] = not state.collapsed[entry.node_id]
    elseif entry and entry.type == "alert" and entry.alert then
      state.selected_id = entry.alert.id
    end
  end
  return nil
end

local function handle_key(mon, key)
  local state = ensure_state(mon)
  if type(keys) ~= "table" then
    return nil
  end
  if key == keys.up or key == keys.down then
    local entries = state.list_bounds.entries or {}
    local direction = key == keys.up and -1 or 1
    local idx = nil
    for i, entry in ipairs(entries) do
      if entry.type == "alert" and entry.alert and entry.alert.id == state.selected_id then
        idx = i
        break
      end
    end
    if idx then
      local next_idx = idx + direction
      while entries[next_idx] and entries[next_idx].type ~= "alert" do
        next_idx = next_idx + direction
      end
      if entries[next_idx] and entries[next_idx].alert then
        state.selected_id = entries[next_idx].alert.id
      end
    else
      state.selected_id = select_first_visible(entries)
    end
    return nil
  end
  if key == keys.pageUp then
    state.page = math.max(1, state.page - 1)
    return nil
  end
  if key == keys.pageDown then
    state.page = state.page + 1
    return nil
  end
  if key == keys.enter or key == keys.space then
    if state.selected_id then
      return { type = "alert_ack", id = state.selected_id }
    end
  end
  if key == keys.backspace then
    if state.search ~= "" then
      state.search = state.search:sub(1, -2)
      state.page = 1
    end
  end
  return nil
end

local function handle_char(mon, char)
  local state = ensure_state(mon)
  if not char then
    return nil
  end
  if char == "/" then
    state.search_active = not state.search_active
    return nil
  end
  if state.search_active then
    state.search = normalize_text(tostring(state.search or "") .. tostring(char))
    state.page = 1
  end
  return nil
end

return { render = render, hit_test = hit_test, handle_key = handle_key, handle_char = handle_char }
