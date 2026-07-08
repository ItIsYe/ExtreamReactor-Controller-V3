local ui = require("core.ui")
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")
local utils = require("core.utils")

local cache = {}
local state_cache = setmetatable({}, { __mode = "k" })

local severity_status = {
  INFO = "LIMITED",
  WARN = "WARNING",
  WARNING = "WARNING",
  CRITICAL = "EMERGENCY"
}

local severity_rank = {
  CRITICAL = 1,
  WARN = 2,
  WARNING = 2,
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

local function sev_key(value)
  local s = tostring(value or "INFO"):upper()
  if s == "WARNING" then s = "WARN" end
  return s
end

local function alert_matches(alert, state)
  if not alert then return false end
  local filters = state.filters
  local severity = sev_key(alert.severity)
  if not filters.severity[severity] then return false end
  if not filters.scope[alert.scope or "SYSTEM"] then return false end
  if not filters.show_acknowledged and alert.acknowledged then return false end
  local role = alert.source and alert.source.role or constants.roles.MASTER
  if not filters.roles[role] then return false end
  local search = state.search or ""
  if search ~= "" then
    local target = table.concat({
      normalize_text(alert.title),
      normalize_text(alert.message),
      normalize_text(alert.code),
      normalize_text(alert.source and alert.source.node_id),
      normalize_text(alert.source and alert.source.device_id)
    }, " ")
    if not target:find(search, 1, true) then return false end
  end
  return true
end

local function sort_alerts(list, mode)
  if mode == "recency" then
    table.sort(list, function(a, b) return (a.ts_last or 0) > (b.ts_last or 0) end)
    return
  end
  if mode == "node" then
    table.sort(list, function(a, b)
      local as, bs = a.source or {}, b.source or {}
      local an, bn = tostring(as.node_id or ""), tostring(bs.node_id or "")
      if an ~= bn then return an < bn end
      local ar, br = tostring(as.role or ""), tostring(bs.role or "")
      if ar ~= br then return ar < br end
      local a_rank = severity_rank[sev_key(a.severity)] or 99
      local b_rank = severity_rank[sev_key(b.severity)] or 99
      if a_rank ~= b_rank then return a_rank < b_rank end
      return (a.ts_last or 0) > (b.ts_last or 0)
    end)
    return
  end
  table.sort(list, function(a, b)
    local ar = severity_rank[sev_key(a.severity)] or 99
    local br = severity_rank[sev_key(b.severity)] or 99
    if ar == br then return (a.ts_last or 0) > (b.ts_last or 0) end
    return ar < br
  end)
end

local function build_entries(list, state)
  local entries = {}
  if state.group_mode ~= "node" then
    for _, alert in ipairs(list) do entries[#entries + 1] = { type = "alert", alert = alert } end
    return entries
  end

  local grouped = {}
  for _, alert in ipairs(list) do
    local node_id = tostring((alert.source or {}).node_id or "SYSTEM")
    grouped[node_id] = grouped[node_id] or {}
    grouped[node_id][#grouped[node_id] + 1] = alert
  end
  local nodes = {}
  for id in pairs(grouped) do nodes[#nodes + 1] = id end
  table.sort(nodes)
  for _, node_id in ipairs(nodes) do
    local group = grouped[node_id]
    sort_alerts(group, state.sort_mode)
    local highest = "INFO"
    for _, a in ipairs(group) do
      if (severity_rank[sev_key(a.severity)] or 99) < (severity_rank[highest] or 99) then highest = sev_key(a.severity) end
    end
    entries[#entries + 1] = { type = "group", node_id = node_id, count = #group, severity = highest }
    if not state.collapsed[node_id] then
      for _, alert in ipairs(group) do entries[#entries + 1] = { type = "alert", alert = alert } end
    end
  end
  return entries
end

local function select_first(entries)
  for _, entry in ipairs(entries or {}) do
    if entry.type == "alert" and entry.alert then return entry.alert.id end
  end
  return nil
end

local function find_selected(entries, id)
  if not id then return nil end
  for _, entry in ipairs(entries or {}) do
    if entry.type == "alert" and entry.alert and entry.alert.id == id then return entry.alert end
  end
  return nil
end

local function fmt_time(ts)
  local n = tonumber(ts)
  if not n or n <= 0 then return "--:--:--" end
  if n > 100000000000 then n = math.floor(n / 1000) end
  if os and os.date then return os.date("!%H:%M:%S", n) end
  return "--:--:--"
end

local function role_short(role)
  for _, entry in ipairs(role_filters) do
    if entry.key == role then return entry.label end
  end
  return tostring(role or "--")
end

local function scope_short(scope)
  local s = tostring(scope or "SYSTEM")
  if s == "SYSTEM" then return "SYS" end
  if s == "DEVICE" then return "DEV" end
  return s
end

local function badge_button(mon, state, key, x, y, label, status)
  ui.badge(mon, x, y, label, status)
  state.buttons[key] = { x1 = x, x2 = x + #(" " .. label .. " ") - 1, y = y }
  return x + #(" " .. label .. " ") + 1
end

local function render_controls(mon, state, w)
  local y = 8
  mux.card(mon, 2, y, w - 3, 7, { title = "FILTER / ANSICHT", status = "OK", icon = "config" })

  local x = 4
  ui.text(mon, x, y + 1, "VIEW", colorset.get("muted"), colorset.get("background"))
  x = x + 6
  x = badge_button(mon, state, "view_active", x, y + 1, "ACTIVE", state.view == "active" and "OK" or "OFFLINE")
  x = badge_button(mon, state, "view_history", x, y + 1, "HISTORY", state.view == "history" and "OK" or "OFFLINE")

  x = math.max(x + 2, math.floor(w * 0.38))
  ui.text(mon, x, y + 1, "SORT", colorset.get("muted"), colorset.get("background"))
  x = x + 5
  x = badge_button(mon, state, "sort_severity", x, y + 1, "S+R", state.sort_mode == "severity" and "OK" or "OFFLINE")
  x = badge_button(mon, state, "sort_recency", x, y + 1, "REC", state.sort_mode == "recency" and "OK" or "OFFLINE")
  x = badge_button(mon, state, "sort_node", x, y + 1, "NODE", state.sort_mode == "node" and "OK" or "OFFLINE")

  x = 4
  ui.text(mon, x, y + 3, "SEVERITY", colorset.get("muted"), colorset.get("background"))
  x = x + 9
  for _, s in ipairs({ "INFO", "WARN", "CRITICAL" }) do
    local label = s == "CRITICAL" and "C" or s:sub(1, 1)
    x = badge_button(mon, state, "sev_" .. s, x, y + 3, label, state.filters.severity[s] and severity_status[s] or "OFFLINE")
  end

  x = x + 2
  ui.text(mon, x, y + 3, "SCOPE", colorset.get("muted"), colorset.get("background"))
  x = x + 6
  for _, entry in ipairs(scope_filters) do
    x = badge_button(mon, state, "scope_" .. entry.key, x, y + 3, entry.label, state.filters.scope[entry.key] and "OK" or "OFFLINE")
  end
  x = badge_button(mon, state, "toggle_ack", x, y + 3, state.filters.show_acknowledged and "ACK" or "NOACK", state.filters.show_acknowledged and "OK" or "OFFLINE")

  x = 4
  ui.text(mon, x, y + 5, "ROLE", colorset.get("muted"), colorset.get("background"))
  x = x + 5
  for _, entry in ipairs(role_filters) do
    x = badge_button(mon, state, "role_" .. entry.key, x, y + 5, entry.label, state.filters.roles[entry.key] and "OK" or "OFFLINE")
  end

  local group_x = math.max(x + 2, math.floor(w * 0.70))
  if group_x < w - 14 then
    group_x = badge_button(mon, state, "group_flat", group_x, y + 5, "FLAT", state.group_mode == "flat" and "OK" or "OFFLINE")
    badge_button(mon, state, "group_node", group_x, y + 5, "BY NODE", state.group_mode == "node" and "OK" or "OFFLINE")
  end
end

local function render(mon, model)
  local state = ensure_state(mon)
  model = model or {}
  local snapshot = utils.safe_serialize({
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
  }) or tostring(model)
  if cache[mon] == snapshot then return end
  cache[mon] = snapshot

  local w, h = ui.getSize(mon)
  if not w or not h then return end
  state.buttons = {}
  state.list_bounds = {}

  local counts = model.counts or {}
  local crit = tonumber(counts.CRITICAL) or 0
  local warn = tonumber(counts.WARN or counts.WARNING) or 0
  local info = tonumber(counts.INFO) or 0
  local total = crit + warn + info
  local page_status = crit > 0 and "EMERGENCY" or warn > 0 and "WARNING" or "OK"

  mux.clear(mon)
  mux.header(mon, { title = "AUX ALERTS", node_id = "MASTER AUX", page = "ALERTS", status = page_status, icon = "warning" })

  if w >= 58 then
    local cw = math.floor((w - 5 - 3) / 4)
    local cards = {
      { label = "ALERTS", value = tostring(total), status = total > 0 and "OK" or "OFFLINE", icon = "warning" },
      { label = "CRIT", value = tostring(crit), status = crit > 0 and "EMERGENCY" or "OFFLINE", icon = "warning" },
      { label = "WARN", value = tostring(warn), status = warn > 0 and "WARNING" or "OFFLINE", icon = "warning" },
      { label = "INFO", value = tostring(info), status = info > 0 and "LIMITED" or "OFFLINE", icon = "network" }
    }
    for i, c in ipairs(cards) do mux.metric_card(mon, 2 + (i - 1) * (cw + 1), 4, cw, 4, c) end
  else
    mux.kpi_strip(mon, 2, 4, w - 3, {
      { label = "ALERTS", value = total, status = "OK", icon = "warning" },
      { label = "CRIT", value = crit, status = crit > 0 and "EMERGENCY" or "OFFLINE", icon = "warning" },
      { label = "WARN", value = warn, status = warn > 0 and "WARNING" or "OFFLINE", icon = "warning" },
      { label = "INFO", value = info, status = info > 0 and "LIMITED" or "OFFLINE", icon = "network" }
    })
  end

  render_controls(mon, state, w)

  local search_y = 15
  mux.card(mon, 2, search_y, w - 3, 3, { status = state.search_active and "LIMITED" or "OFFLINE" })
  local search_text = "Search" .. (state.search_active and "*" or "") .. ": " .. (state.search ~= "" and state.search or "--")
  ui.text(mon, 4, search_y + 1, mux.fit(search_text, w - 12), colorset.get("text"), colorset.get("background"))
  local clear_x = w - 6
  ui.badge(mon, clear_x, search_y + 1, "CLR", state.search ~= "" and "WARNING" or "OFFLINE")
  state.buttons.search_focus = { x1 = 4, x2 = clear_x - 2, y = search_y + 1 }
  state.buttons.search_clear = { x1 = clear_x, x2 = w - 2, y = search_y + 1 }

  local source_list = state.view == "history" and (model.history or {}) or (model.active or {})
  local filtered = {}
  for _, alert in ipairs(source_list) do if alert_matches(alert, state) then filtered[#filtered + 1] = alert end end
  sort_alerts(filtered, state.sort_mode)
  local entries = build_entries(filtered, state)

  if not state.selected_id or not find_selected(entries, state.selected_id) then state.selected_id = select_first(entries) end

  local detail_h = h >= 34 and 10 or 8
  local list_top = 19
  local list_bottom = math.max(list_top + 3, h - detail_h - 2)
  local list_height = math.max(3, list_bottom - list_top + 1)
  local total_pages = math.max(1, math.ceil(#entries / list_height))
  if state.page > total_pages then state.page = total_pages end
  local start_idx = (state.page - 1) * list_height + 1
  local end_idx = math.min(#entries, state.page * list_height)

  mux.card(mon, 2, list_top - 1, w - 3, list_height + 2, {
    title = (state.view == "history" and "HISTORY" or "OPEN ALERTS") .. " (" .. tostring(#filtered) .. ")",
    status = page_status,
    icon = "warning"
  })

  local content_x = 4
  local content_w = w - 7
  local table_y = list_top
  if w >= 70 then
    mux.table_header(mon, content_x, table_y, content_w, {
      { label = "SEV", width = 6 },
      { label = "MESSAGE", width = math.max(18, content_w - 38) },
      { label = "SCOPE", width = 8 },
      { label = "NODE", width = 8 },
      { label = "ROLE", width = 6 },
      { label = "TIME", width = 10 }
    })
  else
    mux.table_header(mon, content_x, table_y, content_w, {
      { label = "SEV", width = 5 },
      { label = "MESSAGE", width = math.max(12, content_w - 21) },
      { label = "NODE", width = 8 },
      { label = "TIME", width = 8 }
    })
  end

  local row_y = table_y + 2
  local visible_ids = {}
  for idx = start_idx, end_idx do
    local entry = entries[idx]
    if entry and row_y <= list_bottom then
      if entry.type == "group" then
        local caret = state.collapsed[entry.node_id] and ">" or "v"
        local line = string.format("%s %s (%d)", caret, entry.node_id, entry.count or 0)
        mux.data_row(mon, content_x, row_y, content_w, { label = line, value = "", status = severity_status[entry.severity] or "LIMITED", icon = "network" })
      else
        local a = entry.alert
        local source = a.source or {}
        local sk = sev_key(a.severity)
        local status = a.acknowledged and "OFFLINE" or severity_status[sk] or "LIMITED"
        local selected = a.id == state.selected_id
        local sev_label = sk == "CRITICAL" and "C" or sk:sub(1, 1)
        local title = tostring(a.title or a.code or source.device_id or source.node_id or "Alert")
        if a.muted then title = "[M] " .. title end
        if a.acknowledged then title = "[A] " .. title end
        if a.lifecycle_state == "wieder_aufgetreten" then title = "[R] " .. title end
        local marker = selected and ">" or " "
        local node = tostring(source.node_id or "--")
        local role = role_short(source.role)
        local time = fmt_time(a.ts_last or a.ts_first)
        local line
        if w >= 70 then
          line = string.format("%s%-4s %-28s %-7s %-7s %-5s %-8s", marker, sev_label, mux.fit(title, 28), scope_short(a.scope), mux.fit(node, 7), mux.fit(role, 5), time)
        else
          line = string.format("%s%-3s %-22s %-7s %-8s", marker, sev_label, mux.fit(title, 22), mux.fit(node, 7), time)
        end
        mux.data_row(mon, content_x, row_y, content_w, { label = line, value = "", status = status })
        if state.view == "active" then visible_ids[#visible_ids + 1] = a.id end
      end
      row_y = row_y + 1
    end
  end

  state.list_bounds = {
    x1 = content_x, x2 = content_x + content_w - 1,
    y1 = table_y + 2, y2 = table_y + 2 + (end_idx - start_idx),
    start_index = start_idx, end_index = end_idx, entries = entries
  }

  local range = string.format("%d-%d/%d", #entries == 0 and 0 or start_idx, end_idx, #entries)
  ui.rightText(mon, content_x, list_top - 1, content_w, range, colorset.get("muted"), colorset.get("background"))
  if total_pages > 1 then
    local ptxt = string.format("< %d/%d >", state.page, total_pages)
    ui.text(mon, content_x, list_bottom, ptxt, colorset.get("text"), colorset.get("background"))
    state.buttons.prev = { x1 = content_x, x2 = content_x + 1, y = list_bottom }
    state.buttons.next = { x1 = content_x + #ptxt - 2, x2 = content_x + #ptxt - 1, y = list_bottom }
  end

  local selected = find_selected(entries, state.selected_id)
  local detail_y = list_bottom + 2
  local detail_bottom = h - 1 -- letzte Zeile h bleibt fuer globale ZURUECK/WEITER-Navigation frei
  local available_h = math.max(4, detail_bottom - detail_y + 1)

  local mute_options = (model.config and model.config.mute_durations) or {}
  state.mute_options = mute_options
  if not state.mute_minutes then state.mute_minutes = model.config and model.config.mute_default_minutes or 10 end
  if #mute_options > 0 and not mute_options[state.mute_index] then state.mute_index = 1 end
  local mute_minutes = mute_options[state.mute_index] or state.mute_minutes or 10
  state.mute_minutes = mute_minutes
  local mutes = model.mutes or { rules = {}, nodes = {} }
  state.last_mutes = mutes

  if w >= 68 and available_h >= 6 then
    local action_w = math.max(22, math.floor((w - 5) * 0.28))
    local detail_w = w - action_w - 5
    mux.card(mon, 2, detail_y, detail_w, available_h, { title = "SELECTED ALERT", status = selected and severity_status[sev_key(selected.severity)] or "OFFLINE", icon = "warning" })
    mux.card(mon, detail_w + 3, detail_y, action_w, available_h, { title = "ACTIONS", status = selected and "WARNING" or "OFFLINE", icon = "config" })

    if selected then
      local src = selected.source or {}
      local status = severity_status[sev_key(selected.severity)] or "LIMITED"
      mux.data_row(mon, 4, detail_y + 1, detail_w - 4, { label = "MESSAGE", value = tostring(selected.title or selected.code or "Alert"), status = status })
      if available_h >= 5 then
        mux.data_row(mon, 4, detail_y + 2, detail_w - 4, { label = "SEVERITY", value = sev_key(selected.severity), status = status })
        mux.data_row(mon, 4, detail_y + 3, detail_w - 4, { label = "SCOPE " .. scope_short(selected.scope) .. " | NODE " .. tostring(src.node_id or "--"), value = "ROLE " .. role_short(src.role), status = "text" })
      end
      if available_h >= 7 then
        mux.data_row(mon, 4, detail_y + 4, detail_w - 4, { label = "TIME " .. fmt_time(selected.ts_last or selected.ts_first), value = "ID " .. tostring(selected.id or "--"), status = "text" })
        mux.data_row(mon, 4, detail_y + 5, detail_w - 4, { label = "DETAILS", value = "", status = "OK" })
        mux.data_row(mon, 4, detail_y + 6, detail_w - 4, { label = tostring(selected.message or "--"), value = "", status = "text" })
      end
    else
      mux.data_row(mon, 4, detail_y + 2, detail_w - 4, { label = "Kein Alert ausgewaehlt", value = "", status = "OFFLINE" })
    end

    local ax = detail_w + 5
    local aw = action_w - 4
    local half = math.floor((aw - 1) / 2)
    local ay = detail_y + 2
    local src = selected and selected.source or {}
    local rule_muted = selected and selected.code and mutes.rules and mutes.rules[selected.code]
    local node_muted = selected and src.node_id and mutes.nodes and mutes.nodes[src.node_id]
    local can_ack = state.view == "active"

    local function action_btn(key, x, y, bw, label, status, extra)
      mux.card(mon, x, y, bw, 3, { status = status })
      ui.text(mon, x + 2, y + 1, mux.fit(label, bw - 4), colorset.get(status), colorset.get("background"))
      state.buttons[key] = { x1 = x, x2 = x + bw - 1, y1 = y, y2 = y + 2 }
      if extra then for k, v in pairs(extra) do state.buttons[key][k] = v end end
    end

    if ay + 2 <= detail_bottom then
      action_btn("mute_cycle", ax, ay, half, string.format("MUTE %dm", mute_minutes), selected and "WARNING" or "OFFLINE")
      action_btn("mute_rule", ax + half + 1, ay, aw - half - 1, rule_muted and "UNMUTE RULE" or "MUTE RULE", selected and "WARNING" or "OFFLINE")
    end
    if ay + 6 <= detail_bottom then
      action_btn("mute_node", ax, ay + 4, half, node_muted and "UNMUTE NODE" or "MUTE NODE", selected and "WARNING" or "OFFLINE")
      action_btn("ack", ax + half + 1, ay + 4, aw - half - 1, selected and selected.acknowledged and "UNACK" or "ACK", selected and can_ack and "WARNING" or "OFFLINE")
    end
    if ay + 10 <= detail_bottom then
      action_btn("ack_visible", ax, ay + 8, half, "ACK VIS", #visible_ids > 0 and can_ack and "WARNING" or "OFFLINE", { ids = visible_ids })
      action_btn("ack_all", ax + half + 1, ay + 8, aw - half - 1, "ACK ALL", #entries > 0 and can_ack and "WARNING" or "OFFLINE")
    end
  else
    mux.card(mon, 2, detail_y, w - 3, available_h, { title = "SELECTED ALERT", status = selected and severity_status[sev_key(selected.severity)] or "OFFLINE", icon = "warning" })
    if selected then
      local src = selected.source or {}
      mux.data_row(mon, 4, detail_y + 1, w - 7, { label = tostring(selected.title or selected.code or "Alert"), value = sev_key(selected.severity), status = severity_status[sev_key(selected.severity)] or "LIMITED" })
      if available_h >= 4 then mux.data_row(mon, 4, detail_y + 2, w - 7, { label = tostring(selected.message or ""), value = tostring(src.node_id or "--"), status = "text" }) end
    end
    -- kompakte Action-Zeile, weiterhin oberhalb der globalen Navigation
    local ay = detail_bottom
    local x = 4
    local mute_label = string.format("MUTE %dm", mute_minutes)
    x = badge_button(mon, state, "mute_cycle", x, ay, mute_label, selected and "WARNING" or "OFFLINE")
    x = badge_button(mon, state, "ack", x, ay, "ACK", selected and state.view == "active" and "WARNING" or "OFFLINE")
    x = badge_button(mon, state, "ack_visible", x, ay, "ACK VIS", #visible_ids > 0 and state.view == "active" and "WARNING" or "OFFLINE")
    badge_button(mon, state, "ack_all", x, ay, "ACK ALL", #entries > 0 and state.view == "active" and "WARNING" or "OFFLINE")
    state.buttons.ack_visible.ids = visible_ids
  end
end

local function hit_test(mon, x, y)
  local state = ensure_state(mon)
  local function hit(bounds)
    if not bounds then return false end
    local y1, y2 = bounds.y1 or bounds.y, bounds.y2 or bounds.y
    return y >= y1 and y <= y2 and x >= bounds.x1 and x <= bounds.x2
  end
  local can_ack = state.view == "active"

  if hit(state.buttons.prev) then state.page = math.max(1, state.page - 1); return nil end
  if hit(state.buttons.next) then state.page = state.page + 1; return nil end
  if hit(state.buttons.view_active) then state.view = "active"; state.page = 1; return nil end
  if hit(state.buttons.view_history) then state.view = "history"; state.page = 1; return nil end
  if hit(state.buttons.sort_severity) then state.sort_mode = "severity"; return nil end
  if hit(state.buttons.sort_recency) then state.sort_mode = "recency"; return nil end
  if hit(state.buttons.sort_node) then state.sort_mode = "node"; return nil end
  if hit(state.buttons.group_flat) then state.group_mode = "flat"; state.page = 1; return nil end
  if hit(state.buttons.group_node) then state.group_mode = "node"; state.page = 1; return nil end
  if hit(state.buttons.toggle_ack) then state.filters.show_acknowledged = not state.filters.show_acknowledged; state.page = 1; return nil end
  if hit(state.buttons.search_clear) then state.search = ""; state.page = 1; return nil end
  if hit(state.buttons.search_focus) then state.search_active = not state.search_active; return nil end

  for _, s in ipairs({ "INFO", "WARN", "CRITICAL" }) do
    if hit(state.buttons["sev_" .. s]) then state.filters.severity[s] = not state.filters.severity[s]; state.page = 1; return nil end
  end
  for _, entry in ipairs(scope_filters) do
    if hit(state.buttons["scope_" .. entry.key]) then state.filters.scope[entry.key] = not state.filters.scope[entry.key]; state.page = 1; return nil end
  end
  for _, entry in ipairs(role_filters) do
    if hit(state.buttons["role_" .. entry.key]) then state.filters.roles[entry.key] = not state.filters.roles[entry.key]; state.page = 1; return nil end
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
    local selected = find_selected(state.list_bounds.entries, state.selected_id)
    if selected and selected.code then
      local mutes = state.last_mutes or {}
      if mutes.rules and mutes.rules[selected.code] then return { type = "alert_unmute_rule", code = selected.code } end
      return { type = "alert_mute_rule", code = selected.code, minutes = state.mute_minutes }
    end
  end

  if hit(state.buttons.mute_node) then
    local selected = find_selected(state.list_bounds.entries, state.selected_id)
    local node_id = selected and selected.source and selected.source.node_id
    if node_id then
      local mutes = state.last_mutes or {}
      if mutes.nodes and mutes.nodes[node_id] then return { type = "alert_unmute_node", node_id = node_id } end
      return { type = "alert_mute_node", node_id = node_id, minutes = state.mute_minutes }
    end
  end

  if hit(state.buttons.ack) then
    if state.selected_id and can_ack then return { type = "alert_ack", id = state.selected_id } end
    return nil
  end
  if hit(state.buttons.ack_visible) then
    local ids = state.buttons.ack_visible.ids or {}
    if can_ack and #ids > 0 then return { type = "alert_ack_visible", ids = ids } end
    return nil
  end
  if hit(state.buttons.ack_all) then
    if can_ack then return { type = "alert_ack_all" } end
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
  if type(keys) ~= "table" then return nil end
  if key == keys.up or key == keys.down then
    local entries = state.list_bounds.entries or {}
    local direction = key == keys.up and -1 or 1
    local idx
    for i, entry in ipairs(entries) do
      if entry.type == "alert" and entry.alert and entry.alert.id == state.selected_id then idx = i; break end
    end
    if idx then
      local next_idx = idx + direction
      while entries[next_idx] and entries[next_idx].type ~= "alert" do next_idx = next_idx + direction end
      if entries[next_idx] and entries[next_idx].alert then state.selected_id = entries[next_idx].alert.id end
    else
      state.selected_id = select_first(entries)
    end
    return nil
  end
  if key == keys.pageUp then state.page = math.max(1, state.page - 1); return nil end
  if key == keys.pageDown then state.page = state.page + 1; return nil end
  if key == keys.enter or key == keys.space then
    if state.selected_id and state.view == "active" then return { type = "alert_ack", id = state.selected_id } end
  end
  if key == keys.backspace and state.search ~= "" then state.search = state.search:sub(1, -2); state.page = 1 end
  return nil
end

local function handle_char(mon, char)
  local state = ensure_state(mon)
  if not char then return nil end
  if char == "/" then state.search_active = not state.search_active; return nil end
  if state.search_active then
    state.search = normalize_text(tostring(state.search or "") .. tostring(char))
    state.page = 1
  end
  return nil
end

return { render = render, hit_test = hit_test, handle_key = handle_key, handle_char = handle_char }
