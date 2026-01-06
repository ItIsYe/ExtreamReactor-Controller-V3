local ui = require("core.ui")
local colorset = require("shared.colors")
local cache = {}

local function render(mon, model)
  local key = textutils.serialize(model)
  if cache[mon] == key then return end
  cache[mon] = key
  ui.panel(mon, 1, 1, 60, 18, "RESOURCES", colorset.get("accent"), colorset.get("background"))
  ui.text(mon, 2, 2, "Fuel Reserve: " .. tostring(model.fuel.reserve or 0), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 3, "Minimum: " .. tostring(model.fuel.minimum or 0), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 4, "Water Total: " .. tostring(model.water.total or 0), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 5, "Water State: " .. tostring(model.water.state or "UNKNOWN"), colorset.get("text"), colorset.get("background"))
  local row = 0
  for name, buf in pairs(model.water.buffers or {}) do
    ui.text(mon, 2, 7 + row, name .. ": " .. tostring(buf.level or 0), colorset.get("text"), colorset.get("background"))
    row = row + 1
  end
end

return { render = render }
