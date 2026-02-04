local utils = require("core.utils")
local alerts_lib = require("core.alerts")
local rules_lib = require("core.alert_rules")

local alert_service = {}

local severity_level = {
  INFO = "INFO",
  WARN = "WARN",
  CRITICAL = "ERROR"
}

local state_defaults = {
  mutes = {
    rules = {},
    nodes = {}
  }
}

local function now_ms()
  return os.epoch("utc")
end

local function normalize_mutes(state)
  state.mutes = type(state.mutes) == "table" and state.mutes or { rules = {}, nodes = {} }
  state.mutes.rules = type(state.mutes.rules) == "table" and state.mutes.rules or {}
  state.mutes.nodes = type(state.mutes.nodes) == "table" and state.mutes.nodes or {}
end

local function is_expired(entry, now)
  if not entry then
    return true
  end
  if type(entry) == "number" then
    return entry <= now
  end
  return type(entry.until) ~= "number" or entry.until <= now
end

function alert_service.new(opts)
  opts = opts or {}
  local config = opts.config or {}
  local alerts = alerts_lib.new({
    info_ttl_s = config.alert_info_ttl or 10,
    history_size = config.alert_history_size or 100
  })
  local state_path = config.alert_state_path or "/xreactor/config/alerts_state.lua"
  local state = utils.load_config(state_path, state_defaults)
  normalize_mutes(state)
  local now = now_ms()
  for key, entry in pairs(state.mutes.rules) do
    if is_expired(entry, now) then
      state.mutes.rules[key] = nil
    end
  end
  for key, entry in pairs(state.mutes.nodes) do
    if is_expired(entry, now) then
      state.mutes.nodes[key] = nil
    end
  end
  local self = {
    log_prefix = opts.log_prefix or "ALERT",
    config = config,
    nodes = opts.nodes,
    power_target = opts.power_target,
    alerts = alerts,
    rules = rules_lib.new(config),
    last_eval = 0,
    recovery_notice = opts.recovery_notice,
    state_path = state_path,
    state = state,
    last_eval_duration_ms = 0,
    last_eval_ts = 0,
    muted_last = 0
  }
  return setmetatable(self, { __index = alert_service })
end

function alert_service:log_alert(alert, event)
  local level = severity_level[alert.severity] or "INFO"
  local source = alert.source or {}
  local node_id = tostring(source.node_id or source.role or "SYSTEM")
  local code = tostring(alert.code or (alert.details and alert.details.code) or "ALERT")
  local msg = tostring(alert.message or "")
  local event_text = event and (" event=" .. tostring(event)) or ""
  local message = string.format("severity=%s code=%s node=%s%s msg=%s", alert.severity or "INFO", code, node_id, event_text, msg)
  utils.log(self.log_prefix, message, level)
end

function alert_service:log_mute(kind, key, until_ts)
  local until = until_ts and os.date("!%H:%M:%S", math.floor(until_ts / 1000)) or "cleared"
  local node_id = (kind == "mute_node" or kind == "unmute_node") and tostring(key) or "SYSTEM"
  local code = (kind == "mute_rule" or kind == "unmute_rule") and tostring(key) or "NODE_MUTE"
  local msg = string.format("%s until=%s", kind, tostring(until))
  local message = string.format("severity=INFO code=%s node=%s msg=%s", code, node_id, msg)
  utils.log(self.log_prefix, message, "INFO")
end

function alert_service:save_state()
  utils.write_config(self.state_path, self.state)
end

function alert_service:_is_muted(entry, now)
  if not entry or type(entry) ~= "table" then
    return nil
  end
  local code = entry.code
  local source = entry.source or {}
  local node_id = source.node_id
  local rule_entry = code and self.state.mutes.rules[code] or nil
  if rule_entry and not is_expired(rule_entry, now) then
    return "rule", code
  end
  if rule_entry then
    self.state.mutes.rules[code] = nil
  end
  if node_id then
    local node_entry = self.state.mutes.nodes[node_id]
    if node_entry and not is_expired(node_entry, now) then
      return "node", node_id
    end
    if node_entry then
      self.state.mutes.nodes[node_id] = nil
    end
  end
  return nil
end

