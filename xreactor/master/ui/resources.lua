local ui = require("core.ui")
local colorset = require("shared.colors")
local cache = {}

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = mon.getSize()
  ui.panel(mon, 1, 1, w, h, "RESOURCES", "OK")

  local fuel_total = model.fuel.total or 0
  local fuel_status = fuel_total <= (model.fuel.minimum or 0) and "WARNING" or "OK"
  ui.bigNumber(mon, 2, 2, "Fuel Total", string.format("%.0f", fuel_total), "mB", fuel_status)
  ui.text(mon, 2, 4, string.format("Reserve %.0f", model.fuel.reserve or 0), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 22, 4, string.format("Min %.0f", model.fuel.minimum or 0), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 5, "Mix", colorset.get("text"), colorset.get("background"))
  ui.badge(mon, 8, 5, model.fuel.mix_status or "SINGLE", fuel_status)
  if fuel_total <= (model.fuel.reserve or 0) then
    ui.badge(mon, 18, 5, "RESERVE", "WARNING")
  end

  local water_total = model.water.total or 0
  local water_target = model.water.target or water_total
  local water_ratio = water_target > 0 and water_total / water_target or 0
  local water_status = "OK"
  if water_ratio < 0.7 then
    water_status = "EMERGENCY"
  elseif water_ratio < 0.9 then
    water_status = "LIMITED"
  end
  ui.text(mon, 2, 7, "Water Loop", colorset.get("text"), colorset.get("background"))
  ui.badge(mon, 14, 7, water_status, water_status)
  ui.text(mon, 2, 8, string.format("Target %.0f  Actual %.0f", water_target, water_total), colorset.get("text"), colorset.get("background"))
  ui.progress(mon, 2, 9, w - 4, math.min(1, water_ratio), water_status)

  local rows = {}
  local buffer_names = {}
  for name in pairs(model.water.buffers or {}) do
    table.insert(buffer_names, name)
  end
  table.sort(buffer_names)
  for _, name in ipairs(buffer_names) do
    local buf = model.water.buffers[name]
    table.insert(rows, { text = string.format("%s %.0f", name, buf.level or 0), status = water_status })
  end
  ui.list(mon, 2, 11, w - 2, rows, { max_rows = h - 12 })
end

return { render = render }
