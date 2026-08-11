-- nodes/fuel/fuel_status_network.lua
-- Network-backed reactor fuel-level cache for the FUEL node.

local protocol = require("core.protocol")
local M = {}
local DIRECT_TTL_MS = 120 * 1000
local MASTER_TTL_MS = 120 * 1000
local MAX_DIRECT_REACTORS = 256
local MAX_REACTORS_PER_MESSAGE = 64
local MAX_MASTER_REACTORS = 256

function M.new()
  return {
    master_relay = {},
    direct_heard = {},
    -- Legacy local reactor IDs are accepted only while one RT source owns
    -- them. Once two sources collide, that alias remains blocked for the
    -- current boot and only node-scoped global IDs are usable.
    direct_legacy_source = {},
    direct_collisions = {},
  }
end

function M.ingest_master_relay(cache, value)
  if type(value) ~= "table" then return end
  local now = os.epoch("utc")
  local replacement, count = {}, 0
  for reactor_id, entry in pairs(value) do
    if count < MAX_MASTER_REACTORS and type(reactor_id) == "string" and type(entry) == "table" then
      local age_ms = math.max(0, tonumber(entry.source_age_ms) or 0)
      replacement[reactor_id] = {
        fuel_amount = entry.fuel_amount,
        fuel_capacity = entry.fuel_capacity,
        label = entry.label,
        ts = now - age_ms,
        source_node = entry.source_node,
        local_reactor_id = entry.local_reactor_id,
        global_reactor_id = entry.global_reactor_id,
      }
      count = count + 1
    end
  end
  cache.master_relay = replacement
end

local function oldest_global(cache)
  local oldest_key, oldest_ts = nil, math.huge
  for key, entry in pairs(cache.direct_heard) do
    if type(entry) == "table" and entry.global_reactor_id == key
        and (tonumber(entry.ts) or 0) < oldest_ts then
      oldest_key, oldest_ts = key, tonumber(entry.ts) or 0
    end
  end
  return oldest_key
end

local function remove_direct(cache, global_id)
  local entry = cache.direct_heard[global_id]
  cache.direct_heard[global_id] = nil
  if not entry then return end
  local local_id = entry.local_reactor_id
  if local_id and cache.direct_heard[local_id] == entry then cache.direct_heard[local_id] = nil end
  if local_id and cache.direct_legacy_source[local_id] == entry.source_node then
    cache.direct_legacy_source[local_id] = nil
  end
  local still_present = false
  if local_id then
    for key, candidate in pairs(cache.direct_heard) do
      if type(candidate) == "table" and candidate.global_reactor_id == key
          and candidate.local_reactor_id == local_id then
        still_present = true
        break
      end
    end
  end
  if local_id and not still_present then
    cache.direct_collisions[local_id] = nil
    cache.direct_legacy_source[local_id] = nil
    cache.direct_heard[local_id] = nil
  end
end

function M.prune(cache, now)
  now = tonumber(now) or os.epoch("utc")
  for id, entry in pairs(cache.master_relay) do
    if type(entry) ~= "table" or now - (tonumber(entry.ts) or 0) > MASTER_TTL_MS then
      cache.master_relay[id] = nil
    end
  end
  local expired = {}
  for id, entry in pairs(cache.direct_heard) do
    if type(entry) == "table" and entry.global_reactor_id == id
        and now - (tonumber(entry.ts) or 0) > DIRECT_TTL_MS then
      expired[#expired + 1] = id
    end
  end
  for _, id in ipairs(expired) do remove_direct(cache, id) end
end

local function store_direct(cache, message, reactor, now)
  local source = message.src or message.sender_id or message.node_id
  if type(source) ~= "string" or source == "" then return end
  local local_id = reactor.local_id or reactor.id
  if local_id == nil then return end
  local_id = tostring(local_id)
  local global_id = reactor.global_id
  if type(global_id) ~= "string" or global_id == "" then
    global_id = source .. ":" .. local_id
  end
  local entry = {
    fuel_amount = reactor.fuel_amount,
    fuel_capacity = reactor.fuel_capacity,
    label = reactor.alias or reactor.name or global_id,
    ts = now,
    source_node = source,
    local_reactor_id = local_id,
    global_reactor_id = global_id,
  }
  local unique_count = 0
  for key, existing in pairs(cache.direct_heard) do
    if type(existing) == "table" and existing.global_reactor_id == key then unique_count = unique_count + 1 end
  end
  if not cache.direct_heard[global_id] and unique_count >= MAX_DIRECT_REACTORS then
    local evict = oldest_global(cache)
    if evict then remove_direct(cache, evict) end
  end
  cache.direct_heard[global_id] = entry

  if cache.direct_collisions[local_id] then return end
  local previous_source = cache.direct_legacy_source[local_id]
  if previous_source == nil or previous_source == source then
    cache.direct_legacy_source[local_id] = source
    cache.direct_heard[local_id] = entry
    return
  end

  cache.direct_collisions[local_id] = true
  cache.direct_heard[local_id] = nil
end

function M.make_overhear_service(cache, constants, opts)
  opts = opts or {}
  local config = opts.config or {}
  local auth_secret = opts.auth_secret or protocol.resolve_auth_secret(config.comms or config)
  return {
    name = "fuel_status_overhear",
    wants_events = true,
    tick = function(_self, dt, event)
      local now = os.epoch("utc")
      M.prune(cache, now)
      if not (event and event[1] == "modem_message") then return end
      if event[3] ~= constants.channels.STATUS then return end
      local raw = event[5]
      if type(raw) ~= "table" then return end

      -- This fallback runs outside comms_service, so it must perform the
      -- same envelope validation explicitly. Previously type/role strings
      -- alone were enough to inject fuel values into a delivery decision.
      local message = protocol.sanitize_message(raw)
      local valid = message and select(1, protocol.validate(message))
      if valid ~= true then return end
      if not auth_secret then return end
      local auth_ok = select(1, protocol.verify_message_auth(message, auth_secret))
      if not auth_ok then return end
      local timestamp = message.ts or message.timestamp
      if type(timestamp) ~= "number" or math.abs(now - timestamp) > 30 * 1000 then return end
      if message.type ~= constants.message_types.STATUS then return end
      if message.role ~= constants.roles.RT_NODE then return end
      local source = message.src or message.sender_id or message.node_id
      if type(source) ~= "string" or source == "" then return end

      local reactors = message.payload and message.payload.reactors
      if type(reactors) ~= "table" then return end
      for index, r in ipairs(reactors) do
        if index > MAX_REACTORS_PER_MESSAGE then break end
        if type(r) == "table" and r.id and (r.fuel_amount ~= nil or r.fuel_capacity ~= nil) then
          store_direct(cache, message, r, now)
        end
      end
    end
  }
end

return M
