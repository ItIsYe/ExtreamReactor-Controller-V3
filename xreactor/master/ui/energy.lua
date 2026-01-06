local colorset = require("shared.colors")

local function draw(monitors, data)
  for _, mon in ipairs(monitors) do
    mon.setBackgroundColor(colorset.get("background"))
    mon.setTextColor(colorset.get("accent"))
    mon.clear()
    mon.setCursorPos(1,1)
    mon.write("[ENERGY DASHBOARD]")
    mon.setTextColor(colorset.get("text"))
    mon.setCursorPos(1,3)
    mon.write(string.format("Total: %s / %s RF", data.stored or 0, data.capacity or 0))
    mon.setCursorPos(1,4)
    mon.write(string.format("Rate: +%s / -%s RF/t", data.input or 0, data.output or 0))
    local row = 6
    for _, store in ipairs(data.stores) do
      mon.setCursorPos(1, row)
      mon.write(store.id)
      mon.setCursorPos(18, row)
      mon.write(string.format("%s/%s", store.stored, store.capacity))
      row = row + 1
    end
  end
end

return { draw = draw }
