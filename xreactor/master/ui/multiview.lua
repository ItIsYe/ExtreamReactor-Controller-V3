local ui_router = require("core.ui_router")
local ui = require("core.ui")
local colors = require("shared.colors")
local utils = require("core.utils")
local widgets = require("master.ui.widgets")

local multiview = {}

local function now_ms()
  return os.epoch("utc")
end

local function ensure_table(value)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

local function build_snapshot(data, extra)
  return textutils.serialize({ data = data or {}, extra = extra or {} })
end

local function sorted_view_keys(views)
  local keys = {}
  for key in pairs(views or {}) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

function multiview.new(opts)
  opts = opts or {}
  local layout_path = opts.layout_path
  local layout_defaults = { version = 1, monitors = {} }
  local layout = layout_defaults
  if layout_path then
    layout = utils.load_config(layout_path, layout_defaults)
  end
  local self = {
    layout_path = layout_path,
    layout = layout,
    views = opts.views or {},
    view_order = opts.view_order or sorted_view_keys(opts.views),
    monitor_states = {},
    monitor_index = {},
    on_action = opts.on_action
  }
  return setmetatable(self, { __index = multiview })
end

function multiview:save_layout()
  if not self.layout_path then
    return
  end
  utils.write_config(self.layout_path, self.layout)
end

local function default_view_for_index(index, view_order)
  local map = {
    "overview",
    "energy",
    "rt",
    "resources",
    "alarms"
  }
  local key = map[index]
  if key then
    return key
  end
  if view_order and view_order[index] then
    return view_order[index]
  end
  return (view_order and view_order[1]) or "overview"
end

function multiview:apply_defaults(monitors)
  local list = monitors or {}
  local count = #list
  local order_lookup = {}
  for idx, key in ipairs(self.view_order) do
    order_lookup[key] = idx
  end
  for idx, mon in ipairs(list) do
    local id = mon.id or mon.name or tostring(idx)
    local entry = self.layout.monitors[id] or {}
    if not entry.locked then
      if count <= 1 then
        entry.mode = "router"
        entry.view = self.view_order[1] or "overview"
      else
        entry.mode = "fixed"
        local default_key = default_view_for_index(idx, self.view_order)
        if order_lookup[default_key] then
          entry.view = default_key
        else
          entry.view = self.view_order[1] or "overview"
        end
      end
      self.layout.monitors[id] = entry
    end
  end
end

function multiview:update_monitors(monitors)
  monitors = monitors or {}
  local index = {}
  for _, mon in ipairs(monitors) do
    if mon.name then
      index[mon.name] = mon
    end
  end
  local signature = {}
  for _, mon in ipairs(monitors) do
    table.insert(signature, mon.id or mon.name)
  end
  local signature_key = table.concat(signature, "|")
  if signature_key ~= self.monitor_signature then
    self.monitor_signature = signature_key
    self.monitor_list = monitors
    self.monitor_index = index
    self:apply_defaults(monitors)
    for _, mon in ipairs(monitors) do
      local state = self.monitor_states[mon.id] or {}
      state.clear_next = true
      self.monitor_states[mon.id] = state
    end
  end
end

local function build_pages(views, view_order, data_map)
  local pages = {}
  for _, key in ipairs(view_order) do
    local view = views[key]
    if view then
      table.insert(pages, {
        name = view.label or key,
        key = key,
        render = function(mon, model)
          view.render(mon, model.data or {})
        end
      })
    end
  end
  return pages
end

function multiview:ensure_router(state, mon, mode, view_key, data_map)
  local needs_new = false
  if not state.router then
    needs_new = true
  elseif mode ~= state.mode or view_key ~= state.view_key then
    needs_new = true
  end
  if needs_new then
    local pages
    if mode == "router" then
      pages = build_pages(self.views, self.view_order, data_map)
    else
      local view = self.views[view_key]
      pages = {
        {
          name = view and view.label or view_key,
          key = view_key,
          render = function(target, model)
            if view then
              view.render(target, model.data or {})
            end
          end
        }
      }
    end
    state.router = ui_router.new(mon, {
      pages = pages,
      interval = 0.1,
      key_prev = { [keys.left] = true, [keys.pageUp] = true },
      key_next = { [keys.right] = true, [keys.pageDown] = true }
    })
    state.mode = mode
    state.view_key = view_key
    state.clear_next = true
  end
end

local function layout_menu_bounds(mon, view_order, has_router)
  local w, _ = mon.getSize()
  local width = math.min(24, w - 2)
  local height = #view_order + (has_router and 3 or 2)
  return {
    x = 2,
    y = 3,
    w = width,
    h = height
  }
end

