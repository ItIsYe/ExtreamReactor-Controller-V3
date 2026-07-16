-- Funktionaler Verifikationstest fuer RT-P1 "stabilen Discovery-Default nach
-- erfolgreichem Boot verlangsamen" (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 6). Extrahiert die exakten
-- should_discover()/discover_with_stability_tracking()-Funktionen aus
-- nodes/rt/main.lua und prueft: waehrend der Boot-Phase (< STABLE_STREAK
-- unveraenderte Scans) laeuft jeder faellige Scan; nach Erreichen der
-- Stabilitaetsschwelle wird nur noch jeder SLOW_MULTIPLIER-te faellige Scan
-- tatsaechlich ausgefuehrt; eine echte Bindungsaenderung (Attach/Detach)
-- setzt sofort auf die normale Kadenz zurueck.

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

local src = read_file(REPO .. "/xreactor/nodes/rt/main.lua")
local block_src = extract(src,
  "local DISCOVERY_STABLE_STREAK    = 3",
  "discovery_slow_skip_count = 0\n  end\nend")
assert(block_src:find("discover_with_stability_tracking", 1, true), "extraction missed discover_with_stability_tracking")

local discover_calls = 0
local env = {
  devices = { binding_signature = nil },
  discover = function() discover_calls = discover_calls + 1 end,
}
env._ENV = env
local chunk = assert(load(block_src .. "\nreturn { should_discover = should_discover, discover_with_stability_tracking = discover_with_stability_tracking }",
  "=discovery_stability", "t", env))
local M = chunk()

------------------------------------------------------------------------------
-- Boot-Phase: unter der Stabilitaetsschwelle laeuft jeder faellige Scan.
------------------------------------------------------------------------------

check(M.should_discover(nil, nil, nil, false) == false, "should_discover must return false when not due")
check(M.should_discover(nil, nil, nil, true) == true, "should_discover must return true while below the stability streak")

for i = 1, 3 do
  M.discover_with_stability_tracking()
end
check(discover_calls == 3, "boot-phase ticks must all actually discover (got " .. discover_calls .. ")")

------------------------------------------------------------------------------
-- Nach Erreichen der Stabilitaetsschwelle (3 unveraenderte Scans): nur noch
-- jeder 6. faellige Tick fuehrt tatsaechlich zu einem discover()-Aufruf.
------------------------------------------------------------------------------

-- Once stable, exactly 1 of every DISCOVERY_SLOW_MULTIPLIER (6) due ticks
-- should actually run; the other 5 should be skipped.
local decisions = {}
for i = 1, 6 do
  decisions[i] = M.should_discover(nil, nil, nil, true)
end
local run_count = 0
for _, d in ipairs(decisions) do
  if d then run_count = run_count + 1 end
end
check(run_count == 1, "exactly 1 of 6 due ticks should actually run once stable (got " .. run_count .. ")")
check(decisions[6] == true, "the 6th due tick after stability must be the one that actually runs")
for i = 1, 5 do
  check(decisions[i] == false, "due tick " .. i .. " of 6 must be skipped once stable")
end

------------------------------------------------------------------------------
-- Eine echte Bindungsaenderung setzt sofort auf normale Kadenz zurueck.
------------------------------------------------------------------------------

env.discover = function()
  discover_calls = discover_calls + 1
  env.devices.binding_signature = "changed-" .. tostring(discover_calls)
end
M.discover_with_stability_tracking()
check(M.should_discover(nil, nil, nil, true) == true, "should_discover must return to full cadence immediately after a real binding change")

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
