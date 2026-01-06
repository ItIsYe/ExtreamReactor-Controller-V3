local colorset = require("shared.colors")
local constants = require("shared.constants")

local function draw(monitors, data)
  for _, mon in ipairs(monitors) do
    mon.setBackgroundColor(colorset.get("background"))
    mon.setTextColor(colorset.get("accent"))
    mon.clear()
    mon.setCursorPos(1,1)
    mon.write("[RT BLOCK / STARTUP SEQUENCER]")
    mon.setTextColor(colorset.get("text"))
    mon.setCursorPos(1,3)
    mon.write("Ramp: " .. data.ramp_profile)
    mon.setCursorPos(1,4)
    mon.write("Sequence: " .. data.sequence_state)
    local row = 6
    for _, rt in ipairs(data.rt_nodes) do
      mon.setCursorPos(1, row)
      mon.write(rt.id)
      mon.setCursorPos(15, row)
      mon.setTextColor(colorset.get("text"))
      mon.write(rt.state)
      mon.setCursorPos(30, row)
      mon.write("Output: " .. tostring(rt.output or 0) .. " RF/t")
      mon.setCursorPos(1, row+1)
      mon.setTextColor(colorset.get("accent"))
      mon.write("Turbine: " .. tostring(rt.turbine_rpm or 0) .. " RPM | Steam: " .. tostring(rt.steam or 0))
      row = row + 2
    end
  end
end

return { draw = draw }
