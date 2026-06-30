local ui = require("core.ui")
local widgets = require("master.ui.widgets")
local sessions_lib = require("master.monitor_sessions")

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
      local ok, err = pcall(function()
        ui.begin_frame(session.mon)
        if should_hard_clear(session) then ui.clear(session.mon) end
        view.render(session.mon, data_map[view_key] or {})
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
    if self.sessions:is_primary(session) then
      ui.badge(session.mon, 2, 1, widgets.fit((badge_view or "PRIMARY"):upper(), 20), badge_status)
    else
      -- AUX: zeige aktuelle View + Hinweis dass Touch wechselt
      local aux_label = "AUX:" .. (badge_view or "?"):upper()
      ui.badge(session.mon, 2, 1, widgets.fit(aux_label, 22), badge_status)
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

  -- AUX-Monitor (nicht locked) → Touch wechselt View im Zyklus
  if not session.locked then
    local new_view = self.sessions.cycle_aux_view(self.sessions, session)
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
