-- Funktionaler Verifikationstest fuer RT-P1 "Capability-Cache exakt einmal
-- pro Discoverygeneration" / "gezielte Invalidierung bei Attach/Detach"
-- (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitt 6).
-- Extrahiert die exakte refresh_capability_cache()-Funktion aus
-- nodes/rt/discovery_runtime.lua und prueft: bereits gecachte Namen werden
-- NICHT erneut per build_capabilities() berechnet; neue Namen werden
-- berechnet; nicht mehr gebundene Namen werden aus dem Cache entfernt.

local REPO = os.getenv("REPO_ROOT") or "."

local function read_file(p)
  local f = assert(io.open(p, "r"))
  local c = f:read("*a")
  f:close()
  return c
end

local function extract(s, start_marker, end_marker)
  local a = s:find(start_marker, 1, true)
  assert(a, "start marker not found: " .. start_marker)
  local b = s:find(end_marker, a, true)
  assert(b, "end marker not found: " .. end_marker)
  return s:sub(a, b + #end_marker - 1)
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local src = read_file(REPO .. "/xreactor/nodes/rt/discovery_runtime.lua")
local fn_src = extract(src,
  "local function refresh_capability_cache(ctx, kind, names)",
  "\nend")
local chunk = assert(load(fn_src .. "\nreturn refresh_capability_cache", "=refresh_capability_cache"))
local refresh_capability_cache = chunk()

local build_calls = {}
local function make_ctx()
  return {
    capability_cache = { turbines = {} },
    build_capabilities = function(name)
      build_calls[name] = (build_calls[name] or 0) + 1
      return { name = name }
    end,
  }
end

------------------------------------------------------------------------------
-- Erster Aufruf: alle drei Namen sind neu, muessen berechnet werden.
------------------------------------------------------------------------------

do
  build_calls = {}
  local ctx = make_ctx()
  refresh_capability_cache(ctx, "turbines", { "turbine_1", "turbine_2", "turbine_3" })

  check(build_calls.turbine_1 == 1, "turbine_1 should be built once")
  check(build_calls.turbine_2 == 1, "turbine_2 should be built once")
  check(build_calls.turbine_3 == 1, "turbine_3 should be built once")
  check(ctx.capability_cache.turbines.turbine_1 ~= nil, "turbine_1 must be cached")

  ------------------------------------------------------------------------------
  -- Zweiter Aufruf, unveraenderte Bindung: KEIN Geraet darf erneut berechnet
  -- werden (Kernpunkt von RT-P1: einmal pro Discoverygeneration, nicht bei
  -- jedem M.cache()-Aufruf erneut fuer bereits bekannte Geraete).
  ------------------------------------------------------------------------------
  refresh_capability_cache(ctx, "turbines", { "turbine_1", "turbine_2", "turbine_3" })
  check(build_calls.turbine_1 == 1, "turbine_1 must NOT be rebuilt when still bound (got " .. build_calls.turbine_1 .. ")")
  check(build_calls.turbine_2 == 1, "turbine_2 must NOT be rebuilt when still bound (got " .. build_calls.turbine_2 .. ")")
  check(build_calls.turbine_3 == 1, "turbine_3 must NOT be rebuilt when still bound (got " .. build_calls.turbine_3 .. ")")

  ------------------------------------------------------------------------------
  -- Dritter Aufruf: turbine_2 wird abgehaengt (detach), turbine_4 neu
  -- angehaengt (attach). Nur turbine_4 darf berechnet werden; turbine_2 muss
  -- aus dem Cache verschwinden (kein unbegrenztes Wachstum); turbine_1/
  -- turbine_3 bleiben unangetastet.
  ------------------------------------------------------------------------------
  refresh_capability_cache(ctx, "turbines", { "turbine_1", "turbine_3", "turbine_4" })
  check(build_calls.turbine_4 == 1, "newly attached turbine_4 should be built exactly once")
  check(build_calls.turbine_1 == 1, "turbine_1 must still not be rebuilt")
  check(build_calls.turbine_3 == 1, "turbine_3 must still not be rebuilt")
  check(ctx.capability_cache.turbines.turbine_2 == nil, "detached turbine_2 must be pruned from the cache")
  check(ctx.capability_cache.turbines.turbine_1 ~= nil, "turbine_1 must remain cached")
  check(ctx.capability_cache.turbines.turbine_4 ~= nil, "turbine_4 must be cached after attach")
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
