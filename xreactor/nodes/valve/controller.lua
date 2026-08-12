-- Dedicated, testable controller for one Mekanism Logistical Sorter.
--
-- The VALVE role uses the sorter's automatic-ejection mode as its only
-- actuator: blocked=true disables automatic ejection.  This module owns the
-- physical write/readback, command deduplication, sender pairing and the
-- optional one-colour status monitor.  The top-level main.lua only wires it
-- into CC:Tweaked services.

local M = {}
M.__index = M

local AUTO_MODE_READERS = { "getAutoMode", "isAutoMode", "getAutoEject", "isAutoEject" }
local SEEN_COMMAND_LIMIT = 16

local function now_ms(os_api)
  if os_api and type(os_api.epoch) == "function" then return os_api.epoch("utc") end
  return 0
end

local function valid_string(value)
  return type(value) == "string" and value ~= ""
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.config) == "table", "valve controller requires config")
  assert(valid_string(opts.node_id), "valve controller requires node_id")
  assert(type(opts.constants) == "table", "valve controller requires constants")
  assert(type(opts.utils) == "table", "valve controller requires utils")

  local self = setmetatable({
    config = opts.config,
    config_path = opts.config_path,
    node_id = opts.node_id,
    constants = opts.constants,
    utils = opts.utils,
    log_prefix = opts.log_prefix or "VALVE",
    peripheral = opts.peripheral_api or peripheral,
    colors = opts.colors_api or colors,
    os = opts.os_api or os,

    current_high = nil,
    initialized = false,
    last_write_error = nil,
    last_command_ts = now_ms(opts.os_api or os),
    sorter_device = nil,
    sorter_resolved_name = nil,
    status_monitor = nil,
    status_monitor_last_color = nil,
    seen_commands = {},
    seen_order = {},
    pairing_persisted = opts.config.trusted_source ~= nil,
    last_pairing_error = nil,
    last_failsafe_attempt_ts = 0,
  }, M)
  return self
end

function M:_log(message, level)
  self.utils.log(self.log_prefix, message, level)
end

function M:_find_sorter_by_capability()
  local p = self.peripheral
  if not p or type(p.getNames) ~= "function" or type(p.getMethods) ~= "function" then return nil end
  local ok_names, names = pcall(p.getNames)
  if not ok_names or type(names) ~= "table" then return nil end
  for _, name in ipairs(names) do
    local ok, methods = pcall(p.getMethods, name)
    if ok and type(methods) == "table" then
      for _, method in ipairs(methods) do
        if method == "setAutoMode" then return name end
      end
    end
  end
  return nil
end

function M:_get_sorter()
  if self.sorter_device then return self.sorter_device end
  local name = self.config.sorter_name
  if name == nil then
    name = self:_find_sorter_by_capability()
    if not name then return nil end
  end
  if not self.peripheral or type(self.peripheral.wrap) ~= "function" then return nil end
  local ok, dev = pcall(self.peripheral.wrap, name)
  if ok and dev and type(dev.setAutoMode) == "function" then
    self.sorter_device = dev
    self.sorter_resolved_name = name
  end
  return self.sorter_device
end

function M:_read_sorter_auto_mode(sorter)
  local found_reader = false
  local last_error = nil
  for _, method in ipairs(AUTO_MODE_READERS) do
    if type(sorter and sorter[method]) == "function" then
      found_reader = true
      local ok, value = pcall(sorter[method])
      if ok and type(value) == "boolean" then return value, method end
      last_error = ok and ("non-boolean readback from " .. method) or tostring(value)
    end
  end
  if found_reader then return nil, nil, last_error or "auto-mode readback failed" end
  return nil, nil, "readback_unavailable"
end

