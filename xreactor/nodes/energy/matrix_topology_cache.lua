local cache = {}

local function now_ms()
  return os.epoch("utc")
end

local function sort_copy(list)
  local copy = {}
  for i, value in ipairs(list or {}) do
    copy[i] = value
  end
  table.sort(copy)
  return copy
end

local function peripheral_signature()
  local names = sort_copy(peripheral.getNames() or {})
  local parts = {}
  for _, name in ipairs(names) do
    local kind = peripheral.getType(name) or "unknown"
    parts[#parts + 1] = tostring(name) .. ":" .. tostring(kind)
  end
  return table.concat(parts, "|")
end

function cache.new(opts)
  opts = opts or {}
  local self = {
    log_prefix = opts.log_prefix or "ENERGY",
    forced_rescan_interval_ms = math.max(1000, math.floor((tonumber(opts.forced_rescan_interval_s) or 300) * 1000)),
    watch_signature = nil,
    topology_signature = nil,
    last_discovery_ts = 0,
    dirty = true
  }
  return setmetatable(self, { __index = cache })
end

function cache:should_discover(ts, event, due)
  local event_name = type(event) == "table" and event[1] or nil
  if event_name == "peripheral" or event_name == "peripheral_detach" then
    self.dirty = true
  end

  if not due then
    return false, "interval_not_due"
  end

  local signature = peripheral_signature()
  local force_due = (ts - (self.last_discovery_ts or 0)) >= self.forced_rescan_interval_ms
  local signature_changed = signature ~= (self.watch_signature or "")

  if self.dirty or signature_changed or force_due then
    self.watch_signature = signature
    return true, self.dirty and "dirty" or (signature_changed and "signature_changed" or "forced_interval")
  end

  return false, "stable"
end

function cache:record_discovery(ts, topology_signature)
  self.last_discovery_ts = ts or now_ms()
  self.topology_signature = topology_signature or self.topology_signature
  self.dirty = false
end

return cache
