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
  local code = entry.code and tostring(entry.code) or nil
  local title = tostring(entry.title or "Alert")
  local message = tostring(entry.message or "")
  local details = self:_ensure_details(entry)
  local existing = self.active_by_key[key]
  local result = { log = false, alert = nil, event = nil, severity_changed = false }
  if existing then
    local prior_severity = existing.severity
    local severity_changed = prior_severity ~= severity
    local severity_increased = severity_rank[severity] < severity_rank[prior_severity]
    existing.ts_last = ts
    if severity_changed then
      existing.severity = severity
      result.severity_changed = true
      result.log = true
      result.event = "severity"
      if existing.acknowledged and severity_increased then
        existing.acknowledged = nil
        existing.ack_ts = nil
      end
    end
    if existing.title ~= title then
      existing.title = title
    end
    if existing.message ~= message then
      existing.message = message
    end
    if code then
      existing.code = code
    end
    existing.details = details
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
    code = code,
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
  result.event = "raise"
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
  return alert
end

function alerts:set_ack(id, value)
  if not id then
    return false
  end
  local alert = self.active_by_id[id]
  if not alert then
    return false
  end
  local next_value = value
  if next_value == nil then
    next_value = not alert.acknowledged
  end
  if not next_value then
    next_value = nil
  end
  if alert.acknowledged == next_value then
    return false
  end
  alert.acknowledged = next_value
  alert.ack_ts = next_value and now_ms() or nil
  self:_mark_dirty()
  return true, alert
end

function alerts:ack(id)
  return self:set_ack(id, nil)
end

function alerts:set_ack_for_ids(ids, value)
  local changed = {}
  for _, id in ipairs(ids or {}) do
    local ok, alert = self:set_ack(id, value)
    if ok and alert then
      table.insert(changed, alert)
    end
  end
  return changed
end

function alerts:ack_all(value)
  local changed = {}
  for _, alert in pairs(self.active_by_key) do
    local next_value = value
    if next_value == nil then
      next_value = true
    end
    if not next_value then
      next_value = nil
    end
    if alert.acknowledged ~= next_value then
      alert.acknowledged = next_value
      alert.ack_ts = next_value and now_ms() or nil
      table.insert(changed, alert)
    end
  end
  if #changed > 0 then
    self:_mark_dirty()
  end
  return changed
end

function alerts:record_muted(entry)
  if type(entry) ~= "table" then
    return
  end
  self.seq = self.seq + 1
  local snapshot = {
    id = string.format("MUTED-%d-%d", entry.ts or now_ms(), self.seq),
    ts_first = entry.ts or now_ms(),
    ts_last = entry.ts or now_ms(),
    severity = normalize_severity(entry.severity or "INFO"),
    code = entry.code and tostring(entry.code) or nil,
    scope = normalize_scope(entry.scope),
    source = type(entry.source) == "table" and entry.source or {},
    title = tostring(entry.title or "Muted alert"),
    message = tostring(entry.message or ""),
    details = self:_ensure_details(entry),
    muted = true
  }
  self:_push_history(snapshot)
  self:_mark_dirty()
end

function alerts:tick(ts)
  local now = ts or now_ms()
  if not self.info_ttl_s or self.info_ttl_s <= 0 then
    return {}
  end
  local ttl_ms = self.info_ttl_s * 1000
  local expired = {}
  for key, alert in pairs(self.active_by_key) do
    if alert.severity == "INFO" and now - (alert.ts_last or 0) >= ttl_ms then
      self.active_by_key[key] = nil
      self.active_by_id[alert.id] = nil
      table.insert(expired, alert)
      self:_mark_dirty()
    end
  end
  return expired
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
