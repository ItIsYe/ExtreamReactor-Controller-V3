-- Funktionaler Verifikationstest fuer RT-P1 "Singular-/Plural-Kind-Namen
-- normalisieren" (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md
-- Abschnitt 6). Extrahiert das echte M.get_device_caps() aus
-- nodes/rt/turbine_control.lua und prueft, dass singularer ("reactor",
-- "turbine") und pluraler ("reactors", "turbines") Aufruf denselben
-- Cache-Eintrag treffen -- statt still zwei getrennte, nie zusammenpassende
-- Cache-Namensraeume anzulegen.

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

local src = read_file(REPO .. "/xreactor/nodes/rt/turbine_control.lua")
local block_src = extract(src,
  "local KIND_TO_CACHE_KEY = {",
  "return ctx.capability_cache[kind][name]\nend")

local build_calls = 0
local chunk = assert(load(
  "local M = {}\n" .. block_src .. "\nreturn M",
  "=get_device_caps",
  "t"))
-- build_capabilities is a module-local upvalue in the real file; the
-- extracted block only includes KIND_TO_CACHE_KEY/normalize_kind/
-- get_device_caps, so provide a stand-in via the global environment.
build_capabilities = function(name)
  build_calls = build_calls + 1
  return { name = name }
end
local M = chunk()

------------------------------------------------------------------------------
-- Singular und Plural muessen denselben Cache-Eintrag treffen.
------------------------------------------------------------------------------

do
  local ctx = { capability_cache = {} }

  local caps1 = M.get_device_caps(ctx, "reactor", "reactor_1")
  check(build_calls == 1, "first call (singular) should build once")

  local caps2 = M.get_device_caps(ctx, "reactors", "reactor_1")
  check(build_calls == 1, "plural call for the same device must hit the cache built by the singular call (got " .. build_calls .. " builds)")
  check(caps1 == caps2, "singular and plural kind must resolve to the identical cached object")

  local caps3 = M.get_device_caps(ctx, "turbine", "turbine_1")
  check(build_calls == 2, "different kind/device should build once")
  local caps4 = M.get_device_caps(ctx, "turbines", "turbine_1")
  check(build_calls == 2, "plural turbine call must hit the cache built by the singular call")
  check(caps3 == caps4, "singular and plural turbine kind must resolve to the identical cached object")

  check(ctx.capability_cache.reactor == nil, "no stray singular 'reactor' cache namespace should be created")
  check(ctx.capability_cache.turbine == nil, "no stray singular 'turbine' cache namespace should be created")
  check(ctx.capability_cache.reactors ~= nil, "the real plural 'reactors' cache namespace must exist")
  check(ctx.capability_cache.turbines ~= nil, "the real plural 'turbines' cache namespace must exist")
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
