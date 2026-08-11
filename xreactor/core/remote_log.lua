local M = {}

-- Fix (2026-06-30): DEFAULT_CHANNEL war 6502, aber shared/constants.lua
-- definiert channels.LOG = 6503 (dort als bewusst gewaehlter, von
-- Control/Status getrennter Kanal dokumentiert). log_collector/main.lua
-- liest den Kanal aus shared.constants (6503), waehrend remote_log.lua
-- (Sender auf RT/Energy/Master) bisher fest 6502 nutzte — kompletter
-- Kanal-Mismatch, LOG empfing dadurch dauerhaft NICHTS (Recv 0), obwohl
-- alle Sender korrekt funkten und ein Ender Modem vorhanden war.
local DEFAULT_CHANNEL = 6503
local NODE_ID_PATH = "/xreactor/config/node_id.txt"
local ROLE_CONFIG_PATH = "/xreactor/config/role.lua"

local state = {
  initialized = false,
  enabled = true,
  channel = DEFAULT_CHANNEL,
  modem = nil,
  modem_name = nil,
  node_id = nil,
  role = nil,
  boot_id = nil,
  seq = 0,
  dropped = 0,
  sent = 0
}

local function read_file(path)
  if not fs or not fs.exists or not fs.exists(path) then return nil end
  local ok, file = pcall(fs.open, path, "r")
  if not ok or not file then return nil end
  local content = file.readAll()
  file.close()
  return content
end

local function trim(text)
  return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function read_node_id()
  local value = trim(read_file(NODE_ID_PATH) or "")
  if value ~= "" then return value end
  if os and type(os.getComputerID) == "function" then
    return "pc-" .. tostring(os.getComputerID())
  end
  return "unknown-node"
end

local function read_role()
  local content = read_file(ROLE_CONFIG_PATH)
  if type(content) == "string" then
    local loader = load(content, "=role", "t", {})
    if loader then
      local ok, result = pcall(loader)
      if ok and type(result) == "table" and type(result.role) == "string" then
        return result.role
      end
    end
  end
  return "UNKNOWN"
end

local function settings_bool(key, fallback)
  if settings and type(settings.get) == "function" then
    local value = settings.get(key)
    if type(value) == "boolean" then return value end
  end
  return fallback
end

local function settings_number(key, fallback)
  if settings and type(settings.get) == "function" then
    local value = tonumber(settings.get(key))
    if value then return value end
  end
  return fallback
end

local function find_wireless_modem()
  if not peripheral or type(peripheral.getNames) ~= "function" then return nil, nil end
  local names_ok, names = pcall(peripheral.getNames)
  if not names_ok or type(names) ~= "table" then return nil, nil end
  local fallback_name, fallback_modem = nil, nil
  for _, name in ipairs(names) do
    local ok_type, p_type = pcall(peripheral.getType, name)
    if ok_type and p_type == "modem" then
      local ok_wrap, modem = pcall(peripheral.wrap, name)
      if ok_wrap and modem then
        local is_wireless = false
        if type(modem.isWireless) == "function" then
          local ok_wireless, result = pcall(modem.isWireless)
          is_wireless = ok_wireless and result == true
        end
        if is_wireless then return name, modem end
        fallback_name, fallback_modem = fallback_name or name, fallback_modem or modem
      end
    end
  end
  return fallback_name, fallback_modem
end

function M.init(opts)
  opts = opts or {}
  state.enabled = opts.enabled
  if state.enabled == nil then state.enabled = settings_bool("xreactor.remote_logging", true) end
  state.channel = tonumber(opts.channel) or settings_number("xreactor.remote_log_channel", DEFAULT_CHANNEL)
  state.node_id = opts.node_id or read_node_id()
  state.role = opts.role or read_role()
  state.boot_id = tostring(state.node_id) .. ":boot:"
    .. tostring(os and os.getComputerID and os.getComputerID() or "unknown") .. ":"
    .. tostring(os and os.epoch and os.epoch("utc") or 0)
  state.modem_name, state.modem = find_wireless_modem()
  state.initialized = true
  return M.describe()
end

function M.send(prefix, level, message, line)
  local ok = pcall(function()
    if not state.initialized then M.init({}) end
    if not state.enabled or not state.modem then
      state.dropped = state.dropped + 1
      return
    end
    state.seq = state.seq + 1
    local payload = {
      type = "LOG_EVENT",
      proto = "xreactor-log-v2",
      node_id = state.node_id or read_node_id(),
      role = state.role or read_role(),
      prefix = tostring(prefix or "LOG"),
      level = tostring(level or "INFO"),
      message = tostring(message or ""),
      line = tostring(line or ""),
      seq = state.seq,
      boot_id = state.boot_id,
      event_id = state.boot_id .. ":" .. tostring(state.seq),
      ack = false,
      ts = os and os.epoch and os.epoch("utc") or nil
    }
    local ok_protocol, protocol = pcall(require, "core.protocol")
    local secret = ok_protocol and protocol.resolve_auth_secret({}) or nil
    local mac = secret and protocol.sign_value(protocol.log_auth_value(payload), secret) or nil
    if not mac then state.dropped = state.dropped + 1; return end
    payload.auth = { algorithm = "HMAC-SHA256", mac = mac }
    state.modem.transmit(state.channel, state.channel, payload)
    state.sent = state.sent + 1
  end)
  if not ok then state.dropped = state.dropped + 1 end
end

function M.describe()
  return {
    enabled = state.enabled == true,
    channel = state.channel,
    modem = state.modem_name,
    node_id = state.node_id,
    role = state.role,
    sent = state.sent,
    dropped = state.dropped
  }
end

return M
