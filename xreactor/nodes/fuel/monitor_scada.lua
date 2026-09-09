-- nodes/fuel/monitor_scada.lua
-- Configurable FUEL monitor scale with one logical SCADA geometry.
--
-- ui_scale = 1.0:
--   8x6 Advanced Monitor => 82x40; renderer uses the monitor directly.
--
-- ui_scale = 0.5:
--   8x6 Advanced Monitor => 164x81; the SCADA fills the monitor instead of
--   being placed in a centered 82x40 viewport. Existing page code continues
--   to render against its proven logical 82x40 geometry through a fullscreen
--   scaling terminal: widget backgrounds/borders occupy 2x2 physical cells,
--   while text remains native 0.5 text and therefore appears smaller/cleaner.
--
-- The logical UI and all existing page touch rectangles stay 82x40. Physical
-- monitor_touch coordinates are mapped 2:1 back to that logical geometry.
-- Row 81 is a one-cell CC:Tweaked rounding remainder and is deliberately not
-- touchable; rendered content occupies rows 1..80 and the monitor background
-- is cleared across all 81 rows.
--
-- SCADA boundary: presentation only. No logistics, routing, valve, delivery,
-- safety, persistence or network-command logic lives here.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local TARGET_W = 82
local TARGET_H = 40
local TARGET_SCALE = 1.0
local COMPACT_SCALE = 0.5

local EXPECTED_W_1 = 82
local EXPECTED_H_1 = 40
local EXPECTED_W_HALF = 164
local EXPECTED_H_HALF = 81
local HALF_RENDER_H = TARGET_H * 2 -- 80; row 81 is the monitor rounding remainder

local bindings = setmetatable({}, { __mode = "k" })

local BLIT_BY_COLOR = {
  [1] = "0", [2] = "1", [4] = "2", [8] = "3",
  [16] = "4", [32] = "5", [64] = "6", [128] = "7",
  [256] = "8", [512] = "9", [1024] = "a", [2048] = "b",
  [4096] = "c", [8192] = "d", [16384] = "e", [32768] = "f",
}

local function normalize_scale(value)
  local n = tonumber(value)
  if n == COMPACT_SCALE then return COMPACT_SCALE end
  return TARGET_SCALE
end

local function expected_full_size(scale)
  if scale == COMPACT_SCALE then return EXPECTED_W_HALF, EXPECTED_H_HALF end
  return EXPECTED_W_1, EXPECTED_H_1
end

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return false end
  return pcall(obj[method], ...)
end

local function read_call(obj, method, fallback)
  if not obj or type(obj[method]) ~= "function" then return fallback end
  local ok, value = pcall(obj[method])
  if ok and value ~= nil then return value end
  return fallback
end

local function color_to_blit(value)
  if type(colors) == "table" and type(colors.toBlit) == "function" then
    local ok, result = pcall(colors.toBlit, value)
    if ok and type(result) == "string" and #result == 1 then return result end
  end
  return BLIT_BY_COLOR[tonumber(value)] or "0"
end

local function apply_scale(mon, scale)
  if not mon then return false end
  local current = nil
  if type(mon.getTextScale) == "function" then
    local ok, value = pcall(mon.getTextScale)
    if ok then current = tonumber(value) end
  end
  if current == scale then return true end
  if type(mon.setTextScale) ~= "function" then return scale == TARGET_SCALE end
  return pcall(mon.setTextScale, scale) == true
end

local function table_of(n, value)
  local out = {}
  for i = 1, n do out[i] = value end
  return out
end

local function put(chars, colors_out, pos, text, color_source, source_offset)
  source_offset = source_offset or 0
  for i = 1, #text do
    local p = pos + i - 1
    if p >= 1 and p <= #chars then
      chars[p] = text:sub(i, i)
      if color_source then
        local src = source_offset + i
        colors_out[p] = color_source:sub(src, src)
      end
    end
  end
end

