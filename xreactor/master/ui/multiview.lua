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
    if self.sessions:is_primary(session) then
      ui.badge(session.mon, 2, 1, widgets.fit((badge_view or "PRIMARY"):upper(), 20), "LIMITED")
    else
      ui.badge(session.mon, 2, 1, widgets.fit(("AUX " .. tostring(badge_view or "overview")):upper(), 20), "OK")
    end
    ::continue::
  end

  self.last_render_results = rendered
  return rendered
end

function M:handle_input(monitor_name, x, y)
  local session = self.sessions:get_session_by_name(monitor_name)
  if not session then return end

  local view_key = self.sessions:resolve_view_key(session)
  local view = self.views[view_key]
  if not (view and view.hit_test and self.on_action) then
    local payload = { monitor = session.name, x = x, y = y, view = view_key, hit = nil, dispatched = false, handled = false }
    self.last_input = payload
    self.sessions:note_input(session, payload)
    return
  end

  local ok, hit = pcall(view.hit_test, session.mon, x, y)
  local payload = { monitor = session.name, x = x, y = y, view = view_key, hit = ok and hit or nil, dispatched = false, handled = false }

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
