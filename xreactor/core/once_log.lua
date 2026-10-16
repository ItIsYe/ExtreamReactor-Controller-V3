-- core/once_log.lua
--
-- Warnungen "einmal je Stoerung" statt "einmal je Laufzeit".
--
-- Die Adapter (adapters/turbine.lua, reactor.lua, energy_storage.lua,
-- induction_matrix.lua, logistical_sorter.lua, monitor.lua) meldeten einen
-- fehlgeschlagenen Peripherieaufruf ueber eine Tabelle `warned[key] = true`
-- -- einmal, und dann nie wieder bis zum Neustart. Erholte sich das Geraet
-- (Chunk wieder geladen) und fiel spaeter erneut aus, blieb die ZWEITE
-- Stoerung stumm: im Log stand nur die erste, Stunden alt. Genau so sieht
-- ein Feldbefund aus, bei dem man "nichts findet" (Selbstheilung Stufe 1,
-- docs/SESSION_HANDOFF.md Abschnitt B).
--
-- Hier gilt: gemeldet wird beim Eintritt einer Stoerung. Meldet der
-- Aufrufer die Erholung (recover), ist die naechste Stoerung wieder eine
-- neue und wird wieder gemeldet -- frühestens aber `rearm_ms` (Vorgabe 60 s)
-- nach der letzten Meldung desselben Schluessels. Ein Geraet, das im
-- Sekundentakt flattert, schreibt also hoechstens eine Zeile je Minute.
--
-- Schluessel sind zweistufig (name, sub) -- name ist die Peripherie, sub die
-- Methode oder Art der Meldung. So kostet recover() im Normalfall (nichts
-- gestoert) genau einen Tabellenzugriff und keinen zusammengesetzten
-- String; der Adapter ruft es bei JEDEM erfolgreichen Aufruf.

local M = {}

M.REARM_MS = 60 * 1000

local function default_clock()
  if os and type(os.epoch) == "function" then return os.epoch("utc") end
  return 0
end

function M.new(opts)
  opts = opts or {}
  local rearm_ms = tonumber(opts.rearm_ms) or M.REARM_MS
  local clock = opts.clock or default_clock
  local active = {}   -- [name][sub] = true: gemeldet, noch nicht erholt
  local last = {}     -- [name][sub] = Zeitpunkt der letzten Meldung

  local self = {}

  -- true: jetzt melden. Danach false, bis recover() kommt.
  function self.report(name, sub)
    local n = tostring(name)
    local s = tostring(sub)
    local a = active[n]
    if a and a[s] then return false end
    if not a then a = {}; active[n] = a end
    a[s] = true
    local l = last[n]
    if not l then l = {}; last[n] = l end
    local now = clock()
    local previous = l[s]
    -- Ein Zeitstempel aus der Zukunft (Uhr zurueckgesprungen) gilt als alt.
    if previous and now >= previous and now - previous < rearm_ms then
      return false
    end
    l[s] = now
    return true
  end

  -- Die Stoerung (name, sub) ist vorbei.
  function self.recover(name, sub)
    if type(name) ~= "string" then name = tostring(name) end
    if type(sub) ~= "string" then sub = tostring(sub) end
    local a = active[name]
    if not a then return end
    a[sub] = nil
    if next(a) == nil then active[name] = nil end
  end

  -- Alle Stoerungen dieser Peripherie sind vorbei (etwa: sie ist weg und
  -- kommt vielleicht als ein anderes Geraet zurueck).
  function self.recover_name(name)
    active[tostring(name)] = nil
  end

  -- Fuer Tests: ist (name, sub) gerade als gestoert gemerkt?
  function self.is_active(name, sub)
    local a = active[tostring(name)]
    return a ~= nil and a[tostring(sub)] == true
  end

  return self
end

return M