function alert_service:tick()
  local now = now_ms()
  local interval = (self.config.alert_eval_interval or 1) * 1000
  if now - self.last_eval < interval then
    return
  end
  local eval_start = now
  self.last_eval = now
  local mutes_changed = false
  for key, entry in pairs(self.state.mutes.rules or {}) do
    if is_expired(entry, now) then
      self.state.mutes.rules[key] = nil
      mutes_changed = true
    end
  end
  for key, entry in pairs(self.state.mutes.nodes or {}) do
    if is_expired(entry, now) then
      self.state.mutes.nodes[key] = nil
      mutes_changed = true
    end
  end
  if mutes_changed then
    self:save_state()
  end
  if self.recovery_notice and self.recovery_notice.active_until and now > self.recovery_notice.active_until then
    self.recovery_notice.active = false
  end
  local alerts, clears = self.rules:evaluate({
    nodes = self.nodes,
    config = self.config,
    power_target = type(self.power_target) == "function" and self.power_target() or self.power_target,
    recovery_notice = self.recovery_notice,
    now = now
  })
  local muted_count = 0
  for _, key in ipairs(clears or {}) do
    local cleared = self.alerts:resolve(key)
    if cleared then
      self:log_alert(cleared, "clear")
    end
  end
  for _, entry in ipairs(alerts or {}) do
    local muted_kind = self:_is_muted(entry, now)
    if muted_kind then
      muted_count = muted_count + 1
      if self.config.alert_log_muted_events then
        local muted_entry = {
          severity = "INFO",
          scope = entry.scope,
          source = entry.source,
          code = entry.code,
          title = "Alert muted",
          message = string.format("%s muted (%s)", tostring(entry.title or entry.code or "Alert"), tostring(muted_kind)),
          details = { muted = muted_kind, ts = now }
        }
        self.alerts:record_muted(muted_entry)
        self:log_alert(muted_entry, "muted")
      end
    else
      local result = self.alerts:raise(entry)
      if result and result.log and result.alert then
        self:log_alert(result.alert, result.event)
      end
    end
  end
  local expired = self.alerts:tick(now)
  for _, alert in ipairs(expired or {}) do
    self:log_alert(alert, "expired")
  end
  self.muted_last = muted_count
  self.last_eval_duration_ms = now_ms() - eval_start
  self.last_eval_ts = eval_start
end

function alert_service:get_active()
  return self.alerts:get_active()
end

function alert_service:get_history()
  return self.alerts:get_history()
end

function alert_service:get_counts()
  return self.alerts:get_counts_by_severity()
end

function alert_service:get_summary()
  return self.alerts:render_summary()
end

function alert_service:get_top_critical(limit)
  local list = {}
  local max = limit or 3
  for _, alert in ipairs(self.alerts:get_active()) do
    if alert.severity == "CRITICAL" then
      table.insert(list, alert)
      if #list >= max then
        break
      end
    end
  end
  return list
end

function alert_service:ack(id)
  local ok, alert = self.alerts:ack(id)
  if ok and alert then
    self:log_alert(alert, alert.acknowledged and "ack" or "unack")
  end
  return ok
end

function alert_service:ack_all()
  local changed = self.alerts:ack_all(true)
  for _, alert in ipairs(changed or {}) do
    self:log_alert(alert, "ack_all")
  end
end

function alert_service:ack_visible(ids)
  local changed = self.alerts:set_ack_for_ids(ids, true)
  for _, alert in ipairs(changed or {}) do
    self:log_alert(alert, "ack_visible")
  end
end

function alert_service:unack(id)
  local ok, alert = self.alerts:set_ack(id, false)
  if ok and alert then
    self:log_alert(alert, "unack")
  end
  return ok
end

function alert_service:mute_rule(code, minutes)
  if not code then
    return false
  end
  local duration = math.max(1, tonumber(minutes) or (self.config.alert_mute_default_minutes or 10))
  local until_ts = now_ms() + duration * 60 * 1000
  self.state.mutes.rules[code] = { until = until_ts, minutes = duration }
  self:save_state()
  self:log_mute("mute_rule", code, until_ts)
  return true
end

function alert_service:unmute_rule(code)
  if not code then
    return false
  end
  if self.state.mutes.rules[code] then
    self.state.mutes.rules[code] = nil
    self:save_state()
    self:log_mute("unmute_rule", code, nil)
  end
  return true
end

function alert_service:mute_node(node_id, minutes)
  if not node_id then
    return false
  end
  local duration = math.max(1, tonumber(minutes) or (self.config.alert_mute_default_minutes or 10))
  local until_ts = now_ms() + duration * 60 * 1000
  self.state.mutes.nodes[node_id] = { until = until_ts, minutes = duration }
  self:save_state()
  self:log_mute("mute_node", node_id, until_ts)
  return true
end

function alert_service:unmute_node(node_id)
  if not node_id then
    return false
  end
  if self.state.mutes.nodes[node_id] then
    self.state.mutes.nodes[node_id] = nil
    self:save_state()
    self:log_mute("unmute_node", node_id, nil)
  end
  return true
end

function alert_service:get_mutes()
  return self.state.mutes
end

function alert_service:get_metrics()
  local active = self.alerts:get_active() or {}
  local counts_by_role = {}
  local counts_by_node = {}
  for _, alert in ipairs(active) do
    local source = alert.source or {}
    local role = source.role or "UNKNOWN"
    local node_id = source.node_id or "UNKNOWN"
    counts_by_role[role] = (counts_by_role[role] or 0) + 1
    counts_by_node[node_id] = (counts_by_node[node_id] or 0) + 1
  end
  local muted_rules = 0
  local muted_nodes = 0
  for _ in pairs(self.state.mutes.rules or {}) do
    muted_rules = muted_rules + 1
  end
  for _ in pairs(self.state.mutes.nodes or {}) do
    muted_nodes = muted_nodes + 1
  end
  return {
    counts_by_role = counts_by_role,
    counts_by_node = counts_by_node,
    last_eval_ts = self.last_eval_ts,
    eval_duration_ms = self.last_eval_duration_ms,
    muted_counts = {
      rules = muted_rules,
      nodes = muted_nodes,
      suppressed = self.muted_last or 0
    }
  }
end

return alert_service
