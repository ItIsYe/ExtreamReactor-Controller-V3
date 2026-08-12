-- tests/sim/scenario.lua  Phase 7.1
-- Versioniertes Szenarioformat + Laufzeit.
-- Jedes Szenario: { version, seed, topology, timeline, invariants, max_ticks }

local M = {}
M.FORMAT_VERSION = 1

-- ── Szenario-Validator ───────────────────────────────────────────────────────
function M.validate(spec)
  assert(type(spec) == "table", "spec must be table")
  assert(type(spec.topology) == "table", "spec.topology required")
  assert(type(spec.invariants) == "table", "spec.invariants required")
  spec.version    = spec.version    or M.FORMAT_VERSION
  spec.seed       = spec.seed       or 0
  spec.max_ticks  = spec.max_ticks  or 10000
  spec.timeline   = spec.timeline   or {}
  return spec
end

-- ── Szenario-Laufzeit ────────────────────────────────────────────────────────
-- run(spec, build_world_fn) → { ok, violations, ticks_run, first_violation }
--   build_world_fn(topology, kernel, eq) → world-Objekt mit :tick(now_ticks) Methode
function M.run(spec, build_world_fn)
  spec = M.validate(spec)

  local kernel   = dofile("tests/sim/cc/kernel.lua")
  local eq_cls   = dofile("tests/sim/cc/event_queue.lua")
  kernel.reset(spec.seed)
  local eq   = eq_cls.new()
  local world = build_world_fn(spec.topology, kernel, eq)

  local violations = {}
  local first_violation = nil
  local ticks = 0

  -- Invarianten beim Laden vorbereiten
  local invariant_fns = {}
  for _, inv in ipairs(spec.invariants) do
    invariant_fns[#invariant_fns + 1] = inv
  end

  -- Timeline-Events vorbereiten (sortiert nach tick)
  local timeline = {}
  for _, ev in ipairs(spec.timeline) do
    timeline[#timeline + 1] = ev
  end
  table.sort(timeline, function(a, b) return a.at < b.at end)
  local tl_idx = 1

  for tick = 1, spec.max_ticks do
    kernel.tick()
    ticks = tick

    -- Timeline-Events feuern
    while tl_idx <= #timeline and timeline[tl_idx].at <= tick do
      local ev = timeline[tl_idx]
      if ev.fn then ev.fn(world, tick) end
      tl_idx = tl_idx + 1
    end

    -- Welt-Tick
    world:tick(tick)

    -- Invarianten prüfen
    for _, inv_fn in ipairs(invariant_fns) do
      local ok, msg = inv_fn(world, tick)
      if not ok then
        local v = { tick = tick, message = msg or "invariant violated" }
        violations[#violations + 1] = v
        if not first_violation then first_violation = v end
        if spec.stop_on_first_violation then
          return { ok = false, violations = violations,
                   ticks_run = ticks, first_violation = first_violation }
        end
      end
    end

    -- Abbruchbedingung
    if world.done and world:done() then break end
  end

  return {
    ok               = #violations == 0,
    violations       = violations,
    ticks_run        = ticks,
    first_violation  = first_violation,
  }
end

return M
