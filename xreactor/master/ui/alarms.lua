-- master/ui/alarms.lua
--
-- AUX-Monitor: Dediziertes Alarm/Warning-Display.
-- Zeigt aktive Alarms gross und farbig auf dem ganzen Monitor.
-- Kein kleiner Text — jeder Alarm bekommt so viel Platz wie möglich.

local ui         = require("core.ui")
local colorset   = require("shared.colors")
local utils      = require("core.utils")
local support_ui = require("nodes.support.ui_pages")

local cache = {}

local severity_rank = {
  EMERGENCY = 1,
  WARNING   = 2,
  LIMITED   = 3,
  OK        = 4,
  OFFLINE   = 5,
}

local severity_label = {
  EMERGENCY = "!! NOTFALL !!",
  WARNING   = "! WARNUNG",
  LIMITED   = "* EINGESCHRAENKT",
  OK        = "OK",
  OFFLINE   = "OFFLINE",
}

local function sort_alarms(alarms)
  local sorted = {}
  for _, a in ipairs(alarms or {}) do
    table.insert(sorted, a)
  end
  table.sort(sorted, function(a, b)
    local ar = severity_rank[a.severity] or 99
    local br = severity_rank[b.severity] or 99
    if ar == br then return (a.timestamp or "") > (b.timestamp or "") end
    return ar < br
  end)
  return sorted
end

-- Zentriert einen Text in einer Zeile der Breite w
local function center_text(mon, y, text, fg, bg, w)
  local t = tostring(text or "")
  local pad = math.max(0, math.floor((w - #t) / 2))
  local line = string.rep(" ", pad) .. t
  -- auf Breite w auffüllen
  if #line < w then line = line .. string.rep(" ", w - #line) end
  ui.text(mon, 1, y, line:sub(1, w), fg, bg)
end

-- Zeichnet einen Alarm als Block über mehrere Zeilen
local function render_alarm_block(mon, y_start, alarm, w)
  local sev   = alarm.severity or "WARNING"
  local bg    = colorset.get(sev) or colorset.get("WARNING")
  local fg    = colorset.background
  local label = severity_label[sev] or sev

  -- Header-Zeile: farbig hinterlegt, Severity + Timestamp
  local ts    = alarm.timestamp and ("[" .. alarm.timestamp .. "]") or ""
  local header = label .. "  " .. ts
  center_text(mon, y_start, header, fg, bg, w)

  -- Titel-Zeile: gross, weiss auf schwarzem Hintergrund
  local title = tostring(alarm.message or alarm.title or alarm.code or "Unbekannter Alarm")
  center_text(mon, y_start + 1, title, colorset.get(sev), colorset.background, w)

  -- Detail-Zeile falls vorhanden
  local detail = alarm.detail or alarm.node_id or ""
  if detail ~= "" then
    center_text(mon, y_start + 2, tostring(detail), colorset.get("text"), colorset.background, w)
    return 3  -- 3 Zeilen genutzt
  end
  return 2    -- 2 Zeilen genutzt
end

-- Trennlinie zwischen Alarmen
local function render_divider(mon, y, w)
  ui.text(mon, 1, y, string.rep("-", w), colorset.get("OFFLINE"), colorset.background)
end

local function render(mon, model)
  local key = utils.safe_serialize(model) or tostring(model)
  if cache[mon] == key then return end
  cache[mon] = key

  local w, h = ui.getSize(mon)
  if not w or not h or w <= 0 or h <= 0 then return end

  local alarms  = sort_alarms(model.alarms or {})
  local blink   = model.header_blink == true
  local hdr_bg  = blink and colorset.get("EMERGENCY") or colorset.get("accent")
  local hdr_fg  = colorset.background

  -- Header: ganzer Monitor-Titel
  local header_text = blink and "  !! AKTIVE ALARME !!  " or "  SYSTEM-STATUS  "
  center_text(mon, 1, header_text, hdr_fg, hdr_bg, w)

  if #alarms == 0 then
    -- Kein Alarm: grüner "Alles OK" Screen
    local ok_bg = colorset.get("OK")
    local ok_fg = colorset.background

    -- Obere Hälfte grün füllen
    for row = 2, math.floor(h / 2) + 1 do
      ui.text(mon, 1, row, string.rep(" ", w), ok_fg, ok_bg)
    end
    center_text(mon, math.floor(h / 4) + 2, "", ok_fg, ok_bg, w)
    center_text(mon, math.floor(h / 4) + 3, "SYSTEM OK", ok_fg, ok_bg, w)
    center_text(mon, math.floor(h / 4) + 4, "Keine aktiven Alarme", ok_fg, ok_bg, w)

    -- Untere Hälfte normal
    for row = math.floor(h / 2) + 2, h - 1 do
      ui.text(mon, 1, row, string.rep(" ", w), colorset.get("text"), colorset.background)
    end
  else
    -- Alarme anzeigen — so viele wie auf den Monitor passen
    local row = 2
    for _, alarm in ipairs(alarms) do
      if row >= h - 1 then break end

      -- Leerzeile vor jedem Alarm (ausser dem ersten)
      if row > 2 then
        if row < h - 1 then
          render_divider(mon, row, w)
          row = row + 1
        end
      end

      if row < h - 1 then
        local used = render_alarm_block(mon, row, alarm, w)
        row = row + used
      end
    end

    -- Rest des Bildschirms leeren
    for r = row, h - 1 do
      ui.text(mon, 1, r, string.rep(" ", w), colorset.get("text"), colorset.background)
    end
  end

  -- Footer: Zeitstempel
  local ts_line = os.date and os.date("!%H:%M UTC") or "--:--"
  local footer  = string.format(" %s | %d Alarm(e) ", ts_line, #alarms)
  ui.text(mon, 1, h, footer .. string.rep(" ", math.max(0, w - #footer)),
    colorset.get("OFFLINE"), colorset.background)

  support_ui.render_log_mode_button(mon, utils, 1, h, w - 2)
end

local function hit_test(mon, x, y)
  local _, h = ui.getSize(mon)
  if not h then return false end
  if support_ui.handle_log_mode_touch(x, y, h, utils, 1) then
    cache[mon] = nil  -- force redraw
    return true
  end
  return false
end

return { render = render, hit_test = hit_test }
