local ui = {}

function ui.new(opts)
  opts = opts or {}
  local self = {
    render = opts.render,
    handle_input = opts.handle_input,
    interval = opts.interval or 0.5,
    last_draw = 0
  }
  return setmetatable(self, { __index = ui })
end

local function now()
  return os.epoch("utc")
end

function ui:tick(_, event)
  if event and self.handle_input then
    self.handle_input(event)
  end
  local ts = now()
  if ts - self.last_draw < self.interval * 1000 then
    return
  end
  self.last_draw = ts
  if self.render then
    self.render()
  end
end

return ui
