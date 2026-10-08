-- core/sleep_guard.lua
-- os.sleep(), das nicht an EINEM Timer haengt.
--
-- CC:Tweakeds os.sleep() (bios.lua) wartet auf genau einen Timer und
-- ignoriert jedes andere Ereignis. CC:Tweaked verwirft aber Ereignisse,
-- sobald 256 in der Warteschlange eines Rechners stehen
-- (ComputerExecutor.QUEUE_LIMIT) -- Timer eingeschlossen, stillschweigend.
-- Ging der eine Timer verloren, kam os.sleep() nie zurueck. Besonders teuer
-- mitten in einem Update: die Wartezeiten zwischen Download-Versuchen und
-- das Warten auf den Quiesce laufen ueber os.sleep(), und der Knoten bliebe
-- dann mit gestoppter Laufzeit stehen, bis jemand ihn neu startet.
--
-- sleep(n) kehrt zurueck, wenn der eigene Timer kommt ODER wenn bei
-- irgendeinem Ereignis n + GRACE_S verstrichen sind. Gemessen mit
-- os.clock(): in CC:Tweaked Servertakte (OSAPI.clock = Takte * 0.05),
-- dieselbe Zeitbasis wie os.startTimer(), monoton. Dieselbe Mechanik wie
-- nodes/support/runtime.lua's make_timer_guard, fuer die Lauf-Schleifen.
--
-- Ohne Filter auf "timer": auch Funknachrichten wecken die Pruefung -- nach
-- einem Quiesce laufen auf dem Rechner sonst kaum noch Timer. Unter
-- parallel.* sieht jede Coroutine jedes Ereignis selbst; was sleep()
-- verwirft, fehlt also keiner anderen.
--
-- start.lua setzt es per install() fuer den ganzen Rechner ein, bevor
-- irgendetwas anderes laeuft.

local M = {}

M.GRACE_S = 1.0

local function clock_s()
  local ok, value = pcall(os.clock)
  if ok and type(value) == "number" then return value end
  return nil
end

function M.sleep(n)
  local seconds = tonumber(n) or 0
  local started = clock_s()
  local timer = os.startTimer(seconds)
  while true do
    local event, param = os.pullEvent()
    if event == "timer" and param == timer then return end
    local now = clock_s()
    if started and now and now - started >= seconds + M.GRACE_S then return end
  end
end

-- Ersetzt os.sleep und sleep. true, wenn eingesetzt.
function M.install()
  if type(os) ~= "table" or type(os.startTimer) ~= "function" or type(os.pullEvent) ~= "function" then
    return false
  end
  os.sleep = M.sleep
  rawset(_G, "sleep", M.sleep)
  return true
end

return M
