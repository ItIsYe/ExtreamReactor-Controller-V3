local utils = require("core.utils")

local alerts = {}

local severity_rank = {
  CRITICAL = 1,
  WARN = 2,
  INFO = 3
}

local function now_ms()
  return os.epoch("utc")
end

local function normalize_severity(value)
  local key = tostring(value or "INFO"):upper()
  if severity_rank[key] then
    return key
  end
  return "INFO"
end

local function normalize_scope(value)
  local key = tostring(value or "SYSTEM"):upper()
  if key == "SYSTEM" or key == "NODE" or key == "DEVICE" then
    return key
  end
  return "SYSTEM"
end

local function build_source_key(source)
  if type(source) ~= "table" then
    return "unknown"
  end
  local parts = {
    tostring(source.node_id or "unknown"),
    tostring(source.role or "unknown"),
    tostring(source.device_id or "")
  }
  return table.concat(parts, "|")
end

local function build_key(entry)
  if entry.key then
    return entry.key
  end
  local code = tostring(entry.code or "ALERT")
  return build_source_key(entry.source) .. "|" .. code
end

function alerts.new(opts)
  opts = opts or {}
  local self = {
    info_ttl_s = tonumber(opts.info_ttl_s) or 10,
    history_size = tonumber(opts.history_size) or 100,
    seq = 0,
    active_by_key = {},
    active_by_id = {},
    active_cache = nil,
    history = {},
    counts_cache = nil,
    summary_cache = nil,
    dirty = true
  }
  return setmetatable(self, { __index = alerts })
end

function alerts:_mark_dirty()
  self.dirty = true
  self.active_cache = nil
  self.counts_cache = nil
  self.summary_cache = nil
end

function alerts:_ensure_details(entry)
  local details = entry.details
  if type(details) ~= "table" then
    details = { value = details }
  end
  if entry.code and details.code == nil then
    details.code = entry.code
  end
  return details
end

function alerts:_push_history(alert)
  local snapshot = utils.deep_copy(alert)
  table.insert(self.history, 1, snapshot)
  if #self.history > self.history_size then
    table.remove(self.history)
  end
end

function alerts:raise(entry)
  if type(entry) ~= "table" then
    return nil
  end
  local key = build_key(entry)
  local ts = entry.ts or now_ms()
  local severity = normalize_severity(entry.severity)
  local scope = normalize_scope(entry.scope)
  local source = type(entry.source) == "table" and entry.source or {}
  local title = tostring(entry.title or "Alert")
  local message = tostring(entry.message or "")
  local details = self:_ensure_details(entry)
  local existing = self.active_by_key[key]
  local result = { log = false, alert = nil }
  if existing then
    local severity_changed = severity_rank[severity] < severity_rank[existing.severity]
    existing.ts_last = ts
    if severity_changed or existing.severity ~= severity then
      existing.severity = severity
      result.log = true
    end
    if existing.title ~= title then
      existing.title = title
    end
    if existing.message ~= message then
      existing.message = message
    end
    existing.details = details
    if existing.acknowledged then
      existing.acknowledged = nil
      existing.ack_ts = nil
    end
    result.alert = existing
    self:_mark_dirty()
    return result
  end
  self.seq = self.seq + 1
  local alert = {
    id = string.format("ALERT-%d-%d", ts, self.seq),
    ts_first = ts,
    ts_last = ts,
    severity = severity,
    scope = scope,
    source = source,
    title = title,
    message = message,
    details = details
  }
  self.active_by_key[key] = alert
  self.active_by_id[alert.id] = alert
  self:_push_history(alert)
  self:_mark_dirty()
  result.alert = alert
  result.log = true
  return result
end

function alerts:resolve(key)
  if not key then
    return false
  end
  local alert = self.active_by_key[key]
  if not alert then
    return false
  end
  self.active_by_key[key] = nil
  self.active_by_id[alert.id] = nil
  self:_mark_dirty()
  return true
end

function alerts:ack(id)
  if not id then
    return false
  end
  local alert = self.active_by_id[id]
  if not alert then
    return false
  end
  alert.acknowledged = true
  alert.ack_ts = now_ms()
  self:_mark_dirty()
  return true
end

function alerts:ack_all()
  for _, alert in pairs(self.active_by_key) do
    alert.acknowledged = true
    alert.ack_ts = now_ms()
  end
  self:_mark_dirty()
end

function alerts:tick(ts)
  local now = ts or now_ms()
  if not self.info_ttl_s or self.info_ttl_s <= 0 then
    return
  end
  local ttl_ms = self.info_ttl_s * 1000
  for key, alert in pairs(self.active_by_key) do
    if alert.severity == "INFO" and now - (alert.ts_last or 0) >= ttl_ms then
      self.active_by_key[key] = nil
      self.active_by_id[alert.id] = nil
      self:_mark_dirty()
    end
  end
end

function alerts:get_active()
  if not self.active_cache then
    local list = {}
    for _, alert in pairs(self.active_by_key) do
      table.insert(list, alert)
    end
    table.sort(list, function(a, b)
      local ar = severity_rank[a.severity] or 99
      local br = severity_rank[b.severity] or 99
      if ar == br then
        return (a.ts_last or 0) > (b.ts_last or 0)
      end
      return ar < br
    end)
    self.active_cache = list
  end
  return self.active_cache
end

function alerts:get_history()
  return self.history
end

function alerts:get_counts_by_severity()
  if not self.counts_cache then
    local counts = { INFO = 0, WARN = 0, CRITICAL = 0 }
    for _, alert in pairs(self.active_by_key) do
      counts[alert.severity] = (counts[alert.severity] or 0) + 1
    end
    self.counts_cache = counts
  end
  return self.counts_cache
end

function alerts:render_summary()
  if not self.summary_cache then
    local counts = self:get_counts_by_severity()
    self.summary_cache = string.format("CRIT:%d WARN:%d INFO:%d", counts.CRITICAL or 0, counts.WARN or 0, counts.INFO or 0)
  end
  return self.summary_cache
end

return alerts
