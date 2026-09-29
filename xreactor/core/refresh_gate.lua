-- core/refresh_gate.lua
--
-- Eine Haltefrist fuer teure Lesungen: "ist der zuletzt geholte Wert alt
-- genug, dass er neu geholt werden muss?"
--
-- Warum eigenes Modul und nicht zwei Zeilen an Ort und Stelle: dieselbe
-- Rechnung ist im Baum mehrfach noetig (nodes/fuel/main.lua drosselt damit
-- sowohl den ME-Bridge-Reservelesevorgang als auch den Statuspayload-Aufbau)
-- und sie hat zwei Faelle, die man inline zuverlaessig vergisst:
--
--   Uhr rueckwaerts   os.epoch("utc") kann in CC:Tweaked zurueckspringen
--                     (Weltwechsel, Serverzeit). Ein blosses
--                     "now - last < interval" ist dann dauerhaft wahr und
--                     der Wert friert fuer immer ein -- dieselbe Falle, die
--                     in nodes/rt/rt2_turbine.lua den Regler angehalten hat.
--   Bindungswechsel   Wird das Geraet hinter dem Wert ein anderes (frisch
--                     gefundene oder verlorene ME Bridge), ist der alte Wert
--                     sofort wertlos, egal wie jung er ist.
--
-- Reine Zustandsmaschine: kein os-Zugriff, keine Peripherie. Die Zeit kommt
-- als Argument herein, damit der Aufrufer (und der Test) sie bestimmt.

local M = {}
M.__index = M

function M.new()
  return setmetatable({ last_ms = nil, key = nil }, M)
end

-- due(now_ms, interval_ms, key) -> true, wenn neu geholt werden muss.
-- key ist optional (z.B. der Peripherie-Name, an dem der Wert haengt).
function M:due(now_ms, interval_ms, key)
  if self.last_ms == nil then return true end
  if key ~= self.key then return true end
  local age = (tonumber(now_ms) or 0) - self.last_ms
  if age < 0 then return true end
  return age >= math.max(0, tonumber(interval_ms) or 0)
end

-- Nach einer tatsaechlich durchgefuehrten Lesung aufrufen.
function M:mark(now_ms, key)
  self.last_ms = tonumber(now_ms) or 0
  self.key = key
end

-- Erzwingt die naechste Lesung, ohne die Zeit zu kennen.
function M:invalidate()
  self.last_ms = nil
  self.key = nil
end

return M