function M:_write_actuator(high)
  local sorter = self:_get_sorter()
  if not sorter then
    local label = self.config.sorter_name and ("'" .. tostring(self.config.sorter_name) .. "'")
      or "automatic discovery failed"
    return false, "sorter not found (" .. label .. ")"
  end

  -- high=true means BLOCKED, so automatic ejection must be disabled.
  local desired_auto = not high
  local ok, result = pcall(sorter.setAutoMode, desired_auto)
  if not ok or result == false then
    -- A peripheral handle may survive a detach.  Never cache a failed handle.
    self.sorter_device = nil
    return false, ok and "setAutoMode returned false" or tostring(result)
  end

  -- If the integration offers readback it is mandatory proof.  Otherwise a
  -- fresh successful physical write is the strongest proof available.
  local auto_mode, reader, read_err = self:_read_sorter_auto_mode(sorter)
  if reader ~= nil then
    if auto_mode ~= desired_auto then
      return false, "sorter readback mismatch via " .. tostring(reader)
        .. " expected_auto=" .. tostring(desired_auto)
        .. " actual_auto=" .. tostring(auto_mode)
    end
  elseif read_err ~= "readback_unavailable" then
    return false, tostring(read_err)
  end
  return true, nil, reader or "write-confirmed"
end

function M:_get_status_monitor()
  if self.status_monitor then return self.status_monitor end
  local p = self.peripheral
  if not p or type(p.find) ~= "function" then return nil end
  local ok, mon = pcall(p.find, "monitor")
  if ok and mon then self.status_monitor = mon end
  return self.status_monitor
end

function M:render_status_monitor()
  local mon = self:_get_status_monitor()
  if not mon then return end
  local color
  if not self.initialized or self.last_write_error then color = self.colors.orange
  else color = self.current_high and self.colors.red or self.colors.green end
  if self.status_monitor_last_color == color then return end
  local ok = pcall(function()
    mon.setBackgroundColor(color)
    mon.clear()
  end)
  if ok then self.status_monitor_last_color = color
  else self.status_monitor = nil; self.status_monitor_last_color = nil end
end

function M:apply_valve(high, force_physical)
  if type(high) ~= "boolean" then return false end
  if not force_physical and self.initialized and high == self.current_high then
    self:render_status_monitor()
    return true
  end

  local ok, err, proof = self:_write_actuator(high)
  if not ok then
    self.last_write_error = tostring(err)
    self:render_status_monitor()
    self:_log("Sorter write failed (" .. tostring(self.sorter_resolved_name or self.config.sorter_name or "?")
      .. "): " .. tostring(err), "ERROR")
    return false
  end

  self.current_high = high
  self.initialized = true
  self.last_write_error = nil
  self.last_command_ts = now_ms(self.os)
  self:render_status_monitor()
  self:_log(string.format("Sorter %s -> %s proof=%s",
    tostring(self.sorter_resolved_name or self.config.sorter_name or "?"),
    high and "BLOCKED" or "OPEN", tostring(proof or "write")), "INFO")
  return true
end

