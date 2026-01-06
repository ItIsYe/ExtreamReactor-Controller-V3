local colorset = require("shared.colors")

local function draw(monitors, data)
  for _, mon in ipairs(monitors) do
    mon.setBackgroundColor(colorset.get("background"))
    mon.setTextColor(colorset.get("accent"))
    mon.clear()
    mon.setCursorPos(1,1)
    mon.write("[FUEL & WATER]")
    mon.setTextColor(colorset.get("text"))
    mon.setCursorPos(1,3)
    mon.write(string.format("Fuel Reserve: %s mB (min %s)", data.fuel.reserve or 0, data.fuel.minimum or 0))
    mon.setCursorPos(1,4)
    mon.write(string.format("Water Loop: %s mB", data.water.total or 0))
    local row = 6
    mon.setCursorPos(1, row)
    mon.write("Fuel Sources:")
    row = row + 1
    for _, src in ipairs(data.fuel.sources) do
      mon.setCursorPos(2, row)
      mon.write(src.id .. " -> " .. src.amount .. " mB")
      row = row + 1
    end
    row = row + 1
    mon.setCursorPos(1, row)
    mon.write("Water Buffers:")
    row = row + 1
    for _, buf in ipairs(data.water.buffers) do
      mon.setCursorPos(2, row)
      mon.write(buf.id .. " -> " .. buf.level .. " mB")
      row = row + 1
    end
  end
end

return { draw = draw }
