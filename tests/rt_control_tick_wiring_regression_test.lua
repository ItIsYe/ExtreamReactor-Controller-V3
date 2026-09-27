package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Vertrag von control_tick(): ES GIBT GENAU EINEN REGLER.
--
-- Bis v768 standen hier zwei: v1s Modul-Lebenszyklus plus Zustandsmaschine
-- und daneben rt2_engine. Erreichbar war nur rt2_engine -- aber beide
-- griffen ueber gemeinsamen Zustand auf dieselbe Hardware, und ein
-- Sicherheits-Schreiber aus dem v1-Pfad konnte die Regelung stillegen
-- (siehe quiesce_cancel_resumes_control_test.lua). v1 ist entfernt.
--
-- Dieser Test bewacht genau zwei Dinge in control_tick():
--   1. Die Quiesce-Sperre steht VOR jeder Regelarbeit und kehrt sofort
--      zurueck -- ein laufendes Update darf nie gegen den Regler schreiben.
--   2. Danach folgt genau ein Aufruf: rt2_engine.tick(ctx). Kein zweiter
--      Regelpfad, keine Zustandsmaschine, kein Lebenszyklus.

local f = assert(io.open('xreactor/nodes/rt/main.lua', 'r'))
local src = f:read('*a')
f:close()

local start = assert(src:find('local function control_tick()', 1, true),
  'control_tick() nicht gefunden')
local stop = assert(src:find('-- ── Command-Handler', start, true),
  'Ende von control_tick() nicht gefunden')
local body = src:sub(start, stop)

local guard_at = assert(body:find('if rt_update_quiescing then', 1, true),
  'control_tick() prueft die Quiesce-Sperre nicht')
assert(body:find('return\n  end', guard_at, true),
  'die Quiesce-Sperre muss sofort zurueckkehren')

local tick_at = assert(body:find('rt2_engine.tick(ctx)', 1, true),
  'control_tick() ruft den Regler nicht auf')
assert(tick_at > guard_at,
  'der Regler darf erst NACH der Quiesce-Sperre laufen')

-- Kein zweiter Regelpfad. Diese Namen sind die von v1.
for _, forbidden in ipairs({
  'module_lifecycle', 'node_state_machine', 'state_handlers',
  'updateReactorControl', 'updateControl', 'process_startup',
}) do
  assert(not body:find(forbidden, 1, true),
    'control_tick() enthaelt wieder einen v1-Regelpfad: ' .. forbidden)
end

-- Und auch sonst nirgends in der Node.
for _, forbidden in ipairs({
  'nodes.rt.module_lifecycle', 'nodes.rt.state_handlers',
  'nodes.rt.command_handler', 'nodes.rt.capacity_learning',
  'nodes.rt.startup_diagnostics', 'nodes.rt.flow_apply_helpers',
  'nodes.rt.reactor_steam_guard', 'nodes.rt.capacity_cache',
  'core.turbine_regulator', 'core.control_rails',
}) do
  assert(not src:find(forbidden, 1, true),
    'main.lua laedt wieder ein v1-Modul: ' .. forbidden)
end

print('rt_control_tick_wiring_regression_test.lua: ok')
