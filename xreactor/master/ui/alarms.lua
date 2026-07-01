-- master/ui/alarms.lua (redesign 2026-07-01)
--
-- AUX-Monitor Alarmliste:
--   - Aktive Alarme aus alert_service (CRITICAL/WARN/INFO)
--   - Farbe je Severity: rot=CRIT, gelb=WARN, grün=OK
--   - Pro Eintrag: Severity-Label | Timestamp | Node-ID (Zeile 1)
--                  Title: Kurztext (Zeile 2)
--   - Automatisch weg wenn nicht mehr aktiv
--   - Touch auf einen Eintrag -> ACK (quittiert, abgedunkelt)
--   - on_ack(id) Callback wird von ui_controller aus alert_service bedient

local ui       = require("core.ui")
local colorset = require("shared.colors")
local widgets  = require("master.ui.widgets")

-- alert_service severity -> Farbe + Kurzlabel
local SEV_MAP = {
  CRITICAL = { label = "CRIT",  color = "EMERGENCY", sort = 1 },
  WARN     = { label = "WARN",  color = "WARNING",   sort = 2 },
  WARNING  = { label = "WARN",  color = "WARNING",   sort = 2 },
  INFO     = { label = "INFO",  color = "LIMITED",   sort = 3 },
}
local function sev(severity)
  return SEV_MAP[tostring(severity or ""):upper()] or { label = "?", color = "OFFLINE", sort = 9 }
end

local function fmt_ts(ts_ms)
  if not ts_ms or ts_ms == 0 then return "--:--" end
  return os.date("!%H:%M", math.floor(ts_ms / 1000))
end

-- Sortierung: CRIT zuerst, dann WARN, dann INFO; innerhalb selber Severity älteste zuerst.
-- Quittierte Alarme ans Ende.
local function sorted_alerts(active)
  local acked, pending = {}, {}
  for _, a in ipairs(active or {}) do
    if a.acknowledged then acked[#acked+1] = a else pending[#pending+1] = a end
  end
  local function by_sev_ts(a, b)
    local sa, sb = sev(a.severity).sort, sev(b.severity).sort
    if sa ~= sb then return sa < sb end
    return (a.ts_first or 0) < (b.ts_first or 0)
  end
  table.sort(pending, by_sev_ts)
  table.sort(acked, by_sev_ts)
  local out = {}
  for _, a in ipairs(pending) do out[#out+1] = a end
  for _, a in ipairs(acked)   do out[#out+1] = a end
  return out, #pending, #acked
end

local hit_zones = {}   -- { id, y1, y2 } für Touch-ACK

local function render(mon, model)
  hit_zones = {}
  local active = model and model.active or {}
  local alerts, n_pending, n_acked = sorted_alerts(active)

  local w, h = ui.getSize(mon)
  if not w or not h or w <= 0 or h <= 0 then return end

  -- ── Header ────────────────────────────────────────────────────────────────
  local n_crit = 0
  for _, a in ipairs(alerts) do
    if not a.acknowledged and (a.severity or ""):upper() == "CRITICAL" then n_crit = n_crit + 1 end
  end
  local hdr_col = n_crit > 0 and "EMERGENCY" or (n_pending > 0 and "WARNING" or "OK")
  local hdr_txt = n_crit > 0 and ("!! " .. n_crit .. " KRITISCH !!")
               or (n_pending > 0 and (n_pending .. " ALARM(E) AKTIV"))
               or "SYSTEM OK"
  ui.panel(mon, 1, 1, w, 1, hdr_txt, hdr_col)

  -- ── Footer ────────────────────────────────────────────────────────────────
  local ts_now = os.date and os.date("!%H:%M UTC") or "--:--"
  local footer = string.format(" %s | %d aktiv  %d quittiert ", ts_now, n_pending, n_acked)
  ui.text(mon, 1, h,
    footer .. string.rep(" ", math.max(0, w - #footer)),
    colorset.get("muted"), colorset.get("background"))

  -- ── Kein Alarm: grüner Bildschirm ─────────────────────────────────────────
  if #alerts == 0 then
    local ok_bg = colorset.get("OK")
    local ok_fg = colorset.get("background")
    for row = 2, h - 1 do
      ui.text(mon, 1, row, string.rep(" ", w), ok_fg, ok_bg)
    end
    local mid = math.floor((h - 2) / 2) + 2
    ui.text(mon, 1, mid,
      widgets.fit("      SYSTEM OK      ", w), ok_fg, ok_bg)
    ui.text(mon, 1, mid + 1,
      widgets.fit("  Keine aktiven Alarme  ", w), ok_fg, ok_bg)
    return
  end

  -- ── Alarmliste ────────────────────────────────────────────────────────────
  local y = 2
  for _, alarm in ipairs(alerts) do
    if y > h - 1 then break end
    local info  = sev(alarm.severity)
    local acked = alarm.acknowledged == true
    local src   = type(alarm.source) == "table"
                  and tostring(alarm.source.node_id or alarm.source.role or "")
                  or ""

    -- Zeile 1: [SEV] HH:MM node-xx
    local bg1 = acked and colorset.get("OFFLINE") or colorset.get(info.color)
    local fg1 = colorset.get("background")
    local prefix = acked and ("[ACK] " .. info.label) or info.label
    local line1  = string.format("%-10s %s  %s", prefix, fmt_ts(alarm.ts_first), src)
    ui.text(mon, 1, y, widgets.fit(line1, w) .. string.rep(" ", math.max(0, w - #line1)),
      fg1, bg1)
    local y1 = y
    y = y + 1
    if y > h - 1 then
      hit_zones[#hit_zones+1] = { id = alarm.id, y1 = y1, y2 = y - 1 }
      break
    end

    -- Zeile 2: Title: message
    local title = tostring(alarm.title or alarm.code or "Alert")
    local msg   = tostring(alarm.message or "")
    local line2 = msg ~= "" and (title .. ": " .. msg) or title
    local fg2   = acked and colorset.get("muted") or colorset.get("text")
    ui.text(mon, 2, y,
      widgets.fit(line2, w - 1) .. string.rep(" ", math.max(0, w)),
      fg2, colorset.get("background"))
    local y2 = y
    y = y + 1
    hit_zones[#hit_zones+1] = { id = alarm.id, y1 = y1, y2 = y2 }

    -- Trennlinie
    if y < h - 1 and y <= h - 1 then
      ui.text(mon, 1, y, string.rep("-", w), colorset.get("OFFLINE"), colorset.get("background"))
      y = y + 1
    end
  end

  -- Restfläche leeren
  for row = y, h - 1 do
    ui.text(mon, 1, row, string.rep(" ", w), colorset.get("text"), colorset.get("background"))
  end
end

local function handle_input(event, model)
  if not event or event[1] ~= "monitor_touch" then return false end
  local _mon, _tx, ty = event[2], event[3], event[4]
  if not ty then return false end
  for _, zone in ipairs(hit_zones) do
    if ty >= zone.y1 and ty <= zone.y2 then
      if model and type(model.on_ack) == "function" then
        model.on_ack(zone.id)
      end
      return true
    end
  end
  return false
end

return { render = render, handle_input = handle_input }
