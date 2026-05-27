local control = {}

function control.new(opts)
  opts = opts or {}
  local runtime = type(opts.runtime) == "table" and opts.runtime or nil
  local self = {
    name = opts.name or "CONTROL",
    tick_fn = opts.tick or (runtime and runtime.tick) or nil,
    handle_command = opts.handle_command or (runtime and runtime.handle_command) or nil
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