function M:_remember_command(id, src, high)
  if self.seen_commands[id] then return end
  self.seen_commands[id] = { src = src, high = high }
  self.seen_order[#self.seen_order + 1] = id
  while #self.seen_order > SEEN_COMMAND_LIMIT do
    local old = table.remove(self.seen_order, 1)
    if old then self.seen_commands[old] = nil end
  end
end

function M:_send_ack(reply_side, command_id, applied, high, err, dst, persisted)
  if not command_id or not reply_side or not self.peripheral
      or type(self.peripheral.wrap) ~= "function" then return end
  local ok, modem = pcall(self.peripheral.wrap, reply_side)
  if not ok or not modem or type(modem.transmit) ~= "function" then return end
  pcall(modem.transmit, self.constants.channels.VALVE, self.constants.channels.VALVE, {
    type = "VALVE_ACK", command_id = command_id, applied = applied == true,
    high = high, error = err, src = self.node_id, dst = dst, persisted = persisted,
  })
end

function M:handle_event(event)
  if type(event) ~= "table" or event[1] ~= "modem_message" then return false end
  local reply_side, channel, message = event[2], event[3], event[5]
  if channel ~= self.constants.channels.VALVE then return false end
  if type(message) ~= "table" or message.type ~= "SET_VALVE" or message.dst ~= self.node_id then return false end
  if not valid_string(message.src) then
    self:_log("SET_VALVE without valid src ignored", "WARN")
    return false
  end
  if not valid_string(message.command_id) then
    self:_log("SET_VALVE without valid command_id ignored", "WARN")
    return false
  end
  if type(message.high) ~= "boolean" then
    self:_log("SET_VALVE without valid high ignored", "WARN")
    return false
  end
  if self.config.trusted_source and message.src ~= self.config.trusted_source then
    self:_log("SET_VALVE from untrusted source ignored: " .. tostring(message.src), "WARN")
    return false
  end

  local seen = self.seen_commands[message.command_id]
  if seen and (seen.src ~= message.src or seen.high ~= message.high) then
    self:_log("SET_VALVE command_id reuse with different payload rejected: "
      .. tostring(message.command_id), "WARN")
    self:_send_ack(reply_side, message.command_id, false, self.current_high,
      "COMMAND_ID_REUSE", message.src, self.pairing_persisted)
    return false
  end

  -- Every accepted command, including a retry, gets a fresh physical write.
  -- RAM state alone is never sufficient evidence for an actuator ACK.
  local applied = self:apply_valve(message.high, true)
  if not applied then
    self:_send_ack(reply_side, message.command_id, false, self.current_high,
      self.last_write_error, message.src,
      self.config.trusted_source ~= nil and self.pairing_persisted or false)
    return false
  end

  if not self.config.trusted_source then
    self.config.trusted_source = message.src
    local ok_pair, pair_err = self.utils.write_config(self.config_path, self.config)
    if ok_pair ~= true then
      self.config.trusted_source = nil
      self.pairing_persisted = false
      self.last_pairing_error = tostring(pair_err or "write_config failed")
      local blocked_ok = self:apply_valve(true, true)
      self:_log("trusted_source pairing was not persisted (" .. self.last_pairing_error
        .. "); fail-safe BLOCKED=" .. tostring(blocked_ok), "ERROR")
      self:_send_ack(reply_side, message.command_id, false, self.current_high,
        "PAIRING_PERSIST_FAILED:" .. self.last_pairing_error, message.src, false)
      return false
    end
    self.pairing_persisted = true
    self.last_pairing_error = nil
    self:_log("trusted_source paired persistently to " .. tostring(message.src), "INFO")
  end

  self:_remember_command(message.command_id, message.src, message.high)
  self:_send_ack(reply_side, message.command_id, true, self.current_high, nil,
    message.src, self.pairing_persisted)
  return true
end

function M:tick_failsafe(stale_command_s, retry_ms)
  local now = now_ms(self.os)
  local age_s = self.last_command_ts and ((now - self.last_command_ts) / 1000) or math.huge
  local stale = age_s > (tonumber(stale_command_s) or 20)
  local uncertain = not self.initialized or self.last_write_error ~= nil
  if not (uncertain or stale) or (now - self.last_failsafe_attempt_ts) < (tonumber(retry_ms) or 2000) then
    return false
  end
  self.last_failsafe_attempt_ts = now
  self:_log(uncertain and "Actuator state unconfirmed; fail-safe writes BLOCKED again"
    or string.format("No SET_VALVE for %.0fs; fail-safe confirms BLOCKED again", age_s), "WARN")
  return self:apply_valve(true, true)
end

function M:get_state()
  return {
    current_high = self.current_high,
    initialized = self.initialized,
    last_write_error = self.last_write_error,
    last_command_ts = self.last_command_ts,
    sorter_name = self.sorter_resolved_name or self.config.sorter_name,
    trusted_source = self.config.trusted_source,
    pairing_persisted = self.pairing_persisted,
    pairing_error = self.last_pairing_error,
  }
end

return M
