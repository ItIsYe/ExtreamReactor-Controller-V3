local palette = {
  background = colors.black,
  panel = colors.gray,
  panel_dark = colors.black,
  text = colors.white,
  muted = colors.lightGray,
  disabled = colors.gray,
  title = colors.cyan,
  accent = colors.cyan,
  success = colors.lime,
  OK = colors.green,
  LIMITED = colors.yellow,
  WARNING = colors.orange,
  EMERGENCY = colors.red,
  OFFLINE = colors.gray,
  STANDBY = colors.gray,
  SHUTDOWN = colors.gray,
  STARTUP = colors.yellow,
  MAINTENANCE = colors.blue,
  MANUAL = colors.blue
}

function palette.get(name)
  return palette[name] or palette.text
end

return palette
