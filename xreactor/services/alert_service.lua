local utils = require("core.utils")
local alerts_lib = require("core.alerts")
local rules_lib = require("core.alert_rules")

local alert_service = {}

local severity_level = {
  INFO = "INFO",
  WARN = "WARN",
  CRITICAL = "ERROR"
}

local function now_ms()
  return os.epoch("utc")
end

function alert_service.new(opts)
  opts = opts or {}
  local config = opts.config or {}
  local alerts = alerts_lib.new({
    info_ttl_s = config.alert_info_ttl or 10,
    history_size = config.alert_history_size or 100
  })
  local self = {
    log_prefix = opts.log_prefix or "ALERT",
    config = config,
    nodes = opts.nodes,
    power_target = opts.power_target,
    alerts = alerts,
    rules = rules_lib.new(config),
    last_eval = 0,
    recovery_notice = opts.recovery_notice
  }
  return setmetatable(self, { __index = alert_service })
end

function alert_service:log_alert(alert)
  local level = severity_level[alert.severity] or "INFO"
  local source = alert.source or {}
  local src = tostring(source.node_id or source.role or "SYSTEM")
  local message = string.format("%s | %s | %s", alert.title or "Alert", src, alert.message or "")
  utils.log(self.log_prefix, message, level)
end

function alert_service:tick()
  local now = now_ms()
  local interval = (self.config.alert_eval_interval or 1) * 1000
  if now - self.last_eval < interval then
    return
  end
  self.last_eval = now
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
  for _, key in ipairs(clears or {}) do
    self.alerts:resolve(key)
  end
  for _, entry in ipairs(alerts or {}) do
    local result = self.alerts:raise(entry)
    if result and result.log and result.alert then
      self:log_alert(result.alert)
    end
  end
  self.alerts:tick(now)
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
  return self.alerts:ack(id)
end

function alert_service:ack_all()
  self.alerts:ack_all()
end

return alert_service
