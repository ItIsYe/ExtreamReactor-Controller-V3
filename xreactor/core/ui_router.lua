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

function router.new(opts)
  opts = opts or {}
  local self = {
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
    key_prev = opts.key_prev,
    key_next = opts.key_next
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
  end
  return false
end

local function build_snapshot(page_name, model)
  return textutils.serialize({ page = page_name or "", model = model or {} })
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
