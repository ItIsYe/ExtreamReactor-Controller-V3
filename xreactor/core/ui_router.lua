local ui = require("core.ui")
local colors = require("shared.colors")

local router = {}

local function now_ms()
  return os.epoch("utc")
end

local function clamp(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

function router.paginate(list, per_page, page)
  local total = math.max(1, math.ceil(#list / per_page))
  local current = clamp(page or 1, 1, total)
  local start_idx = (current - 1) * per_page + 1
  local end_idx = math.min(#list, current * per_page)
  return {
    page = current,
    total = total,
    start_index = start_idx,
    end_index = end_idx
  }
end

function router.new(mon_or_opts, opts)
  local target = nil
  if opts == nil and type(mon_or_opts) == "table" and mon_or_opts.pages then
    opts = mon_or_opts
  else
    target = mon_or_opts
  end
  opts = opts or {}
  local list_key_prev = opts.list_key_prev
  local list_key_next = opts.list_key_next
  if not list_key_prev then
    list_key_prev = {}
    if type(keys) == "table" then
      list_key_prev[keys.up] = true
      list_key_prev[keys.pageUp] = true
    end
  end
  if not list_key_next then
    list_key_next = {}
    if type(keys) == "table" then
      list_key_next[keys.down] = true
      list_key_next[keys.pageDown] = true
    end
  end
  local self = {
    mon = target,
    title = opts.title,
    pages = opts.pages or {},
    index = opts.index or 1,
    last_snapshot = nil,
    last_draw = 0,
    interval = opts.interval or 0.5,
    footer = {
      prev = nil,
      next = nil,
      indicator = nil
    },
    list_controls = nil,
    key_prev = opts.key_prev,
    key_next = opts.key_next,
    list_key_prev = list_key_prev,
    list_key_next = list_key_next
  }
  return setmetatable(self, { __index = router })
end

function router:count()
  return #self.pages
end

function router:current()
  return self.pages[self.index]
end

function router:set(index)
  local total = math.max(1, #self.pages)
  local next_index = clamp(index, 1, total)
  if next_index ~= self.index then
    self.index = next_index
    self.last_snapshot = nil
  end
end

function router:next()
  local total = math.max(1, #self.pages)
  local next_index = self.index + 1
  if next_index > total then
    next_index = 1
  end
  self:set(next_index)
end

function router:prev()
  local total = math.max(1, #self.pages)
  local prev_index = self.index - 1
  if prev_index < 1 then
    prev_index = total
  end
  self:set(prev_index)
end

function router:handle_input(event)
  if not event then return end
  local kind = event[1]
  if kind == "key" then
    local key = event[2]
    if self.key_prev and self.key_prev[key] then
      self:prev()
      return true
    end
    if self.key_next and self.key_next[key] then
      self:next()
      return true
    end
    local list = self.list_controls
    if list then
      if self.list_key_prev and self.list_key_prev[key] and list.on_prev then
        list.on_prev()
        return true
      end
      if self.list_key_next and self.list_key_next[key] and list.on_next then
        list.on_next()
        return true
      end
    end
  elseif kind == "monitor_touch" then
    local x, y = event[3], event[4]
    local prev = self.footer.prev
    if prev and y == prev.y and x >= prev.x1 and x <= prev.x2 then
      self:prev()
      return true
    end
    local next_btn = self.footer.next
    if next_btn and y == next_btn.y and x >= next_btn.x1 and x <= next_btn.x2 then
      self:next()
      return true
    end
    local list = self.list_controls
    if list then
      local list_prev = list.prev
      if list_prev and y == list_prev.y and x >= list_prev.x1 and x <= list_prev.x2 then
        if list.on_prev then list.on_prev() end
        return true
      end
      local list_next = list.next
      if list_next and y == list_next.y and x >= list_next.x1 and x <= list_next.x2 then
        if list.on_next then list.on_next() end
        return true
      end
    end
  end
  return false
end

local function build_snapshot(page_name, model)
  if model and model.snapshot ~= nil then
    return textutils.serialize({ page = page_name or "", snapshot = model.snapshot })
  end
  return textutils.serialize({ page = page_name or "", model = model or {} })
end

function router:render_list_controls(mon, opts)
  if not mon then return end
  opts = opts or {}
  local _, h = mon.getSize()
  local page = opts.page or 1
  local total = opts.total or 1
  local label = opts.label or "List"
  local x = opts.x or 2
  local y = opts.y or (h - 1)
  local text = ("< %s %d/%d >"):format(label, page, total)
  ui.text(mon, x, y, text, colors.get("text"), colors.get("background"))
  self.list_controls = {
    prev = { x1 = x, x2 = x + 1, y = y },
    next = { x1 = x + #text - 1, x2 = x + #text, y = y },
    on_prev = opts.on_prev,
    on_next = opts.on_next
  }
  return self.list_controls
end

function router:render(mon, model)
  if not mon then return end
  local ts = now_ms()
  if ts - self.last_draw < self.interval * 1000 then
    return
  end
  self.last_draw = ts
  local page = self:current()
  local snapshot = build_snapshot(page and page.name, model)
  if snapshot == self.last_snapshot then
    return
  end
  self.last_snapshot = snapshot
  self.list_controls = nil
  if page and page.render then
    page.render(mon, model)
  end
  local w, h = mon.getSize()
  local page_count = math.max(1, #self.pages)
  local indicator = ("< Page %d/%d >"):format(self.index, page_count)
  ui.rightText(mon, 2, h, w - 2, indicator, colors.get("text"), colors.get("background"))
  local start = 2 + math.max(0, (w - 2) - #indicator)
  self.footer.prev = { x1 = start, x2 = start + 1, y = h }
  self.footer.next = { x1 = start + #indicator - 1, x2 = start + #indicator, y = h }
  self.footer.indicator = { x1 = start, x2 = start + #indicator, y = h }
end

return router
