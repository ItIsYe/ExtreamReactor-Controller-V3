local utils = require("core.utils")

local function now()
  return os.epoch("utc")
end

local function is_terminate_error(err)
  local message = tostring(err or ""):match("^%s*(.-)%s*$"):lower()
  return message == "terminate" or message == "terminated"
end

local discovery = {}

function discovery.new(opts)
  opts = opts or {}
  local start_delay = opts.start_delay
  if start_delay == nil then
    start_delay = 4
  end
  local self = {
    name = opts.name or "DISCOVERY",
    log_prefix = opts.log_prefix or "DISCOVERY",
    registry = opts.registry,
    discover = opts.discover,
    managed_registry = opts.managed_registry ~= false,
    interval = opts.interval or 15,
    should_discover = opts.should_discover,
    start_delay = start_delay,
    start_at = now() + (start_delay * 1000),
    last_scan = 0,
    snapshot = { found = {}, bound = {}, missing = {}, last_scan = nil, errors = {} },
    update_health = opts.update_health
  }
  return setmetatable(self, { __index = discovery })
end

function discovery:tick(_, event)
  local ts = now()
  if ts < self.start_at then
    return
  end
  local due = ts - self.last_scan >= self.interval * 1000
  local should_scan = due
  if type(self.should_discover) == "function" then
    local ok, decision = pcall(self.should_discover, self, ts, event, due)
    if ok and decision ~= nil then
      should_scan = decision == true
    elseif not ok then
      utils.log(self.log_prefix, "Discovery precheck failed: " .. tostring(decision), "WARN")
      should_scan = due
    end
  end
  if not should_scan then
    return
  end
  self.last_scan = ts
  if not self.discover then return end
  local ok, devices, err = pcall(self.discover)
  if not ok then
    if is_terminate_error(devices) then
      error(devices, 0)
    end
    utils.log(self.log_prefix, "Discovery failed: " .. tostring(devices), "WARN")
    self.snapshot.errors = { tostring(devices) }
    if self.update_health then
      self.update_health(false, "DISCOVERY_FAILED")
    end
    return
  end
  if err then
    utils.log(self.log_prefix, "Discovery warning: " .. tostring(err), "WARN")
  end
  devices = devices or {}
  if self.managed_registry and self.registry then
    self.registry:sync(devices)
  end
  local found = {}
  local bound = {}
  if self.registry then
    for _, entry in ipairs(self.registry:list()) do
      if entry.found ~= false then
        table.insert(found, entry)
      end
      local is_bound = entry.bound
      if is_bound == nil then
        is_bound = not entry.missing
      end
      if is_bound then
        table.insert(bound, entry)
      end
    end
  end
  local missing = {}
  if self.registry then
    for _, entry in ipairs(self.registry:list()) do
      if entry.missing then
        table.insert(missing, entry)
      end
    end
  end
  self.snapshot = {
    found = found,
    bound = bound,
    missing = missing,
    last_scan = ts,
    errors = {},
    diagnostics = self.registry and self.registry.get_diagnostics and self.registry:get_diagnostics() or nil
  }
  if self.update_health then
    self.update_health(true)
  end
end

function discovery:get_snapshot()
  return self.snapshot
end

return discovery
