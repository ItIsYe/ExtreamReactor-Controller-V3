local ui = require("core.ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")

local cache = {}
local button_cache = setmetatable({}, { __mode = "k" })

local function build_profile_buttons(mon, x, y, profiles, active, auto_enabled)
  local buttons = {}
  local cursor = x
  ui.text(mon, cursor, y, "PROFILE:", colorset.get("text"), colorset.get("background"))
  cursor = cursor + 9
  for _, name in ipairs(profiles) do
    local status = (active == name) and "OK" or "OFFLINE"
    local label = name
    ui.badge(mon, cursor, y, label, status)
    table.insert(buttons, { type = "profile", name = name, x1 = cursor, x2 = cursor + #label + 1, y = y })
    cursor = cursor + #label + 3
  end
  local auto_status = auto_enabled and "LIMITED" or "OFFLINE"
  ui.badge(mon, cursor, y, "AUTO", auto_status)
  table.insert(buttons, { type = "auto", name = "AUTO", x1 = cursor, x2 = cursor + 5, y = y })
  return buttons
end

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = mon.getSize()
  ui.panel(mon, 1, 1, w, h, nil, model.system_status)

  ui.text(mon, 2, 1, "SYSTEM", colorset.get("text"), colorset.get("background"))
  ui.badge(mon, 10, 1, model.system_status or "OK", model.system_status or "OK")
  local counts = model.alert_counts or {}
  local crit = counts.CRITICAL or 0
  local warn = counts.WARN or 0
  if crit > 0 or warn > 0 then
    ui.badge(mon, 22, 1, "CRIT " .. tostring(crit), crit > 0 and "EMERGENCY" or "OFFLINE")
    ui.badge(mon, 32, 1, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OFFLINE")
  end

  local tiles = model.tiles or {}
  local tile_y = 3
  local tile_h = 4
  local tile_w = math.floor((w - 2) / math.max(1, #tiles))
  for idx, tile in ipairs(tiles) do
    local x = 2 + (idx - 1) * tile_w
    ui.panel(mon, x, tile_y, tile_w - 1, tile_h, tile.label, tile.status)
    ui.text(mon, x + 1, tile_y + 1, tile.detail or "", colorset.get("text"), colorset.get("background"))
    ui.badge(mon, x + 1, tile_y + 2, tile.status or "OFFLINE", tile.status or "OFFLINE")
  end

  local node_y = tile_y + tile_h + 1
  local profile_y = h - 6
  local node_rows = math.max(0, profile_y - node_y - 1)
  if node_rows > 0 then
    ui.text(mon, 2, node_y, "Nodes", colorset.get("text"), colorset.get("background"))
    local rows = {}
    for _, node in ipairs(model.nodes or {}) do
      local mode = "-"
      if node.role == constants.roles.RT_NODE then
        mode = (node.mode == "MASTER" and "MANAGED") or (node.mode or "AUTONOM")
      end
      local last_seen = node.last_seen or "--:--"
      if node.last_seen_age then
        last_seen = last_seen .. (" (%ds)"):format(node.last_seen_age)
      end
      local details = {}
      if node.reasons and node.reasons ~= "" then
        table.insert(details, node.reasons)
      end
      if node.bindings and node.bindings ~= "" then
        table.insert(details, node.bindings)
      end
      local suffix = #details > 0 and (" " .. table.concat(details, " ")) or ""
      local label = string.format("%s %s %s %s%s", node.id or "NODE", node.status or "OFFLINE", mode, last_seen, suffix)
      table.insert(rows, { text = label, status = node.status })
    end
    ui.list(mon, 2, node_y + 1, w - 3, rows, { max_rows = node_rows })
  end

  button_cache[mon] = build_profile_buttons(mon, 2, profile_y, model.profile_list or {}, model.active_profile, model.auto_profile)

  local power_y = profile_y + 1
  ui.text(mon, 2, power_y, "Power Target", colorset.get("text"), colorset.get("background"))
  ui.bigNumber(mon, 16, power_y, "", string.format("%.0f", model.power_target or 0), "RF/t", model.system_status)

  local alert_rows = {}
  local top_alerts = model.alert_top or {}
  for i = 1, 3 do
    local alert = top_alerts[i]
    if alert then
      table.insert(alert_rows, { text = alert.title or alert.message or "--", status = alert.severity == "CRITICAL" and "EMERGENCY" or "WARNING" })
    else
      table.insert(alert_rows, { text = "--", status = "OFFLINE" })
    end
  end
  ui.text(mon, 2, h - 3, "Top Alerts", colorset.get("text"), colorset.get("background"))
  ui.list(mon, 2, h - 2, w - 2, alert_rows, { max_rows = 3 })
end

local function hit_test(mon, x, y)
  local buttons = button_cache[mon] or {}
  for _, btn in ipairs(buttons) do
    if y == btn.y and x >= btn.x1 and x <= btn.x2 then
      return btn
    end
  end
  return nil
end

return { render = render, hit_test = hit_test }
