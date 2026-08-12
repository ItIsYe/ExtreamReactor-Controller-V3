-- tests/sim_invariants_contract_test.lua
local inv_control = dofile("tests/sim/invariants/control.lua")
local inv_safety  = dofile("tests/sim/invariants/safety.lua")
local inv_comms   = dofile("tests/sim/invariants/comms.lua")
local inv_update  = dofile("tests/sim/invariants/update.lua")
local reactor_mod = dofile("tests/sim/models/reactor.lua")
local turbine_mod = dofile("tests/sim/models/turbine.lua")
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
local function T(v,m) if not v then error(m or"true") end end

-- ── control.lua ──────────────────────────────────────────────────────────────
local r = reactor_mod.new({rod_level=50, initial_fuel=4000})
local world_r = { reactors={r}, turbines={}, energy={} }

local rod_ok = inv_control.rod_bounds(0, 100)
A(rod_ok(world_r, 1), true, "rod in bounds")

r.setControlRod(0, 150)  -- Klemmt intern auf 100
local rod_ok2 = inv_control.rod_bounds(0, 100)
A(rod_ok2(world_r, 2), true, "rod still clamped to 100")

local temp_ok = inv_control.temp_ceiling(2000)
A(temp_ok(world_r, 1), true, "temp ceiling ok at start")

local t = turbine_mod.new({initial_flow=500, flow_capacity=2000})
local world_t = { turbines={t}, reactors={}, energy={} }
local flow_ok = inv_control.flow_bounds(2000)
A(flow_ok(world_t, 1), true, "flow in bounds")

-- ── safety.lua ───────────────────────────────────────────────────────────────
local fuel_ok = inv_safety.fuel_nonneg()
A(fuel_ok(world_r, 1), true, "fuel >= 0")
local waste_ok = inv_safety.waste_bounded()
A(waste_ok(world_r, 1), true, "waste bounded")

-- scram_on_overtemp: aktiver Reaktor unter Temp → OK
local r2 = reactor_mod.new({casing_temp=1000})
local scram_check = inv_safety.scram_on_overtemp(1500)
A(scram_check({reactors={r2}}, 5), true, "temp below limit ok")

-- scram: Reaktor aktiv über Limit → Verletzung
local r3 = reactor_mod.new({casing_temp=2000})
local ok3, msg3 = scram_check({reactors={r3}}, 6)
A(ok3, false, "over limit active = violation")
T(msg3:find("tick=6") ~= nil, "msg has tick")

-- Reaktor inaktiv über Limit → OK (SCRAM ausgelöst)
r3.setActive(false)
A(scram_check({reactors={r3}}, 7), true, "inactive over limit ok")

-- ── comms.lua ────────────────────────────────────────────────────────────────
local always = inv_comms.always_ok("test")
A(always({}, 1), true, "always ok")

-- ── update.lua ───────────────────────────────────────────────────────────────
local mono = inv_update.version_monotone()
A(mono({manifest_version=1}, 1), true, "v1 ok")
A(mono({manifest_version=2}, 2), true, "v2 ok")
local ok_down, _ = mono({manifest_version=1}, 3)
A(ok_down, false, "v1 after v2 = violation")

local hash_ok = inv_update.installer_hash_stable("abc123")
A(hash_ok({installer_hash="abc123"}, 1), true, "hash match")
local ok_h, _ = hash_ok({installer_hash="wronghash"}, 2)
A(ok_h, false, "hash mismatch = violation")

print("sim_invariants_contract_test.lua: ok")
