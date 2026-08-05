-- tests/sim_recorder_contract_test.lua
local M = dofile("xreactor/trace/recorder.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

local rec = M.new({ node_id="RT-1", role="RT-NODE", seed=42 })

-- tick
rec:tick(); rec:tick(); rec:tick()
A(rec:stats().ticks, 3, "3 ticks")

-- peripheral_call
rec:record_peripheral("reactor_0", "getCasingTemperature", {}, {350.2})
rec:record_peripheral("reactor_0", "getActive", {}, {true})
A(rec:stats().entries, 2, "2 entries")

-- event
rec:record_event("timer", 7)
A(rec:stats().entries, 3, "3 entries")

-- modem_rx / modem_tx
rec:record_modem_rx(6500, 6501, {type="cmd"}, 1)
rec:record_modem_tx(6500, 6501, {type="ack"})
A(rec:stats().entries, 5, "5 entries")

-- state_change
rec:record_state("INIT", "RUNNING", "startup")
A(rec:stats().entries, 6, "6 entries")

-- decision
rec:record_decision("set_rod_level", 50, {temp=350.2})
A(rec:stats().entries, 7, "7 entries")

-- entry Kinds prüfen
local kinds = {}
for _, e in ipairs(rec:entries()) do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
A(kinds["peripheral_call"], 2, "2 peripheral_calls")
A(kinds["event"], 1, "1 event")
A(kinds["modem_rx"], 1, "1 modem_rx")
A(kinds["modem_tx"], 1, "1 modem_tx")
A(kinds["state_change"], 1, "1 state_change")
A(kinds["decision"], 1, "1 decision")

-- wrap_peripheral instrumentiert alle Methoden
local proxy = { getTemp=function() return 500 end, setLevel=function(l) end }
local w = rec:wrap_peripheral("dev1", proxy)
T(w ~= nil, "wrap not nil")
local t = w.getTemp()
A(t, 500, "wrapped call returns value")
-- Aufzeichnung geprüft: wrap fügt einen Entry hinzu
T(rec:stats().entries > 7, "wrap records call")

-- serialize produziert validen Lua-String
local s = rec:serialize()
T(type(s) == "string", "serialize returns string")
T(s:find("format_version") ~= nil, "has format_version")
T(s:find("RT%-1") ~= nil, "has node_id")
T(s:find("peripheral_call") ~= nil, "has peripheral_call entries")

-- MAX_ENTRIES Begrenzung
local rec2 = M.new({})
M.MAX_ENTRIES = 5
for i = 1, 10 do rec2:record_event("x", i) end
T(rec2:stats().entries <= 5, "entries capped")
T(rec2:stats().dropped > 0, "dropped > 0")
M.MAX_ENTRIES = 50000  -- zurücksetzen

-- disable/enable
local rec3 = M.new({})
rec3:disable()
rec3:record_event("hidden", 1)
A(rec3:stats().entries, 0, "disabled: no entries")
rec3:enable()
rec3:record_event("visible", 2)
A(rec3:stats().entries, 1, "enabled: 1 entry")

-- in-memory save (mit VFS)
local fs_mod = dofile("tests/sim/cc/fs.lua")
local vfs = fs_mod.new()
local ok, err = rec:save(vfs, "/trace/run1.lua")
T(ok, "save ok: " .. tostring(err))
T(vfs.exists("/trace/run1.lua"), "file written")

print("sim_recorder_contract_test.lua: ok")
