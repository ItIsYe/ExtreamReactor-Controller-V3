local M = {}

function M.draw_status_page(target, ui, colors, title, lines)
  local w, h = target.getSize()
  target.setBackgroundColor(colors.bg)
  target.clear()
  ui.panel(target, 1, 1, w, h, colors.panel)
  ui.write_center(target, 1, title, colors.title, colors.panel)
  local y = 3
  for _, line in ipairs(lines or {}) do
    if y >= h then break end
    ui.write_at(target, 2, y, tostring(line), colors.text, colors.panel)
    y = y + 1
  end
end

return M
