-- tests/sim_fixture_replay_test.lua
-- Integrationstest: synthetische Fixture laden und Replay verifizieren.

local loader  = dofile("tests/sim/replay/loader.lua")
local engine  = dofile("tests/sim/replay/engine.lua")
local reactor = dofile("tests/sim/models/reactor.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

-- Fixture laden
local trace = loader.from_file("tests/sim/fixtures/reactor_normal_run.lua")
T(trace ~= nil, "fixture loaded")
A(trace.node_id, "RT-1", "fixture node_id")
A(trace.ticks, 60, "fixture ticks")

-- Peripheral-Replay-Source aufbauen
local src = engine.make_peripheral_replay(trace.entries)

-- Simulierten Reaktor laufen lassen und Entscheidungen loggen
local r    = reactor.new({ rod_level=50, initial_fuel=4000, casing_temp=340 })
local actual_decisions = {}

for tick = 1, 20 do
  r.tick()
  -- Simulierter Regler: bei Temp > 400 → Rods erhöhen
  local temp = r.getCasingTemperature()
  if tick % 5 == 0 then
    local new_level = temp > 400 and 52 or 50
    r.setAllControlRodLevels(new_level)
    actual_decisions[#actual_decisions+1] = {
      kind  = "set_rod_level",
      value = new_level,
    }
  end
end

T(#actual_decisions > 0, "decisions made")

-- Aufgezeichnete Entscheidungen
local recorded = loader.decisions(trace)
T(#recorded > 0, "recorded decisions loaded")

-- Vergleich mit Toleranz 2 (Rod-Level darf um 2 abweichen)
local cmp = engine.compare_decisions(recorded, actual_decisions, 2)

-- Minimal-Prüfung: kein dramatischer Ausreißer
local dramatic = false
for _, mm in ipairs(cmp.mismatches) do
  if mm.issue and mm.issue:find("kind mismatch") then
    dramatic = true
  end
end
T(not dramatic, "no kind mismatches in fixture replay")

-- Peripheral-Replay-Sequenz bleibt konsistent
local temp1 = src.next("reactor_0","getCasingTemperature")
T(temp1 ~= nil, "replay temp1 not nil")
T(type(temp1[1]) == "number", "replay temp1 is number")

print("sim_fixture_replay_test.lua: ok")
print("  fixture: " .. trace.node_id .. " (" .. trace.ticks .. " ticks)")
print("  decisions: recorded=" .. #recorded .. " actual=" .. #actual_decisions)
print("  mismatches: " .. #cmp.mismatches)
