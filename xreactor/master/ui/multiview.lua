local ui = require("core.ui")
local widgets = require("master.ui.widgets")
local layout = require("master.ui.layout")
local sessions_lib = require("master.monitor_sessions")
local utils = require("core.utils")

local M = {}

local function render_error(mon, w, h, title, message)
  if not mon or type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then
    return false, "invalid-monitor-size"
  end
  ui.clear(mon)
  ui.panel(mon, 1, 1, w, h, title, "EMERGENCY")
  ui.text(mon, 2, 3, widgets.fit(tostring(message), math.max(10, w - 3)), 0xFFFFFF, 0x000000)
  return true
end

local function should_hard_clear(session)
  if not session then return false end
  return session.rebind_pending == true or session.dirty_reason == "rebind"
end

-- Fix (2026-07-02, Teil 2): Touch-ausgeloeste Zustandswechsel (z.B.
-- cycle_aux_view() nach Antippen eines AUX-Monitors, oder ein
-- maintenance_toggle/rt_hold/profile-Wechsel) setzen session.dirty = true.
-- Diese muessen IMMER sofort ein Redraw erzwingen, auch wenn das Model
-- zufaellig textuell identisch serialisiert wie beim letzten Mal (z.B.
-- Wechsel zurueck auf eine View, deren Daten sich seit dem letzten Besuch
-- nicht veraendert haben) — sonst wuerde ein Touch-Wechsel unsichtbar
-- bleiben, bis irgendein anderer Wert sich zufaellig aendert.
local function should_force_redraw(session)
  return should_hard_clear(session) or session.dirty == true
end

-- Fix (2026-07-02): view.render() wurde bisher bei JEDEM M:render()-Aufruf
-- unconditional ausgefuehrt — das deklarierte view.interval-Feld (aus
-- init_runtime.lua, z.B. 0.5/1.0/2.0s) wurde nirgends ausgewertet. In der
-- Praxis bedeutete das: sobald sich IRGENDWO im System eine einzelne Zahl
-- aenderte (z.B. RT-Leistung, die sich fast jeden Tick minimal aendert),
-- wurde mux.clear() + kompletter Re-Draw fuer ALLE 10 Views auf ALLEN
-- Monitoren ausgefuehrt, nicht nur fuer die tatsaechlich betroffene Seite.
-- Jetzt: pro (Monitor, View)-Kombination wird das jeweilige Model
-- serialisiert und mit dem letzten bekannten Stand verglichen. Nur bei
-- echter Aenderung, bei Touch-Interaktion, oder wenn view.interval
-- abgelaufen ist, wird tatsaechlich neu gezeichnet. Ein zusaetzliches
-- Force-Intervall (4x view.interval, min. 5s) erzwingt trotzdem ein
-- periodisches Redraw, damit die Anzeige nie "einfriert" falls der
-- Snapshot-Vergleich aus irgendeinem Grund (z.B. Zeitstempel-Feld, das
-- sich technisch aendert aber visuell nichts Neues zeigt) staendig
-- "geaendert" meldet, oder umgekehrt niemals als geaendert erkannt wird.
local render_state = setmetatable({}, { __mode = "k" })

local function serialize_model(model)
  if utils and utils.safe_serialize then
    return utils.safe_serialize(model) or tostring(model)
  end
  local ok, serialized = pcall(textutils.serialize, model)
  return ok and serialized or tostring(model)
end

