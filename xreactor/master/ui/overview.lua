local ui = require("core.ui")
local colorset = require("shared.colors")
local constants = require("shared.constants")

local cache = {}

local function render_node(mon, index, node)
  local status_color = colorset.get(node.status) or colorset.get("OFFLINE")
  ui.text(mon, 1, index, string.format("%s (%s)", node.id, node.role), colorset.text, colorset.background)
  ui.text(mon, 24, index, node.status or "OFFLINE", status_color, colorset.background)
end

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  ui.panel(mon, 1, 1, 50, 18, "SYSTEM OVERVIEW", colorset.get("accent"), colorset.get("background"))
  ui.text(mon, 2, 2, "Power Target: " .. tostring(model.power_target or 0) .. " RF/t", colorset.get("text"), colorset.get("background"))
  local alarm_line = "Alarms: " .. tostring(#(model.alarms or {}))
  ui.text(mon, 2, 3, alarm_line, colorset.get("text"), colorset.get("background"))
  local i = 0
  for _, node in ipairs(model.nodes or {}) do
    render_node(mon, 5 + i, node)
    i = i + 1
  end
end

return { render = render }
