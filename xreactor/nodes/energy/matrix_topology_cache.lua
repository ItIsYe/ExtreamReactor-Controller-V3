local cache = {}

-- P-DISC-BACKOFF: after this many consecutive "stable" should_discover()
-- checks, the expensive peripheral_signature() scan (full getNames() +
-- getType() per name) backs off to once every SLOW_MULTIPLIER checks
-- instead of every single due-check -- same pattern as nodes/rt/main.lua's
-- discovery stable-streak slowdown. A "peripheral"/"peripheral_detach"
-- event (self.dirty) or the forced_rescan_interval_ms safety net still
-- force an immediate, real recheck regardless of this backoff.
local STABLE_STREAK_LIMIT = 3
local SLOW_MULTIPLIER = 6

local function now_ms()
  return os.epoch("utc")
end

local function sort_copy(list)
  local copy = {}
  for i, value in ipairs(list or {}) do
    copy[i] = value
  end
  table.sort(copy)
  return copy
end

local function peripheral_signature()
  local names = sort_copy(peripheral.getNames() or {})
  local parts = {}
  for _, name in ipairs(names) do
    local kind = peripheral.getType(name) or "unknown"
    parts[#parts + 1] = tostring(name) .. ":" .. tostring(kind)
  end
  return table.concat(parts, "|")
end

function cache.new(opts)
  opts = opts or {}
  local self = {
    log_prefix = opts.log_prefix or "ENERGY",
    forced_rescan_interval_ms = math.max(1000, math.floor((tonumber(opts.forced_rescan_interval_s) or 300) * 1000)),
    watch_signature = nil,
    topology_signature = nil,
    last_discovery_ts = 0,
    dirty = true,
    stable_streak = 0,
    next_slow_check_at = 0
  }
  return setmetatable(self, { __index = cache })
end

-- interval_s is the caller's discovery interval (seconds), used only to
-- size the backoff window -- optional, defaults to 1s if omitted so a
-- caller that doesn't pass it just gets a (still correct, just more
-- conservative) 6s backoff window instead of no backoff at all.
function cache:should_discover(ts, event, due, interval_s)
  local event_name = type(event) == "table" and event[1] or nil
  if event_name == "peripheral" or event_name == "peripheral_detach" then
    self.dirty = true
  end

  if not due then
    return false, "interval_not_due"
  end

  local force_due = (ts - (self.last_discovery_ts or 0)) >= self.forced_rescan_interval_ms

  if not self.dirty and not force_due and self.stable_streak >= STABLE_STREAK_LIMIT
      and self.next_slow_check_at and ts < self.next_slow_check_at then
    return false, "stable_backoff"
  end

  local signature = peripheral_signature()
  local signature_changed = signature ~= (self.watch_signature or "")

  if self.dirty or signature_changed or force_due then
    self.watch_signature = signature
    self.stable_streak = 0
    self.next_slow_check_at = 0
    return true, self.dirty and "dirty" or (signature_changed and "signature_changed" or "forced_interval")
  end

  self.stable_streak = self.stable_streak + 1
  if self.stable_streak >= STABLE_STREAK_LIMIT then
    local slow_period_ms = SLOW_MULTIPLIER * math.max(1, tonumber(interval_s) or 1) * 1000
    self.next_slow_check_at = ts + slow_period_ms
  end
  return false, "stable"
end

function cache:record_discovery(ts, topology_signature)
  self.last_discovery_ts = ts or now_ms()
  self.topology_signature = topology_signature or self.topology_signature
  self.dirty = false
end

return cache
