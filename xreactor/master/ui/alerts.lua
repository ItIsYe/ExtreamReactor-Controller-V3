local ui = require("core.ui")
local colorset = require("shared.colors")

local cache = {}
local state_cache = setmetatable({}, { __mode = "k" })

local severity_status = {
  INFO = "OK",
  WARN = "WARNING",
  CRITICAL = "EMERGENCY"
}

local function ensure_state(mon)
  local state = state_cache[mon]
  if not state then
    state = { page = 1, selected_id = nil, list_bounds = {}, buttons = {} }
    state_cache[mon] = state
  end
  return state
end

local function build_rows(active, start_idx, end_idx, selected_id)
  local rows = {}
  for idx = start_idx, end_idx do
    local alert = active[idx]
    local prefix = alert and (alert.id == selected_id and ">" or " ") or " "
    local severity = alert and alert.severity or "INFO"
    local source = alert and alert.source or {}
    local source_label = source.device_id or source.node_id or "SYSTEM"
    local text = alert and string.format("%s%s %s", prefix, severity:sub(1, 1), tostring(alert.title or source_label)) or ""
    table.insert(rows, { text = text, status = severity_status[severity] or "OK", id = alert and alert.id })
  end
  return rows
end

local function render(mon, model)
  local state = ensure_state(mon)
  local snapshot = textutils.serialize({ model = model, page = state.page, selected = state.selected_id })
  if cache[mon] == snapshot then
    return
  end
  cache[mon] = snapshot
  local w, h = mon.getSize()
  ui.panel(mon, 1, 1, w, h, "ALERTS", "OK")

  local counts = model.counts or {}
  local crit = counts.CRITICAL or 0
  local warn = counts.WARN or 0
  local info = counts.INFO or 0
  ui.text(mon, 2, 1, "ALERTS", colorset.get("text"), colorset.get("background"))
  ui.badge(mon, 10, 1, "CRIT " .. tostring(crit), crit > 0 and "EMERGENCY" or "OFFLINE")
  ui.badge(mon, 20, 1, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OFFLINE")
  ui.badge(mon, 30, 1, "INFO " .. tostring(info), info > 0 and "OK" or "OFFLINE")

  ui.text(mon, 2, 2, model.summary or "", colorset.get("text"), colorset.get("background"))

  local active = model.active or {}
  local list_top = 4
  local list_height = math.max(3, h - 8)
  local total_pages = math.max(1, math.ceil(#active / list_height))
  if state.page > total_pages then
    state.page = total_pages
  end
  local start_idx = (state.page - 1) * list_height + 1
  local end_idx = math.min(#active, state.page * list_height)

  if not state.selected_id and active[1] then
    state.selected_id = active[1].id
  end

  local rows = build_rows(active, start_idx, end_idx, state.selected_id)
  ui.list(mon, 2, list_top, w - 3, rows, { max_rows = list_height })
  state.list_bounds = {
    x1 = 2,
    x2 = w - 2,
    y1 = list_top,
    y2 = list_top + list_height - 1,
    start_index = start_idx,
    end_index = end_idx,
    rows = rows
  }

  local page_text = string.format("< Alerts %d/%d >", state.page, total_pages)
  local page_y = list_top + list_height
  ui.text(mon, 2, page_y, page_text, colorset.get("text"), colorset.get("background"))
  state.buttons.prev = { x1 = 2, x2 = 3, y = page_y }
  state.buttons.next = { x1 = 2 + #page_text - 1, x2 = 2 + #page_text, y = page_y }

  local selected = nil
  for _, alert in ipairs(active) do
    if alert.id == state.selected_id then
      selected = alert
      break
    end
  end
  local detail_y = page_y + 1
  if detail_y <= h - 1 then
    if selected then
      ui.text(mon, 2, detail_y, string.format("%s (%s)", selected.title or "Alert", selected.severity), colorset.get("text"), colorset.get("background"))
      detail_y = detail_y + 1
      if detail_y <= h - 1 then
        ui.text(mon, 2, detail_y, selected.message or "", colorset.get("text"), colorset.get("background"))
      end
    else
      ui.text(mon, 2, detail_y, "No active alerts", colorset.get("text"), colorset.get("background"))
    end
  end

  local button_y = h
  local ack_status = selected and "WARNING" or "OFFLINE"
  local ack_text = "ACK"
  local ack_all_text = "ACK ALL"
  local ack_render = " " .. ack_text .. " "
  local ack_all_render = " " .. ack_all_text .. " "
  ui.badge(mon, 2, button_y, ack_text, ack_status)
  ui.badge(mon, 8, button_y, ack_all_text, (crit + warn + info) > 0 and "WARNING" or "OFFLINE")
  state.buttons.ack = { x1 = 2, x2 = 2 + #ack_render - 1, y = button_y }
  state.buttons.ack_all = { x1 = 8, x2 = 8 + #ack_all_render - 1, y = button_y }
end

local function hit_test(mon, x, y)
  local state = ensure_state(mon)
  if state.buttons.prev and y == state.buttons.prev.y and x >= state.buttons.prev.x1 and x <= state.buttons.prev.x2 then
    state.page = math.max(1, state.page - 1)
    return nil
  end
  if state.buttons.next and y == state.buttons.next.y and x >= state.buttons.next.x1 and x <= state.buttons.next.x2 then
    state.page = state.page + 1
    return nil
  end
  if state.buttons.ack and y == state.buttons.ack.y and x >= state.buttons.ack.x1 and x <= state.buttons.ack.x2 then
    if state.selected_id then
      return { type = "alert_ack", id = state.selected_id }
    end
    return nil
  end
  if state.buttons.ack_all and y == state.buttons.ack_all.y and x >= state.buttons.ack_all.x1 and x <= state.buttons.ack_all.x2 then
    return { type = "alert_ack_all" }
  end
  local bounds = state.list_bounds
  if bounds and y >= bounds.y1 and y <= bounds.y2 and x >= bounds.x1 and x <= bounds.x2 then
    local index = bounds.start_index + (y - bounds.y1)
    local row = bounds.rows and bounds.rows[y - bounds.y1 + 1]
    if row and row.id then
      state.selected_id = row.id
    elseif bounds.rows and bounds.rows[index] and bounds.rows[index].id then
      state.selected_id = bounds.rows[index].id
    end
  end
  return nil
end

return { render = render, hit_test = hit_test }
