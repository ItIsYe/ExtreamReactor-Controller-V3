package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Betreiber (2026-10-15): "jetzt scheint es so als wuerden alle Ampeln
-- nicht mehr funktionieren ... alle Nodes sind betroffen, und mache die
-- Ampel auch fuer 1x1 Monitor kompatibel".
--
-- Bis v828 malten optional/ampel.lua, optional/master_ampel.lua und der
-- VALVE-Statusmonitor nur bei einem Farbwechsel. Verlor ein Monitor seinen
-- Inhalt (Chunk neu geladen, Skala von anderer Stelle umgestellt, Monitor
-- neu gebaut), blieb die Ampel bei ruhig laufender Anlage dauerhaft
-- schwarz bzw. nur zum Teil gefaerbt. Erkannt wurde ausserdem nur die
-- 1x3-Form.
--
-- Diese Datei haelt fest:
--   1. 1x1 und 1x3 werden als Ampel erkannt, andere Formen nicht,
--   2. spaetestens alle 10 s wird neu gemalt -- verlorener Inhalt kommt
--      zurueck, ohne dass sich der Status aendern muss,
--   3. eine abgezogene und wieder angeschlossene Ampel wird sofort wieder
--      gefunden und gemalt,
--   4. eine 1x1-Ampel wird nie zum Hauptmonitor, auch nicht direkt am
--      Rechner,
--   5. dasselbe fuer die MASTER-Ampel und den VALVE-Statusmonitor.

_G.colors = _G.colors or {}
colors.green = 0x2000; colors.yellow = 0x10; colors.orange = 0x2
colors.red = 0x4000; colors.gray = 0x80; colors.black = 0x8000

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ---- Welt: Monitore mit der Geometrie von CC:Tweaked ---------------------

-- MonitorBlockEntity: Rand 2/16 + 0.5/16 je Seite, Zeichen 6x9 Pixel bei
-- 64 Pixel je Block und Skala 1.
local function chars(bw, bh, scale)
  local inner_w = bw - 2 * (2 / 16 + 0.5 / 16)
  local inner_h = bh - 2 * (2 / 16 + 0.5 / 16)
  local w = math.max(math.floor(inner_w / (scale * 6 / 64) + 0.5), 1)
  local h = math.max(math.floor(inner_h / (scale * 9 / 64) + 0.5), 1)
  return w, h
end

local function new_monitor(bw, bh, scale)
  local m = { bw = bw, bh = bh, scale = scale or 0.5, bg = colors.black, screen = nil, paints = 0, scale_calls = 0 }
  function m.getTextScale() return m.scale end
  function m.setTextScale(s)
    -- Neue Skala = neue Terminalgroesse: Inhalt ist danach nur noch zum
    -- Teil da (CC:Tweaked Terminal.resize) -- hier vereinfacht: weg.
    if s ~= m.scale then m.screen = nil end
    m.scale = s
    m.scale_calls = m.scale_calls + 1
  end
  function m.getSize() return chars(m.bw, m.bh, m.scale) end
  function m.setBackgroundColor(c) m.bg = c end
  function m.clear() m.screen = m.bg; m.paints = m.paints + 1 end
  return m
end

local world = { monitors = {}, attached = {} }
local function reset_world(spec)
  world.monitors, world.attached = {}, {}
  for name, dims in pairs(spec) do
    world.monitors[name] = new_monitor(dims[1], dims[2], dims[3])
    world.attached[name] = true
  end
end

local clock = 0
os.clock = function() return clock end

