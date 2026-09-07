package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer nodes/fuel/hop_timing.lua: lernt distanzabhaengige
-- Liefer-Timeouts aus HOP_SCAN-Meldungen der VALVE-Nodes, siehe dortiger
-- Kopfkommentar. Deckt: Fallback ohne gelernte Daten, Baseline-Handhabung
-- (Altbestand darf nicht als "gerade angekommen" zaehlen), min_samples-
-- Schwelle, Persistenz ueber eine "neue" Instanz hinweg, und einen
-- abgebrochenen Transfer (kein Sample gelernt).

local files = {}

_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function(p) return (p:match("^(.*)/[^/]+$")) or "" end,
  makeDir = function() end,
  delete = function(p) files[p] = nil end,
  open = function(p, mode)
    if mode == "w" then
      local buf = {}
      return {
        writeLine = function(line) buf[#buf + 1] = line end,
        write = function(s) buf[#buf + 1] = s end,
        close = function() files[p] = table.concat(buf, "\n") .. "\n" end,
      }
    elseif mode == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    return nil
  end,
}
_G.dofile = function(path)
  local content = files[path]
  if not content then error("dofile: no such mock file: " .. tostring(path), 0) end
  local chunk, err = load(content, "=" .. path)
  if not chunk then error("dofile parse error: " .. tostring(err), 0) end
  return chunk()
end

local hop_timing = require('nodes.fuel.hop_timing')

local STATE_PATH = "/xreactor_config/fuel_hop_timing.lua"

local now = 0
local function os_api() return { epoch = function() return now end } end

local function new_hop_timing(overrides)
  overrides = overrides or {}
  return hop_timing.new({
    state_path = STATE_PATH,
    os_api = os_api(),
    min_samples = overrides.min_samples or 2,
    safety_margin = overrides.safety_margin or 1.5,
  })
end

-- 1) No persisted data at all: compute_timeout_ms falls back entirely to
--    default_edge_ms for a 2-hop path (2 hop edges + 1 final unsensored leg).
do
  files = {}
  local ht = new_hop_timing()
  local ms = ht:compute_timeout_ms({ "VALVE-1", "VALVE-2" }, 1000)
  assert(ms == 3000, "expected pure fallback 3x1000, got " .. tostring(ms))
end

-- 2) A single delivery: fuel appears at VALVE-1 then VALVE-2, in order.
--    Below min_samples (2), get_edge_ms must still be nil (not trusted yet)
--    and compute_timeout_ms must still use the default for those edges.
do
  files = {}
  local ht = new_hop_timing()
  now = 1000
  ht:begin_delivery("R01", { "VALVE-1", "VALVE-2" }, "minecraft:uranium_ingot", now)
  now = 1500
  ht:record_scan("VALVE-1", { ["minecraft:uranium_ingot"] = 8 }, now) -- 500ms transit
  now = 2200
  ht:record_scan("VALVE-2", { ["minecraft:uranium_ingot"] = 8 }, now) -- 700ms transit
  ht:finish_delivery("R01")

  assert(ht:get_edge_ms("EXPORT", "VALVE-1") == nil, "must not trust a single sample yet")
  local ms = ht:compute_timeout_ms({ "VALVE-1", "VALVE-2" }, 1000)
  assert(ms == 3000, "still pure fallback below min_samples, got " .. tostring(ms))
end

-- 3) Pre-existing stock at a hop before a delivery starts (baseline) must
--    NOT be misread as this delivery's arrival -- only a rise above the
--    baseline counts.
do
  files = {}
  local ht = new_hop_timing()
  now = 500
  ht:record_scan("VALVE-1", { ["minecraft:uranium_ingot"] = 4 }, now) -- leftover stock
  now = 1000
  ht:begin_delivery("R01", { "VALVE-1" }, "minecraft:uranium_ingot", now)
  now = 1300
  -- Same count as baseline -- must NOT be treated as arrival.
  ht:record_scan("VALVE-1", { ["minecraft:uranium_ingot"] = 4 }, now)
  now = 1800
  -- Now it actually rises -- this is the real arrival.
  ht:record_scan("VALVE-1", { ["minecraft:uranium_ingot"] = 12 }, now)
  ht:finish_delivery("R01")

  -- Two deliveries needed to cross min_samples=2; do a second identical one.
  now = 3000
  ht:begin_delivery("R01", { "VALVE-1" }, "minecraft:uranium_ingot", now)
  now = 3800
  ht:record_scan("VALVE-1", { ["minecraft:uranium_ingot"] = 20 }, now) -- +800ms
  ht:finish_delivery("R01")

  local edge_ms = ht:get_edge_ms("EXPORT", "VALVE-1")
  assert(edge_ms ~= nil, "expected a trusted edge after 2 samples")
  -- max(observed) = max(800, 800) = 800, * safety_margin 1.5 = 1200
  assert(edge_ms == 1200, "expected learned+margin 1200, got " .. tostring(edge_ms))
end

-- 4) Learned edges feed into compute_timeout_ms; an uncalibrated trailing
--    edge (VALVE-1 -> VALVE-2, never observed) still falls back to default,
--    plus the always-default final leg into the reactor.
do
  files = {}
  local ht = new_hop_timing()
  for i = 1, 2 do
    now = i * 10000
    ht:begin_delivery("R01", { "VALVE-1" }, "minecraft:uranium_ingot", now)
    now = now + 900
    ht:record_scan("VALVE-1", { ["minecraft:uranium_ingot"] = i * 8 }, now)
    ht:finish_delivery("R01")
  end
  -- learned EXPORT->VALVE-1 = 900 * 1.5 = 1350
  local ms = ht:compute_timeout_ms({ "VALVE-1", "VALVE-2" }, 1000)
  assert(ms == 1350 + 1000 + 1000, "expected learned+2 defaults, got " .. tostring(ms))
end

-- 5) Aborted/failed delivery (finish_delivery called with zero arrivals
--    recorded) must not fabricate a sample.
do
  files = {}
  local ht = new_hop_timing()
  now = 1000
  ht:begin_delivery("R01", { "VALVE-1" }, "minecraft:uranium_ingot", now)
  ht:finish_delivery("R01") -- no record_scan in between
  assert(ht:get_edge_ms("EXPORT", "VALVE-1") == nil, "aborted delivery must not learn a sample")
end

-- 6) Persistence: a fresh instance pointed at the same state_path picks up
--    what a previous instance learned (simulating a restart).
do
  files = {}
  local ht1 = new_hop_timing()
  for i = 1, 2 do
    now = i * 5000
    ht1:begin_delivery("R01", { "VALVE-1" }, "minecraft:uranium_ingot", now)
    now = now + 600
    ht1:record_scan("VALVE-1", { ["minecraft:uranium_ingot"] = i * 4 }, now)
    ht1:finish_delivery("R01")
  end
  assert(files[STATE_PATH], "expected hop timing state to be persisted to disk")

  local ht2 = new_hop_timing()
  local edge_ms = ht2:get_edge_ms("EXPORT", "VALVE-1")
  assert(edge_ms == math.ceil(600 * 1.5), "restarted instance should see the persisted learned edge, got " .. tostring(edge_ms))
end

print('fuel_hop_timing_test.lua: ok')
