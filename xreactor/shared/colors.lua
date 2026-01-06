local term = term or {}

local palette = {
  background = colors.black,
  text = colors.white,
  ok = colors.green,
  limited = colors.yellow,
  warning = colors.orange,
  emergency = colors.red,
  offline = colors.gray,
  manual = colors.blue,
  accent = colors.cyan
}

function palette.get(name)
  return palette[name] or palette.text
end

return palette
