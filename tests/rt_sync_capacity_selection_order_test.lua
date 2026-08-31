-- build_node_setpoint_plan() zaehlte "wie viele Nodes werden benoetigt"
-- (needed_nodes) gegen die Reihenfolge nach aktuellem Output
-- (sort_by_priority_then_id), waehlte dann aber die tatsaechlich aktiven
-- Nodes nach Kapazitaet aus (table.sort(active, ...) nach Kapazitaet,
-- direkt vor der needed_capacity-Summe). Ein Node mit hohem aktuellem
-- Output aber kleiner Kapazitaet konnte so den Zaehler "verbrauchen",
-- bevor ein viel groesserer, aber gerade untaetiger Node an der Reihe
-- war -- Ergebnis: ein unnoetiger zusaetzlicher Reaktor wurde aktiviert.
--
-- Szenario: Node A hat wenig Kapazitaet (100) aber laeuft gerade mit
-- hohem Output (90) -- unter der alten, output-sortierten Zaehlung kam A
-- zuerst dran. Node B hat viel Kapazitaet (1000), aber aktuell 0 Output.
-- global_target = 150 <= B.capacity allein -- es wird nur 1 Node
-- benoetigt. Alt: needed_nodes wurde gegen [A, B] gezaehlt (A zuerst,
-- deckt 150 nicht -> B auch noetig) -> needed_nodes=2, beide aktiv.
-- Neu: Kapazitaets-Sortierung zuerst -> [B, A] -> B allein deckt 150 ->
-- needed_nodes=1 -> nur B aktiv, A geht in Standby/Shed.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

os.epoch = os.epoch or function() return 0 end
local now_ms = 1000000
os.epoch = function() return now_ms end

local rt_sync = require('master.rt_sync')
local constants = require('shared.constants')

local node_a = {
  id = 'RT-A',
  role = constants.roles.RT_NODE,
  mode = 'MASTER',
  status = constants.status_levels.OK,
  state = constants.node_states.RUNNING,
  actual_output = 90,
  capacity_ready = true,
  capacity_max = 100,
}

local node_b = {
  id = 'RT-B',
  role = constants.roles.RT_NODE,
  mode = 'MASTER',
  status = constants.status_levels.OK,
  state = constants.node_states.RUNNING,
  actual_output = 0,
  capacity_ready = true,
  capacity_max = 1000,
}

local ctx = {
  nodes = { [node_a.id] = node_a, [node_b.id] = node_b },
  config = {},
  power_target = 150,
  rt_global_off = false,
}

local result = rt_sync.build_node_setpoint_plan(ctx)
local plan = result.nodes

local by_id = {}
for _, entry in ipairs(plan) do
  by_id[entry.id] = entry
end

if result.required_nodes ~= 1 then
  error('expected required_nodes=1 (single high-capacity node covers global_target), got ' .. tostring(result.required_nodes))
end

if not by_id['RT-B'] or by_id['RT-B'].assignment_state ~= 'active' then
  error('expected RT-B (large capacity, idle) to be assignment_state=active, got ' ..
    tostring(by_id['RT-B'] and by_id['RT-B'].assignment_state))
end

if not by_id['RT-A'] or by_id['RT-A'].assignment_state == 'active' then
  error('expected RT-A (small capacity, currently high output) to NOT be activated, got ' ..
    tostring(by_id['RT-A'] and by_id['RT-A'].assignment_state))
end

local active_count = 0
for _, entry in ipairs(plan) do
  if entry.assignment_state == 'active' then active_count = active_count + 1 end
end
if active_count ~= 1 then
  error('expected exactly 1 active node given global_target=150 <= single node capacity, got ' .. tostring(active_count))
end

print('rt_sync_capacity_selection_order_test.lua: ok')
