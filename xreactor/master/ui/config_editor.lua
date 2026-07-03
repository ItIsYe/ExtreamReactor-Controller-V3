-- xreactor/master/ui/config_editor.lua
--
-- Config-Editor am Monitor (Feature, 2026-07-02).
--
-- Zweck: zentrale Seite fuer Werte, die vorher nur durch manuelles
-- Bearbeiten von Config-Dateien oder ueber verstreute Touch-Buttons auf
-- verschiedenen Seiten aenderbar waren. PEAK/IDLE-Schwellen und RT-Global-
-- Hold existierten bereits im Overview — diese Seite fasst sie zusammen
-- und ergaenzt Fuel-Reserve, Water-Target, Auto-Update.
--
-- Fuel-Reserve/Water-Target senden SET_RESERVE/SET_TARGET Commands an den
-- jeweils ersten gefundenen Node dieser Rolle (siehe
-- master/runtime_loop.lua set_fuel_reserve/set_water_target).

local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local hit_cache = setmetatable({}, { __mode = "k" })

local function render(mon, model)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "Config-Editor", "OK")
  local hits = {}

  model = model or {}
  local cx, y

  local function row(label_fmt, value, delta_small, delta_large, action_type, min_v, max_v)
    ui.text(mon, 2, y, widgets.fit(string.format(label_fmt, value), w - 2), colors.get("text"), colors.get("background"))
    local function put(text)
      local t = tostring(text)
      ui.text(mon, cx, y, t, colors.get("muted"), colors.get("background"))
      local start_x = cx
      cx = cx + #t
      return start_x, cx - 1
    end
    cx = w - 14
    local m1, m2 = put("[-]")
    put(" ")
    local p1, p2 = put("[+]")
    hits[#hits + 1] = { type = action_type, delta = -delta_small, x1 = m1, x2 = m2, y1 = y, y2 = y }
    hits[#hits + 1] = { type = action_type, delta = delta_small, x1 = p1, x2 = p2, y1 = y, y2 = y }
    y = y + 1
  end

  y = 3
  row("PEAK-Schwelle: %d%%", model.peak_threshold_pct or 30, 5, 5, "peak_threshold_adjust")
  row("IDLE-Schwelle: %d%%", model.idle_threshold_pct or 90, 5, 5, "idle_threshold_adjust")

  y = y + 1
  local hold_label = model.rt_global_off_hold and "AN" or "AUS"
  ui.text(mon, 2, y, widgets.fit("RT-Global-Hold: " .. hold_label, w - 2), colors.get(model.rt_global_off_hold and "WARNING" or "text"), colors.get("background"))
  ui.badge(mon, w - 10, y, "TOGGLE", model.rt_global_off_hold and "WARNING" or "OK")
  hits[#hits + 1] = { type = "rt_hold", x1 = w - 10, x2 = w - 2, y1 = y, y2 = y }
  y = y + 2

  row("Fuel-Reserve: %d", model.fuel_reserve_pct or 2000, 250, 250, "fuel_reserve_adjust")
  row("Water-Target: %d", model.water_target_pct or 0, 250, 250, "water_target_adjust")

  y = y + 1
  local auto_label = model.auto_update_enabled ~= false and "AN" or "AUS"
  ui.text(mon, 2, y, widgets.fit("Auto-Update: " .. auto_label, w - 2), colors.get("text"), colors.get("background"))
  ui.badge(mon, w - 10, y, "TOGGLE", model.auto_update_enabled ~= false and "OK" or "WARNING")
  hits[#hits + 1] = { type = "auto_update_toggle", x1 = w - 10, x2 = w - 2, y1 = y, y2 = y }
  y = y + 2

  ui.text(mon, 2, y, widgets.fit("Wartungsmodus: siehe eigene 'Maintenance'-Seite", w - 2), colors.get("muted"), colors.get("background"))

  hit_cache[mon] = hits
end

local function hit_test(mon, x, y)
  for _, hit in ipairs(hit_cache[mon] or {}) do
    local y1 = hit.y1 or hit.y
    local y2 = hit.y2 or hit.y
    if y >= y1 and y <= y2 and x >= hit.x1 and x <= hit.x2 then
      return hit
    end
  end
end

return { render = render, hit_test = hit_test }
