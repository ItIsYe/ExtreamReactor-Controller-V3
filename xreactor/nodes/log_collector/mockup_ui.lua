local M = {}

local function fit(text, width)
  local s = tostring(text or ""):gsub("[\r\n]", " ")
  local w = math.max(1, tonumber(width) or #s)
  if #s <= w then return s end
  if w <= 2 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "~"
end

local function short(value)
  local n = tonumber(value)
  if not n then return "-" end
  local a = math.abs(n)
  if a >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if a >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end

function M.render(ctx)
  local w, h = ctx.begin_frame()
  local stats = ctx.stats
  local color = ctx.color
  local line = ctx.line_ui
  local queue = ctx.queue_segment
  local badge = ctx.badge_ui
  local progress = ctx.progress_ui
  local free_space = ctx.free_space
  local min_free = ctx.min_free_bytes

  local status = "OK"
  if stats.last_error then status = "WARN" end
  if #(stats.modems or {}) == 0 or #(stats.disks or {}) == 0 then status = "ERR" end
  if stats.paused then status = "WARN" end

  local accent = status == "ERR" and color("red", 16384)
    or status == "WARN" and color("yellow", 16)
    or color("lime", 32)

  queue(1, 1, string.rep(" ", w), color("black", 32768), accent)
  line(2, 2, "[L] LOG COLLECTOR", color("white", 1), color("black", 32768))
  local page = "LIVE"
  queue(math.max(2, w - #page), 2, page, color("lightGray", 256), color("black", 32768))

  local bx = 2
  bx = bx + badge(bx, 3, stats.paused and "PAUSED" or status, status) + 1
  bx = bx + badge(bx, 3, "CH " .. tostring(ctx.channel), "INFO") + 1
  if bx < w - 12 then bx = bx + badge(bx, 3, "DISKS " .. tostring(#(stats.disks or {})), #(stats.disks or {}) > 0 and "OK" or "ERR") + 1 end

  local banner = stats.paused and "DISK WRITES PAUSIERT"
    or stats.last_error and "LOG SYSTEM WARNING"
    or (#(stats.disks or {}) == 0 and "KEINE SCHREIBBARE DISK")
    or "LOG SYSTEM NORMAL"
  queue(2, 5, string.rep(" ", math.max(1, w - 3)), color("black", 32768), accent)
  local bt = fit("> " .. banner, math.max(1, w - 5))
  queue(math.max(2, math.floor((w - #bt) / 2)), 5, bt, color("black", 32768), accent)

  line(2, 7, "[N] TRAFFIC", color("cyan", 2048), color("black", 32768))
  line(2, 8, string.rep("-", math.max(1, w - 3)), color("gray", 128), color("black", 32768))

  local cells = {
    { "RECV", stats.received, "OK" },
    { "WRITE", stats.written, "OK" },
    { "DROP", stats.dropped, (stats.dropped or 0) > 0 and "WARN" or "OK" },
    { "DUP", stats.duplicates, "INFO" },
  }
  local cw = math.max(8, math.floor((w - 5) / 4))
  for i, item in ipairs(cells) do
    local x = 2 + (i - 1) * (cw + 1)
    badge(x, 9, item[1], item[3])
    line(x, 10, fit(short(item[2]), cw), item[3] == "WARN" and color("yellow", 16) or color("white", 1), color("black", 32768))
  end

  line(2, 12, "[S] DISK RING", color("cyan", 2048), color("black", 32768))
  line(2, 13, string.rep("-", math.max(1, w - 3)), color("gray", 128), color("black", 32768))
  local dx = 2
  for _, disk in ipairs(stats.disks or {}) do
    local free = free_space(disk.mount)
    local disk_status = free < min_free and "WARN" or "OK"
    local label = (disk.id == stats.last_write_index and "*" or "") .. tostring(disk.id) .. ":" .. tostring(disk.role):sub(1, 3)
    dx = dx + badge(dx, 14, label, disk_status)
    if dx > w - 5 then break end
  end

  local current = stats.disks and (stats.disks[stats.last_write_index or 1] or stats.disks[1]) or nil
  if current then
    local free = free_space(current.mount)
    local free_ok = free > min_free * 4
    line(2, 16, "[S] CURRENT DISK", color("cyan", 2048), color("black", 32768))
    line(2, 17, string.format("%s | %s", tostring(current.mount), tostring(current.role)), color("white", 1), color("black", 32768))
    line(2, 18, "PATH " .. fit(stats.last_write_path or "-", math.max(1, w - 8)), color("lightGray", 256), color("black", 32768))
    line(2, 19, "FREE " .. short(free) .. " B", free_ok and color("lime", 32) or color("yellow", 16), color("black", 32768))
    progress(2, 20, math.max(8, w - 3), free == math.huge and 1 or math.min(1, free / math.max(min_free * 8, 1)), free_ok)
  else
    line(2, 16, "[!] KEINE SCHREIBBARE DISK", color("red", 16384), color("black", 32768))
    line(2, 17, "Logs werden verworfen bis eine Disk verfuegbar ist.", color("yellow", 16), color("black", 32768))
  end

  if h >= 23 then
    line(2, 22, "[N] SYSTEM", color("cyan", 2048), color("black", 32768))
    line(2, 23, string.format("ACK %s | WIPED %s | PAUSE DROP %s", short(stats.ack_sent), short(stats.wiped), short(stats.paused_dropped)), color("lightGray", 256), color("black", 32768))
  end
  if h >= 25 then
    line(2, 25, "LAST " .. fit(tostring(stats.last_role) .. "/" .. tostring(stats.last_node) .. " " .. tostring(stats.last_level), math.max(1, w - 7)), color("white", 1), color("black", 32768))
  end
  if h >= 27 then
    if stats.last_error then
      line(2, 27, "[!] " .. fit(stats.last_error, math.max(1, w - 6)), color("red", 16384), color("black", 32768))
    elseif stats.paused then
      line(2, 27, "[!] PAUSED: incoming logs werden verworfen.", color("yellow", 16), color("black", 32768))
    else
      line(2, 27, "[*] STATUS OK", color("lime", 32), color("black", 32768))
    end
  end

  if h >= 30 and #(ctx.live_diag or {}) > 0 then
    line(2, 29, "[N] DIAGNOSTICS", color("cyan", 2048), color("black", 32768))
    local rows = math.min(#ctx.live_diag, h - 30)
    for i = 1, rows do
      local entry = ctx.live_diag[#ctx.live_diag - rows + i]
      line(2, 29 + i, fit(entry, math.max(1, w - 3)), color("lightGray", 256), color("black", 32768))
    end
  end

  ctx.draw_pause_button(2, h - 2)
  queue(1, h, string.rep(" ", w), color("white", 1), color("gray", 128))
  line(2, h, "LOG COLLECTOR", color("white", 1), color("gray", 128))
  local right = stats.paused and "PAUSED" or status
  queue(math.max(2, w - #right), h, right, color("white", 1), color("gray", 128))

  ctx.flush_ui()
  stats.last_draw_s = ctx.now_s()
end

return M
