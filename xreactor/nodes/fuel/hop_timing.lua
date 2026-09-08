-- nodes/fuel/hop_timing.lua
-- Learns per-hop (VALVE-Node-to-VALVE-Node) fuel transit times from real
-- deliveries and derives a distance-aware HOLD_OPEN timeout, instead of the
-- one flat config.logistics.valve_open_ms used for every reactor regardless
-- of how far it physically is.
--
-- Data source: VALVE-Nodes that have an optional local junction-chest
-- peripheral (see nodes/valve/hop_reporter.lua) periodically report that
-- chest's item contents over the wireless VALVE channel (HOP_SCAN, see
-- redstone_router.lua's handle_hop_scan()). This module never controls
-- routing itself -- it is a passive observer that:
--   1. During an active delivery (begin_delivery), watches for the
--      delivered item's count to rise above its pre-delivery baseline at
--      each hop on the path -- that transition is "fuel arrived here".
--   2. On completion (finish_delivery), turns the observed arrival
--      timestamps into per-edge transit durations and folds them into a
--      persisted, ever-improving estimate.
--   3. Exposes compute_timeout_ms(path, default_total_ms) so
--      logistics_router.lua can size begin_transaction()'s HOLD_OPEN window
--      per reactor instead of using one global constant.
--
-- Bootstrapping ("einmal einlernen"): a freshly installed system has no
-- persisted edges at all. compute_timeout_ms() splits default_total_ms
-- evenly across the path's legs and substitutes a leg's learned duration
-- once min_samples real deliveries have crossed it -- with nothing learned
-- yet, the total is EXACTLY default_total_ms regardless of path length
-- (never an unannounced multiple of the configured value just because a
-- reactor happens to be many hops away). The first real deliveries after a
-- fresh install ARE the calibration pass, no separate step needed.
--
-- Only ONE delivery is ever active system-wide (redstone_router.lua's
-- begin_transaction() rejects a second transaction as "busy" while one is
-- running), so there is no ambiguity about which delivery an observed item
-- count belongs to -- a single `_active` slot is sufficient, no per-reactor
-- bookkeeping needed here.
--
-- Persisted at state_path (see M.new(), defaults below) as plain Lua,
-- deliberately separate from the hand-authored config.lua -- this is
-- derived/learned data, not something a config push should ever overwrite
-- or a person should hand-edit.

local M = {}
M.__index = M

local EXPORT_NODE = "EXPORT"
local DEFAULT_STATE_PATH = "/xreactor_config/fuel_hop_timing.lua"
local DEFAULT_MIN_SAMPLES = 3
local DEFAULT_SAFETY_MARGIN = 1.3

local function edge_key(from, to)
  return tostring(from) .. "->" .. tostring(to)
end

local function load_edges(path)
  if type(fs) ~= "table" or not fs.exists(path) then return {} end
  local ok, result = pcall(dofile, path)
  if ok and type(result) == "table" and type(result.edges) == "table" then
    return result.edges
  end
  return {}
end

local function write_edges(edges, path)
  if type(fs) ~= "table" then return false end
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  local ok_open, f = pcall(fs.open, path, "w")
  if not ok_open or not f then return false end
  f.writeLine("-- Fuel hop timing -- auto-learned, do not edit manually")
  f.writeLine("return {")
  f.writeLine("  edges = {")
  -- Deterministic key order keeps the written file (and test fixtures)
  -- stable across runs instead of depending on pairs() iteration order.
  local keys = {}
  for key in pairs(edges) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local entry = edges[key]
    f.writeLine(string.format("    [%q] = { ms = %s, samples = %s },",
      key, tostring(tonumber(entry.ms) or 0), tostring(tonumber(entry.samples) or 0)))
  end
  f.writeLine("  },")
  f.writeLine("}")
  f.close()
  return true
end

function M.new(opts)
  opts = opts or {}
  local state_path = opts.state_path or DEFAULT_STATE_PATH
  local self = setmetatable({
    state_path = state_path,
    min_samples = tonumber(opts.min_samples) or DEFAULT_MIN_SAMPLES,
    safety_margin = tonumber(opts.safety_margin) or DEFAULT_SAFETY_MARGIN,
    log = opts.log or function() end,
    os_api = opts.os_api or os,
    _edges = load_edges(state_path),
    _scans = {},   -- [node_id] = { items = {[item_name]=count}, ts = ms }
    _active = nil, -- { reactor_id, path, item, started_ts, arrived, baseline, path_set }
  }, M)
  return self
end

function M:_now_ms()
  return (self.os_api and self.os_api.epoch and self.os_api.epoch("utc")) or 0
end

-- Called whenever redstone_router.lua receives a HOP_SCAN from a VALVE-Node.
-- items: {[item_name] = count}, the full observed content of that VALVE-
-- Node's configured junction chest.
function M:record_scan(node_id, items, ts)
  if type(node_id) ~= "string" or node_id == "" or type(items) ~= "table" then return end
  ts = tonumber(ts) or self:_now_ms()
  self._scans[node_id] = { items = items, ts = ts }

  local active = self._active
  if not active or active.arrived[node_id] or not active.path_set[node_id] then return end
  local count = tonumber(items[active.item]) or 0
  local baseline = active.baseline[node_id] or 0
  if count > baseline then
    active.arrived[node_id] = ts
  end
