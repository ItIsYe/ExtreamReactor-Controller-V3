local ui = require("core.ui")
local widgets = require("master.ui.widgets")
local sessions_lib = require("master.monitor_sessions")

local M = {}

local PRIMARY_VIEWS = { "overview", "rt", "energy" }

local function resolve_aux_view(session, view_order)
  if session.view_key and session.view_key ~= "aux" then return session.view_key end
  return (view_order and view_order[1]) or "overview"
end

local function render_error(mon, w, h, title, message)
  ui.clear(mon)
  ui.panel(mon, 1, 1, w, h, title, "EMERGENCY")
  ui.text(mon, 2, 3, widgets.fit(tostring(message), math.max(10, w - 3)), 0xFFFFFF, 0x000000)
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
  self.sessions:bind_or_update(monitors or {}, nil, self.view_order)
  local rendered = {}

  for idx, session in ipairs(self.sessions:get_sessions()) do
    session.view_key = (idx <= 3) and PRIMARY_VIEWS[idx] or resolve_aux_view(session, self.view_order)
    session.locked = idx <= 3

    local view_key = session.view_key or "overview"
    local view = self.views[view_key]
    local w, h = ui.getSize(session.mon)
    local requires_full_clear = self.sessions:needs_full_clear(session)

    if view and view.render then
      local ok, err = pcall(function()
        ui.begin_frame(session.mon)
        if requires_full_clear then ui.clear(session.mon) end
        view.render(session.mon, data_map[view_key] or {})
      end)

      if ok then
        local render_hash = table.concat({ view_key, tostring(session.size_key), tostring(session.layout_key) }, "|")
        self.sessions:note_render_success(session, render_hash)
      else
        self.sessions:note_render_failure(session, err)
        render_error(session.mon, w, h, "RENDER ERROR", err)
      end

      rendered[#rendered + 1] = {
        ok = ok,
        view = view_key,
        monitor = session.name,
        role = session.role,
        id = session.id,
        error = ok and nil or tostring(err)
      }
    else
      local err = "view-missing-or-no-render"
      self.sessions:note_render_failure(session, err)
      render_error(session.mon, w, h, "VIEW ERROR", "Missing view: " .. tostring(view_key))
      rendered[#rendered + 1] = { ok = false, view = view_key, monitor = session.name, role = session.role, id = session.id, error = err }
    end

    if session.locked then
      ui.badge(session.mon, 2, 1, widgets.fit((session.view_key or "PRIMARY"):upper(), 20), "LIMITED")
    else
      ui.badge(session.mon, 2, 1, widgets.fit(("AUX " .. tostring(session.view_key or "overview")):upper(), 20), "OK")
    end
  end

  self.last_render_results = rendered
  return rendered
end

function M:handle_input(monitor_name, x, y)
  local session = self.sessions:get_session_by_name(monitor_name)
  if not session then return end

  local view_key = session.view_key or self.view_order[1] or "overview"
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
