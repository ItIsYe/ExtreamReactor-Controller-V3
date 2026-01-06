local colorset = require("shared.colors")

local function draw(monitors, alarms)
  for _, mon in ipairs(monitors) do
    mon.setBackgroundColor(colorset.get("background"))
    mon.setTextColor(colorset.get("accent"))
    mon.clear()
    mon.setCursorPos(1,1)
    mon.write("[ALARM WALL]")
    local row = 3
    for i = #alarms, 1, -1 do
      local alarm = alarms[i]
      if row > mon.getSize() then break end
      mon.setCursorPos(1, row)
      local color = colorset.get("warning")
      if alarm.severity == "EMERGENCY" then color = colorset.get("emergency") end
      mon.setTextColor(color)
      mon.write(string.format("%s %s: %s", alarm.timestamp, alarm.sender_id, alarm.message))
      row = row + 1
    end
  end
end

return { draw = draw }
