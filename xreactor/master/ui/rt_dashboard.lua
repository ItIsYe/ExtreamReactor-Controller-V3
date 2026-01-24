local ui = require("core.ui")
local colorset = require("shared.colors")
local widgets = require("master.ui.widgets")
local cache = {}

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = mon.getSize()
  widgets.card(mon, 1, 1, w, h, "RT DASHBOARD", "OK")
  ui.text(mon, 2, 2, "Ramp: " .. tostring(model.ramp_profile or "NORMAL"), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 3, "Sequence: " .. tostring(model.sequence_state or "IDLE"), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 4, "Control: " .. tostring(model.control_mode or "AUTO"), colorset.get("text"), colorset.get("background"))
  local row = 6
  if model.alerts and #model.alerts > 0 then
    ui.text(mon, 2, row, "Alerts", colorset.get("WARNING"), colorset.get("background"))
    row = row + 1
    for i = 1, math.min(2, #model.alerts) do
      ui.text(mon, 4, row, model.alerts[i], colorset.get("WARNING"), colorset.get("background"))
      row = row + 1
    end
  end
  for _, rt in ipairs(model.rt_nodes or {}) do
    if row >= h - 3 then break end
    local status = rt.status or "OFFLINE"
    ui.panel(mon, 2, row, w - 3, 5, rt.id .. " (" .. tostring(rt.state or "OFF") .. ")", status)
    ui.bigNumber(mon, 4, row + 1, "Target", string.format("%.0f", rt.target or rt.output or 0), "RF/t", status)
    ui.bigNumber(mon, 22, row + 1, "Actual", string.format("%.0f", rt.actual_output or rt.output or 0), "RF/t", status)
    local modules = rt.modules or {}
    local module_names = {}
    for name in pairs(modules) do
      table.insert(module_names, name)
    end
    table.sort(module_names)
    local mrow = row + 3
    local col = 4
    for _, name in ipairs(module_names) do
      local mod = modules[name]
      local active = model.active_step and model.active_step.node_id == rt.id and model.active_step.module_id == name
      local bar_status = active and "LIMITED" or status
      ui.text(mon, col, mrow, name .. ":" .. tostring(mod.state or "OFF"), colorset.get("text"), colorset.get("background"))
      ui.progress(mon, col + 12, mrow, 12, mod.progress or 0, bar_status)
      mrow = mrow + 1
      if mrow >= row + 4 then break end
    end
    row = row + 6
  end
end

return { render = render }
