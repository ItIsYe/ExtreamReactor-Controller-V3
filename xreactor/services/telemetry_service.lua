local constants = require("shared.constants")
local utils = require("core.utils")
local build_info = require("shared.build_info")
local telemetry_schema = require("shared.telemetry_schema")

local telemetry = {}

function telemetry.new(opts)
  opts = opts or {}
  local self = {
    name = opts.name or "TELEMETRY",
    log_prefix = opts.log_prefix or "TELEMETRY",
    comms = opts.comms,
    build_payload = opts.build_payload,
    heartbeat_state = opts.heartbeat_state,
    status_interval = opts.status_interval or 5,
    heartbeat_interval = opts.heartbeat_interval or 2,
    enable_heartbeat = opts.enable_heartbeat ~= false,
    status_max_age_ms = opts.status_max_age_ms or 1000,
    trace_send_interval = opts.trace_send_interval or 5,
    last_status = 0,
    last_heartbeat = 0,
    last_heartbeat_warn = 0,
    last_status_trace = 0,
    last_heartbeat_trace = 0
  }
  return setmetatable(self, { __index = telemetry })
end

local function now()
  return os.epoch("utc")
end

local function is_terminate_error(err)
  local message = tostring(err or ""):match("^%s*(.-)%s*$"):lower()
  return message == "terminate" or message == "terminated"
end

local function count_table(value)
  if type(value) ~= "table" then return 0 end
  if #value > 0 then return #value end
  local n = 0
  for _, _ in pairs(value) do n = n + 1 end
  return n
end

local function maybe_trace_send(self, kind, payload, ts)
  if self.log_prefix ~= "RT" then return end
  local trace_interval_ms = math.max(1000, (tonumber(self.trace_send_interval) or 5) * 1000)
  if kind == "heartbeat" then
    if ts - (self.last_heartbeat_trace or 0) < trace_interval_ms then return end
    self.last_heartbeat_trace = ts
    utils.log(self.log_prefix, ("Heartbeat send role=%s node=%s state=%s payload=%s"):format(
      tostring(self.comms and self.comms.network and self.comms.network.role or "?"),
      tostring(self.comms and self.comms.network and self.comms.network.id or "?"),
      tostring(type(payload) == "table" and payload.state or "-"),
      type(payload)
    ), "INFO")
    return
  end
  if ts - (self.last_status_trace or 0) < trace_interval_ms then return end
  self.last_status_trace = ts
  utils.log(self.log_prefix, ("Status send role=%s node=%s mode=%s state=%s output=%s turbines=%d reactors=%d modules=%d meta_role=%s"):format(
    tostring(self.comms and self.comms.network and self.comms.network.role or "?"),
    tostring(self.comms and self.comms.network and self.comms.network.id or "?"),
    tostring(type(payload) == "table" and payload.mode or "-"),
    tostring(type(payload) == "table" and payload.state or "-"),
    tostring(type(payload) == "table" and payload.output or "-"),
    count_table(type(payload) == "table" and payload.turbines or nil),
    count_table(type(payload) == "table" and payload.reactors or nil),
    count_table(type(payload) == "table" and payload.modules or nil),
    tostring(type(payload) == "table" and type(payload.meta) == "table" and payload.meta.role or "-")
  ), "INFO")
end

function telemetry:tick()
  local ts = now()
  local heartbeat_elapsed = ts - self.last_heartbeat
  local heartbeat_interval_ms = self.heartbeat_interval * 1000
  if self.enable_heartbeat and self.last_heartbeat > 0 and heartbeat_interval_ms > 0 then
    local warn_threshold = heartbeat_interval_ms * 2
    if heartbeat_elapsed > warn_threshold and ts - self.last_heartbeat_warn >= warn_threshold then
      utils.log(
        self.log_prefix,
        ("Heartbeat tick delayed by %dms (interval=%dms)"):format(heartbeat_elapsed, heartbeat_interval_ms),
        "WARN"
      )
      self.last_heartbeat_warn = ts
    end
  end
  if self.enable_heartbeat and heartbeat_elapsed >= heartbeat_interval_ms then
    self.last_heartbeat = ts
    if self.heartbeat_state then
      local heartbeat_payload = self.heartbeat_state()
      self.comms:send_heartbeat(heartbeat_payload)
      maybe_trace_send(self, "heartbeat", heartbeat_payload, ts)
    else
      self.comms:send_heartbeat({})
      maybe_trace_send(self, "heartbeat", {}, ts)
    end
  end
  if ts - self.last_status >= self.status_interval * 1000 then
    self.last_status = ts
    if self.build_payload then
      local ok, payload = pcall(self.build_payload, {
        reason = "telemetry_status",
        max_age_ms = self.status_max_age_ms
      })
      if ok and payload then
        local build = build_info.get()
        payload.meta = payload.meta or {
          proto_ver = constants.proto_ver,
          role = self.comms.network and self.comms.network.role or nil,
          node_id = self.comms.network and self.comms.network.id or nil,
          build = build,
          schema_version = telemetry_schema.version
        }
        self.comms:publish_status(payload)
        maybe_trace_send(self, "status", payload, ts)
      elseif not ok then
        if is_terminate_error(payload) then
          error(payload, 0)
        end
        utils.log(self.log_prefix, "Status payload error: " .. tostring(payload), "WARN")
      end
    end
    local after_status_ts = now()
    local heartbeat_after_status = after_status_ts - self.last_heartbeat
    if self.enable_heartbeat and heartbeat_interval_ms > 0 and heartbeat_after_status >= heartbeat_interval_ms then
      self.last_heartbeat = after_status_ts
      if self.heartbeat_state then
        local heartbeat_payload = self.heartbeat_state()
        self.comms:send_heartbeat(heartbeat_payload)
        maybe_trace_send(self, "heartbeat", heartbeat_payload, after_status_ts)
      else
        self.comms:send_heartbeat({})
        maybe_trace_send(self, "heartbeat", {}, after_status_ts)
      end
    end
  end
end

return telemetry
