package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Dampfmessung ohne externen Tank liest jeden Reaktor FRISCH ein.
--
-- Bis v816 nahm nodes/rt/reactor_control.lua's read_reactor_steam_amount()
-- zuerst das wrap-Handle, das die Discovery einmal je Reaktor anlegte
-- (ctx.peripherals.reactors). Ein Handle traegt die Methoden von seinem
-- Einbindezeitpunkt: war der Reaktor da halb geladen (Chunk, Multiblock im
-- Zusammenbau), fehlte ihm getHotFluidAmount fuer immer -- die
-- Dampfanzeige blieb leer, obwohl der Reaktor laengst wieder alles konnte.
--
--   1. ein altes Handle ohne Dampf-Methoden liegt bereit, der Reaktor kann
--      aber inzwischen getHotFluidAmount -> gelesen wird der echte Wert
--   2. Reaktor weg -> unbekannt (nil), einmal gemeldet

local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local present = { reactor_0 = true }
local real_peripheral = rawget(_G, 'peripheral')
_G.peripheral = {
  isPresent = function(name) return present[name] == true end,
  -- Frisch eingebunden kann der Reaktor jetzt alles.
  wrap = function(name)
    if not present[name] then return nil end
    return { getHotFluidAmount = function() return 4321 end }
  end,
}

local reactor_control = require('nodes.rt.reactor_control')
local warnings = {}
local ctx = {
  config = { reactors = { 'reactor_0' } },
  utils = require('core.utils'),
  fluid = require('core.fluid'),
  warn_once = function(key, msg) warnings[key] = msg end,
  -- Das alte Handle aus der Discovery: eingebunden, als der Reaktor noch
  -- halb geladen war -- ohne jede Dampf-Methode. Gibt es den Zugriff noch,
  -- liefert er nichts.
  peripherals = { reactors = { reactor_0 = { getActive = function() return true end } } },
}

assert_eq(reactor_control.read_reactor_steam_amount(ctx), 4321,
  'der Dampf muss aus dem frisch eingebundenen Reaktor kommen, nicht aus dem alten Handle')

present.reactor_0 = nil
assert_eq(reactor_control.read_reactor_steam_amount(ctx), nil, 'Reaktor weg: Dampf unbekannt')
assert_eq(warnings['reactor_wrap:reactor_0'] ~= nil, true, 'und gemeldet')

_G.peripheral = real_peripheral
print('ok rt_reactor_steam_fresh_read_test')
