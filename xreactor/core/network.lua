local constants = require("shared.constants")
local utils = require("core.utils")
local protocol = require("core.protocol")

local network = {}
local warned = {}

local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  utils.log("NET", message)
end

local function safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(obj[method], ...)
end

local function resolve_node_id(config)
  if config.node_id then
    local normalized = utils.normalize_node_id(config.node_id)
    if normalized ~= "UNKNOWN" then
      if type(config.node_id) ~= "string" then
        warn_once("node_id.normalize", "WARN: normalized node_id to string")
      end
      return normalized
    end
  end
  local path = "/xreactor/config/node_id.txt"
  if fs.exists(path) then
    local file = fs.open(path, "r")
    if file then
      local stored = utils.trim(file.readAll())
      file.close()
      if stored ~= "" then
        return stored
      end
    end
  end
  local generated = os.getComputerLabel() or (config.role .. "-" .. os.getComputerID())
  utils.ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if file then
    file.write(generated)
    file.close()
  end
  return generated
end

local function open_modem(name, channels)
  if not name or not peripheral.isPresent(name) then
    return nil, "missing"
  end
  local modem, err = utils.safe_wrap(name)
  if not modem then
    return nil, "wrap failed: " .. tostring(err)
  end
  if type(modem.open) ~= "function" or type(modem.transmit) ~= "function" then
    return nil, "not a modem"
  end
  local opened = {}
  for _, channel in ipairs(channels or {}) do
    local channel_type = type(channel)
    if channel_type ~= "number" then
      utils.log("NET", "Skipping modem channel open; expected number but got " .. tostring(channel_type) .. " value=" .. tostring(channel), "WARN")
    elseif not opened[channel] then
      utils.log("NET", "Opening modem channel (numeric): " .. tostring(channel))
      local ok, open_err = safe_wrapped_call(modem, "open", channel)
      if not ok then
        return nil, "open failed for channel " .. tostring(channel) .. ": " .. tostring(open_err)
      end
      opened[channel] = true
      utils.log("NET", "Opened modem channel: " .. tostring(channel))
    end
  end
  if not next(opened) then
    return nil, "open failed: no numeric channels"
  end
  return modem
end