local function should_render_view(session, view_key, view, model)
  local now = os.epoch and os.epoch("utc") or 0
  local key = tostring(session.name or session.id or "?") .. "|" .. tostring(view_key)
  local state = render_state[key]
  if not state then
    state = { last_snapshot = nil, last_draw = 0, last_force = 0 }
    render_state[key] = state
  end

  local interval_ms = math.max(0.1, tonumber(view and view.interval) or 1.0) * 1000
  local force_interval_ms = math.max(interval_ms * 4, 5000)

  local due = (now - state.last_draw) >= interval_ms
  local force_due = (now - state.last_force) >= force_interval_ms

  -- Fix (2026-07-06): CRITICAL. state.last_draw/state.last_force wurden
  -- bisher NIE aktualisiert (blieben dauerhaft bei ihrem Initialwert 0).
  -- Praktische Folge: "due" war ab dem allerersten Tick fuer immer true
  -- (now - 0 ist quasi immer >= interval_ms), das Intervall-Gating griff
  -- also nie. Das haette eigentlich zu HAEUFIGEREM statt selteneren
  -- Rendering fuehren muessen — der eigentliche, dazu passende Bug liegt
  -- an anderer Stelle (separat behoben), aber dieser fehlende State-
  -- Update ist trotzdem ein echter Bug im Rate-Limiting selbst und wird
  -- hier korrigiert, damit view.interval tatsaechlich wirksam ist.
  if should_force_redraw(session) then
    state.last_draw = now
    state.last_force = now
    return true, state, now
  end
  if not due then
    return false, state, now
  end

  local snapshot = serialize_model(model)
  local changed = snapshot ~= state.last_snapshot
  state.last_snapshot = snapshot
  state.last_draw = now

  if changed or force_due then
    state.last_force = now
    return true, state, now
  end
  return false, state, now
end

local function safe_size(mon)
  local w, h = ui.getSize(mon)
  if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then
    return nil, nil, "invalid-monitor-size"
  end
  return w, h
end

local function unpack_input_args(monitor_name, x, y)
  if type(monitor_name) == "table" then
    local event = monitor_name
    if event[1] == "monitor_touch" then
      return event[2], event[3], event[4], event[1]
    end
    return nil, nil, nil, tostring(event[1] or "unknown")
  end
  return monitor_name, x, y, "direct"
end

function M.new(opts)
  local self = {
    views = opts.views or {},
    view_order = opts.view_order or { "overview", "rt", "energy" },
    on_action = opts.on_action,
    sessions = sessions_lib.new({ view_order = opts.view_order })
  }
  return setmetatable(self, { __index = M })
end

