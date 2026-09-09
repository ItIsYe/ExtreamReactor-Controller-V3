-- nodes/fuel/monitor_scada.lua
--
-- FUEL monitor presentation contract: fixed 8x6 Advanced Monitor at
-- TextScale 1.0 => exactly 82x40 terminal cells.
--
-- This deliberately removes the former TextScale-0.5 fullscreen transform.
-- The transform made text physically small while backgrounds/buttons were
-- expanded, which produced inconsistent in-game proportions. The FUEL GUI is
-- now rendered natively at 82x40 again: larger text/frames, with deliberately
-- smaller buttons in the page renderers.
--
-- SCADA boundary: presentation only. No logistics, routing, valve, delivery,
-- safety, persistence or network-command logic lives here.

local M = {}
local mux = require("core.mockup_ui")
local colorset = require("shared.colors")

local TARGET_W = 82
local TARGET_H = 40
local TARGET_SCALE = 1.0

local bindings = setmetatable({}, { __mode = "k" })

local function apply_fixed_scale(mon)
  if not mon then return false end
  if type(mon.getTextScale) == "function" then
    local ok, current = pcall(mon.getTextScale)
    if ok and tonumber(current) == TARGET_SCALE then return true end
  end
  if type(mon.setTextScale) ~= "function" then return false end
  return pcall(mon.setTextScale, TARGET_SCALE) == true
end

function M.normalize_scale(_value)
  return TARGET_SCALE
end

function M.expected_full_size(_value)
  return TARGET_W, TARGET_H
end

-- requested_scale is accepted for backwards-compatible call sites but is
-- intentionally ignored. Existing /xreactor_config/fuel.lua files containing
-- ui_scale=0.5 therefore recover automatically to the fixed 1.0 UI.
function M.ensure(mon, _requested_scale)
  if not mon or type(mon.getSize) ~= "function" then
    return false, 0, 0, nil, TARGET_SCALE
  end
  if not apply_fixed_scale(mon) then
    return false, 0, 0, nil, TARGET_SCALE
  end
  local ok, w, h = pcall(mon.getSize)
  if not ok then return false, 0, 0, nil, TARGET_SCALE end
  if w ~= TARGET_W or h ~= TARGET_H then
    bindings[mon] = nil
    return false, w, h, nil, TARGET_SCALE
  end
  bindings[mon] = {
    mon = mon, target = mon, scale = TARGET_SCALE,
    full_w = w, full_h = h, x = 1, y = 1,
    w = TARGET_W, h = TARGET_H, fullscreen = true,
  }
  return true, w, h, mon, TARGET_SCALE
end

-- At fixed scale physical and logical coordinates are identical.
function M.touch_to_local(mon, x, y)
  local entry = mon and bindings[mon] or nil
  x, y = tonumber(x), tonumber(y)
  if not entry or not x or not y then return nil, nil, false end
  if x < 1 or x > TARGET_W or y < 1 or y > TARGET_H then
    return nil, nil, false
  end
  return x, y, true
end

function M.get_binding(mon)
  local entry = mon and bindings[mon] or nil
  if not entry then return nil end
  return {
    scale = TARGET_SCALE,
    physical_width = TARGET_W,
    physical_height = TARGET_H,
    physical_render_width = TARGET_W,
    physical_render_height = TARGET_H,
    logical_width = TARGET_W,
    logical_height = TARGET_H,
    origin_x = 1,
    origin_y = 1,
    fullscreen = true,
  }
end

function M.render_size_error(mon, w, h, _requested_scale)
  if not mon then return end
  w, h = tonumber(w) or 0, tonumber(h) or 0
  mux.clear(mon)
  mux.header(mon, {
    title = "FUEL SCADA - MONITOR FEHLER",
    node_id = "FUEL",
    page = "82x40",
    status = "WARNING",
    icon = "warning",
  })
  local box_w = math.max(30, math.min(math.max(w - 4, 30), 76))
  local box_x = math.max(2, math.floor((math.max(w, box_w + 2) - box_w) / 2) + 1)
  mux.card(mon, box_x, 8, box_w, 15, {
    title = "8x6 ADVANCED MONITOR ERFORDERLICH",
    status = "WARNING",
    icon = "warning",
  })
  mux.text(mon, box_x + 3, 11,
    mux.fit("Diese FUEL-UI hat bewusst KEIN altes Fallback-Layout.", box_w - 6),
    colorset.get("WARNING"), colorset.get("background"))
  mux.text(mon, box_x + 3, 14,
    "Feste Skalierung: TextScale 1.0",
    colorset.get("text"), colorset.get("background"))
  mux.text(mon, box_x + 3, 17,
    "Erwartet: 82x40  |  Erkannt: " .. tostring(w) .. "x" .. tostring(h),
    colorset.get("muted"), colorset.get("background"))
end

-- Shared page footer. Smaller than the previous 22x3 controls: the buttons
-- remain easy to hit while no longer dominating the bottom of the screen.
function M.footer(mon, center)
  local left = mux.button(mon, 3, 38, 15, "<< ZURUECK", "LIMITED", 2)
  local right = mux.button(mon, 65, 38, 15, "WEITER >>", "LIMITED", 2)
  local text = tostring(center or "FUEL")
  local x = math.floor((TARGET_W - #text) / 2) + 1
  mux.text(mon, x, 39, mux.fit(text, 28),
    colorset.get("muted"), colorset.get("background"))
  return { left = left, right = right }
end

M.TARGET_W = TARGET_W
M.TARGET_H = TARGET_H
M.TARGET_SCALE = TARGET_SCALE
M.SUPPORTED_SCALES = { 1.0 }
M.FIXED_SCALE = true

return M