local function sorted_names(items)
  local copy = {}
  for _, value in ipairs(items or {}) do
    copy[#copy + 1] = value
  end
  table.sort(copy, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return copy
end

local function discover_modems()
  local discovered = {
    all = {},
    wireless = {},
    wired = {},
    modem_unknown = {},
    modem_like = {}
  }
  if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
    return discovered
  end
  local names = peripheral.getNames() or {}
  for _, name in ipairs(sorted_names(names)) do
    if peripheral.isPresent(name) then
      local type_name = peripheral.getType(name)
      local wrapped = select(1, utils.safe_wrap(name))
      local is_modem_like = type_name == "modem" or type_name == "peripheral_hub"
      if is_modem_like then
        discovered.modem_like[#discovered.modem_like + 1] = {
          name = name,
          type = type_name,
          wrapped = wrapped
        }
      end
      if type_name == "modem" and wrapped then
        local wireless = nil
        if type(wrapped.isWireless) == "function" then
          local ok, result = safe_wrapped_call(wrapped, "isWireless")
          if ok then
            wireless = result == true
          end
        end
        local entry = {
          name = name,
          type = type_name,
          wireless = wireless,
          wrapped = wrapped
        }
        discovered.all[#discovered.all + 1] = entry
        if wireless == true then
          discovered.wireless[#discovered.wireless + 1] = entry
        elseif wireless == false then
          discovered.wired[#discovered.wired + 1] = entry
        else
          discovered.modem_unknown[#discovered.modem_unknown + 1] = entry
        end
      elseif type_name == "peripheral_hub" and wrapped then
        discovered.wired[#discovered.wired + 1] = {
          name = name,
          type = type_name,
          wireless = false,
          wrapped = wrapped
        }
      end
    end
  end
  return discovered
end

local function modem_type_matches_expected(entry, expected)
  if not entry then
    return false, "missing"
  end
  if expected == "wireless" then
    if entry.type ~= "modem" then
      return false, "not modem"
    end
    if entry.wireless == false then
      return false, "wired modem"
    end
    return true
  end
  if expected == "wired" then
    if entry.type == "peripheral_hub" then
      return true
    end
    if entry.type == "modem" then
      if entry.wireless == true then
        return false, "wireless modem"
      end
      return true
    end
    return false, "unsupported type"
  end
  return false, "unsupported expectation"
end

local function entry_by_name(discovered, name)
  if not discovered or not name then return nil end
  for _, entry in ipairs(discovered.modem_like or {}) do
    if entry.name == name then
      return entry
    end
  end
  return nil
end

local function pick_first(entries, excluded_name)
  for _, entry in ipairs(entries or {}) do
    if not excluded_name or entry.name ~= excluded_name then
      return entry
    end
  end
  return nil
end

local function resolve_modems(config)
  local discovered = discover_modems()
  local selected = {
    wireless = nil,
    wired = nil,
    wireless_source = "autodetect",
    wired_source = "autodetect"
  }

  local wireless_override = type(config.wireless_modem) == "string" and config.wireless_modem or nil
  local wired_override = type(config.wired_modem) == "string" and config.wired_modem or nil
  local legacy_modem = type(config.modem) == "string" and config.modem or nil

  if not wireless_override and legacy_modem then
    wireless_override = legacy_modem
    warn_once("modem.legacy.alias", "WARN: legacy config field \"modem\" detected; treating as wireless_modem override")
  elseif wireless_override and legacy_modem and wireless_override ~= legacy_modem then
    warn_once("modem.legacy.ignored", "WARN: legacy modem field ignored because wireless_modem override is set")
  end

  if wireless_override then
    local entry = entry_by_name(discovered, wireless_override)
    local ok, reason = modem_type_matches_expected(entry, "wireless")
    if ok then
      selected.wireless = entry
      selected.wireless_source = "config override"
    else
      warn_once("modem.override.wireless", "WARN: configured wireless_modem \"" .. tostring(wireless_override) .. "\" invalid (" .. tostring(reason) .. "); falling back to autodetect")
    end
  end

  if wired_override then
    local entry = entry_by_name(discovered, wired_override)
    local ok, reason = modem_type_matches_expected(entry, "wired")
    if ok then
      selected.wired = entry
      selected.wired_source = "config override"
    else
      warn_once("modem.override.wired", "WARN: configured wired_modem \"" .. tostring(wired_override) .. "\" invalid (" .. tostring(reason) .. "); falling back to autodetect")
    end
  end

  if not selected.wireless then
    selected.wireless = pick_first(discovered.wireless)
    if not selected.wireless then
      selected.wireless = pick_first(discovered.modem_unknown)
      if selected.wireless then
        warn_once("modem.autodetect.unknown", "WARN: wireless modem autodetect using modem without isWireless() signal: " .. tostring(selected.wireless.name))
      end
    end
  end

  if not selected.wired then
    selected.wired = pick_first(discovered.wired, selected.wireless and selected.wireless.name or nil)
    if not selected.wired and selected.wireless then
      local wireless_ok_for_wired = modem_type_matches_expected(selected.wireless, "wired")
      if wireless_ok_for_wired then
        selected.wired = selected.wireless
        warn_once("modem.shared", "WARN: using same modem for wireless and wired paths: " .. tostring(selected.wired.name))
      end
    end
  end

  return selected, discovered
end

local function channel_number(value, fallback)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed then
      return parsed
    end
  end
  if type(value) == "table" then
    local candidate = value.channel or value.value or value.id or value[1]
    local parsed = tonumber(candidate)
    if parsed then
      return parsed
    end
  end
  return fallback
end

local function resolve_channels(config)
  local channels = type(config.channels) == "table" and config.channels or {}
  local control = channel_number(channels.control, constants.channels.CONTROL)
  local status = channel_number(channels.status, constants.channels.STATUS)
  return { control = control, status = status }
end

local function legacy_receive_disabled()
  warn_once("receive.legacy", "WARN: network.receive() is legacy/disabled; use modem_message event handling via comms_service")
  return nil, "legacy receive disabled"
end

local function legacy_receive(timeout)
  local timer
  if timeout then
    timer = os.startTimer(timeout)
  end
  while true do
    local event = { os.pullEvent() }
    if event[1] == "modem_message" then
      local _, _, _, _, message = table.unpack(event)
      local ok, err = protocol.validateMessage(message)
      if ok then
        return protocol.sanitize_message(message)
      end
      warn_once("schema:" .. tostring(err), "WARN: invalid message ignored (" .. tostring(err) .. ")")
    elseif event[1] == "timer" and event[2] == timer then
      return nil
    end
  end
end

local function safe_call_remote(wired, device_name, method, ...)
  if not wired then
    return nil, "wired modem missing"
  end
  if type(wired.callRemote) ~= "function" then
    return nil, "wired modem unsupported"
  end
  if type(wired.isPresentRemote) == "function" then
    local ok_present, present_or_err = safe_wrapped_call(wired, "isPresentRemote", device_name)
    if not ok_present then
      return nil, present_or_err
    end
    if not present_or_err then
      return nil, "remote peripheral missing"
    end
  end
  local results = table.pack(safe_wrapped_call(wired, "callRemote", device_name, method, ...))
  if not results[1] then
    return nil, results[2]
  end
  if results.n == 1 then
    return true
  end
  return table.unpack(results, 2, results.n)
end


function network.init(config)
  config = config or {}
  local channels = resolve_channels(config)
  local selected_modems = resolve_modems(config)
  local wireless_name = selected_modems.wireless and selected_modems.wireless.name or nil
  local wired_name = selected_modems.wired and selected_modems.wired.name or nil

  if wireless_name then
    utils.log("NET", "Wireless modem selected: " .. tostring(wireless_name) .. " (" .. tostring(selected_modems.wireless_source) .. ")")
  else
    warn_once("modem.autodetect.none.wireless", "WARN: no wireless modem found (override/autodetect)")
  end
  if wired_name then
    utils.log("NET", "Wired modem selected: " .. tostring(wired_name) .. " (" .. tostring(selected_modems.wired_source) .. ")")
  else
    warn_once("modem.autodetect.none.wired", "WARN: no wired modem/peripheral hub found; remote peripherals disabled")
  end

  utils.log("NET", ("Resolved channels control=%s status=%s"):format(tostring(channels.control), tostring(channels.status)))
  local modem, modem_err = open_modem(wireless_name, { channels.control, channels.status })
  local wired = wired_name and select(1, utils.safe_wrap(wired_name)) or nil
  local node_id = resolve_node_id(config)
  if not modem then
    warn_once("modem.missing", "WARN: wireless modem missing; comms disabled (" .. tostring(modem_err) .. ")")
    return {
      modem = nil,
      wired = wired,
      selected_modems = selected_modems,
      channels = channels,
      id = node_id,
      role = config.role,
      send = function(_, _, _)
        return false, "wireless modem missing"
      end,
      receive = function(_, timeout)
        if config.allow_legacy_receive == true then
          return legacy_receive(timeout)
        end
        return legacy_receive_disabled()
      end,
      broadcast = function(_, _)
        return false, "wireless modem missing"
      end,
      push_wired = function(_, device_name, method, ...)
        return safe_call_remote(wired, device_name, method, ...)
      end
    }
  end
  return {
    modem = modem,
    wired = wired,
    selected_modems = selected_modems,
    channels = channels,
    id = node_id,
    role = config.role,
    send = function(_, channel, payload)
      local sanitized = protocol.sanitize_message(payload)
      if not sanitized then
        return false, "invalid payload"
      end
      local ok, err = safe_wrapped_call(modem, "transmit", channel, channel, sanitized)
      if not ok then
        return false, tostring(err)
      end
      return true
    end,
    receive = function(_, timeout)
      if config.allow_legacy_receive == true then
        return legacy_receive(timeout)
      end
      return legacy_receive_disabled()
    end,
    broadcast = function(_, payload)
      local sanitized = protocol.sanitize_message(payload)
      if not sanitized then
        return false, "invalid payload"
      end
      local ok, err = safe_wrapped_call(modem, "transmit", channels.control, channels.control, sanitized)
      if not ok then
        return false, tostring(err)
      end
      return true
    end,
    push_wired = function(_, device_name, method, ...)
      return safe_call_remote(wired, device_name, method, ...)
    end
  }
end

return network
