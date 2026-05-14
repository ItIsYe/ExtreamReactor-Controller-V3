local ui = require("core.ui")
local widgets = require("master.ui.widgets")

local M = {}

local PRIMARY_ROLE_MAP = { "overview", "rt", "energy" }
local ROLE_LABELS = {
  overview = "MON1 UEBERSICHT",
  rt = "MON2 RT-FLOTTE",
  energy = "MON3 ENERGY/RES"
}

local function primary_view(index, view_order)
  local role = PRIMARY_ROLE_MAP[index]
  if role then return role end
  return (view_order and view_order[1]) or "overview"
end

function M.new(opts)
  local self = {
    views = opts.views or {},
    view_order = opts.view_order or { "overview", "rt", "energy" },
    layout = { monitors = {} },
    monitor_index = {},
    monitor_list = {},
    on_action = opts.on_action
  }
  return setmetatable(self, { __index = M })
end

function M:update_monitors(monitors)
  self.monitor_list = monitors or {}
  self.monitor_index = {}

  for idx, mon in ipairs(self.monitor_list) do
    self.monitor_index[mon.name] = mon
    self.monitor_index[mon.id or mon.name] = mon
    self.monitor_index[tostring(mon.mon)] = mon
    local id = mon.id or mon.name
    local prior = self.layout.monitors[id] or {}
    local role_view = primary_view(idx, self.view_order)

    if idx <= 3 then
      prior.mode = "primary_fixed"
      prior.view = role_view
      prior.locked = true
      prior.role = role_view
      prior.reason = "primary-monitor-role"
      prior.last_frame_size = prior.last_frame_size or nil
    else
      prior.mode = "aux_cycle"
      if not prior.view or prior.view == prior.role then prior.view = role_view end
      prior.locked = false
      prior.role = "aux"
      prior.reason = "operator-cycle"
    end

    self.layout.monitors[id] = prior
  end
end

function M:render(monitors, data_map)
  self:update_monitors(monitors)
  local rendered = {}

  for idx, mon_entry in ipairs(self.monitor_list) do
    local id = mon_entry.id or mon_entry.name
    local layout = self.layout.monitors[id] or { view = primary_view(idx, self.view_order) }
    local view_key = layout.view or primary_view(idx, self.view_order)
    local view = self.views[view_key]
    local w, h = ui.getSize(mon_entry.mon)
    local size_key = (w and h) and (("%dx%d"):format(w, h)) or "unknown"
    local requires_full_clear = layout.last_frame_size ~= size_key

    if view and view.render then
      local ok, err = pcall(function()
        ui.begin_frame(mon_entry.mon)
        if requires_full_clear then
          ui.clear(mon_entry.mon)
        end
        view.render(mon_entry.mon, data_map[view_key] or {})
      end)
      rendered[#rendered + 1] = {
        ok = ok,
        view = view_key,
        monitor = mon_entry.name,
        role = layout.role,
        id = id,
        error = ok and nil or tostring(err)
      }
      if not ok then
        ui.clear(mon_entry.mon)
        ui.panel(mon_entry.mon, 1, 1, w or select(1, ui.getSize(mon_entry.mon)), h or select(2, ui.getSize(mon_entry.mon)), "RENDER ERROR", "EMERGENCY")
        ui.text(mon_entry.mon, 2, 3, widgets.fit(tostring(err), math.max(10, (w or select(1, ui.getSize(mon_entry.mon)) or 20) - 3)), 0xFFFFFF, 0x000000)
        mon_entry.last_render_error = tostring(err)
      else
        mon_entry.last_render_error = nil
        layout.last_frame_size = size_key
      end
    else
      rendered[#rendered + 1] = {
        ok = false,
        view = view_key,
        monitor = mon_entry.name,
        role = layout.role,
        id = id,
        error = "view-missing-or-no-render"
      }
      ui.clear(mon_entry.mon)
      ui.panel(mon_entry.mon, 1, 1, w or select(1, ui.getSize(mon_entry.mon)), h or select(2, ui.getSize(mon_entry.mon)), "VIEW ERROR", "EMERGENCY")
      ui.text(mon_entry.mon, 2, 3, widgets.fit("Missing view: " .. tostring(view_key), math.max(10, (w or select(1, ui.getSize(mon_entry.mon)) or 20) - 3)), 0xFFFFFF, 0x000000)
    end

    if w then
      if idx <= 3 then
        local fix_x = math.max(2, w - 8)
        local role_label = widgets.fit(ROLE_LABELS[view_key] or "PRIMARY", math.max(10, fix_x - 4))
        ui.badge(mon_entry.mon, 2, 1, role_label, "LIMITED")
        ui.badge(mon_entry.mon, fix_x, 1, "FIX", "LIMITED")
      else
        ui.badge(mon_entry.mon, math.max(2, w - 18), 1, "AUX VIEW", "OK")
        widgets.layout_button(mon_entry.mon, math.max(2, w - 11), 1, "LAYOUT", "LIMITED")
      end
    end
  end
  self.last_render_results = rendered
  return rendered
end

function M:handle_input(monitor_name, x, y)
  local mon = self.monitor_index[monitor_name] or self.monitor_index[tostring(monitor_name)]
  if not mon then return end
  local state = self.layout.monitors[mon.id or mon.name]
  if not state then return end

  local w = select(1, ui.getSize(mon.mon))
  if (not state.locked) and w and y == 1 and x >= math.max(2, w - 11) then
    local current = 1
    for i, key in ipairs(self.view_order) do
      if key == state.view then current = i break end
    end
    state.view = self.view_order[(current % #self.view_order) + 1]
    return
  end

  local view_key = state.view or self.view_order[1] or "overview"
  local view = self.views[view_key]
  if not (view and view.hit_test and self.on_action) then return end

  local ok, hit = pcall(view.hit_test, mon.mon, x, y)
  self.last_input = { monitor = mon.name, x = x, y = y, view = view_key, hit = ok and hit or nil, hit_error = ok and nil or tostring(hit) }
  if not ok or type(hit) ~= "table" then return end

  if hit.type then
    local action = {}
    for k, v in pairs(hit) do action[k] = v end
    action.monitor = mon.name
    action.view = view_key
    local dispatched, handled_or_err = pcall(self.on_action, action)
    self.last_input.action = action.type
    self.last_input.dispatched = dispatched
    self.last_input.handled = dispatched and (handled_or_err ~= false) or false
    self.last_input.dispatch_error = dispatched and nil or tostring(handled_or_err)
    if not dispatched and mon then mon.last_input_error = tostring(handled_or_err) end
  end
end

return M