function multiview:render_layout_menu(mon, state, layout, view_order)
  if not state.menu_open then
    state.menu_items = nil
    return
  end
  local bounds = layout_menu_bounds(mon, view_order, true)
  widgets.card(mon, bounds.x, bounds.y, bounds.w, bounds.h, "Layout", "OK")
  local row = bounds.y + 1
  local items = {}
  for _, key in ipairs(view_order) do
    local view = self.views[key]
    local label = view and view.label or key
    local active = layout.view == key and layout.mode == "fixed"
    local status = active and "OK" or "OFFLINE"
    ui.text(mon, bounds.x + 1, row, label, colors.get(status), colors.get("background"))
    table.insert(items, { type = "view", key = key, x1 = bounds.x, x2 = bounds.x + bounds.w - 1, y = row })
    row = row + 1
  end
  ui.text(mon, bounds.x + 1, row, "Router", colors.get(layout.mode == "router" and "OK" or "OFFLINE"), colors.get("background"))
  table.insert(items, { type = "mode", mode = "router", x1 = bounds.x, x2 = bounds.x + bounds.w - 1, y = row })
  row = row + 1
  local lock_label = layout.locked and "Lock: ON" or "Lock: OFF"
  ui.text(mon, bounds.x + 1, row, lock_label, colors.get(layout.locked and "WARNING" or "OK"), colors.get("background"))
  table.insert(items, { type = "lock", x1 = bounds.x, x2 = bounds.x + bounds.w - 1, y = row })
  state.menu_items = items
end

function multiview:render(monitors, data_map)
  data_map = data_map or {}
  self:update_monitors(monitors)
  local rendered = {}
  for _, mon_entry in ipairs(monitors or {}) do
    local id = mon_entry.id or mon_entry.name
    local state = self.monitor_states[id] or { last_render = {}, menu_open = false }
    self.monitor_states[id] = state
    local layout = ensure_table(self.layout.monitors[id])
    if not layout.view then
      layout.view = self.view_order[1] or "overview"
      layout.mode = layout.mode or "fixed"
      self.layout.monitors[id] = layout
    end
    self:ensure_router(state, mon_entry.mon, layout.mode, layout.view, data_map)
    local router = state.router
    local current_page = router and router:current()
    local current_key = current_page and (current_page.key or layout.view) or layout.view
    local view = self.views[current_key]
    local interval = view and view.interval or 1
    local now = now_ms()
    local last_render = state.last_render[current_key] or 0
    local should_render = state.menu_open or state.clear_next or (now - last_render >= interval * 1000)
    local view_model = data_map[current_key] or {}
    if should_render and mon_entry.mon then
      if state.clear_next then
        ui.clear(mon_entry.mon)
        state.clear_next = false
      end
      if router then
        router.interval = interval
        local snapshot = build_snapshot(view_model, {
          mode = layout.mode,
          view = layout.view,
          page = current_key,
          menu = state.menu_open
        })
        router:render(mon_entry.mon, { snapshot = snapshot, data = view_model })
        rendered[current_key] = true
      end
      state.last_render[current_key] = now
    end
    local w, _ = mon_entry.mon.getSize()
    local layout_x = math.max(2, w - 7)
    state.layout_button = widgets.layout_button(mon_entry.mon, layout_x, 1, "LAYOUT", "accent")
    self:render_layout_menu(mon_entry.mon, state, layout, self.view_order)
  end
  return rendered
end

local function hit(bounds, x, y)
  return bounds and y == bounds.y and x >= bounds.x1 and x <= bounds.x2
end

function multiview:handle_input(monitor_name, x, y)
  local mon_entry = self.monitor_index and self.monitor_index[monitor_name] or nil
  if not mon_entry then
    return
  end
  local id = mon_entry.id or mon_entry.name
  local state = self.monitor_states[id]
  if not state then
    return
  end
  local layout = ensure_table(self.layout.monitors[id])
  if state.layout_button and hit(state.layout_button, x, y) then
    state.menu_open = not state.menu_open
    state.clear_next = true
    return true
  end
  if state.menu_open and state.menu_items then
    for _, item in ipairs(state.menu_items) do
      if hit(item, x, y) then
        if item.type == "view" then
          layout.view = item.key
          layout.mode = "fixed"
        elseif item.type == "mode" then
          layout.mode = "router"
        elseif item.type == "lock" then
          layout.locked = not layout.locked
        end
        self.layout.monitors[id] = layout
        state.menu_open = false
        state.clear_next = true
        self:save_layout()
        return true
      end
    end
  end
  if state.router then
    local handled = state.router:handle_input({ "monitor_touch", monitor_name, x, y })
    if handled then
      return true
    end
  end
  local view_key = layout.view
  if layout.mode == "router" and state.router and state.router.current then
    local page = state.router:current()
    if page and page.key then
      view_key = page.key
    end
  end
  local view = self.views[view_key]
  if view and view.hit_test then
    local action = view.hit_test(mon_entry.mon, x, y)
    if action and self.on_action then
      self.on_action(action)
      return true
    end
  end
  return false
end

return multiview