function M:render(monitors, data_map)
  data_map = data_map or {}
  self.sessions:bind_or_update(monitors or {}, nil, self.view_order)
  local rendered = {}

  for _, session in ipairs(self.sessions:get_sessions()) do
    local view_key = self.sessions:resolve_view_key(session)
    local view = self.views[view_key]
    local w, h, size_err = safe_size(session.mon)

    if size_err then
      self.sessions:note_render_failure(session, size_err)
      rendered[#rendered + 1] = { ok = false, view = view_key, monitor = session.name, role = session.role, id = session.id, error = size_err }
      goto continue
    end

    if view and view.render then
      local model = data_map[view_key] or {}
      local do_render = should_render_view(session, view_key, view, model)
      if not do_render then
        -- Kein neuer Draw noetig (Model unveraendert, Intervall nicht
        -- abgelaufen, kein Force-Redraw faellig). WICHTIG: hier bewusst
        -- KEIN self.sessions:note_render_success(session) — das wuerde
        -- session.dirty faelschlich auf false zuruecksetzen, obwohl gar
        -- nicht neu gezeichnet wurde. session.dirty/first_draw_done bleiben
        -- unveraendert, bis tatsaechlich gerendert wird.
        rendered[#rendered + 1] = { ok = true, view = view_key, monitor = session.name, role = session.role, id = session.id, skipped = true }
        goto continue
      end
      local ok, err = pcall(function()
        ui.begin_frame(session.mon)
        if should_hard_clear(session) then ui.clear(session.mon) end
        view.render(session.mon, model)
      end)

      if ok then
        self.sessions:note_render_success(session)
      else
        self.sessions:note_render_failure(session, err)
        render_error(session.mon, w, h, "RENDER ERROR", err)
      end

      rendered[#rendered + 1] = { ok = ok, view = view_key, monitor = session.name, role = session.role, id = session.id, error = ok and nil or tostring(err) }
    else
      local err = "view-missing-or-no-render"
      self.sessions:note_render_failure(session, err)
      render_error(session.mon, w, h, "VIEW ERROR", "Missing view: " .. tostring(view_key))
      rendered[#rendered + 1] = { ok = false, view = view_key, monitor = session.name, role = session.role, id = session.id, error = err }
    end

    local badge_view = self.sessions:resolve_view_key(session)
    -- Badge-Status (oben links) muss den echten globalen Alarmstatus zeigen,
    -- unabhängig davon welche View gerade auf diesem Monitor sichtbar ist —
    -- vorher war der Status hier fest auf "OK"/"LIMITED" hartcodiert, sodass
    -- der Monitor auch bei aktiven CRITICAL/WARN-Alarmen dauerhaft grün/gelb
    -- blieb statt den Zustand widerzuspiegeln. Quelle: overview.alert_counts
    -- (von ui_controller.build_models() aus alert_service:get_counts()),
    -- das einzige Model das die globalen Zählwerte mitführt — ein eigenes
    -- "alerts"-Model existiert in data_map nicht.
    local overview_data = data_map.overview or {}
    local counts = overview_data.alert_counts or {}
    local crit_count = tonumber(counts.CRITICAL) or 0
    local warn_count = tonumber(counts.WARN) or 0
    local badge_status
    if crit_count > 0 then
      badge_status = "EMERGENCY"
    elseif warn_count > 0 then
      badge_status = "WARNING"
    else
      badge_status = "OK"
    end
    -- UI-Redesign Schritt 1 (2026-07-01): layout.badge_row() statt direktem
    -- ui.badge() — garantiert, dass die Badge-Leiste NIE über die
    -- Monitorbreite hinauslaeuft. Vorher fest verdrahteter Einzel-Badge, der
    -- bei sehr schmalen Monitoren abgeschnitten werden konnte ohne Fallback.
    local wm, _ = ui.getSize(session.mon)
    wm = wm or 26
    if self.sessions:is_primary(session) then
      layout.badge_row(session.mon, 2, 1, math.max(6, wm - 3), {
        { label = (badge_view or "PRIMARY"):upper(), short = (badge_view or "PRI"):upper():sub(1, 4), status = badge_status, priority = 1 },
      })
    else
      -- AUX: zeige aktuelle View + Hinweis dass Touch wechselt
      layout.badge_row(session.mon, 2, 1, math.max(6, wm - 3), {
        { label = "AUX:" .. (badge_view or "?"):upper(), short = "AUX", status = badge_status, priority = 1 },
      })
    end

    -- Bei aktiven CRITICAL/WARN-Alarmen die dringendste Meldung als Text
    -- unter dem Badge anzeigen, damit man sie sieht ohne erst manuell auf
    -- die "alerts"-View umschalten zu müssen (Touch-Zyklus). Quelle ist
    -- overview.alert_rows (bis zu 4 Einträge, sortiert nach Dringlichkeit
    -- in ui_controller.build_models() über alert_service:get_top_critical()).
    if badge_status ~= "OK" then
      local rows = overview_data.alert_rows or {}
      local top_row = rows[1]
      if top_row then
        local w2 = select(1, ui.getSize(session.mon)) or 30
        local alert_text = widgets.fit(
          tostring(top_row.title or "Alert") .. ": " .. tostring(top_row.text or ""),
          math.max(10, w2 - 3)
        )
        ui.text(session.mon, 2, 2, alert_text, 0xFFFFFF, 0x000000)
      end
    end
    -- Feature (2026-07-06): sichtbare [<]/[>]-Navigations-Buttons am
    -- unteren Bildschirmrand fuer AUX-Monitore. Vorher gab es UEBERHAUPT
    -- KEINE sichtbaren Buttons — jeder Touch irgendwo auf dem Bildschirm
    -- loeste einen Vorwaerts-Zyklus aus, ohne jegliche visuelle
    -- Kennzeichnung dass das ueberhaupt moeglich ist. Jetzt: expliziter
    -- Footer mit "< ZURUECK" links / "WEITER >" rechts, beide mit
    -- funktionierenden Touch-Zonen, gespeichert in self.aux_nav_hitboxes.
    if not self.sessions:is_primary(session) then
      local wm2, footer_h = ui.getSize(session.mon)
      wm2 = wm2 or 26
      footer_h = footer_h or 6
      local left_text = "< ZURUECK"
      local right_text = "WEITER >"
      ui.text(session.mon, 2, footer_h, widgets.fit(left_text, math.floor(wm2 / 2) - 1), 0xFFFFFF, 0x000000)
      local right_x = math.max(2, wm2 - #right_text - 1)
      ui.text(session.mon, right_x, footer_h, right_text, 0xFFFFFF, 0x000000)
      self.aux_nav_hitboxes = self.aux_nav_hitboxes or {}
      self.aux_nav_hitboxes[session.name] = {
        prev = { x1 = 2, x2 = 2 + #left_text - 1, y = footer_h },
        next = { x1 = right_x, x2 = right_x + #right_text - 1, y = footer_h },
      }
    end
    ::continue::
  end

  self.last_render_results = rendered
  return rendered
end

function M:handle_input(monitor_name, x, y)
  local input_kind
  monitor_name, x, y, input_kind = unpack_input_args(monitor_name, x, y)
  if not monitor_name then
    self.last_input = { monitor = "-", x = x, y = y, view = "-", input = input_kind, hit = nil, dispatched = false, handled = false, ignored = true }
    return
  end

  local session = self.sessions:get_session_by_name(monitor_name)
  if not session then
    self.last_input = { monitor = monitor_name, x = x, y = y, view = "-", input = input_kind, hit = nil, dispatched = false, handled = false, missing_session = true }
    return
  end

  local view_key = self.sessions:resolve_view_key(session)

  -- AUX-Monitor (nicht locked) → Touch auf [<]/[>]-Buttons wechselt View
  if not session.locked then
    -- Fix (2026-07-06): vorher loeste JEDER Touch irgendwo auf dem
    -- Bildschirm einen Vorwaerts-Zyklus aus, ohne dass sichtbare Buttons
    -- existierten. Jetzt: nur Touch auf die tatsaechlich sichtbaren
    -- [<]/[>]-Buttons (Koordinaten aus self.aux_nav_hitboxes, gesetzt beim
    -- letzten Render) loest einen Wechsel aus, mit korrekter Richtung.
    local hitboxes = self.aux_nav_hitboxes and self.aux_nav_hitboxes[session.name]
    local direction = nil
    if hitboxes then
      if hitboxes.prev and y == hitboxes.prev.y and x >= hitboxes.prev.x1 and x <= hitboxes.prev.x2 then
        direction = -1
      elseif hitboxes.next and y == hitboxes.next.y and x >= hitboxes.next.x1 and x <= hitboxes.next.x2 then
        direction = 1
      end
    end
    if not direction then
      self.last_input = { monitor = session.name, x = x, y = y, view = view_key, input = input_kind, hit = nil, dispatched = false, handled = false, outside_nav_buttons = true }
      return
    end
    local new_view = self.sessions.cycle_aux_view(self.sessions, session, direction)
    local payload = {
      monitor = session.name, x = x, y = y,
      view = view_key, new_view = new_view,
      input = input_kind, hit = nil, dispatched = true, handled = true,
      aux_cycle = true
    }
    self.last_input = payload
    self.sessions:note_input(session, payload)
    return
  end

  local view = self.views[view_key]
  if not (view and view.hit_test and self.on_action) then
    local payload = { monitor = session.name, x = x, y = y, view = view_key, input = input_kind, hit = nil, dispatched = false, handled = false }
    self.last_input = payload
    self.sessions:note_input(session, payload)
    return
  end

  local ok, hit = pcall(view.hit_test, session.mon, x, y)
  local payload = { monitor = session.name, x = x, y = y, view = view_key, input = input_kind, hit = ok and hit or nil, dispatched = false, handled = false }

  if not ok or type(hit) ~= "table" or not hit.type then
    payload.clears_hitboxes = true
    self.last_input = payload
    self.sessions:note_input(session, payload)
    return
  end

  local action = {}
  for k, v in pairs(hit) do action[k] = v end
  action.monitor = session.name
  action.view = view_key

  local dispatched, handled_or_err = pcall(self.on_action, action)
  payload.action = action.type
  payload.dispatched = dispatched
  payload.handled = dispatched and (handled_or_err ~= false) or false
  payload.dispatch_error = dispatched and nil or tostring(handled_or_err)

  self.last_input = payload
  self.sessions:note_input(session, payload)
end

return M
