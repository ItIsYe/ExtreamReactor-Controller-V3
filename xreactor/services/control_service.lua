local control = {}

function control.new(opts)
  opts = opts or {}
  local self = {
    tick_fn = opts.tick,
    handle_command = opts.handle_command
  }
  return setmetatable(self, { __index = control })
end

function control:tick(dt, event)
  if self.tick_fn then
    self.tick_fn(dt, event)
  end
end

function control:handle(msg)
  if self.handle_command then
    self.handle_command(msg)
  end
end

return control
