-- master/ui/alarms.lua -- Seite MELDUNGEN (v835).
--
-- Ersetzt die beiden bisherigen Seiten "Logs" (diese Datei) und "Alerts"
-- (master/ui/alerts.lua, entfernt). Betreiber 2026-10-16: "an die
-- Meldungen, Warnungen, Stoerungen muss was dran ... ich kann die Meldungen
-- nicht quittieren" -- und: "die Node anklicken, damit man weitere Infos
-- bekommt".
--
-- Aufbau (Zeile 1 gehoert der Statusleiste von master/ui/multiview.lua):
--   2  Zusammenfassung: Stoerungen, Warnungen, zu quittieren
--   3  Reiter LISTE / VERLAUF, ENTSPERREN wenn etwas gesperrt ist
--   4  Spaltenkopf
--   5+ je Ursache eine Zeile: Klasse, Zeit, Node, Text, AN/WEG, Q, xN
--      -- Antippen waehlt aus und zeigt unten die Einzelheiten (bei "RT
--      meldet ein Problem" alle Zeilen der Node). Quittiert wird NUR ueber
--      die Taste: frueher quittierte schon das Antippen einer Zeile, und weil
--      die Liste sich dabei umsortierte, traf der naechste Tipp eine andere.
--   Einzelheiten der Auswahl
--   letzte Zeile: QUITT. | ALLE QUITT. | SPERREN 1h | VERGESSEN | < >
--
-- Farben: anstehend und unquittiert in der Klassenfarbe hinterlegt;
-- gegangen und unquittiert (nur Stoerungen bleiben so stehen) in
-- Klassenfarbe als Schrift; quittiert grau.
--
-- Zustand je echtem Monitor: auf AUX-Monitoren zeichnet multiview.lua mit
-- einem jedes Mal neuen Stellvertreter (xr_session_mon zeigt auf den echten
-- Monitor) -- Auswahl, Seite und Reiter muessen das ueberstehen.

local ui       = require("core.ui")
local colorset = require("shared.colors")
local widgets  = require("master.ui.widgets")

local M = {}

local CLASS = {
  CRITICAL = { short = "S", label = "STOERUNG", color = "EMERGENCY", rank = 1 },
  WARN     = { short = "W", label = "WARNUNG",  color = "WARNING",   rank = 2 },
  INFO     = { short = "M", label = "MELDUNG",  color = "LIMITED",   rank = 3 },
}
local function class_of(severity)
  local s = tostring(severity or ""):upper()
  if s == "WARNING" then s = "WARN" end
  return CLASS[s] or CLASS.INFO
end

M.EVENT_LABEL = {
  raise = "KOMMT", again = "KOMMT", clear = "GEHT", ack = "QUITT.",
  auto_ack = "AUTO-Q.", severity = "KLASSE", muted = "GESPERRT",
}

M.MUTE_MINUTES = 60

local state_by_mon = setmetatable({}, { __mode = "k" })

local function owner(mon)
  return (type(mon) == "table" and rawget(mon, "xr_session_mon")) or mon
end

local function state_for(mon)
  local key = owner(mon)
  local st = state_by_mon[key]
  if not st then
    st = { view = "list", page = 1, selected_key = nil, rows = {}, buttons = {} }
    state_by_mon[key] = st
  end
  return st
end

local function hm(ms)
  local n = tonumber(ms)
  if not n or n <= 0 then return "--:--" end
  return os.date("!%H:%M", math.floor(n / 1000))
end

local function hms(ms)
  local n = tonumber(ms)
  if not n or n <= 0 then return "--:--:--" end
  return os.date("!%H:%M:%S", math.floor(n / 1000))
end

local function line(mon, y, w, text, fg, bg)
  ui.text(mon, 1, y, widgets.pad(text, w), fg or colorset.get("text"), bg or colorset.get("background"))
end

local function node_of(alert)
  local src = type(alert.source) == "table" and alert.source or {}
  return tostring(src.node_id or src.role or "SYSTEM")
end

local function row_colors(alert)
  local cls = class_of(alert.severity)
  if alert.acknowledged then return colorset.get("muted"), colorset.get("background") end
  if alert.active == false then return colorset.get(cls.color), colorset.get("background") end
  return colorset.get("background"), colorset.get(cls.color)
end

local function right_part(alert)
  local parts = { alert.active == false and "WEG" or "AN" }
  if alert.acknowledged then parts[#parts + 1] = alert.ack_auto and "AQ" or "Q" end
  if (tonumber(alert.count) or 1) > 1 then parts[#parts + 1] = "x" .. tostring(alert.count) end
  return table.concat(parts, " ")
end

local function find_by_key(list, key)
  if not key then return nil end
  for _, alert in ipairs(list or {}) do
    if alert.key == key then return alert end
  end
  return nil
end

-- Einzelheiten: was die Regel mitgibt (details.lines bei RT_PROBLEM,
-- details.reasons bei NODE_DEGRADED), dazu Kommen/Quittung.
function M.detail_lines(alert)
  local cls = class_of(alert.severity)
  local out = {}
  out[#out + 1] = string.format("%s | %s | %s%s", cls.label, node_of(alert),
    alert.active == false and ("WEG seit " .. hm(alert.ts_gone)) or ("AN seit " .. hm(alert.ts_came or alert.ts_first)),
    (tonumber(alert.count) or 1) > 1 and (" | " .. tostring(alert.count) .. "x gekommen") or "")
  local details = type(alert.details) == "table" and alert.details or {}
  if type(details.lines) == "table" and #details.lines > 0 then
    -- Die Node meldet selbst (RT_PROBLEM): ihre Zeilen statt des
    -- zusammengefassten Texts, und wo es weitergeht.
    out[#out + 1] = string.format("%s -- Details am Monitor von %s", tostring(alert.title or alert.code or "Meldung"),
      node_of(alert))
    for _, l in ipairs(details.lines) do out[#out + 1] = "  " .. tostring(l) end
  else
    out[#out + 1] = tostring(alert.title or alert.code or "Meldung") .. ": " .. tostring(alert.message or "")
    if details.reasons then out[#out + 1] = "  Grund: " .. tostring(details.reasons) end
  end
  if alert.acknowledged then
    out[#out + 1] = string.format("Quittiert %s%s", hm(alert.ack_ts), alert.ack_auto and " (automatisch)" or "")
  elseif alert.active == false then
    out[#out + 1] = "Gegangen, noch nicht quittiert"
  end
  return out
end

local function button(mon, st, key, x, y, w, label, enabled, action)
  if w <= 0 then return x end
  ui.button(mon, x, y, w, widgets.fit(label, w), enabled and "WARNING" or "OFFLINE", 1)
  if enabled then st.buttons[#st.buttons + 1] = { x1 = x, x2 = x + w - 1, y = y, action = action, key = key } end
  return x + w + 1
end

local function render_list(mon, st, model, w, h)
  local active = model.active or {}
  local selected = find_by_key(active, st.selected_key)
  if not selected then st.selected_key = nil end

  -- Einzelheiten wachsen mit der Hoehe: halb so viel wie unter Zeile 4
  -- frei ist, 2 bis 6 Zeilen.
  local detail_h = math.max(2, math.min(6, math.floor((h - 6) / 2)))
  local button_y = h
  local detail_top = button_y - detail_h
  local list_top, list_bottom = 5, detail_top - 2
  local per_page = math.max(1, list_bottom - list_top + 1)
  local pages = math.max(1, math.ceil(#active / per_page))
  if st.page > pages then st.page = pages end
  if st.page < 1 then st.page = 1 end

  local head = string.format(" K ZEIT  %-8s MELDUNG", "NODE")
  local page_txt = pages > 1 and string.format("%d/%d ", st.page, pages) or ""
  line(mon, 4, w, widgets.pad(head, w - #page_txt) .. page_txt, colorset.get("muted"))

  local first = (st.page - 1) * per_page + 1
  for i = 0, per_page - 1 do
    local y = list_top + i
    local alert = active[first + i]
    if alert then
      local fg, bg = row_colors(alert)
      local marker = alert.key == st.selected_key and ">" or " "
      local right = " " .. right_part(alert)
      local left = string.format("%s%s %s %-8s %s", marker, class_of(alert.severity).short,
        hm(alert.ts_came or alert.ts_first), widgets.fit(node_of(alert), 8), tostring(alert.title or alert.code or "Meldung"))
      local text = widgets.pad(left, math.max(1, w - #right)) .. right
      ui.text(mon, 1, y, widgets.pad(text, w), fg, bg)
      st.rows[#st.rows + 1] = { y = y, key = alert.key }
    elseif i == 0 and #active == 0 then
      line(mon, y, w, "  Keine Meldungen -- alles in Ordnung", colorset.get("OK"))
    else
      line(mon, y, w, "")
    end
  end

  line(mon, detail_top - 1, w, string.rep("-", w), colorset.get("OFFLINE"))
  local details = selected and M.detail_lines(selected) or { "Eintrag antippen fuer Einzelheiten" }
  for i = 1, detail_h do
    local text = details[i] or ""
    if i == detail_h and #details > detail_h then text = "  ... (" .. tostring(#details - detail_h + 1) .. " Zeilen mehr am Node-Monitor)" end
    line(mon, detail_top + i - 1, w, text, i == 1 and selected and colorset.get(class_of(selected.severity).color) or nil)
  end

  -- Tasten
  line(mon, button_y, w, "")
  local can_ack = selected and not selected.acknowledged
  local any_unacked = false
  for _, alert in ipairs(active) do if not alert.acknowledged then any_unacked = true break end end
  local can_forget = selected and selected.code == "NODE_COMMS_DOWN" and selected.active ~= false
  local paging = pages > 1
  local nav_w = paging and 7 or 0
  local slot = math.floor((w - nav_w - 3) / 4)
  local x = 1
  x = button(mon, st, "ack", x, button_y, slot, "QUITT.", can_ack, can_ack and { type = "alert_ack", id = selected.id } or nil)
  x = button(mon, st, "ack_all", x, button_y, slot, "ALLE QUITT.", any_unacked, { type = "alert_ack_all" })
  x = button(mon, st, "mute", x, button_y, slot, "SPERREN 1h", selected ~= nil,
    selected and { type = "alert_mute_key", key = selected.key, minutes = M.MUTE_MINUTES } or nil)
  x = button(mon, st, "forget", x, button_y, slot, "VERGESSEN", can_forget,
    can_forget and { type = "alert_forget_node", node_id = (selected.source or {}).node_id } or nil)
  if paging then
    x = button(mon, st, "prev", x, button_y, 3, "<", st.page > 1, nil)
    button(mon, st, "next", x, button_y, 3, ">", st.page < pages, nil)
  end
end

local function render_history(mon, st, model, w, h)
  local history = model.history or {}
  local list_top, list_bottom = 5, h - 1
  local per_page = math.max(1, list_bottom - list_top + 1)
  local pages = math.max(1, math.ceil(#history / per_page))
  if st.page > pages then st.page = pages end
  if st.page < 1 then st.page = 1 end
  local page_txt = pages > 1 and string.format("%d/%d ", st.page, pages) or ""
  line(mon, 4, w, widgets.pad(string.format(" ZEIT     EREIGNIS K %-8s MELDUNG", "NODE"), w - #page_txt) .. page_txt,
    colorset.get("muted"))
  local first = (st.page - 1) * per_page + 1
  for i = 0, per_page - 1 do
    local entry = history[first + i]
    if entry then
      local cls = class_of(entry.severity)
      local text = string.format(" %s %-8s %s %-8s %s", hms(entry.event_ts or entry.ts_last),
        M.EVENT_LABEL[entry.event] or tostring(entry.event or "?"), cls.short,
        widgets.fit(node_of(entry), 8), tostring(entry.title or entry.code or ""))
      local fg = (entry.event == "raise" or entry.event == "again") and colorset.get(cls.color) or colorset.get("text")
      line(mon, list_top + i, w, text, fg)
    elseif i == 0 then
      line(mon, list_top, w, "  Noch kein Verlauf", colorset.get("muted"))
    else
      line(mon, list_top + i, w, "")
    end
  end
  line(mon, h, w, "")
  if pages > 1 then
    local x = math.max(1, w - 6)
    x = button(mon, st, "prev", x, h, 3, "<", st.page > 1, nil)
    button(mon, st, "next", x, h, 3, ">", st.page < pages, nil)
  end
end

function M.render(mon, model)
  model = model or {}
  local w, h = ui.getSize(mon)
  if not w or not h or w <= 0 or h < 8 then return end
  local st = state_for(mon)
  st.rows, st.buttons = {}, {}

  local counts = model.counts or {}
  local crit, warn = tonumber(counts.CRITICAL) or 0, tonumber(counts.WARN) or 0
  local unacked = tonumber(counts.UNACKED) or 0
  local status = crit > 0 and "EMERGENCY" or ((tonumber(counts.GONE_UNACKED_CRITICAL) or 0) > 0 and "EMERGENCY")
    or (warn > 0 and "WARNING") or (unacked > 0 and "LIMITED") or "OK"
  local summary = string.format(" STOERUNG %d | WARNUNG %d | ZU QUITTIEREN %d", crit, warn, unacked)
  if #summary > w then summary = string.format(" STOER. %d  WARN. %d  ZU QUITT. %d", crit, warn, unacked) end
  ui.text(mon, 1, 2, widgets.pad(summary, w), colorset.get("background"), colorset.get(status))

  -- Reiter
  line(mon, 3, w, "")
  local x = 1
  x = button(mon, st, "tab_list", x, 3, 8, "LISTE", true, nil)
  x = button(mon, st, "tab_history", x, 3, 9, "VERLAUF", true, nil)
  local muted = tonumber(model.muted_count) or 0
  if muted > 0 then
    local label = string.format("ENTSPERREN (%d)", muted)
    button(mon, st, "unmute", math.max(x, w - #label - 1), 3, #label + 2, label, true, { type = "alert_unmute_keys" })
  end

  if st.view == "history" then
    render_history(mon, st, model, w, h)
  else
    render_list(mon, st, model, w, h)
  end
end

-- Signatur (mon, x, y) wie alle anderen Views (multiview.lua).
function M.hit_test(mon, x, y)
  if not y then return nil end
  local st = state_for(mon)
  for _, b in ipairs(st.buttons or {}) do
    if y == b.y and x >= b.x1 and x <= b.x2 then
      if b.key == "tab_list" then st.view = "list"; st.page = 1; return nil end
      if b.key == "tab_history" then st.view = "history"; st.page = 1; return nil end
      if b.key == "prev" then st.page = math.max(1, st.page - 1); return nil end
      if b.key == "next" then st.page = st.page + 1; return nil end
      return b.action
    end
  end
  for _, r in ipairs(st.rows or {}) do
    if y == r.y then
      -- Nochmal antippen hebt die Auswahl auf.
      st.selected_key = (st.selected_key ~= r.key) and r.key or nil
      return nil
    end
  end
  return nil
end

-- Alter Name fuer denselben Einstieg (init_runtime.lua verdrahtete
-- handle_input als hit_test).
M.handle_input = M.hit_test

return M
