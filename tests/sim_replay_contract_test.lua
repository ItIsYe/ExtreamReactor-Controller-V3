-- tests/sim_replay_contract_test.lua
local loader = dofile("tests/sim/replay/loader.lua")
local engine = dofile("tests/sim/replay/engine.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

-- Fixture direkt einbetten (kein Dateisystem nötig)
local FIXTURE_SRC = [[return {
  format_version=1, node_id="RT-1", role="RT-NODE", seed=42, ticks=60, dropped=0,
  entries={
    {t=5, kind="peripheral_call",data={name="reactor_0",method="getCasingTemperature",args={},result={350.2}}},
    {t=10,kind="peripheral_call",data={name="reactor_0",method="getCasingTemperature",args={},result={382.7}}},
    {t=10,kind="peripheral_call",data={name="reactor_0",method="getFuelAmount",args={},result={3980}}},
    {t=1, kind="state_change",   data={from="INIT",to="RUNNING",reason="startup"}},
    {t=5, kind="decision",       data={kind="set_rod_level",value=50,context={temp=350.2}}},
    {t=15,kind="decision",       data={kind="set_rod_level",value=52,context={temp=401.1}}},
    {t=5, kind="modem_tx",       data={channel=6500,reply_channel=6501,message={type="status"}}},
  },
}]]

-- Loader
local trace = loader.from_string(FIXTURE_SRC)
A(trace.node_id, "RT-1", "node_id")
A(trace.ticks, 60, "ticks")
A(trace.format_version, 1, "format_version")
T(#trace.entries > 0, "has entries")

-- filter
local pcs = loader.filter(trace, "peripheral_call")
A(#pcs, 3, "3 peripheral_calls")
local states = loader.filter(trace, "state_change")
A(#states, 1, "1 state_change")

-- peripheral_calls
local temp_calls = loader.peripheral_calls(trace, "reactor_0", "getCasingTemperature")
A(#temp_calls, 2, "2 temp calls")

-- decisions
local decs = loader.decisions(trace)
A(#decs, 2, "2 decisions")
A(decs[1].data.kind, "set_rod_level", "decision kind")
A(decs[1].data.value, 50, "decision value")

-- make_peripheral_replay
local src = engine.make_peripheral_replay(trace.entries)
local r1 = src.next("reactor_0","getCasingTemperature")
T(r1 ~= nil, "first replay result not nil")
A(r1[1], 350.2, "first temp")
local r2 = src.next("reactor_0","getCasingTemperature")
A(r2[1], 382.7, "second temp")
local r3 = src.next("reactor_0","getFuelAmount")
A(r3[1], 3980, "fuel amount")

-- compare_decisions: exact match
local recorded = {
  {t=5,  data={kind="rod",value=50}},
  {t=15, data={kind="rod",value=52}},
}
local actual = {
  {kind="rod",value=50},
  {kind="rod",value=52},
}
local cmp1 = engine.compare_decisions(recorded, actual, 0)
A(cmp1.ok, true, "exact match ok")

-- compare_decisions: within tolerance
local actual2 = {
  {kind="rod",value=50.3},
  {kind="rod",value=51.8},
}
local cmp2 = engine.compare_decisions(recorded, actual2, 0.5)
A(cmp2.ok, true, "within tolerance ok")

-- compare_decisions: outside tolerance
local actual3 = {
  {kind="rod",value=55},
  {kind="rod",value=52},
}
local cmp3 = engine.compare_decisions(recorded, actual3, 0.5)
A(cmp3.ok, false, "outside tolerance fails")
T(#cmp3.mismatches > 0, "mismatches reported")

-- count mismatch
local cmp4 = engine.compare_decisions(recorded, {{kind="rod",value=50}}, 0)
A(cmp4.ok, false, "count mismatch")

print("sim_replay_contract_test.lua: ok")
