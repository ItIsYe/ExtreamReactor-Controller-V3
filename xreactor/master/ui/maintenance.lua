local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local hit_cache = setmetatable({}, { __mode = "k" })

local function status_key(node)
  if node.offline or node.stale then return "muted" end
  if node.maintenance_mode then return "LIMITED" end
  local s = tostring(node.status or "OK")
  if s == "EMERGENCY" or s == "CRITICAL" then return "EMERGENCY" end
  if s == "WARNING" or s == "DEGRADED" then return "WARNING" end
  if s == "LIMITED" then return "LIMITED" end
  return "OK"
end

local function mode_label(node)
  return node.maintenance_mode and "MAINTENANCE" or "AUTO"
end

local function role_short(role)
  local r = tostring(role or "?")
  r = r:gsub("%-NODE$", "")
  return r
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  model = model or {}
  local nodes = model.nodes or {}
  local hits = {}
  local maintenance_count, warning_count = 0, 0
  for _, node in ipairs(nodes) do
    if node.maintenance_mode then maintenance_count = maintenance_count + 1 end
    local key = status_key(node)
    if key == "WARNING" or key == "EMERGENCY" then warning_count = warning_count + 1 end
  end

  local page_status = warning_count > 0 and "WARNING" or "OK"
  ui.panel(mon, 1, 1, w, h, "AUX MONITOR | MAINTENANCE", page_status)

  ui.badge(mon, 2, 2, string.format("NODES %02d/%02d", #nodes, #nodes), "OK")
  if w >= 34 then ui.badge(mon, math.floor(w * 0.36), 2, string.format("MAINT %02d", maintenance_count), maintenance_count > 0 and "LIMITED" or "OK") end
  if w >= 52 then ui.badge(mon, math.floor(w * 0.68), 2, string.format("WARN %02d", warning_count), warning_count > 0 and "WARNING" or "OK") end

  local table_x = 2
  local right_w = w >= 60 and math.max(18, math.floor(w * 0.30)) or 0
  local table_w = right_w > 0 and (w - right_w - 4) or (w - 3)
  local y = 5

  ui.text(mon, table_x, y, "NODE", colors.get("muted"), colors.get("background"))
  if table_w >= 34 then ui.text(mon, table_x + math.floor(table_w * 0.42), y, "MODE", colors.get("muted"), colors.get("background")) end
  ui.rightText(mon, table_x, y, table_x + table_w - 1, "STATUS", colors.get("muted"), colors.get("background"))
  y = y + 1

  local max_rows = math.max(1, h - y - 2)
  local shown = 0
  for _, node in ipairs(nodes) do
    if shown >= max_rows then break end
    local key = status_key(node)
    local mode = mode_label(node)
    local id = widgets.fit(tostring(node.id or "?"), table_w >= 34 and 15 or 10)
    local online = (node.offline or node.stale) and "OFFLINE" or (node.maintenance_mode and "MAINTENANCE" or "ONLINE")

    if table_w >= 34 then
      ui.text(mon, table_x, y, id, colors.get(key), colors.get("background"))
      ui.text(mon, table_x + math.floor(table_w * 0.42), y, widgets.fit(mode, 12), colors.get(node.maintenance_mode and "LIMITED" or "text"), colors.get("background"))
      ui.rightText(mon, table_x, y, table_x + table_w - 1, online, colors.get(key), colors.get("background"))
    else
      ui.text(mon, table_x, y, widgets.fit(string.format("%-10s %-11s %s", id, mode, online), table_w), colors.get(key), colors.get("background"))
    end

    hits[#hits + 1] = { type = "maintenance_toggle", node_id = node.id, x1 = table_x, x2 = table_x + table_w - 1, y1 = y, y2 = y }
    y = y + 1
    shown = shown + 1
  end

  if #nodes == 0 then
    ui.text(mon, table_x, y, "Keine Nodes bekannt.", colors.get("muted"), colors.get("background"))
  elseif #nodes > shown and y <= h - 2 then
    ui.text(mon, table_x, y, string.format("... +%d weitere Nodes", #nodes - shown), colors.get("muted"), colors.get("background"))
  end

  if right_w > 0 then
    local rx = w - right_w + 1
    ui.text(mon, rx, 5, "MAINTENANCE EFFECT", colors.get("LIMITED"), colors.get("background"))
    ui.text(mon, rx, 7, widgets.fit("Nodes in Wartung", right_w - 1), colors.get("text"), colors.get("background"))
    ui.text(mon, rx, 8, widgets.fit("nehmen keine Last an", right_w - 1), colors.get("WARNING"), colors.get("background"))
    ui.text(mon, rx, 10, widgets.fit("Reserven decken", right_w - 1), colors.get("text"), colors.get("background"))
    ui.text(mon, rx, 11, widgets.fit("aktive Nodes automatisch", right_w - 1), colors.get("LIMITED"), colors.get("background"))
    ui.text(mon, rx, 13, widgets.fit("Wartung != Offline", right_w - 1), colors.get("text"), colors.get("background"))
    if maintenance_count > 0 and h >= 17 then
      local selected = nil
      for _, node in ipairs(nodes) do if node.maintenance_mode then selected = node; break end end
      if selected then
        ui.text(mon, rx, 15, widgets.fit(tostring(selected.id or "?") .. " IN MAINTENANCE", right_w - 1), colors.get("LIMITED"), colors.get("background"))
        ui.text(mon, rx, 16, widgets.fit("NO LOAD ASSIGNED", right_w - 1), colors.get("muted"), colors.get("background"))
      end
    end
  end

  if h >= 3 then
    ui.text(mon, 2, h - 1, widgets.fit("Zeile antippen = AUTO / MAINTENANCE", w - 3), colors.get("muted"), colors.get("background"))
  end
  hit_cache[mon] = hits
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    local y1 = hit.y1 or hit.y
    local y2 = hit.y2 or hit.y
    if y >= y1 and y <= y2 and x >= hit.x1 and x <= hit.x2 then return hit end
  end
end

return { render = render, hit_test = hit_test }
