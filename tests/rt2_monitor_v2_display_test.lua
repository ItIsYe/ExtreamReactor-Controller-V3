package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Live-Test node-101 (gemeldet mit zwei Bildern): im Terminal lief
--     [RT] v2 Einlernen FERTIG: 834054315 RF/t aus 25 Turbinen gemessen
-- waehrend derselbe Knoten auf seinem Monitor gleichzeitig
--     ! LEARNING / > KAPAZITAET WIRD GELERNT / CAPACITY 0.0 / SOLL 0.0 / MASTER % 0.0
-- anzeigte. Beides stimmte fuer sich: die Regelung lief auf v2, die
-- Anzeige las v1.
--
-- Ursache: main.lua's build_status_payload() uebersetzte v2 -> v1-Felder
-- (das ist der Weg zu MASTER), update_monitor() aber nicht. Der
-- RT-eigene Schirm zog also ctx.capacity_learning (v1's Lernzustand, den
-- unter engine=v2 niemand mehr fuellt), ctx.node_state_machine (unter v2
-- bewusst nie weitergeschaltet) und ctx.targets (unter v2 nicht mehr
-- befuellt, weil handle_command_v2 v1's command_handler ersetzt).
--
-- Diese Datei sichert beide Haelften der Reparatur: monitor_ui nimmt eine
-- explizite Vorgabe der regelnden Engine entgegen, und main.lua gibt sie
-- ihr auch.

_G.keys = _G.keys or { left = 1, right = 2, pageUp = 3, pageDown = 4 }
if not os.epoch then
  local now = 0
  os.epoch = function() now = now + 1000; return now end
end

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

package.loaded['nodes.rt.monitor_ui'] = nil
package.loaded['core.ui'] = setmetatable({}, { __index = function() return function() return 20, 10 end end })

-- Der Router wird ersetzt, damit das Modell greifbar ist, das die Seiten
-- tatsaechlich zu sehen bekommen -- genau aus ihm speisen sich Banner,
-- Statuspunkt und die CAPACITY-Kachel.
local rendered_model = nil
package.loaded['core.ui_router'] = {
  new = function()
    return {
      render = function(_, _, model) rendered_model = model end,
      handle_input = function() end,
    }
  end,
}

local monitor_ui = require('nodes.rt.monitor_ui')

-- Genau die Zahlen aus dem Live-Test.
local MEASURED = 834054315
local TURBINES = 25

local function build_ctx(overrides)
  local ctx = {
    config = { node_id = 'node-101', monitor_interval = 0 },
    devices = { reactors = {}, turbines = {}, registry_summary = {}, monitor = {} },
    registry = { get_summary = function() return {} end },
    get_available_steam = function() return 112300 end,
    build_health_payload = function() return { status = 'OK' } end,
    comms = { network = { id = 'node-101' }, get_diagnostics = function() return { peers = {}, metrics = {} } end },
    constants = { roles = { MASTER = 'master' } },
    -- v1's Lernzustand, so wie er unter engine=v2 aussieht: leer. Genau
    -- das hat der Schirm bisher angezeigt.
    capacity_learning = {},
    targets = {},
    node_state_machine = { state = function() return 'RUNNING' end },
    current_state = 'AUTONOM',
  }
  for k, v in pairs(overrides or {}) do ctx[k] = v end
  return ctx
end

-- Ein kompletter Monitor-Durchlauf, so wie main.lua ihn macht.
local function render(ctx)
  rendered_model = nil
  monitor_ui.last_monitor_update = 0
  monitor_ui.monitor_router = nil
  local snapshot = monitor_ui.update(ctx.devices.monitor, ctx)
  assert_true(rendered_model ~= nil, 'die Overview-Seite muss ein Modell bekommen haben')
  return snapshot, rendered_model
end

-- ── 1. Ohne Vorgabe bleibt es beim alten (v1-)Verhalten ──────────────────

do
  local _, model = render(build_ctx())
  assert_eq(model.capacity_ready, false, 'ohne Vorgabe zaehlt weiter v1s Lernzustand')
  assert_eq(model.capacity_max, 0, 'und dessen (leere) Kapazitaet')
  assert_eq(model.node_state, 'RUNNING', 'und v1s Zustandsautomat')
end

-- ── 2. Mit Vorgabe zeigt der Schirm, was die Engine wirklich weiss ───

do
  local snapshot, model = render(build_ctx({
    capacity_override = {
      ready = true, max_output = MEASURED, at_target = TURBINES,
      total_turbines = TURBINES, reason = 'MEASURED',
    },
    node_state = 'AUTONOM',
    targets = { power = 700000000, power_percent = 84, rpm = 900 },
  }))

  assert_eq(snapshot.capacity_ready, true,
    'nach "Einlernen FERTIG" darf der Schirm nicht weiter LEARNING zeigen')
  assert_eq(snapshot.capacity_max, MEASURED,
    'und muss die gemessene Kapazitaet nennen statt 0')
  assert_eq(snapshot.capacity_stable_turbines, TURBINES, 'inklusive der Turbinenzahl dahinter')
  assert_eq(snapshot.capacity_total_turbines, TURBINES)
  assert_eq(snapshot.capacity_source, 'MEASURED')

  -- Das Modell ist es, aus dem Banner ("> KAPAZITAET WIRD GELERNT"),
  -- Statuspunkt ("LEARNING") und die CAPACITY-Kachel gebaut werden.
  assert_eq(model.capacity_ready, true, 'sonst steht weiter LEARNING im Kopf der Seite')
  assert_eq(model.capacity_max, MEASURED, 'sonst zeigt die CAPACITY-Kachel 0.0')
  assert_eq(model.node_state, 'AUTONOM',
    'der Zustand kommt von der Engine, nicht vom unter v2 eingefrorenen node_state_machine')
  assert_eq(model.target_percent, 84, 'und die Leistungsvorgabe aus der Engine statt v1s leerem ctx.targets')
  assert_eq(model.target_power, 700000000)
end

-- ── 3. main.lua muss die Vorgabe auch tatsaechlich setzen ────────────────
--
-- Der monitor_ui-Teil allein reicht nicht: der Fehler war, dass niemand
-- die Uebersetzung aufruft. Ohne diese Pruefung faellt genau das wieder
-- unbemerkt heraus.

do
  local f = assert(io.open('xreactor/nodes/rt/main.lua', 'r'))
  local src = f:read('*a')
  f:close()

  local start = src:find('local function update_monitor()', 1, true)
  assert_true(start ~= nil, 'update_monitor() nicht gefunden')
  local stop = src:find('local function control_tick()', start, true)
  assert_true(stop ~= nil, 'Ende von update_monitor() nicht gefunden')
  local body = src:sub(start, stop)

  assert_true(body:find('engine_v2', 1, true) ~= nil,
    'update_monitor() muss den v2-Fall ueberhaupt kennen -- sonst zeigt der RT-Schirm v1-Daten,'
      .. ' waehrend v2 regelt (Live-Test node-101)')
  assert_true(body:find('capacity_override', 1, true) ~= nil,
    'update_monitor() muss monitor_ui den Lernzustand der regelnden Engine mitgeben')
  assert_true(body:find('monitor_ctx.node_state', 1, true) ~= nil,
    'update_monitor() muss auch den projizierten Knotenzustand mitgeben')
  assert_true(body:find('master_percent', 1, true) ~= nil,
    'und die Leistungsvorgabe -- sonst steht dort dauerhaft MASTER % 0.0')
end

print('rt2_monitor_v2_display_test.lua: ok')
