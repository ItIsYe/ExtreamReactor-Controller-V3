local palette = {
  background = colors.black,
  text = colors.white,
  OK = colors.green,
  LIMITED = colors.yellow,
  WARNING = colors.orange,
  EMERGENCY = colors.red,
  OFFLINE = colors.gray,
  MANUAL = colors.blue,
  accent = colors.cyan
}

function palette.get(name)
  return palette[name] or palette.text
end

return palette
