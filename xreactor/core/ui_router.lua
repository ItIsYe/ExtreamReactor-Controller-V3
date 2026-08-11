local ui = require("core.ui")
local colors = require("shared.colors")

local router = {}

local function clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

function router.paginate(list, per_page, page)
  if type(list) ~= "table" then list = {} end
  local per = tonumber(per_page) or 1
  if per < 1 then per = 1 end
  local total = math.max(1, math.ceil(#list / per))
  local current = clamp(page or 1, 1, total)
  return { page = current, total = total,
    start_index = (current - 1) * per + 1, end_index = math.min(#list, current * per) }
end

local function wrapped_peripheral_name(mon)
  if type(mon) ~= "table" or type(peripheral) ~= "table" or type(peripheral.getName) ~= "function" then return nil end
  local ok, name = pcall(peripheral.getName, mon)
  if ok and type(name) == "string" and name ~= "" then return name end
  return nil
end

function router.new(mon_or_opts, opts)
  local target = nil
  if opts == nil and type(mon_or_opts) == "table" and mon_or_opts.pages then opts = mon_or_opts else target = mon_or_opts end
  opts = opts or {}
  local list_key_prev = opts.list_key_prev
  local list_key_next = opts.list_key_next
  if not list_key_prev then
    list_key_prev = {}
    if type(keys) == "table" then list_key_prev[keys.up] = true; list_key_prev[keys.pageUp] = true end
  end
  if not list_key_next then
    list_key_next = {}
    if type(keys) == "table" then list_key_next[keys.down] = true; list_key_next[keys.pageDown] = true end
  end
  local self = {
    mon = target, title = opts.title, pages = opts.pages or {}, index = opts.index or 1,
    last_snapshot = nil,
    ui_diag = { frames_requested = 0, frames_committed = 0, frames_skipped = 0,
      full_clears = 0, render_errors = 0, last_render_ms = 0, foreign_monitor_touches = 0 },
    error_title = opts.error_title or "UI RENDER ERROR", on_render_error = opts.on_render_error,
    monitor_name = opts.monitor_name,
    last_render_page_index = nil, last_render_mon = nil, last_render_mon_name = nil,
    last_render_model = nil,
    last_render_w = nil, last_render_h = nil, last_render_scale = nil,
    shared_backbuffer = nil, footer = { prev = nil, next = nil, indicator = nil },
    list_controls = nil, key_prev = opts.key_prev, key_next = opts.key_next,
    list_key_prev = list_key_prev, list_key_next = list_key_next
  }
  return setmetatable(self, { __index = router })
end

function router:set_monitor_name(name)
  if name ~= nil and type(name) ~= "string" then return false end
  if self.monitor_name ~= name then self.monitor_name = name; self.last_render_mon_name = nil end
  return true
end

-- Force the next frame to rebuild all geometry derived from the render
-- target. This is required when an owner replaces a window backbuffer (for
-- example after a monitor resize or text-scale change): the model snapshot
-- may still be identical even though the new target has never been drawn.
function router:invalidate_layout()
  self.last_snapshot = nil
  self.last_render_mon = nil
  self.last_render_mon_name = nil
  self.last_render_page_index = nil
  self.last_render_w, self.last_render_h, self.last_render_scale = nil, nil, nil
  self.footer = { prev = nil, next = nil, indicator = nil }
  self.list_controls = nil
  self.shared_backbuffer = nil
end

function router:get_diagnostics()
  return {
    error_count = self.error_count or 0, last_error = self.last_error,
    transition_count = self.transition_count or 0,
    frames_requested = self.ui_diag.frames_requested, frames_committed = self.ui_diag.frames_committed,
    frames_skipped = self.ui_diag.frames_skipped, full_clears = self.ui_diag.full_clears,
    render_errors = self.ui_diag.render_errors, last_render_ms = self.ui_diag.last_render_ms,
    foreign_monitor_touches = self.ui_diag.foreign_monitor_touches,
    monitor_name = self.monitor_name or self.last_render_mon_name,
  }
end

function router:count() return #self.pages end
function router:current() return self.pages[self.index] end
function router:set(index)
  local total = math.max(1, #self.pages)
  local next_index = clamp(index, 1, total)
  if next_index ~= self.index then self.index = next_index; self.last_snapshot = nil end
end
function router:next() local total = math.max(1, #self.pages); local n = self.index + 1; if n > total then n = 1 end; self:set(n) end
function router:prev() local total = math.max(1, #self.pages); local n = self.index - 1; if n < 1 then n = total end; self:set(n) end

-- Navigation must never wait behind a fresh role model, registry scan or
-- peripheral sample. Redraw the newly selected page from the last committed
-- model immediately; the UI service will refresh the data on its next normal
-- tick. Window targets are hidden for the short redraw to avoid tearing.
function router:redraw_cached()
  local mon = self.last_render_mon
  if not mon then return false end
  local buffered = type(mon.setVisible) == "function"
  if buffered then pcall(mon.setVisible, false) end
  local ok = pcall(self.render, self, mon, self.last_render_model)
  if buffered then
    pcall(mon.setVisible, true)
    if type(mon.redraw) == "function" then pcall(mon.redraw) end
  end
  return ok
end

local function navigate_and_redraw(self, direction)
  if direction == "prev" then self:prev() else self:next() end
  local redrawn = self:redraw_cached()
  return true, redrawn and "page_navigation_redrawn" or "page_navigation"
end

-- CC:Tweaked already marks keyboard auto-repeat in the third `key` event
-- field (`is_held`).  A time-based debounce cannot distinguish that from
-- separate, intentional inputs: it also swallowed quick monitor taps and a
-- deliberate direction change (for example NEXT followed by PREV).  Only
-- suppress the event type which can actually be an automatic repeat.
local function key_is_repeat(event)
  return event and event[3] == true
end

local function monitor_touch_matches(self, event)
  if event[1] ~= "monitor_touch" then return true end
  local expected = self.monitor_name or self.last_render_mon_name
  if expected == nil then return true end
  if event[2] == expected then return true end
  self.ui_diag.foreign_monitor_touches = (self.ui_diag.foreign_monitor_touches or 0) + 1
  return false
end

function router:handle_input(event)
  if not event then return end
  local kind = event[1]
  if kind == "monitor_touch" and not monitor_touch_matches(self, event) then
    -- Consume a foreign monitor event so caller-side page handlers cannot
    -- receive the same coordinates after the router rejected navigation.
    return true
  end
  if kind == "key" then
    local key = event[2]
    if self.key_prev and self.key_prev[key] then
      if key_is_repeat(event) then return true, "key_repeat" end
      return navigate_and_redraw(self, "prev")
    end
    if self.key_next and self.key_next[key] then
      if key_is_repeat(event) then return true, "key_repeat" end
      return navigate_and_redraw(self, "next")
    end
    local list = self.list_controls
    if list then
      if self.list_key_prev and self.list_key_prev[key] and list.on_prev then list.on_prev(); return true end
      if self.list_key_next and self.list_key_next[key] and list.on_next then list.on_next(); return true end
    end
  elseif kind == "monitor_touch" or kind == "mouse_click" then
    local x, y = event[3], event[4]
    local prev = self.footer.prev
    if prev and y == prev.y and x >= prev.x1 and x <= prev.x2 then return navigate_and_redraw(self, "prev") end
    local next_btn = self.footer.next
    if next_btn and y == next_btn.y and x >= next_btn.x1 and x <= next_btn.x2 then return navigate_and_redraw(self, "next") end
    local list = self.list_controls
    if list then
      local list_prev = list.prev
      if list_prev and y == list_prev.y and x >= list_prev.x1 and x <= list_prev.x2 then if list.on_prev then list.on_prev() end; return true end
      local list_next = list.next
      if list_next and y == list_next.y and x >= list_next.x1 and x <= list_next.x2 then if list.on_next then list.on_next() end; return true end
    end
  end
  return false
end

local function prepare_render_target(self, mon, width, height)
  if type(mon) ~= "table" or type(mon.setVisible) == "function" then return mon, false, false end
  if type(window) ~= "table" or type(window.create) ~= "function" or type(width) ~= "number" or type(height) ~= "number" or width < 1 or height < 1 then
    self.shared_backbuffer = nil; return mon, false, false
  end
  local cached = self.shared_backbuffer
  local created = false
  if not cached or cached.parent ~= mon or cached.width ~= width or cached.height ~= height or type(cached.target) ~= "table" then
    local ok, target = pcall(window.create, mon, 1, 1, width, height, false)
    if not ok or not target then self.shared_backbuffer = nil; return mon, false, false end
    cached = { parent = mon, width = width, height = height, target = target }
    self.shared_backbuffer = cached; created = true; ui.invalidate(target)
  end
  pcall(cached.target.setVisible, false)
  return cached.target, true, created
end

local function publish_render_target(target, buffered)
  if not buffered or not target then return end
  pcall(target.setVisible, true)
  if type(target.redraw) == "function" then pcall(target.redraw) end
end

local function build_snapshot(page_name, model)
  local payload = model and model.snapshot ~= nil and { page = page_name or "", snapshot = model.snapshot }
    or { page = page_name or "", model = model or {} }
  if textutils and textutils.serialize then local ok, result = pcall(textutils.serialize, payload); if ok then return result end end
  return tostring(payload)
end

local function page_footer_zones(width, height, page_footer)
  local w, h = tonumber(width), tonumber(height)
  if not w or not h or w < 1 or h < 1 then return nil, nil end
  local y = h
  if type(page_footer) == "table" and type(page_footer.left) == "table"
      and type(page_footer.right) == "table"
      and tonumber(page_footer.left.y) == tonumber(page_footer.right.y) then
    y = clamp(tonumber(page_footer.left.y) or h, 1, h)
  end
  local left_end = math.max(1, math.floor(w / 3))
  local right_start = math.min(w, math.floor((w * 2) / 3) + 1)
  return { x1 = 1, x2 = left_end, y = y }, { x1 = right_start, x2 = w, y = y }
end

function router:render_list_controls(mon, opts)
  if not mon then return end
  opts = opts or {}
  local _, h = ui.getSize(mon); if not h then return end
  local page, total, label = opts.page or 1, opts.total or 1, opts.label or "List"
  local x, y = opts.x or 2, opts.y or (h - 1); if y < 1 then y = 1 end
  local text = ("< %s %d/%d >"):format(label, page, total)
  ui.text(mon, x, y, text, colors.get("text"), colors.get("background"))
  self.list_controls = { prev = { x1 = x, x2 = x + 1, y = y },
    next = { x1 = x + #text - 1, x2 = x + #text - 1, y = y }, on_prev = opts.on_prev, on_next = opts.on_next }
  return self.list_controls
end

function router:render(mon, model)
  self.ui_diag.frames_requested = self.ui_diag.frames_requested + 1
  if not mon then
    self.footer.prev, self.footer.next, self.footer.indicator = nil, nil, nil
    self.list_controls = nil; self.last_render_mon = nil; self.last_render_mon_name = nil
    self.last_render_model = nil; self.shared_backbuffer = nil
    return
  end
  self.last_render_model = model
  local page = self:current()
  local cur_w, cur_h = ui.getSize(mon)
  local scale_ok, cur_scale = pcall(mon.getTextScale); if not scale_ok then cur_scale = nil end
  local resolved_name = self.monitor_name or wrapped_peripheral_name(mon)
  local is_transition = self.last_render_mon ~= mon or self.last_render_page_index ~= self.index
    or self.last_render_w ~= cur_w or self.last_render_h ~= cur_h or self.last_render_scale ~= cur_scale
    or self.last_render_mon_name ~= resolved_name
  local snapshot = build_snapshot(page and page.name, model)
  -- Snapshot-Skip: nur überspringen wenn footer bereits gesetzt
  if not is_transition and snapshot == self.last_snapshot then
    if self.footer.prev ~= nil then
      self.ui_diag.frames_skipped = self.ui_diag.frames_skipped + 1; return
    end
    -- footer noch nicht gesetzt (z.B. nach Transition) → trotzdem rendern
  end
  self.ui_diag.frames_committed = self.ui_diag.frames_committed + 1
  local render_start_ms = os.epoch and os.epoch("utc") or nil
  self.last_snapshot = snapshot
  if is_transition then self.list_controls = nil end
  local should_clear = is_transition
  self.last_render_mon, self.last_render_mon_name = mon, resolved_name
  self.last_render_page_index, self.last_render_w, self.last_render_h, self.last_render_scale = self.index, cur_w, cur_h, cur_scale
  if is_transition then
    -- footer NICHT auf nil setzen — bleibt gültig bis neuer Render sie überschreibt
    self.list_controls = nil
    self.transition_count = (self.transition_count or 0) + 1; self.ui_diag.full_clears = self.ui_diag.full_clears + 1
  end
  local render_target, buffered, buffer_created = prepare_render_target(self, mon, cur_w, cur_h)
  if buffer_created and not should_clear then should_clear = true; self.ui_diag.full_clears = self.ui_diag.full_clears + 1 end
  mon = render_target; ui.begin_frame(mon)
  local page_footer = nil
  if page and page.render then
    local ok, result = xpcall(function() return page.render(mon, model, should_clear) end,
      function(err) if debug and debug.traceback then return debug.traceback(tostring(err), 2) end; return tostring(err) end)
    if ok then page_footer = result else
      self.error_count = (self.error_count or 0) + 1; self.ui_diag.render_errors = self.ui_diag.render_errors + 1
      self.last_error = { page = tostring(page.name or "?"), code = "RENDER_FAILED", message = tostring(result), ts = os.epoch and os.epoch("utc") or nil }
      if self.on_render_error then pcall(self.on_render_error, self.last_error) end
      pcall(function()
        ui.clear(mon); ui.text(mon, 2, 2, self.error_title, colors.get("WARNING"), colors.get("background"))
        ui.text(mon, 2, 4, "Seite: " .. tostring(page.name or "?"), colors.get("text"), colors.get("background"))
        ui.text(mon, 2, 5, "Code: RENDER_FAILED", colors.get("text"), colors.get("background"))
        ui.text(mon, 2, 7, "Details im LOG_COLLECTOR-Export.", colors.get("muted"), colors.get("background"))
        ui.text(mon, 2, 9, "Naechster Zyklus versucht erneut zu zeichnen.", colors.get("muted"), colors.get("background"))
      end)
    end
  end
  if render_start_ms then self.ui_diag.last_render_ms = (os.epoch and os.epoch("utc") or render_start_ms) - render_start_ms end
  local w, h = ui.getSize(mon); if not w or not h then publish_render_target(mon, buffered); return end
  if type(page_footer) == "table" and page_footer.left and page_footer.right then
    self.footer.prev, self.footer.next = page_footer_zones(w, h, page_footer)
    self.footer.indicator = nil; publish_render_target(mon, buffered); return
  end
  local page_count = math.max(1, #self.pages)
  local indicator = ("< Page %d/%d >"):format(self.index, page_count)
  ui.rightText(mon, 2, h, w - 2, indicator, colors.get("text"), colors.get("background"))
  local start = 2 + math.max(0, (w - 2) - #indicator)
  self.footer.prev, self.footer.next = page_footer_zones(w, h)
  self.footer.indicator = { x1 = start, x2 = start + #indicator, y = h }
  publish_render_target(mon, buffered)
end

return router
