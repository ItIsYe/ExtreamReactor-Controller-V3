-- xreactor/master/ui/system_map.lua
--
-- AUX-Monitor-Seite: Anlagen-Schema / System Map (Feature, 2026-07-02).
--
-- Zweck: grafische Übersicht über Abhängigkeiten und Zustand der
-- Gesamtanlage, als einfaches Text-Diagramm (CC:Tweaked-Monitore haben
-- keine echte Grafik, daher ASCII-artige Boxen + Pfeile). Zeigt pro
-- Rollentyp (nicht pro einzelnem Node) den aggregierten Zustand — siehe
-- ui_controller.lua's system_map_model (schlechtester Einzelzustand pro
-- Rolle gewinnt, analog zur MASTER-Gesamtampel-Logik).
--
-- Layout (angelehnt an die urspruengliche Anforderung):
--   [FUEL] --> [RT] --> [ENERGY]
--              ^
--   [WATER] ---+
--
--   [LOG]  <-- Logs von allen Nodes

local ui = require("core.ui")
local colors = require("shared.colors")
local widgets = require("master.ui.widgets")

local STATUS_COLOR_KEY = {
  OK = "OK", EMERGENCY = "EMERGENCY", WARNING = "WARNING",
  LIMITED = "LIMITED", OFFLINE = "muted",
}

local function role_label(role_status, role_counts, role_key, short_name)
  local count = role_counts[role_key] or 0
  local status = role_status[role_key]
  if count == 0 then return string.format("[%s]", short_name), "muted" end
  return string.format("[%s:%d]", short_name, count), STATUS_COLOR_KEY[status] or "muted"
end

local function render(mon, model)
  local w, h = ui.getSize(mon)
  ui.panel(mon, 1, 1, w, h, "AUX:SYSTEM MAP", "OK")

  local role_status = (model and model.role_status) or {}
  local role_counts = (model and model.role_counts) or {}

  -- Rollen-Keys aus shared/constants.lua (als Strings dupliziert, da diese
  -- View kein core-Modul importiert — nur Anzeige, keine Logik)
  local FUEL, RT, ENERGY, WATER, LOG = "FUEL-NODE", "RT-NODE", "ENERGY-NODE", "WATER-NODE", "LOG_COLLECTOR"

  local y = 3
  local fuel_text, fuel_status = role_label(role_status, role_counts, FUEL, "FUEL")
  local rt_text, rt_status = role_label(role_status, role_counts, RT, "RT")
  local energy_text, energy_status = role_label(role_status, role_counts, ENERGY, "ENERGY")

  -- Zeile 1: FUEL --> RT --> ENERGY
  local x = 2
  ui.text(mon, x, y, fuel_text, colors.get(fuel_status), colors.get("background")); x = x + #fuel_text
  ui.text(mon, x, y, " --> ", colors.get("muted"), colors.get("background")); x = x + 5
  ui.text(mon, x, y, rt_text, colors.get(rt_status), colors.get("background")); x = x + #rt_text
  ui.text(mon, x, y, " --> ", colors.get("muted"), colors.get("background")); x = x + 5
  ui.text(mon, x, y, energy_text, colors.get(energy_status), colors.get("background"))

  y = y + 1
  -- Zeile 2: Verbindungspfeil-Andeutung unter RT (einfaches "^")
  local rt_x = 2 + #fuel_text + 5
  ui.text(mon, rt_x, y, "^", colors.get("muted"), colors.get("background"))

  y = y + 1
  local water_text, water_status = role_label(role_status, role_counts, WATER, "WATER")
  ui.text(mon, 2, y, water_text, colors.get(water_status), colors.get("background"))
  ui.text(mon, 2 + #water_text, y, " ---+", colors.get("muted"), colors.get("background"))

  y = y + 2
  local log_text, log_status = role_label(role_status, role_counts, LOG, "LOG")
  ui.text(mon, 2, y, log_text, colors.get(log_status), colors.get("background"))
  ui.text(mon, 2 + #log_text, y, widgets.fit("  <-- Logs von allen Nodes", w - 4 - #log_text), colors.get("muted"), colors.get("background"))

  y = y + 2
  local counts = (model and model.alert_counts) or {}
  ui.text(mon, 2, y, widgets.fit(string.format("Alarme: C:%d W:%d I:%d", counts.CRITICAL or 0, counts.WARN or 0, counts.INFO or 0), w - 4),
    colors.get((counts.CRITICAL or 0) > 0 and "EMERGENCY" or (counts.WARN or 0) > 0 and "WARNING" or "text"), colors.get("background"))
end

return { render = render }
