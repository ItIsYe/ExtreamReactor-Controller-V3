-- core/discovery_stability.lua
--
-- Generic peripheral-topology stability gate for services/discovery_service.lua's
-- optional `should_discover(service, ts, event, due)` hook.
--
-- Why this exists: without it, a node scans EVERY peripheral (full
-- peripheral.getNames() + getType() per name -- a real, non-trivial
-- cross-mod cost) on every due discovery tick forever, even once the
-- physical hardware topology has been stable for hours. This cache lets a
-- node keep discovering promptly while topology is actually changing, then
-- back off to a much slower verification cadence once it's been stable for
-- a few checks in a row -- mirroring nodes/rt/main.lua's own discovery
-- stable-streak slowdown (which predates this shared module) and
-- nodes/energy/matrix_topology_cache.lua's per-node variant.
--
-- A "peripheral"/"peripheral_detach" CC:Tweaked event (real attach/detach)
-- always forces an immediate, real recheck regardless of any backoff.

local cache = {}

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

-- opts.forced_rescan_interval_s: safety-net full rescan even if the
-- signature looks stable (default 300s) -- catches changes a signature
-- comparison alone might miss (e.g. programmatic peripheral swaps that
-- keep the same name/type).
function cache.new(opts)
  opts = opts or {}
  local self = {
    forced_rescan_interval_ms = math.max(1000, math.floor((tonumber(opts.forced_rescan_interval_s) or 300) * 1000)),
    watch_signature = nil,
    last_discovery_ts = 0,
    dirty = true,
    stable_streak = 0,
    next_slow_check_at = 0
  }
  return setmetatable(self, { __index = cache })
end

-- interval_s: caller's discovery interval (seconds), used only to size the
-- backoff window -- optional, defaults to a conservative 1s if omitted.
--
-- Self-managing: services/discovery_service.lua's tick() always calls
-- discover() right after should_discover() returns true, so this clears
-- self.dirty and stamps last_discovery_ts itself on a "raise" decision --
-- no separate record_discovery() call needed from the node's own discover()
-- function (record_discovery() is still available for a caller that wants
-- to report an actual outcome instead, e.g. only clearing dirty when the
-- scan didn't error).
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
    self.dirty = false
    self.last_discovery_ts = ts
    return true, "rescan"
  end

  self.stable_streak = self.stable_streak + 1
  if self.stable_streak >= STABLE_STREAK_LIMIT then
    local slow_period_ms = SLOW_MULTIPLIER * math.max(1, tonumber(interval_s) or 1) * 1000
    self.next_slow_check_at = ts + slow_period_ms
  end
  return false, "stable"
end

function cache:record_discovery(ts)
  self.last_discovery_ts = ts or now_ms()
  self.dirty = false
end

return cache
