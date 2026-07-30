local mux = require("core.mockup_ui")

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

local function render(mon, model)
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
  mux.clear(mon)
  mux.header(mon, { title = "AUX MAINTENANCE", node_id = "MASTER AUX", page = "SERVICE", status = page_status, icon = "config" })
  local w, h = mon.getSize()
  mux.status_dot(mon, 2, 3, string.format("NODES %d", #nodes), "OK")
  if w >= 38 then mux.status_dot(mon, math.floor(w * 0.38), 3, string.format("MAINT %d", maintenance_count), maintenance_count > 0 and "LIMITED" or "OK") end
  if w >= 58 then mux.status_dot(mon, math.floor(w * 0.70), 3, string.format("WARN %d", warning_count), warning_count > 0 and "WARNING" or "OK") end

  mux.section(mon, 2, 5, w - 3, "NODE MAINTENANCE", maintenance_count > 0 and "LIMITED" or "OK", "config")
  local right_w = w >= 66 and math.max(20, math.floor(w * 0.30)) or 0
  local list_w = right_w > 0 and (w - right_w - 4) or (w - 3)
  local y = 7
  mux.table_header(mon, 2, y, list_w, {
    { label = "NODE", width = math.max(10, math.floor(list_w * 0.42)) },
    { label = "MODE", width = math.max(10, math.floor(list_w * 0.30)) },
    { label = "STATUS", width = math.max(8, math.floor(list_w * 0.28)) },
  })
  y = y + 2

  local max_rows = math.max(1, h - y - 2)
  local shown = 0
  for _, node in ipairs(nodes) do
    if shown >= max_rows then break end
    local key = status_key(node)
    local mode = node.maintenance_mode and "MAINTENANCE" or "AUTO"
    local online = (node.offline or node.stale) and "OFFLINE" or (node.maintenance_mode and "MAINT" or "ONLINE")
    local id = tostring(node.id or "?")
    local line = string.format("%-16s %-14s %-10s", mux.fit(id, 16), mode, online)
    mux.data_row(mon, 2, y, list_w, { label = line, value = "", status = key, icon = node.maintenance_mode and "config" or "ok" })
    hits[#hits + 1] = { type = "maintenance_toggle", node_id = node.id, x1 = 2, x2 = 1 + list_w, y1 = y, y2 = y }
    y = y + 1
    shown = shown + 1
  end

  if #nodes == 0 then mux.warning_box(mon, 2, y, list_w, { "Keine Nodes bekannt", "Heartbeat / Registry pruefen" }, "WARNING") end

  if right_w > 0 then
    local rx = w - right_w + 1
    mux.card(mon, rx, 5, right_w - 1, math.min(12, h - 6), { title = "MAINTENANCE EFFECT", status = "LIMITED", icon = "config" })
    mux.data_row(mon, rx + 2, 7, right_w - 5, { label = "Keine Last", value = "RT", status = "WARNING", icon = "reactor" })
    mux.data_row(mon, rx + 2, 8, right_w - 5, { label = "Reserven", value = "AUTO", status = "LIMITED", icon = "energy" })
    mux.data_row(mon, rx + 2, 9, right_w - 5, { label = "Online bleibt", value = "JA", status = "OK", icon = "network" })
    mux.data_row(mon, rx + 2, 10, right_w - 5, { label = "Offline", value = "NEIN", status = "text", icon = "warning" })
    local selected
    for _, node in ipairs(nodes) do if node.maintenance_mode then selected = node; break end end
    if selected then
      mux.section(mon, rx + 2, 12, right_w - 5, "AKTIV", "LIMITED", "config")
      mux.data_row(mon, rx + 2, 14, right_w - 5, { label = tostring(selected.id or "?"), value = "NO LOAD", status = "LIMITED" })
    end
  end

  mux.footer_nav(mon, h, w, { left = "ZEILE = TOGGLE", center = "MAINTENANCE", right = "AUTO / MAINT" })
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
