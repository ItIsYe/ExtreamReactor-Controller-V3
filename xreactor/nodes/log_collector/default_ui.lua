-- LOG Collector default renderer.
-- Same M.render(ctx) interface as nodes/log_collector/mockup_ui.lua. This is
-- the original built-in draw() layout from main.lua, extracted verbatim into
-- its own module so main.lua can call it through the normal renderer
-- interface instead of embedding the layout inline.

local M = {}

local function fit(text, width)
  local s = tostring(text or ""):gsub("[\r\n]", " ")
  local w = math.max(1, tonumber(width) or #s)
  if #s <= w then return s end
  if w <= 1 then return s:sub(1, 1) end
  return s:sub(1, w - 1) .. "~"
end

function M.render(ctx)
  local stats = ctx.stats
  local color = ctx.color
  local line_ui = ctx.line_ui
  local badge_ui = ctx.badge_ui
  local progress_ui = ctx.progress_ui
  local free_space = ctx.free_space
  local min_free_bytes = ctx.min_free_bytes
  local disks_per_role = ctx.disks_per_role

  local w, h = ctx.begin_frame()

  local title = " XReactor LOG Collector v2 "
  line_ui(1, 1, title .. string.rep(" ", math.max(0, w - #title)),
    color("black", 32768), color("gray", 128))

  local status = "OK"
  if stats.last_error then status = "WARN" end
  if #stats.modems == 0 or #stats.disks == 0 then status = "ERR" end
  if stats.paused then status = "WARN" end

  local bx = 2
  bx = bx + badge_ui(bx, 2, stats.paused and "PAUSED" or status, status) + 1
  bx = bx + badge_ui(bx, 2, "CH " .. tostring(ctx.channel), "INFO") + 1
  bx = bx + badge_ui(bx, 2, stats.modem ~= "" and stats.modem or "NO-MODEM", stats.modem ~= "" and "OK" or "ERR") + 1
  badge_ui(bx, 2, "DISKS " .. tostring(#stats.disks), #stats.disks > 0 and "OK" or "ERR")

  line_ui(2, 3, "Display: " .. tostring(stats.display_name or "term"), color("lightGray", 256))
  ctx.draw_pause_button(2, 4)
  ctx.draw_log_mode_buttons(2, 5)

  line_ui(2, 6, "Disk Ring (" .. disks_per_role .. "x pro Rolle: RT/MASTER/ENERGY/WATER/FUEL/REPROC/LOG)", color("cyan", 2048))
  local dx = 2
  for _, disk in ipairs(stats.disks) do
    local free = free_space(disk.mount)
    local disk_status = free < min_free_bytes and "WARN" or "OK"
    local label = (disk.id == stats.last_write_index and "*" or "") .. tostring(disk.id) .. ":" .. tostring(disk.role):sub(1, 3)
    dx = dx + badge_ui(dx, 7, label, disk_status)
    if dx > w - 4 then break end
  end

  local current = stats.disks[stats.last_write_index or 1] or stats.disks[1]
  if current then
    line_ui(2, 8, string.format("Last disk: %s role=%s", tostring(current.mount), tostring(current.role)), color("lightGray", 256))
    line_ui(2, 9, "Path: " .. fit(stats.last_write_path or "-", w - 8), color("lightGray", 256))
    local free = free_space(current.mount)
    local free_ok = free > min_free_bytes * 4
    line_ui(2, 10, "Free: " .. tostring(free) .. " bytes", free_ok and color("lime", 32) or color("yellow", 16))
    progress_ui(2, 11, math.max(8, w - 3), free == math.huge and 1 or math.min(1, free / math.max(min_free_bytes * 8, 1)), free_ok)
  else
    line_ui(2, 8, "No writable disk. Logs are dropped until a disk is attached.", color("red", 16384))
  end

  line_ui(2, 13, "Traffic", color("cyan", 2048))
  line_ui(2, 14, string.format("Recv %-6s Write %-6s Drop %-6s Dup %-6s", stats.received, stats.written, stats.dropped, stats.duplicates), color("white", 1))
  line_ui(2, 15, string.format("ACK %-7s Wiped %-5s PauseDrop %-5s", stats.ack_sent, stats.wiped, stats.paused_dropped), color("lightGray", 256))
  line_ui(2, 16, string.format("Refresh modem=%s disk=%s", stats.modem_refreshes, stats.disk_refreshes), color("lightGray", 256))
  line_ui(2, 18, "Last: " .. fit(tostring(stats.last_role) .. "/" .. tostring(stats.last_node) .. " " .. tostring(stats.last_level), w - 8), color("white", 1))

  if stats.last_error and h >= 20 then
    line_ui(2, 20, "Error: " .. fit(stats.last_error, w - 9), color("red", 16384))
  elseif stats.paused and h >= 20 then
    line_ui(2, 20, "PAUSED: incoming logs are acknowledged only when written/duplicate; paused logs are dropped.", color("yellow", 16))
  elseif h >= 20 then
    line_ui(2, 20, "Status OK", color("lime", 32))
  end

  local live_diag = ctx.live_diag
  if #live_diag > 0 and h >= 23 then
    line_ui(2, 22, "Diagnostics:", color("cyan", 2048))
    local rows = math.min(#live_diag, h - 22)
    for i = 1, rows do
      local entry = live_diag[#live_diag - rows + i]
      line_ui(2, 22 + i, fit(entry, w - 3), color("lightGray", 256))
    end
  end

  ctx.flush_ui()
  stats.last_draw_s = ctx.now_s()
end

return M
