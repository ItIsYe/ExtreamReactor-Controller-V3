package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Der lokale RT-Schirm liest Turbinen nur noch ueber adapters/turbine.lua --
-- denselben Weg wie der Regler.
--
-- Bis v814 las monitor_ui.build_turbine_status() eine Turbine, deren
-- Drehzahl oder Durchfluss inspect() nicht lieferte, ein zweites Mal: per
-- peripheral.wrap() und dem Faehigkeiten-Cache ctx.capability_cache. Der
-- Cache wird von der Discovery einmal je Name geschrieben und nie erneuert
-- (nach dem Chunk-Laden also womoeglich mit verkuerzter Methodenliste),
-- und wenn der Rueckfall doch las, zeigte der Schirm einen Wert, den der
-- Regler nicht hatte -- beim Durchfluss sogar den Verbrauch statt des
-- Sollwerts. Die Oberflaeche sah dann normal aus, waehrend der Regler blind
-- war (tests/rt2_unreadable_turbine_write_test.lua).
--
--   1. inspect() liest: Werte kommen aus inspect(), keine Peripherie sonst
--   2. inspect() liest Drehzahl/Durchfluss NICHT ("n/a"): der Schirm zeigt
--      "unbekannt" (nil) -- kein wrap, kein Cache, kein erfundener Wert,
--      und nie der String "n/a" (der sprengte das Zahlenformat)
--   3. Turbine weg (inspect() -> nil): unbekannt, kein wrap
--   4. die Turbinenseite zeichnet "unbekannt" ohne Fehler

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

_G.keys = _G.keys or { left = 1, right = 2, pageUp = 3, pageDown = 4 }

-- Jeder Zugriff am Adapter vorbei wird gezaehlt. Die Methoden des
-- wrap-Handles liefern Zahlen -- haette der alte Rueckfall gelesen, staenden
-- sie auf dem Schirm.
local side_reads = 0
local real_peripheral = rawget(_G, 'peripheral')
_G.peripheral = {
  wrap = function()
    side_reads = side_reads + 1
    return {
      getRotorSpeed = function() side_reads = side_reads + 1; return 4321 end,
      getFluidFlowRateMax = function() side_reads = side_reads + 1; return 1999 end,
      getFluidFlowRate = function() side_reads = side_reads + 1; return 1234 end,
    }
  end,
  getMethods = function()
    side_reads = side_reads + 1
    return { 'getRotorSpeed', 'getFluidFlowRateMax', 'getFluidFlowRate' }
  end,
  isPresent = function() return true end,
}

package.loaded['nodes.rt.monitor_ui'] = nil
local monitor_ui = require('nodes.rt.monitor_ui')

-- So sieht inspect() je Fall aus (adapters/turbine.lua: read_number()
-- liefert "n/a" fuer nicht Lesbares, inspect() nil fuer eine fehlende
-- Peripherie).
local readings = {
  T_ok      = { rpm = 1800, flow = 1500, energy = 20000, active = true, coil_engaged = true },
  T_blind   = { rpm = 'n/a', flow = 'n/a', energy = nil, active = true, coil_engaged = false },
  T_gone    = nil,
}
local inspected = {}
local turbine_adapter = {
  inspect = function(name)
    inspected[#inspected + 1] = name
    return readings[name]
  end,
}

-- Alles, was der alte Rueckfall brauchte, steht bereit -- der neue Code
-- darf es nur nicht benutzen. (Die alte Signatur nahm diese drei
-- Funktionen positionell; der neue Aufruf ueber update_status_snapshot()
-- reicht sie gar nicht mehr durch.)
local cache_reads = 0
local ctx = {
  devices = {
    turbines = {
      { id = 'turbine:T_ok', name = 'T_ok' },
      { id = 'turbine:T_blind', name = 'T_blind' },
      { id = 'turbine:T_gone', name = 'T_gone' },
    },
    reactors = {},
    registry_summary = {},
  },
  registry = { get_summary = function() return {} end },
  config = { node_id = 'RT-1' },
  turbine_adapter = turbine_adapter,
  reactor_adapter = { inspect = function() return nil end },
  read_turbine_rpm = function(t, caps)
    if t and caps and caps.getRotorSpeed then return t.getRotorSpeed() end
    return nil
  end,
  read_turbine_flow = function(t, caps)
    if t and caps and caps.getFluidFlowRate then return t.getFluidFlowRate() end
    return nil
  end,
  get_device_caps = function()
    cache_reads = cache_reads + 1
    return { getRotorSpeed = true, getFluidFlowRateMax = true, getFluidFlowRate = true }
  end,
  get_available_steam = function() return 0 end,
}

local snap = monitor_ui.update_status_snapshot(ctx)
_G.peripheral = real_peripheral

local by_id = {}
for _, t in ipairs(snap.turbines) do by_id[t.id] = t end

-- 1. Gelesen wird ueber inspect(), fuer jede Turbine genau einmal.
assert_eq(#inspected, 3, 'inspect() je Turbine genau einmal')
assert_eq(by_id['turbine:T_ok'].rpm, 1800, 'Drehzahl aus inspect()')
assert_eq(by_id['turbine:T_ok'].flow, 1500, 'Durchfluss aus inspect()')
assert_eq(by_id['turbine:T_ok'].energy, 20000, 'Ausstoss aus inspect()')

-- 2. Nicht lesbar heisst unbekannt -- nicht das, was ein zweiter Weg fand.
assert_eq(side_reads, 0, 'am Adapter vorbei darf keine Peripherie angefasst werden (wrap/getMethods/Methoden)')
assert_eq(cache_reads, 0, 'der Faehigkeiten-Cache der Discovery darf nicht gelesen werden')
assert_eq(by_id['turbine:T_blind'].rpm, nil, 'nicht lesbare Drehzahl bleibt unbekannt')
assert_eq(by_id['turbine:T_blind'].flow, nil, 'nicht lesbarer Durchfluss bleibt unbekannt')

-- 3. Weg ist weg.
assert_eq(by_id['turbine:T_gone'].rpm, nil, 'fehlende Turbine: Drehzahl unbekannt')
assert_eq(by_id['turbine:T_gone'].flow, nil, 'fehlende Turbine: Durchfluss unbekannt')

-- Die Summen rechnen nur mit dem, was gelesen wurde.
assert_eq(snap.avg_rpm, 1800, 'Mittelwert nur ueber lesbare Turbinen')
assert_eq(snap.min_rpm, 1800, 'Minimum nur ueber lesbare Turbinen')
assert_eq(snap.actual_output, 20000, 'Ausstoss nur ueber lesbare Turbinen')

-- 4. Die Turbinenseite zeichnet "unbekannt", ohne am Zahlenformat zu
-- scheitern. Gezeichnet wird auf einen Schirm, der alles schluckt.
do
  local mockup_pages = require('nodes.rt.mockup_pages')
  local sink = setmetatable({}, { __index = function(_, k)
    if k == 'getSize' then return function() return 79, 38 end end
    if k == 'isColor' or k == 'isColour' then return function() return true end end
    return function() end
  end })
  local ok, err = pcall(mockup_pages.render_turbines, sink, {
    snapshot = { snapshot = snap },
    targets = {},
    configured_turbines = {},
  })
  assert_true(ok, 'die Turbinenseite muss unbekannte Werte zeichnen koennen: ' .. tostring(err))
end

print('ok rt_monitor_single_read_path_test')
