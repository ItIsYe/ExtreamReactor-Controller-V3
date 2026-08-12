-- Network-backed reactor fuel cache for the FUEL node.

local protocol = require("core.protocol")
local reactor_identity = require("core.reactor_identity")

local M = {}

local DIRECT_TTL_MS = 120 * 1000
local MASTER_TTL_MS = 120 * 1000
local MAX_DIRECT_REACTORS = 256
local MAX_MASTER_REACTORS = 256
local MAX_REACTORS_PER_MESSAGE = 64
local MAX_MESSAGE_AGE_MS = 30 * 1000

function M.new()
  return {
    master_relay = {},
    direct_heard = {},
    direct_legacy_source = {},
    direct_collisions = {},
  }
end

local function cache_entry(source, local_id, global_id, entry, timestamp)
  return {
    fuel_amount = entry.fuel_amount,
    fuel_capacity = entry.fuel_capacity,
    label = entry.label or entry.alias or entry.name or global_id,
    ts = timestamp,
    source_node = source,
    local_reactor_id = local_id,
    global_reactor_id = global_id,
  }
end

-- Replaces the whole MASTER snapshot so reactors which disappeared or went
-- stale cannot survive indefinitely in the route picker.
function M.ingest_master_relay(cache, value)
  if type(cache) ~= "table" or type(value) ~= "table" then return end
  local now = os.epoch("utc")
  local replacement, legacy_sources = {}, {}
  local count = 0

  for transport_id, entry in pairs(value) do
    if count >= MAX_MASTER_REACTORS then break end
    if type(transport_id) == "string" and type(entry) == "table" then
      local source = entry.source_node
      local local_hint = entry.local_reactor_id
      if local_hint == nil and source ~= nil then
        local prefix = tostring(source) .. ":"
        if transport_id:sub(1, #prefix) == prefix then
          local_hint = transport_id:sub(#prefix + 1)
        else
          local_hint = transport_id
        end
      end
      local local_id, global_id = reactor_identity.resolve(source, {
        id = local_hint,
        global_id = entry.global_reactor_id,
      })
      if local_id and global_id
          and reactor_identity.valid_transport_key(transport_id, local_id, global_id) then
        local age_ms = math.max(0, tonumber(entry.source_age_ms) or 0)
        local normalized = cache_entry(
          tostring(source), local_id, global_id, entry, now - age_ms)
        replacement[global_id] = normalized
        count = count + 1

        local sources = legacy_sources[local_id]
        if not sources then sources = {}; legacy_sources[local_id] = sources end
        sources[tostring(source)] = normalized
      end
    end
  end

  for local_id, sources in pairs(legacy_sources) do
    local source_count, only = 0, nil
    for _, entry in pairs(sources) do
      source_count = source_count + 1
      only = entry
      if source_count > 1 then break end
    end
    if source_count == 1 and replacement[local_id] == nil then
      replacement[local_id] = only
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

  local remaining_sources = {}
  if local_id then
    for key, candidate in pairs(cache.direct_heard) do
      if type(candidate) == "table" and candidate.global_reactor_id == key
          and candidate.local_reactor_id == local_id then
        remaining_sources[candidate.source_node] = candidate
      end
    end
  end
  local remaining_count, only_source, only_entry = 0, nil, nil
  for source, candidate in pairs(remaining_sources) do
    remaining_count = remaining_count + 1
    only_source, only_entry = source, candidate
  end
  if remaining_count == 1 then
    cache.direct_collisions[local_id] = nil
    cache.direct_legacy_source[local_id] = only_source
    cache.direct_heard[local_id] = only_entry
  elseif remaining_count == 0 then
    cache.direct_collisions[local_id] = nil
    cache.direct_legacy_source[local_id] = nil
    cache.direct_heard[local_id] = nil
  end
end

function M.prune(cache, now)
  now = tonumber(now) or os.epoch("utc")
  for id, entry in pairs(cache.master_relay or {}) do
    if type(entry) ~= "table" or now - (tonumber(entry.ts) or 0) > MASTER_TTL_MS then
      cache.master_relay[id] = nil
    end
  end
  local expired = {}
  for id, entry in pairs(cache.direct_heard or {}) do
    if type(entry) == "table" and entry.global_reactor_id == id
        and now - (tonumber(entry.ts) or 0) > DIRECT_TTL_MS then
      expired[#expired + 1] = id
    end
  end
  for _, id in ipairs(expired) do remove_direct(cache, id) end
end

local function store_direct(cache, message, reactor, now)
  local source = message.src or message.sender_id or message.node_id
  local local_id, global_id = reactor_identity.resolve(source, reactor)
  if not local_id or not global_id then return false end

  local entry = cache_entry(tostring(source), local_id, global_id, reactor, now)
  local unique_count = 0
  for key, existing in pairs(cache.direct_heard) do
    if type(existing) == "table" and existing.global_reactor_id == key then
      unique_count = unique_count + 1
    end
  end
  if not cache.direct_heard[global_id] and unique_count >= MAX_DIRECT_REACTORS then
    local evict = oldest_global(cache)
    if evict then remove_direct(cache, evict) end
  end
  cache.direct_heard[global_id] = entry

  if cache.direct_collisions[local_id] then return true end
  local previous_source = cache.direct_legacy_source[local_id]
  if previous_source == nil or previous_source == source then
    cache.direct_legacy_source[local_id] = source
    cache.direct_heard[local_id] = entry
    return true
  end

  cache.direct_collisions[local_id] = true
  cache.direct_heard[local_id] = nil
  return true
end

function M.make_overhear_service(cache, constants)
  return {
    name = "fuel_status_overhear",
    wants_events = true,
    tick = function(_self, _dt, event)
      local now = os.epoch("utc")
      M.prune(cache, now)
      if not (event and event[1] == "modem_message") then return end
      if event[3] ~= constants.channels.STATUS then return end
      local raw = event[5]
      if type(raw) ~= "table" then return end

      -- This listener runs outside comms_service. Validate the original
      -- envelope before sanitizing it: sanitize_message supplies defaults and
      -- must not turn a missing timestamp or sender into a valid packet.
      if select(1, protocol.validate(raw)) ~= true then return end
      local message = protocol.sanitize_message(raw)
      if not message then return end
      if message.type ~= constants.message_types.STATUS
          or message.role ~= constants.roles.RT_NODE then return end
      local source = message.src or message.sender_id or message.node_id
      if type(source) ~= "string" or source == "" or source == "UNKNOWN" then return end
      local timestamp = message.ts or message.timestamp
      if type(timestamp) ~= "number" or math.abs(now - timestamp) > MAX_MESSAGE_AGE_MS then return end

      local reactors = message.payload and message.payload.reactors
      if type(reactors) ~= "table" then return end
      for index, reactor in ipairs(reactors) do
        if index > MAX_REACTORS_PER_MESSAGE then break end
        if type(reactor) == "table" and reactor.id
            and (reactor.fuel_amount ~= nil or reactor.fuel_capacity ~= nil) then
          store_direct(cache, message, reactor, now)
        end
      end
    end,
  }
end

M._store_direct = store_direct

return M
