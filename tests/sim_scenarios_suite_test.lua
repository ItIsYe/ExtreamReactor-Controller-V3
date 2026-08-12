-- tests/sim_scenarios_suite_test.lua
-- Führt alle drei Pflicht-Szenarien aus.

local function run_scenario(path)
  local ok, err = pcall(dofile, path)
  if not ok then error("SCENARIO FAILED: " .. path .. "\n" .. tostring(err), 2) end
end

run_scenario("tests/sim/scenarios/normal_boot.lua")
run_scenario("tests/sim/scenarios/overtemp_scram.lua")
run_scenario("tests/sim/scenarios/turbine_startup.lua")

print("sim_scenarios_suite_test.lua: ok (3/3 Szenarien bestanden)")
