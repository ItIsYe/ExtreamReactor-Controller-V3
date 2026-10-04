package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die RT-Diagnoseseite zeigt verlorene und verspaetete Timer-Ereignisse der
-- Lauf-Schleifen (nodes/support/runtime.lua's loop_stats).
--
-- Ein verlorener Timer hat die Node bis v811 bis zum Neustart stillgelegt.
-- Heute laeuft sie weiter -- und ohne diese Zeile erfuehre niemand, dass es
-- passiert ist. Genau das ist der Beleg, ob der Feldbefund (RT haengt nach
-- dem Laden der Anlage-Chunks) diese Ursache hatte.

local rows = {}
local mux = setmetatable({
  data_row = function(_, _, _, _, item) rows[#rows + 1] = item end,
  footer_nav = function() return {} end,
}, { __index = function() return function() end end })

package.loaded['core.mockup_ui'] = mux
package.loaded['nodes.rt.mockup_pages'] = nil
local mockup_pages = require('nodes.rt.mockup_pages')

local mon = { getSize = function() return 60, 30 end }

local function timer_row(loop_stats)
  rows = {}
  mockup_pages.render_diagnostics(mon, { node_id = 'RT-1', master_state = 'OK', loop_stats = loop_stats })
  for _, item in ipairs(rows) do
    if item.label == 'TIMER LOST / LATE' then return item end
  end
  error('die Diagnoseseite zeigt keine Zeile TIMER LOST / LATE')
end

local function check(loop_stats, value, status, message)
  local row = timer_row(loop_stats)
  if row.value ~= value or row.status ~= status then
    error(('%s: erwartet %s/%s, gezeigt %s/%s'):format(
      message, value, status, tostring(row.value), tostring(row.status)))
  end
end

-- Ohne Zaehler (etwa ein Modell ohne loop_stats): nichts passiert.
check(nil, '0 / 0', 'OK', 'ohne Zaehler')
-- Nur verspaetet: ein Stau, kein Verlust -- gelb, nicht rot.
check({ lost = 0, late = 3 }, '0 / 3', 'LIMITED', 'nur verspaetet')
-- Verloren: das ist der Fall, der die Node frueher stillgelegt hat.
check({ lost = 1, late = 3 }, '1 / 3', 'WARNING', 'verloren')

print('ok rt_diagnostics_timer_row_test')
