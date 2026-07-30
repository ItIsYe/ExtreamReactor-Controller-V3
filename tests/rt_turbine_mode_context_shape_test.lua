-- tests/rt_turbine_mode_context_shape_test.lua
--
-- Pflicht-Test fuer RT-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 11 "KRITISCH OFFEN"). nodes/rt/main.lua's echter
-- make_lifecycle_ctx() lieferte "TURBINE_MODE = CONFIG.TURBINE_MODE_RAMP or
-- \"RAMP\"" -- also einen STRING -- waehrend nodes/rt/module_lifecycle.lua
-- diesen Wert an zwei Stellen als TABELLE indizierte (ctx.TURBINE_MODE.RAMP).
-- Der vorherige End-to-End-Test (tests/rt_master_startup_end_to_end_test.lua)
-- baute seinen eigenen, HANDGESCHRIEBENEN Mock-Context mit der (falschen)
-- Tabellenform und deckte die reale Produktionsabweichung deshalb nicht auf.
--
-- nodes/rt/main.lua hat schwere Boot-Zeit-Seiteneffekte und kann nicht per
-- require() instanziiert werden -- dieser Test prueft deshalb strukturell
-- per Quelltext-Suche, dass main.lua's echte make_lifecycle_ctx() und
-- module_lifecycle.lua's tatsaechliche Zugriffe auf denselben Feldnamen UND
-- denselben (skalaren, nicht verschachtelten) Typ uebereinstimmen -- ein
-- direkter, unmissverstaendlicher Regressionsschutz gegen genau diese Art
-- von Context-Shape-Drift zwischen den beiden Dateien.

local function read(path)
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local c = f:read('*a')
  f:close()
  return c
end

local main_src = read('xreactor/nodes/rt/main.lua')
local lifecycle_src = read('xreactor/nodes/rt/module_lifecycle.lua')

-- main.lua's make_lifecycle_ctx() must expose a plain scalar
-- TURBINE_MODE_RAMP field (matching turbine_control.lua's own established
-- ctx.CONFIG.TURBINE_MODE_RAMP convention -- always a string, never a
-- table), not a "TURBINE_MODE" table wrapper.
assert(main_src:find('TURBINE_MODE_RAMP = CONFIG.TURBINE_MODE_RAMP or "RAMP"', 1, true),
  'nodes/rt/main.lua make_lifecycle_ctx() must define a scalar TURBINE_MODE_RAMP field')
assert(not main_src:find('TURBINE_MODE = CONFIG.TURBINE_MODE_RAMP', 1, true),
  'nodes/rt/main.lua must not reintroduce a "TURBINE_MODE" (table-shaped) context field')

-- module_lifecycle.lua must consume that same scalar field directly, never
-- index into it as a table (the exact production crash-risk from the
-- audit).
assert(not lifecycle_src:find('ctx.TURBINE_MODE.RAMP', 1, true),
  'module_lifecycle.lua must not index ctx.TURBINE_MODE as a table -- the real context provides a scalar TURBINE_MODE_RAMP')

local occurrences = 0
local pos = 1
while true do
  local s = lifecycle_src:find('ctx.TURBINE_MODE_RAMP', pos, true)
  if not s then break end
  occurrences = occurrences + 1
  pos = s + 1
end
assert(occurrences >= 2,
  'module_lifecycle.lua must read ctx.TURBINE_MODE_RAMP at both call sites (start_module() and apply_safe_controls()), found: ' .. occurrences)

print('rt_turbine_mode_context_shape_test.lua: ok')
