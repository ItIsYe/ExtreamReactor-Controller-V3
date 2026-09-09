-- nodes/fuel/monitor_scada.lua
-- Fixed logical 82x40 SCADA surface with configurable physical monitor scale.
--
-- ui_scale = 1.0:
--   8x6 Advanced Monitor => 82x40; renderer uses the monitor directly.
--
-- ui_scale = 0.5:
--   8x6 Advanced Monitor => 164x81; the same logical 82x40 SCADA surface
--   is centered inside the larger character grid. Touches are translated
--   back to logical 82x40 coordinates.
--
-- There is deliberately still NO legacy FUEL layout. Both modes render the
-- same SCADA pages and logical touch geometry; only the physical text scale
-- and viewport position change.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local TARGET_W = 82
local TARGET_H = 40
local TARGET_SCALE = 1.0
local COMPACT_SCALE = 0.5

-- Exact 8x6 dimensions from CC:Tweaked's monitor terminal formula.
local EXPECTED_W_1 = 82
local EXPECTED_H_1 = 40
local EXPECTED_W_HALF = 164
local EXPECTED_H_HALF = 81

local bindings = setmetatable({}, { __mode = "k" })

local function normalize_scale(value)
  local n = tonumber(value)
  if n == COMPACT_SCALE then return COMPACT_SCALE end
  return TARGET_SCALE
end

local function expected_full_size(scale)
  if scale == COMPACT_SCALE then return EXPECTED_W_HALF, EXPECTED_H_HALF end
  return EXPECTED_W_1, EXPECTED_H_1
end

local function hide_target(entry)
  if entry and entry.target and entry.target ~= entry.mon
      and type(entry.target.setVisible) == "function" then
    pcall(entry.target.setVisible, false)
  end
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
  local ok = pcall(mon.setTextScale, scale)
  return ok == true
end

local function create_target(mon, scale, full_w, full_h)
  local cached = bindings[mon]
  if cached and cached.scale == scale and cached.full_w == full_w
      and cached.full_h == full_h and cached.target then
    return cached.target, cached
  end

  hide_target(cached)

  if scale == TARGET_SCALE then
    local entry = {
      mon = mon, target = mon, scale = scale,
      full_w = full_w, full_h = full_h,
      x = 1, y = 1, w = TARGET_W, h = TARGET_H,
    }
    bindings[mon] = entry
    return mon, entry
  end

  if type(window) ~= "table" or type(window.create) ~= "function" then
    bindings[mon] = nil
    return nil, nil
  end

  local x = math.floor((full_w - TARGET_W) / 2) + 1
  local y = math.floor((full_h - TARGET_H) / 2) + 1

  if type(mon.setBackgroundColor) == "function" then
    pcall(mon.setBackgroundColor, colorset.get("background"))
  end
  if type(mon.clear) == "function" then pcall(mon.clear) end

  local ok, target = pcall(window.create, mon, x, y, TARGET_W, TARGET_H, true)
  if not ok or not target then
    bindings[mon] = nil
    return nil, nil
  end

  local entry = {
    mon = mon, target = target, scale = scale,
    full_w = full_w, full_h = full_h,
    x = x, y = y, w = TARGET_W, h = TARGET_H,
  }
  bindings[mon] = entry
  return target, entry
end

function M.normalize_scale(value) return normalize_scale(value) end

function M.expected_full_size(value)
  return expected_full_size(normalize_scale(value))
end

-- Returns ready, physical_w, physical_h, logical_render_target, normalized_scale.
function M.ensure(mon, requested_scale)
  local scale = normalize_scale(requested_scale)
  if not mon or type(mon.getSize) ~= "function" then
    return false, 0, 0, nil, scale
  end
  if not apply_scale(mon, scale) then return false, 0, 0, nil, scale end

  local ok, w, h = pcall(mon.getSize)
  if not ok then return false, 0, 0, nil, scale end

  local expected_w, expected_h = expected_full_size(scale)
  if w ~= expected_w or h ~= expected_h then
    hide_target(bindings[mon])
    bindings[mon] = nil
    return false, w, h, nil, scale
  end

  local target = create_target(mon, scale, w, h)
  if not target then return false, w, h, nil, scale end
  return true, w, h, target, scale
end

-- Translate physical monitor_touch coordinates to the fixed logical 82x40
-- viewport. Touches in the unused border of 0.5 mode are rejected.
function M.touch_to_local(mon, x, y)
  local entry = mon and bindings[mon] or nil
  x, y = tonumber(x), tonumber(y)
  if not entry or not x or not y then return nil, nil, false end
  if x < entry.x or x > entry.x + entry.w - 1
      or y < entry.y or y > entry.y + entry.h - 1 then
    return nil, nil, false
  end
  return x - entry.x + 1, y - entry.y + 1, true
end

function M.get_binding(mon)
  local entry = mon and bindings[mon] or nil
  if not entry then return nil end
  return {
    scale = entry.scale,
    physical_width = entry.full_w,
    physical_height = entry.full_h,
    logical_width = entry.w,
    logical_height = entry.h,
    origin_x = entry.x,
    origin_y = entry.y,
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
  local box_w = math.max(30, math.min(math.max(w - 4, 30), 80))
  local box_x = math.max(2, math.floor((math.max(w, box_w + 2) - box_w) / 2) + 1)
  mux.card(mon, box_x, 8, box_w, 17, {
    title = "FESTE BILDSCHIRMGROESSE ERFORDERLICH", status = "WARNING", icon = "warning"
  })
  mux.text(mon, box_x + 3, 12,
    mux.fit("Diese FUEL-UI hat bewusst KEIN altes Fallback-Layout.", box_w - 6),
    colorset.get("WARNING"), colorset.get("background"))
  mux.text(mon, box_x + 3, 15, "UI-Skalierung: " .. tostring(scale),
    colorset.get("text"), colorset.get("background"))
  mux.text(mon, box_x + 3, 17,
    "Erwartet: " .. tostring(expected_w) .. "x" .. tostring(expected_h) .. " Zeichen",
    colorset.get("text"), colorset.get("background"))
  mux.text(mon, box_x + 3, 19, "Monitor: 8x6 Advanced Monitor",
    colorset.get("text"), colorset.get("background"))
  mux.text(mon, box_x + 3, 22,
    "Erkannt: " .. tostring(w) .. "x" .. tostring(h),
    colorset.get("WARNING"), colorset.get("background"))
end

function M.footer(mon, center)
  local left = mux.button(mon, 2, 38, 22, "<< ZURUECK", "LIMITED", 3)
  local right = mux.button(mon, 59, 38, 22, "WEITER >>", "LIMITED", 3)
  local text = tostring(center or "FUEL")
  local x = math.floor((TARGET_W - #text) / 2) + 1
  mux.text(mon, x, 39, mux.fit(text, 30), colorset.get("muted"), colorset.get("background"))
  return { left = left, right = right }
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.TARGET_SCALE = TARGET_SCALE
M.COMPACT_SCALE = COMPACT_SCALE
M.SUPPORTED_SCALES = { 0.5, 1.0 }

return M