_G.peripheral = {
  getNames = function()
    local out = {}
    for name in pairs(world.monitors) do if world.attached[name] then out[#out + 1] = name end end
    table.sort(out)
    return out
  end,
  isPresent = function(name) return world.attached[name] == true end,
  getType = function(name) return world.attached[name] and 'monitor' or nil end,
  wrap = function(name) return world.attached[name] and world.monitors[name] or nil end,
}

local printed = {}
local real_print = print
_G.print = function(...) local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end printed[#printed + 1] = table.concat(t, ' ') end

package.loaded['adapters.monitor'] = nil
package.loaded['optional.ampel'] = nil
package.loaded['optional.master_ampel'] = nil
local monitor_adapter = require('adapters.monitor')
local ampel_mod = require('optional.ampel')

-- ══ 1. Form: 1x1 und 1x3 ja, alles andere nein ══════════════════════════

do
  local function shape(bw, bh) return monitor_adapter.is_ampel_shape(chars(bw, bh, 1)) end
  assert_eq(shape(1, 1), true, '1x1 ist eine Ampel')
  assert_eq(shape(1, 3), true, '1x3 ist eine Ampel')
  for _, d in ipairs({ { 1, 2 }, { 2, 1 }, { 2, 2 }, { 1, 4 }, { 2, 3 }, { 3, 2 }, { 3, 3 }, { 4, 3 } }) do
    assert_eq(shape(d[1], d[2]), false, d[1] .. 'x' .. d[2] .. ' ist keine Ampel')
  end
end

-- ══ 2. Node-Ampel: 1x1 und 1x3 werden gefunden und gemalt ═══════════════

for _, dims in ipairs({ { 1, 1, '1x1' }, { 1, 3, '1x3' } }) do
  -- "a_other" sortiert vor "ampel" und wird darum zuerst sondiert.
  reset_world({ main = { 3, 2 }, ampel = { dims[1], dims[2] }, a_other = { 2, 2 } })
  clock = 0
  local a = ampel_mod.new()
  a.render('main', 'OK')
  assert_eq(world.monitors.ampel.screen, colors.green, dims[3] .. ': gefunden und gruen')
  assert_eq(world.monitors.main.screen, nil, dims[3] .. ': der Hauptmonitor wird nie bemalt')
  assert_eq(world.monitors.main.scale_calls, 0, 'und seine Skala nie angefasst')
  assert_true(world.monitors.a_other.scale_calls > 0, 'der andere Monitor wurde sondiert')
  assert_eq(world.monitors.a_other.scale, 0.5, 'ein Nicht-Treffer bekommt seine Skala zurueck')
end

-- Der Hauptmonitor wird gar nicht erst sondiert, auch wenn er in der
-- Liste vor der Ampel steht (Skalenwechsel = Flackern auf der Anzeige).
do
  reset_world({ aa_main = { 3, 2 }, ampel = { 1, 3 } })
  clock = 50
  ampel_mod.new().render('aa_main', 'OK')
  assert_eq(world.monitors.ampel.screen, colors.green)
  assert_eq(world.monitors.aa_main.scale_calls, 0, 'die Skala des Hauptmonitors wird nie angefasst')
end

-- ══ 3. Inhalt weg: spaetestens nach 10 s wieder da, nicht dauernd ═══════

do
  reset_world({ main = { 3, 2 }, ampel = { 1, 3 } })
  clock = 100
  local a = ampel_mod.new()
  a.render('main', 'OK')
  local amp = world.monitors.ampel
  assert_eq(amp.screen, colors.green)
  local paints = amp.paints

  amp.screen = nil -- Chunk neu geladen: Monitor leer, Status unveraendert
  clock = 105; a.render('main', 'OK')
  assert_eq(amp.paints, paints, 'innerhalb von 10 s wird nicht dauernd neu gemalt')
  clock = 110; a.render('main', 'OK')
  assert_eq(amp.screen, colors.green, 'nach 10 s ist die Farbe wieder da -- ohne Statuswechsel')

  amp.setTextScale(0.5) -- Skala von anderer Stelle umgestellt: Inhalt weg
  clock = 121; a.render('main', 'OK')
  assert_eq(amp.screen, colors.green, 'auch nach einem Skalenwechsel kommt die Farbe zurueck')

  clock = 122; a.render('main', 'EMERGENCY')
  assert_eq(amp.screen, colors.red, 'ein Statuswechsel malt sofort')
end

-- ══ 4. Abgezogen und wieder angeschlossen: sofort wieder da ═════════════

do
  reset_world({ main = { 3, 2 }, ampel = { 1, 1 } })
  clock = 200
  local a = ampel_mod.new()
  a.render('main', 'LIMITED')
  assert_eq(world.monitors.ampel.screen, colors.yellow)

  world.attached.ampel = false
  clock = 201; a.render('main', 'LIMITED')
  world.attached.ampel = true
  world.monitors.ampel = new_monitor(1, 1, 0.5) -- frisch geladen, leer
  clock = 202; a.render('main', 'LIMITED')
  assert_eq(world.monitors.ampel.screen, colors.yellow, 'wieder angeschlossen: sofort gefunden und gemalt')
end

-- ══ 5. 1x1 wird nie Hauptmonitor -- auch nicht direkt am Rechner ════════

do
  -- "top" ist eine Rechnerseite: direkt angeschlossene Monitore haben
  -- Vorrang vor Netzwerk-Monitoren (adapters/monitor.lua DIRECT_SIDES).
  reset_world({ top = { 1, 1 }, monitor_7 = { 3, 2 } })
  monitor_adapter.invalidate_name('top'); monitor_adapter.invalidate_name('monitor_7')
  local found = monitor_adapter.find(nil, 'largest', 0.5, 'TEST')
  assert_true(found ~= nil, 'ein Hauptmonitor wird gefunden')
  assert_eq(found.name, 'monitor_7', 'die 1x1-Ampel an der Rechnerseite wird nicht Hauptmonitor')

  reset_world({ top = { 1, 1 } })
  monitor_adapter.invalidate_name('top')
  local only = monitor_adapter.find('top', 'largest', 0.5, 'TEST')
  assert_eq(only, nil, 'auch ausdruecklich gewaehlt nicht')

  reset_world({ top = { 1, 3 }, monitor_7 = { 3, 2 } })
  monitor_adapter.invalidate_name('top'); monitor_adapter.invalidate_name('monitor_7')
  assert_eq(monitor_adapter.find(nil, 'largest', 0.5, 'TEST').name, 'monitor_7', '1x3 wie bisher auch nicht')

  reset_world({ top = { 2, 2 }, monitor_7 = { 3, 2 } })
  monitor_adapter.invalidate_name('top'); monitor_adapter.invalidate_name('monitor_7')
  assert_eq(monitor_adapter.find(nil, 'largest', 0.5, 'TEST').name, 'top', 'ein normaler Monitor an der Seite bleibt bevorzugt')
end

-- ══ 6. MASTER-Ampel: 1x1, Neu-Malen, Wiederfinden ═══════════════════════

do
  local master_ampel = require('optional.master_ampel')
  reset_world({ overview = { 4, 3 }, ampel = { 1, 1 } })
  clock = 300
  local runtime = {
    state = { rt_global_off_hold = false, power_target = 100, active_profile = 'BASELOAD', nodes = {} },
    refs = {
      alert_service = { get_counts = function() return {} end },
      view_manager = { sessions = { get_sessions = function() return { { name = 'overview' } } end } },
    },
  }
  local constants = { roles = { RT_NODE = 'RT-NODE' } }
  master_ampel.update(runtime, constants)
  local amp = world.monitors.ampel
  assert_eq(amp.screen, colors.green, 'MASTER: 1x1-Ampel gefunden und gruen')
  assert_eq(world.monitors.overview.scale, 0.5, 'ein gebundener MASTER-Monitor wird nicht sondiert')

  amp.screen = nil
  clock = 305; master_ampel.update(runtime, constants)
  assert_eq(amp.screen, nil, 'MASTER: nicht dauernd neu malen')
  clock = 310; master_ampel.update(runtime, constants)
  assert_eq(amp.screen, colors.green, 'MASTER: nach 10 s wieder da')

  world.attached.ampel = false
  clock = 311; master_ampel.update(runtime, constants)
  world.attached.ampel = true
  world.monitors.ampel = new_monitor(1, 1, 0.5)
  clock = 312; master_ampel.update(runtime, constants)
  assert_eq(world.monitors.ampel.screen, colors.green, 'MASTER: wieder angeschlossen -> sofort gemalt')
end

-- ══ 7. VALVE-Statusmonitor: Neu-Malen ohne Schaltvorgang ════════════════

do
  local controller_lib = require('nodes.valve.controller')
  local epoch = 1000000
  local mon = new_monitor(1, 1, 1)
  local controller = controller_lib.new({
    config = { sorter_name = 'logisticalSorter_1', trusted_source = 'FUEL-1' },
    config_path = '/xreactor/config/valve.lua', node_id = 'VALVE-1',
    constants = { channels = { VALVE = 6504 } },
    utils = { log = function() end, write_config = function() return true end },
    peripheral_api = {
      wrap = function() return { setAutoMode = function() end } end,
      find = function(kind) if kind == 'monitor' then return mon end end,
    },
    colors_api = { orange = colors.orange, red = colors.red, green = colors.green },
    os_api = { epoch = function() return epoch end },
  })
  assert_true(controller:apply_valve(false, true))
  assert_eq(mon.screen, colors.green)
  mon.screen = nil
  epoch = epoch + 5000; controller:render_status_monitor()
  assert_eq(mon.screen, nil, 'VALVE: nicht dauernd neu malen')
  epoch = epoch + 5000; controller:render_status_monitor()
  assert_eq(mon.screen, colors.green, 'VALVE: nach 10 s wieder da')
end

_G.print = real_print
print('ampel_selfheal_1x1_test.lua: ok')