-- Convert one logical blit segment to two physical rows. Background cells are
-- doubled horizontally and vertically. Normal text phrases stay consecutive
-- physical characters (native 0.5 text), while structural card/section lines
-- expand to the full doubled widget width.
local function expand_blit_segment(text, fg, bg)
  text = tostring(text or "")
  fg = tostring(fg or "")
  bg = tostring(bg or "")
  local n = #text
  if #fg ~= n or #bg ~= n then error("Arguments must be the same length", 3) end
  local pw = n * 2
  local top_text = table_of(pw, " ")
  local bottom_text = table_of(pw, " ")
  local top_fg = table_of(pw, "0")
  local bottom_fg = table_of(pw, "0")
  local top_bg = table_of(pw, "f")
  local bottom_bg = table_of(pw, "f")
  local consumed = {}

  -- Every logical background cell owns two physical columns on both rows.
  for i = 1, n do
    local p = (i - 1) * 2 + 1
    local f, b = fg:sub(i, i), bg:sub(i, i)
    top_fg[p], top_fg[p + 1] = f, f
    bottom_fg[p], bottom_fg[p + 1] = f, f
    top_bg[p], top_bg[p + 1] = b, b
    bottom_bg[p], bottom_bg[p + 1] = b, b
  end

  -- Card/top/bottom borders: +-----+ becomes a truly full-width line.
  local scan = 1
  while scan <= n do
    local s, e = text:find("%+%-+%+", scan)
    if not s then break end
    local ps, pe = (s - 1) * 2 + 1, e * 2
    top_text[ps], top_text[pe] = "+", "+"
    local line_fg = fg:sub(s, s)
    top_fg[ps], top_fg[pe] = line_fg, line_fg
    for p = ps + 1, pe - 1 do
      top_text[p], top_fg[p] = "-", line_fg
    end
    for i = s, e do consumed[i] = true end
    scan = e + 1
  end

  -- Standalone section/table rules.
  scan = 1
  while scan <= n do
    local s, e = text:find("%-+", scan)
    if not s then break end
    if e - s + 1 >= 3 then
      local blocked = false
      for i = s, e do if consumed[i] then blocked = true; break end end
      if not blocked then
        local ps, pe = (s - 1) * 2 + 1, e * 2
        local line_fg = fg:sub(s, s)
        for p = ps, pe do top_text[p], top_fg[p] = "-", line_fg end
        for i = s, e do consumed[i] = true end
      end
    end
    scan = e + 1
  end

  -- Vertical card borders continue through both physical rows.
  for i = 1, n do
    if not consumed[i] and text:sub(i, i) == "|" then
      local p = (i - 1) * 2 + 1
      local f = fg:sub(i, i)
      top_text[p], bottom_text[p] = "|", "|"
      top_fg[p], bottom_fg[p] = f, f
      consumed[i] = true
    end
  end

  -- Compact normal text into native 0.5 cells. Two or more source spaces
  -- split fields; a single internal space remains a normal word separator.
  local i = 1
  while i <= n do
    while i <= n and (consumed[i] or text:sub(i, i) == " ") do i = i + 1 end
    if i > n then break end
    local start = i
    local last_non_space = i
    local gap = 0
    local j = i
    while j <= n and not consumed[j] do
      local ch = text:sub(j, j)
      if ch == " " then
        gap = gap + 1
        if gap >= 2 then break end
      else
        gap = 0
        last_non_space = j
      end
      j = j + 1
    end
    local finish = last_non_space
    local phrase = text:sub(start, finish)

    -- If this phrase sits inside a bounded non-default background region
    -- (button/banner), re-center it inside the doubled physical region.
    local bg_code = bg:sub(start, start)
    local left, right = start, finish
    while left > 1 and bg:sub(left - 1, left - 1) == bg_code do left = left - 1 end
    while right < n and bg:sub(right + 1, right + 1) == bg_code do right = right + 1 end
    local region_len = right - left + 1
    local phys_start = (start - 1) * 2 + 1
    if region_len < n and region_len >= #phrase + 2 then
      local region_start = (left - 1) * 2 + 1
      phys_start = region_start + math.max(0, math.floor((region_len * 2 - #phrase) / 2))
    end

    put(top_text, top_fg, phys_start, phrase, fg, start - 1)
    i = math.max(j, finish + 1)
  end

  return table.concat(top_text), table.concat(top_fg), table.concat(top_bg),
    table.concat(bottom_text), table.concat(bottom_fg), table.concat(bottom_bg)
end

local function make_fullscreen_surface(mon)
  local cursor_x, cursor_y = 1, 1
  local cursor_blink = false
  local text_color = read_call(mon, "getTextColor", 1)
  local bg_color = read_call(mon, "getBackgroundColor", 32768)

  local surface = {}

  local function physical_pos(x, y)
    return (math.max(1, math.floor(tonumber(x) or 1)) - 1) * 2 + 1,
      (math.max(1, math.floor(tonumber(y) or 1)) - 1) * 2 + 1
  end

  local function emit_row(px, py, t, f, b)
    if py < 1 or py > HALF_RENDER_H then return end
    if type(mon.blit) == "function" then
      mon.setCursorPos(px, py)
      mon.blit(t, f, b)
      return
    end
    -- Very old/fake terminal fallback; loses per-cell colors but preserves
    -- geometry and is sufficient for graceful compatibility.
    if type(mon.setCursorPos) == "function" then mon.setCursorPos(px, py) end
    if type(mon.write) == "function" then mon.write(t) end
  end

  local function scaled_blit(text, fg, bg)
    local logical_y = math.floor(tonumber(cursor_y) or 1)
    if logical_y < 1 or logical_y > TARGET_H then return end
    local logical_x = math.floor(tonumber(cursor_x) or 1)
    if logical_x < 1 then
      local cut = 2 - logical_x
      text, fg, bg = text:sub(cut), fg:sub(cut), bg:sub(cut)
      logical_x = 1
    end
    local max_len = TARGET_W - logical_x + 1
    if max_len <= 0 then return end
    if #text > max_len then
      text, fg, bg = text:sub(1, max_len), fg:sub(1, max_len), bg:sub(1, max_len)
    end
    if #text == 0 then return end

    local top_t, top_f, top_b, bot_t, bot_f, bot_b = expand_blit_segment(text, fg, bg)
    local px, py = physical_pos(logical_x, logical_y)
    emit_row(px, py, top_t, top_f, top_b)
    emit_row(px, py + 1, bot_t, bot_f, bot_b)
    cursor_x = logical_x + #text
  end

  surface.getSize = function() return TARGET_W, TARGET_H end
  surface.getTextScale = function() return COMPACT_SCALE end
  surface.setTextScale = function(value)
    if tonumber(value) ~= COMPACT_SCALE then error("fullscreen surface scale is fixed at 0.5", 2) end
  end
  surface.isColor = function()
    if type(mon.isColor) == "function" then return mon.isColor() end
    if type(mon.isColour) == "function" then return mon.isColour() end
    return true
  end
  surface.isColour = surface.isColor
  surface.setCursorPos = function(x, y) cursor_x, cursor_y = tonumber(x) or 1, tonumber(y) or 1 end
  surface.getCursorPos = function() return cursor_x, cursor_y end
  surface.setCursorBlink = function(value)
    cursor_blink = value == true
    if type(mon.setCursorBlink) == "function" then
      local px, py = physical_pos(cursor_x, cursor_y)
      pcall(mon.setCursorPos, px, py)
      pcall(mon.setCursorBlink, cursor_blink)
    end
  end
  surface.getCursorBlink = function() return cursor_blink end
  surface.setTextColor = function(value) text_color = value end
  surface.setTextColour = surface.setTextColor
  surface.getTextColor = function() return text_color end
  surface.getTextColour = surface.getTextColor
  surface.setBackgroundColor = function(value) bg_color = value end
  surface.setBackgroundColour = surface.setBackgroundColor
  surface.getBackgroundColor = function() return bg_color end
  surface.getBackgroundColour = surface.getBackgroundColor
  surface.write = function(value)
    local text = tostring(value or "")
    scaled_blit(text, string.rep(color_to_blit(text_color), #text),
      string.rep(color_to_blit(bg_color), #text))
  end
  surface.blit = function(text, fg, bg) scaled_blit(tostring(text or ""), tostring(fg or ""), tostring(bg or "")) end
  surface.clear = function()
    if type(mon.setBackgroundColor) == "function" then pcall(mon.setBackgroundColor, bg_color) end
    if type(mon.clear) == "function" then pcall(mon.clear) end
    cursor_x, cursor_y = 1, 1
  end
  surface.clearLine = function()
    local _, py = physical_pos(1, cursor_y)
    local bg = color_to_blit(bg_color)
    local fg = color_to_blit(text_color)
    local spaces = string.rep(" ", EXPECTED_W_HALF)
    local fgs = string.rep(fg, EXPECTED_W_HALF)
    local bgs = string.rep(bg, EXPECTED_W_HALF)
    emit_row(1, py, spaces, fgs, bgs)
    emit_row(1, py + 1, spaces, fgs, bgs)
  end
  surface.scroll = function(lines)
    if type(mon.scroll) == "function" then pcall(mon.scroll, math.floor(tonumber(lines) or 0) * 2) end
  end

  -- Palette functions are forwarded so CC:Tweaked window.create() can treat
  -- this exactly like a normal terminal redirect.
  surface.setPaletteColor = function(...)
    if type(mon.setPaletteColor) == "function" then return mon.setPaletteColor(...) end
  end
  surface.setPaletteColour = surface.setPaletteColor
  surface.getPaletteColor = function(...)
    if type(mon.getPaletteColor) == "function" then return mon.getPaletteColor(...) end
    return nil
  end
  surface.getPaletteColour = surface.getPaletteColor

  return surface
end

local function create_target(mon, scale, full_w, full_h)
  local cached = bindings[mon]
  if cached and cached.scale == scale and cached.full_w == full_w
      and cached.full_h == full_h and cached.target then
    return cached.target, cached
  end

  if scale == TARGET_SCALE then
    local entry = {
      mon = mon, target = mon, scale = scale,
      full_w = full_w, full_h = full_h,
      x = 1, y = 1, w = TARGET_W, h = TARGET_H,
      physical_render_w = full_w, physical_render_h = full_h,
      fullscreen = true,
    }
    bindings[mon] = entry
    return mon, entry
  end

  if type(mon.setBackgroundColor) == "function" then
    pcall(mon.setBackgroundColor, colorset.get("background"))
  end
  if type(mon.clear) == "function" then pcall(mon.clear) end

  local target = make_fullscreen_surface(mon)
  local entry = {
    mon = mon, target = target, scale = scale,
    full_w = full_w, full_h = full_h,
    x = 1, y = 1, w = TARGET_W, h = TARGET_H,
    physical_render_w = EXPECTED_W_HALF,
    physical_render_h = HALF_RENDER_H,
    fullscreen = true,
  }
  bindings[mon] = entry
  return target, entry
end

function M.normalize_scale(value) return normalize_scale(value) end
function M.expected_full_size(value) return expected_full_size(normalize_scale(value)) end

-- Returns ready, physical_w, physical_h, logical_render_target, normalized_scale.
function M.ensure(mon, requested_scale)
  local scale = normalize_scale(requested_scale)
  if not mon or type(mon.getSize) ~= "function" then return false, 0, 0, nil, scale end
  if not apply_scale(mon, scale) then return false, 0, 0, nil, scale end

  local ok, w, h = pcall(mon.getSize)
  if not ok then return false, 0, 0, nil, scale end
  local expected_w, expected_h = expected_full_size(scale)
  if w ~= expected_w or h ~= expected_h then
    bindings[mon] = nil
    return false, w, h, nil, scale
  end

  local target = create_target(mon, scale, w, h)
  if not target then return false, w, h, nil, scale end
  return true, w, h, target, scale
end

-- Convert physical touch coordinates to the existing logical 82x40 page
-- geometry. In 0.5 mode every logical cell occupies a visible 2x2 physical
-- background block, so hit targets exactly follow those visible blocks.
function M.touch_to_local(mon, x, y)
  local entry = mon and bindings[mon] or nil
  x, y = tonumber(x), tonumber(y)
  if not entry or not x or not y then return nil, nil, false end

  if entry.scale == COMPACT_SCALE then
    if x < 1 or x > EXPECTED_W_HALF or y < 1 or y > HALF_RENDER_H then
      return nil, nil, false
    end
    return math.floor((x - 1) / 2) + 1,
      math.floor((y - 1) / 2) + 1, true
  end

  if x < 1 or x > TARGET_W or y < 1 or y > TARGET_H then return nil, nil, false end
  return x, y, true
end

function M.get_binding(mon)
  local entry = mon and bindings[mon] or nil
  if not entry then return nil end
  return {
    scale = entry.scale,
    physical_width = entry.full_w,
    physical_height = entry.full_h,
    physical_render_width = entry.physical_render_w,
    physical_render_height = entry.physical_render_h,
    logical_width = entry.w,
    logical_height = entry.h,
    origin_x = entry.x,
    origin_y = entry.y,
    fullscreen = entry.fullscreen == true,
  }
end

function M.render_size_error(mon, w, h, requested_scale)
  if not mon then return end
  local scale = normalize_scale(requested_scale)
  local expected_w, expected_h = expected_full_size(scale)
  w, h = tonumber(w) or 0, tonumber(h) or 0
  mux.clear(mon)
  mux.header(mon, {
    title = "FUEL SCADA - MONITOR FEHLER", node_id = "FUEL",
    page = tostring(expected_w) .. "x" .. tostring(expected_h),
    status = "WARNING", icon = "warning",
  })
  local box_w = math.max(30, math.min(math.max(w - 4, 30), 100))
  local box_x = math.max(2, math.floor((math.max(w, box_w + 2) - box_w) / 2) + 1)
  mux.card(mon, box_x, 8, box_w, 17, {
    title = "8x6 ADVANCED MONITOR ERFORDERLICH", status = "WARNING", icon = "warning"
  })
  mux.text(mon, box_x + 3, 11,
    mux.fit("Diese FUEL-UI hat bewusst KEIN altes Fallback-Layout.", box_w - 6),
    colorset.get("WARNING"), colorset.get("background"))
  mux.text(mon, box_x + 3, 13, "UI-Skalierung: " .. tostring(scale),
    colorset.get("text"), colorset.get("background"))
  mux.text(mon, box_x + 3, 15,
    "Erwartet: " .. tostring(expected_w) .. "x" .. tostring(expected_h) .. " Zeichen",
    colorset.get("text"), colorset.get("background"))
  mux.text(mon, box_x + 3, 18,
    "Erkannt: " .. tostring(w) .. "x" .. tostring(h),
    colorset.get("WARNING"), colorset.get("background"))
end

function M.footer(mon, center)
  local binding = M.get_binding(mon)
  local left_x, left_w = 2, 22
  local right_x, right_w = 59, 22

  -- In 0.5 fullscreen the old doubled footer buttons looked overly massive.
  -- Keep them fully readable, but reduce their logical width so they occupy
  -- less physical monitor area while retaining the same bottom navigation role.
  if binding and binding.scale == COMPACT_SCALE then
    left_x, left_w = 4, 16
    right_w = 16
    right_x = TARGET_W - right_w - 3
  end

  local left = mux.button(mon, left_x, 38, left_w, "<< ZURUECK", "LIMITED", 3)
  local right = mux.button(mon, right_x, 38, right_w, "WEITER >>", "LIMITED", 3)
  local text = tostring(center or "FUEL")
  local x = math.floor((TARGET_W - #text) / 2) + 1
  mux.text(mon, x, 39, mux.fit(text, 30), colorset.get("muted"), colorset.get("background"))
  return { left = left, right = right }
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.TARGET_SCALE = TARGET_SCALE
M.COMPACT_SCALE = COMPACT_SCALE
M.EXPECTED_W_HALF = EXPECTED_W_HALF
M.EXPECTED_H_HALF = EXPECTED_H_HALF
M.HALF_RENDER_H = HALF_RENDER_H
M.SUPPORTED_SCALES = { 0.5, 1.0 }

return M
