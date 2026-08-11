local constants = require("shared.constants")
local utils = require("core.utils")

local protocol = {}
local protocol_sequence = 0
local UINT32 = 4294967296
local SHA256_K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function add32(...)
  local sum = 0
  for i = 1, select("#", ...) do sum = (sum + select(i, ...)) % UINT32 end
  return sum
end

local function word_bytes(value)
  return string.char(
    bit32.band(bit32.rshift(value, 24), 0xff),
    bit32.band(bit32.rshift(value, 16), 0xff),
    bit32.band(bit32.rshift(value, 8), 0xff),
    bit32.band(value, 0xff))
end

local function sha256_raw(input)
  if not bit32 then return nil, "bit32 unavailable" end
  local bit_len = #input * 8
  local high = math.floor(bit_len / UINT32)
  local low = bit_len % UINT32
  local pad_len = (56 - ((#input + 1) % 64)) % 64
  local data = input .. string.char(0x80) .. string.rep(string.char(0), pad_len)
    .. word_bytes(high) .. word_bytes(low)
  local h = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
  for offset = 1, #data, 64 do
    local w = {}
    for i = 0, 15 do
      local p = offset + i * 4
      w[i] = add32(bit32.lshift(data:byte(p), 24), bit32.lshift(data:byte(p + 1), 16),
        bit32.lshift(data:byte(p + 2), 8), data:byte(p + 3))
    end
    for i = 16, 63 do
      local a = w[i - 15]
      local b = w[i - 2]
      local s0 = bit32.bxor(bit32.rrotate(a, 7), bit32.rrotate(a, 18), bit32.rshift(a, 3))
      local s1 = bit32.bxor(bit32.rrotate(b, 17), bit32.rrotate(b, 19), bit32.rshift(b, 10))
      w[i] = add32(w[i - 16], s0, w[i - 7], s1)
    end
    local a,b,c,d,e,f,g,hh = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]
    for i = 0, 63 do
      local s1 = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
      local ch = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
      local t1 = add32(hh, s1, ch, SHA256_K[i + 1], w[i])
      local s0 = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
      local maj = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
      local t2 = add32(s0, maj)
      hh,g,f,e,d,c,b,a = g,f,e,add32(d, t1),c,b,a,add32(t1, t2)
    end
    h[1],h[2],h[3],h[4] = add32(h[1],a),add32(h[2],b),add32(h[3],c),add32(h[4],d)
    h[5],h[6],h[7],h[8] = add32(h[5],e),add32(h[6],f),add32(h[7],g),add32(h[8],hh)
  end
  local out = {}
  for i = 1, 8 do out[i] = word_bytes(h[i]) end
  return table.concat(out)
end

local function hmac_sha256_hex(secret, content)
  secret = tostring(secret or "")
  if #secret > 64 then
    local hashed, err = sha256_raw(secret)
    if not hashed then return nil, err end
    secret = hashed
  end
  secret = secret .. string.rep(string.char(0), 64 - #secret)
  local inner, outer = {}, {}
  for i = 1, 64 do
    local byte = secret:byte(i)
    inner[i] = string.char(bit32.bxor(byte, 0x36))
    outer[i] = string.char(bit32.bxor(byte, 0x5c))
  end
  local inner_hash, err = sha256_raw(table.concat(inner) .. content)
  if not inner_hash then return nil, err end
  local digest
  digest, err = sha256_raw(table.concat(outer) .. inner_hash)
  if not digest then return nil, err end
  return (digest:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function canonical(value, seen)
  local kind = type(value)
  if kind == "nil" then return "n" end
  if kind == "boolean" then return value and "b1" or "b0" end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil, "non-finite number" end
    return "d" .. string.format("%.17g", value)
  end
  if kind == "string" then return "s" .. tostring(#value) .. ":" .. value end
  if kind ~= "table" then return nil, "unsupported value type" end
  seen = seen or {}
  if seen[value] then return nil, "cyclic table" end
  seen[value] = true
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" and type(key) ~= "number" then seen[value] = nil; return nil, "unsupported key type" end
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    local lt, rt = type(left), type(right)
    if lt ~= rt then return lt < rt end
    return left < right
  end)
  local parts = { "t", tostring(#keys), ":" }
  for _, key in ipairs(keys) do
    local encoded_key, key_err = canonical(key, seen)
    local encoded_value, value_err = canonical(value[key], seen)
    if not encoded_key or not encoded_value then seen[value] = nil; return nil, key_err or value_err end
    parts[#parts + 1] = encoded_key
    parts[#parts + 1] = encoded_value
  end
  seen[value] = nil
  return table.concat(parts)
end

local function auth_material(message)
  return canonical({
    type = message.type, message_id = message.message_id, src = message.src,
    sender_id = message.sender_id, node_id = message.node_id, dst = message.dst,
    role = message.role, ts = message.ts, timestamp = message.timestamp,
    proto_ver = message.proto_ver, ack_for = message.ack_for, phase = message.phase,
    payload = message.payload,
  })
end

local function constant_equals(left, right)
  if type(left) ~= "string" or type(right) ~= "string" or #left ~= #right then return false end
  local diff = 0
  for i = 1, #left do diff = bit32.bor(diff, bit32.bxor(left:byte(i), right:byte(i))) end
  return diff == 0
end

local function normalize_proto(ver)
  if type(ver) == "table" then
    local major = tonumber(ver.major)
    local minor = tonumber(ver.minor) or 0
    if major then return { major = major, minor = minor } end
  elseif type(ver) == "string" then
    local major, minor = ver:match("^(%d+)%.(%d+)$")
    if major then return { major = tonumber(major), minor = tonumber(minor) } end
    local single = tonumber(ver)
    if single then return { major = single, minor = 0 } end
  elseif type(ver) == "number" then
    return { major = ver, minor = 0 }
  end
  return nil
end

local function is_proto_compatible(ver)
  local current = normalize_proto(constants.proto_ver)
  local incoming = normalize_proto(ver)
  if not incoming then return false, "missing/invalid proto_ver" end
  if incoming.major ~= current.major then return false, "proto_ver mismatch" end
  return true
end

local MAX_VALUE_DEPTH = 6
local MAX_TABLE_ENTRIES = 256
local MAX_STRING_LENGTH = 4096
local MAX_ID_LENGTH = 128

local function sanitize_value(value, depth)
  if depth > MAX_VALUE_DEPTH then return nil end
  local value_type = type(value)
  if value_type == "string" then return value:sub(1, MAX_STRING_LENGTH) end
  if value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if value_type == "boolean" then return value end
  if value_type ~= "table" then return nil end
  local out = {}
  local count = 0
  for k, v in pairs(value) do
    count = count + 1
    if count > MAX_TABLE_ENTRIES then break end
    local key_type = type(k)
    if key_type == "string" or key_type == "number" then
      if key_type == "string" then k = k:sub(1, MAX_STRING_LENGTH) end
      local sanitized = sanitize_value(v, depth + 1)
      if sanitized ~= nil then out[k] = sanitized end
    end
  end
  return out
end

-- normalize_node_id() intentionally has a local-computer fallback for callers
-- creating their own identity. Incoming network fields must NOT use that
-- fallback: an absent/blank remote src is invalid, not "this computer".
local function normalize_remote_id(value)
  if value == nil then return nil end
  local text = tostring(value):match("^%s*(.-)%s*$") or ""
  if text == "" then return nil end
  return utils.normalize_node_id(text)
end

local function base_message(msg_type, sender_id, role, payload)
  local ts = os.epoch("utc")
  local normalized_sender = utils.normalize_node_id(sender_id)
  protocol_sequence = protocol_sequence + 1
  return {
    type = msg_type,
    message_id = string.format("%s-%d-%d", tostring(normalized_sender), ts, protocol_sequence),
    sender_id = normalized_sender,
    src = normalized_sender,
    dst = nil,
    node_id = normalized_sender,
    role = role,
    ts = ts,
    timestamp = ts,
    proto_ver = normalize_proto(constants.proto_ver),
    payload = payload or {}
  }
end

function protocol.hello(sender_id, role, capabilities)
  return base_message(constants.message_types.HELLO, sender_id, role, { capabilities = capabilities })
end

function protocol.register(sender_id, role, capabilities)
  return base_message(constants.message_types.REGISTER, sender_id, role, { capabilities = capabilities })
end

function protocol.heartbeat(sender_id, role, state)
  return base_message(constants.message_types.HEARTBEAT, sender_id, role, { state = state })
end

function protocol.status(sender_id, role, payload)
  return base_message(constants.message_types.STATUS, sender_id, role, payload)
end

function protocol.alert(sender_id, role, severity, message)
  return base_message(constants.message_types.ALERT, sender_id, role, { severity = severity, message = message })
end

function protocol.command(sender_id, role, target_node, command)
  command = type(command) == "table" and command or {}
  command.command_id = command.command_id or os.epoch("utc")
  local msg = base_message(constants.message_types.COMMAND, sender_id, role,
    { target = target_node, command = command })
  msg.dst = target_node
  return msg
end

function protocol.ack(sender_id, role, command_id, detail, module_id)
  return base_message(constants.message_types.ACK, sender_id, role,
    { command_id = command_id, detail = detail, module_id = module_id })
end

function protocol.ack_delivered(sender_id, role, command_id, detail)
  return base_message(constants.message_types.ACK_DELIVERED, sender_id, role,
    { command_id = command_id, detail = detail })
end

function protocol.ack_applied(sender_id, role, command_id, result)
  return base_message(constants.message_types.ACK_APPLIED, sender_id, role,
    { command_id = command_id, result = result })
end

function protocol.error(sender_id, role, message)
  return base_message(constants.message_types.ERROR, sender_id, role, { message = message })
end

function protocol.sanitize_message(message)
  if type(message) ~= "table" then return nil end
  local normalized_proto = normalize_proto(message.proto_ver)
  local ts = message.ts or message.timestamp or os.epoch("utc")
  local sender = normalize_remote_id(message.sender_id or message.src)
  local node = normalize_remote_id(message.node_id or message.sender_id or message.src)
  local src = normalize_remote_id(message.src or message.sender_id)
  local sanitized = {
    type = message.type,
    message_id = message.message_id,
    sender_id = sender,
    node_id = node,
    src = src,
    dst = normalize_remote_id(message.dst),
    role = message.role,
    ts = ts,
    timestamp = ts,
    proto_ver = normalized_proto,
    ack_for = message.ack_for,
    phase = message.phase,
    auth = sanitize_value(message.auth, 0),
    payload = sanitize_value(message.payload or {}, 0)
  }
  if type(sanitized.payload) ~= "table" then sanitized.payload = {} end
  return sanitized
end

function protocol.validateMessage(message)
  if type(message) ~= "table" then return false, "message not table" end
  if type(message.type) ~= "string" then return false, "missing type" end
  local sender_id = normalize_remote_id(message.sender_id or message.src)
  if sender_id == nil then return false, "missing sender_id" end
  if #sender_id > MAX_ID_LENGTH then return false, "sender_id too long" end
  if type(message.role) ~= "string" or message.role == "" then return false, "missing role" end
  if #message.role > MAX_ID_LENGTH then return false, "role too long" end
  if type(message.type) == "string" and #message.type > MAX_ID_LENGTH then return false, "type too long" end
  if type(message.message_id) == "string" and #message.message_id > MAX_ID_LENGTH then return false, "message_id too long" end
  if type(message.ts) ~= "number" and type(message.timestamp) ~= "number" then
    return false, "missing timestamp"
  end
  if type(message.payload) ~= "table" then return false, "missing payload" end
  if message.type == constants.message_types.COMMAND then
    if type(message.message_id) ~= "string" or message.message_id == "" then return false, "missing message_id" end
  elseif message.type == constants.message_types.ACK_DELIVERED
      or message.type == constants.message_types.ACK_APPLIED then
    if type(message.message_id) ~= "string" or message.message_id == "" then return false, "missing message_id" end
    if type(message.ack_for) ~= "string" or message.ack_for == "" then return false, "missing ack_for" end
  end
  local ok, err = is_proto_compatible(message.proto_ver)
  if not ok then return false, err end
  return true
end

function protocol.validate(message) return protocol.validateMessage(message) end
function protocol.is_proto_compatible(ver) return is_proto_compatible(ver) end

function protocol.sign_message(message, secret)
  if type(message) ~= "table" or type(secret) ~= "string" or secret == "" then
    return false, "missing auth secret"
  end
  local material, material_err = auth_material(message)
  if not material then return false, material_err end
  local mac, mac_err = hmac_sha256_hex(secret, material)
  if not mac then return false, mac_err end
  message.auth = { algorithm = "HMAC-SHA256", mac = mac }
  return true
end

function protocol.verify_message_auth(message, secret)
  if type(message) ~= "table" or type(secret) ~= "string" or secret == "" then
    return false, "missing auth secret"
  end
  local auth = message.auth
  if type(auth) ~= "table" or auth.algorithm ~= "HMAC-SHA256" or type(auth.mac) ~= "string" then
    return false, "missing message authentication"
  end
  local material, material_err = auth_material(message)
  if not material then return false, material_err end
  local expected, mac_err = hmac_sha256_hex(secret, material)
  if not expected then return false, mac_err end
  if not constant_equals(auth.mac:lower(), expected) then return false, "message authentication mismatch" end
  return true
end

function protocol.sign_value(value, secret)
  if type(secret) ~= "string" or secret == "" then return nil, "missing auth secret" end
  local material, material_err = canonical(value)
  if not material then return nil, material_err end
  return hmac_sha256_hex(secret, material)
end

function protocol.verify_value(value, secret, mac)
  if type(mac) ~= "string" then return false, "missing authentication code" end
  local expected, err = protocol.sign_value(value, secret)
  if not expected then return false, err end
  if not constant_equals(mac:lower(), expected) then return false, "authentication mismatch" end
  return true
end

function protocol.resolve_auth_secret(config)
  local function valid(value)
    if type(value) ~= "string" then return nil end
    local trimmed = value:match("^%s*(.-)%s*$") or ""
    if #trimmed < 16 then return nil end
    return value
  end
  config = type(config) == "table" and config or {}
  local direct = valid(config.auth_secret)
  if direct then return direct end
  local paths = {
    config.auth_config_path or "/xreactor/config/network_auth.lua",
    "/xreactor/config/remote_update.lua",
  }
  for _, path in ipairs(paths) do
    if fs and type(fs.exists) == "function" and fs.exists(path) then
      local loaded = utils.load_config(path, {})
      if type(loaded) == "table" then
        local secret = valid(loaded.secret or loaded.auth_secret or loaded.token)
        if secret then return secret end
      end
    end
  end
  return nil
end

function protocol.valve_auth_value(message)
  if type(message) ~= "table" then return nil end
  return {
    type = message.type, src = message.src, dst = message.dst,
    command_id = message.command_id, side = message.side, high = message.high,
    applied = message.applied, error = message.error, persisted = message.persisted,
    ts = message.ts,
  }
end

function protocol.log_auth_value(message)
  if type(message) ~= "table" then return nil end
  return {
    type = message.type, proto = message.proto, event_id = message.event_id,
    node_id = message.node_id, role = message.role, prefix = message.prefix,
    level = message.level, message = message.message, line = message.line,
    seq = message.seq, boot_id = message.boot_id, ack = message.ack,
    to_node = message.to_node, collector_node = message.collector_node,
    status = message.status, ts = message.ts,
  }
end

function protocol.is_for_node(message, node_id)
  local normalized_node = utils.normalize_node_id(node_id)
  local normalized_dst = normalize_remote_id(message.dst)
  if normalized_dst and normalized_dst ~= normalized_node then return false end
  local payload = message.payload or {}
  if message.type == constants.message_types.COMMAND then
    local normalized_target = normalize_remote_id(payload.target)
    if normalized_target and normalized_target ~= normalized_node then return false end
  end
  return true
end

return protocol
