local ui = require("core.ui")
local widgets = require("master.ui.widgets")
local sessions_lib = require("master.monitor_sessions")

local M = {}

local PRIMARY_VIEWS = { "overview", "rt", "energy" }

local function resolve_aux_view(session, view_order)
  if session.view_key and session.view_key ~= "aux" then
    return session.view_key
  end
  return (view_order and view_order[1]) or "overview"
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
    if idx <= 3 then
      session.view_key = PRIMARY_VIEWS[idx]
      session.locked = true
    else
      session.view_key = resolve_aux_view(session, self.view_order)
      session.locked = false
    end

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
        session.dirty = false
        session.first_draw_done = true
        session.last_error = nil
      else
        session.last_error = tostring(err)
        self.sessions:mark_dirty(session, err)
        ui.clear(session.mon)
        ui.panel(session.mon, 1, 1, w, h, "RENDER ERROR", "EMERGENCY")
        ui.text(session.mon, 2, 3, widgets.fit(tostring(err), math.max(10, w - 3)), 0xFFFFFF, 0x000000)
      end
      rendered[#rendered + 1] = { ok = ok, view = view_key, monitor = session.name, role = session.role, id = session.id, error = ok and nil or tostring(err) }
    else
      session.last_error = "view-missing-or-no-render"
      self.sessions:mark_dirty(session, session.last_error)
      ui.clear(session.mon)
      ui.panel(session.mon, 1, 1, w, h, "VIEW ERROR", "EMERGENCY")
      ui.text(session.mon, 2, 3, widgets.fit("Missing view: " .. tostring(view_key), math.max(10, w - 3)), 0xFFFFFF, 0x000000)
      rendered[#rendered + 1] = { ok = false, view = view_key, monitor = session.name, role = session.role, id = session.id, error = session.last_error }
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
    self.last_input = { monitor = session.name, x = x, y = y, view = view_key, hit = nil, dispatched = false, handled = false }
    return
  end

  local ok, hit = pcall(view.hit_test, session.mon, x, y)
  self.last_input = { monitor = session.name, x = x, y = y, view = view_key, hit = ok and hit or nil }
  session.last_input = self.last_input
  session.hitboxes = type(hit) == "table" and { hit } or (session.hitboxes or {})
  if not ok or type(hit) ~= "table" or not hit.type then return end

  local action = {}
  for k, v in pairs(hit) do action[k] = v end
  action.monitor = session.name
  action.view = view_key
  local dispatched, handled_or_err = pcall(self.on_action, action)
  self.last_input.action = action.type
  self.last_input.dispatched = dispatched
  self.last_input.handled = dispatched and (handled_or_err ~= false) or false
  self.last_input.dispatch_error = dispatched and nil or tostring(handled_or_err)
end

return M
