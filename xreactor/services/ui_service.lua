local ui = {}

local function snapshot_value(value)
  if type(value) == "table" and textutils and textutils.serialize then
    local ok, serialized = pcall(textutils.serialize, value)
    if ok then
      return serialized
    end
  end
  return tostring(value)
end

function ui.new(opts)
  opts = opts or {}
  local self = {
    render = opts.render,
    handle_input = opts.handle_input,
    interval = opts.interval or 0.5,
    force_interval = opts.force_interval or math.max(opts.interval or 0.5, 2),
    snapshot = opts.snapshot,
    last_draw = 0,
    last_force_draw = 0,
    last_snapshot = nil
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
  local due = ts - self.last_draw >= self.interval * 1000
  local force_due = ts - self.last_force_draw >= self.force_interval * 1000
  local snapshot_changed = false
  if self.snapshot then
    local current = snapshot_value(self.snapshot(event))
    snapshot_changed = current ~= self.last_snapshot
    self.last_snapshot = current
  end
  local interactive = event and (event[1] == "monitor_touch" or event[1] == "key" or event[1] == "char")
  if not due or (not interactive and not snapshot_changed and not force_due) then
    return
  end
  self.last_draw = ts
  if force_due then
    self.last_force_draw = ts
  end
  if self.render then
    self.render()
  end
end

return ui
