local ui = require("core.ui")
local widgets = require("master.ui.widgets")

local M = {}

local PRIMARY_ROLE_MAP = { "overview", "rt", "energy" }
local ROLE_LABELS = {
  overview = "MON1 UEBERSICHT",
  rt = "MON2 RT",
  energy = "MON3 ENERGY"
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
    monitor_list = {}
  }
  return setmetatable(self, { __index = M })
end

function M:update_monitors(monitors)
  self.monitor_list = monitors or {}
  self.monitor_index = {}

  for idx, mon in ipairs(self.monitor_list) do
    self.monitor_index[mon.name] = mon
    local id = mon.id or mon.name
    local prior = self.layout.monitors[id] or {}
    local role_view = primary_view(idx, self.view_order)

    if idx <= 3 then
      prior.mode = "primary_fixed"
      prior.view = role_view
      prior.locked = true
      prior.role = role_view
      prior.reason = "primary-monitor-role"
    else
      prior.mode = prior.mode or "aux_cycle"
      prior.view = prior.view or role_view
      prior.locked = false
      prior.role = "aux"
      prior.reason = prior.reason or "operator-cycle"
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

    if view and view.render then
      ui.clear(mon_entry.mon)
      view.render(mon_entry.mon, data_map[view_key] or {})
      rendered[view_key] = true
    end

    local w = select(1, ui.getSize(mon_entry.mon))
    if w then
      if idx <= 3 then
        ui.badge(mon_entry.mon, math.max(2, w - 22), 1, ROLE_LABELS[view_key] or "PRIMARY", "LIMITED")
        ui.badge(mon_entry.mon, math.max(2, w - 12), 2, "FIX", "OFFLINE")
      else
        ui.badge(mon_entry.mon, math.max(2, w - 18), 1, "AUX VIEW", "OK")
        widgets.layout_button(mon_entry.mon, math.max(2, w - 7), 1, "LAYOUT", "accent")
      end
    end
  end

  return rendered
end

function M:handle_input(monitor_name, x, y)
  local mon = self.monitor_index[monitor_name]
  if not mon then return end
  local state = self.layout.monitors[mon.id or mon.name]
  if not state or state.locked then return end

  local w = select(1, ui.getSize(mon.mon))
  if w and y == 1 and x >= math.max(2, w - 7) then
    local current = 1
    for i, key in ipairs(self.view_order) do
      if key == state.view then
        current = i
        break
      end
    end
    state.view = self.view_order[(current % #self.view_order) + 1]
  end
end

return M
