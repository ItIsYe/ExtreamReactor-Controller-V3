-- tests/sim_scenario_contract_test.lua
local M = dofile("tests/sim/scenario.lua")
local eq_cls = dofile("tests/sim/cc/event_queue.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

-- Minimalwelt
local function mk_world(n, always_ok)
  return function(topology, kernel, eq)
    local w = { count = 0 }
    function w:tick(t)
      self.count = self.count + 1
    end
    return w
  end
end

-- Basis: leere Invarianten → immer ok
local r1 = M.run({
  topology={reactors={}}, invariants={}, max_ticks=10, seed=0,
  timeline={}
}, mk_world())
A(r1.ok, true, "no invariants = ok")
A(r1.ticks_run, 10, "ran 10 ticks")
A(#r1.violations, 0, "no violations")

-- Invariante die immer verletzt ist
local r2 = M.run({
  topology={}, invariants={function() return false,"fail" end},
  max_ticks=5, stop_on_first_violation=true
}, mk_world())
A(r2.ok, false, "violated = not ok")
T(r2.first_violation ~= nil, "first_violation set")
A(r2.first_violation.tick, 1, "first violation at tick 1")
A(r2.first_violation.message, "fail", "violation message")

-- Timeline-Event feuert zur richtigen Zeit
local fired_at = nil
local r3 = M.run({
  topology={}, invariants={}, max_ticks=20, seed=0,
  timeline={ { at=10, fn=function(w,t) fired_at=t end } },
}, mk_world())
A(fired_at, 10, "timeline event fired at tick 10")

-- stop_on_first_violation stoppt früh
local count = 0
local r4 = M.run({
  topology={}, invariants={function(w,t) count=count+1; return false,"x" end},
  max_ticks=100, stop_on_first_violation=true
}, mk_world())
A(r4.ok, false, "stopped early")
T(r4.ticks_run < 100, "early stop: ticks_run=" .. r4.ticks_run)

-- validate: fehlende Felder werden mit Defaults befüllt
local spec = M.validate({ topology={}, invariants={} })
A(spec.seed, 0, "default seed")
A(spec.max_ticks, 10000, "default max_ticks")
A(spec.version, M.FORMAT_VERSION, "format version")

print("sim_scenario_contract_test.lua: ok")