end

-- Called by logistics_router.lua right before opening the path for a
-- delivery. path: ordered list of VALVE-Node ids (route.path). Snapshots
-- each hop's CURRENT count of the item about to be delivered as the
-- baseline, so leftover stock already sitting in a chest is never mistaken
-- for this delivery's arrival.
function M:begin_delivery(reactor_id, path, item_name, started_ts)
  if reactor_id == nil or type(path) ~= "table" or type(item_name) ~= "string" or item_name == "" then
    self._active = nil
    return
  end
  local path_set, baseline = {}, {}
  for _, node_id in ipairs(path) do
    path_set[node_id] = true
    local scan = self._scans[node_id]
    baseline[node_id] = (scan and tonumber(scan.items[item_name])) or 0
  end
  self._active = {
    reactor_id = reactor_id,
    path = path,
    item = item_name,
    started_ts = tonumber(started_ts) or self:_now_ms(),
    arrived = {},
    baseline = baseline,
    path_set = path_set,
  }
end

-- Called once a delivery reaches a terminal state (success or failure alike
-- -- a failed/aborted delivery still yields real transit data for whatever
-- hops it did reach). Turns observed arrivals into learned edge durations.
function M:finish_delivery(reactor_id)
  local active = self._active
  if not active or active.reactor_id ~= reactor_id then return end
  self._active = nil

  local prev_node, prev_ts = EXPORT_NODE, active.started_ts
  local changed = false
  for _, node_id in ipairs(active.path) do
    local arrived_ts = active.arrived[node_id]
    if not arrived_ts then break end -- no scan coverage past this point
    local observed_ms = arrived_ts - prev_ts
    if observed_ms >= 0 then
      self:_learn(edge_key(prev_node, node_id), observed_ms)
      changed = true
    end
    prev_node, prev_ts = node_id, arrived_ts
  end
  if changed then
    if not write_edges(self._edges, self.state_path) then
      self.log("WARN", "HopTiming: konnte gelernte Hop-Zeiten nicht speichern (" .. tostring(self.state_path) .. ")")
    end
  end
end

-- Deliberately biased towards the slower of (new observation, previous
-- estimate) rather than a plain average -- a too-short timeout re-blocks a
-- path before fuel that's still in transit arrives (the original pile-up
-- bug), a too-long one just wastes a little time. But a pure max() would
-- let a single delayed/jittery scan inflate an edge forever with no way
-- back -- so a new, faster observation is still allowed to pull the
-- estimate down, just slowly (at most 15% per sample) rather than
-- instantly, so real improvement (a route got shorter) or a one-off outlier
-- both eventually correct themselves.
local DECAY_FACTOR = 0.85
function M:_learn(key, observed_ms)
  local entry = self._edges[key]
  if not entry then
    entry = { ms = observed_ms, samples = 1 }
  else
    entry.ms = math.max(observed_ms, (tonumber(entry.ms) or 0) * DECAY_FACTOR)
    entry.samples = (tonumber(entry.samples) or 0) + 1
  end
  self._edges[key] = entry
end

-- Returns the learned+margin duration for one edge, or nil while it hasn't
-- accumulated min_samples real observations yet (caller falls back to a
-- flat default for that edge).
function M:get_edge_ms(from, to)
  local entry = self._edges[edge_key(from, to)]
  if not entry or (tonumber(entry.samples) or 0) < self.min_samples then return nil end
  return math.ceil((tonumber(entry.ms) or 0) * self.safety_margin)
end

-- Splits default_total_ms evenly across every leg of the path (each hop-to-
-- hop edge, plus one final, always-unsensored leg from the last VALVE-Node
-- into the reactor itself) and replaces a leg's share with its learned
-- duration once calibrated. This is deliberately NOT "default_total_ms per
-- leg" -- with zero calibration data (a fresh install, or an uncalibrated
-- edge), compute_timeout_ms(path, default_total_ms) returns EXACTLY
-- default_total_ms, identical to the old flat-valve_open_ms behavior for
-- every reactor regardless of path length. Only once real deliveries
-- calibrate specific edges does the total grow or shrink away from that
-- baseline, in proportion to how much longer or shorter those edges
-- actually are than their even share -- never an unannounced multiple of
-- the configured value just because a path happens to have many hops.
function M:compute_timeout_ms(path, default_total_ms)
  default_total_ms = tonumber(default_total_ms) or 2000
  local hops = (type(path) == "table") and #path or 0
  if hops == 0 then return default_total_ms end -- no path to reason about: unchanged behavior

  local legs = hops + 1 -- +1 for the final, always-unsensored leg
  local per_leg_default = default_total_ms / legs

  local total, prev_node = 0, EXPORT_NODE
  for _, node_id in ipairs(path) do
    total = total + (self:get_edge_ms(prev_node, node_id) or per_leg_default)
    prev_node = node_id
  end
  total = total + per_leg_default -- final leg: never calibrated, always the even share
  return math.max(1, math.floor(total + 0.5))
end

return M
