local colorset = require("shared.colors")
local constants = require("shared.constants")

local function draw_banner(mon, title)
  mon.setBackgroundColor(colorset.get("background"))
  mon.setTextColor(colorset.get("accent"))
  mon.clear()
  mon.setCursorPos(1,1)
  mon.write("[SYSTEM OVERVIEW] " .. title)
end

local function render_node(mon, index, node)
  local status_color = colorset.get("offline")
  if node.status == constants.status_levels.OK then status_color = colorset.get("ok")
  elseif node.status == constants.status_levels.LIMITED then status_color = colorset.get("limited")
  elseif node.status == constants.status_levels.WARNING then status_color = colorset.get("warning")
  elseif node.status == constants.status_levels.EMERGENCY then status_color = colorset.get("emergency")
  elseif node.status == constants.status_levels.MANUAL then status_color = colorset.get("manual") end

  mon.setCursorPos(1, index + 1)
  mon.setTextColor(colorset.get("text"))
  mon.write(string.format("%s (%s)", node.id, node.role))
  mon.setCursorPos(25, index + 1)
  mon.setTextColor(status_color)
  mon.write(node.status)
end

local function draw(monitors, snapshot)
  for _, mon in ipairs(monitors) do
    draw_banner(mon, snapshot.power_target and ("Target: " .. tostring(snapshot.power_target) .. " RF/t") or "")
    local i = 1
    for _, node in ipairs(snapshot.nodes) do
      render_node(mon, i, node)
      i = i + 1
    end
  end
end

return { draw = draw }
