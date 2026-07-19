package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer core/ui_router.lua's Seiten-Navigation: weder
-- Tasten- noch Footer-Touch-Navigation hatten bisher eine Entprellung.
-- CC:Tweaked feuert bei gehaltener Taste (Tastaturwiederholung) mehrere
-- "key"-Events in schneller Folge -- jedes rief unabhaengig self:next()
-- auf, ein einzelner gefuehlter Tastendruck/Tipp konnte den Seitenindex
-- dadurch um 2+ statt um 1 erhoehen (gemeldetes Symptom: "Seite 2 wird
-- uebersprungen", Wechsel von Seite 1 landet direkt auf Seite 3). Jetzt
-- wird eine zweite Navigation innerhalb von 350ms nach der letzten
-- ignoriert (Event gilt trotzdem als konsumiert), waehrend ein bewusster,
-- langsamerer zweiter Tastendruck/Tipp weiterhin normal funktioniert.

local now = 0
os.epoch = function() return now end

local ui_router = require('core.ui_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

-- 1. Zwei rasch aufeinanderfolgende "next"-Tastendruecke (< 350ms, wie bei
--    Tastaturwiederholung) duerfen den Index nur EINMAL erhoehen.
do
  local router = ui_router.new({
    pages = { { name = 'A' }, { name = 'B' }, { name = 'C' }, { name = 'D' } },
    key_next = { [1] = true },
    key_prev = { [2] = true },
  })
  assert_eq(router.index, 1, 'router should start on page 1')

  now = 1000
  local consumed1 = router:handle_input({ 'key', 1 })
  assert_eq(consumed1, true, 'first key press must be consumed')
  assert_eq(router.index, 2, 'first next() must advance to page 2')

  now = 1100 -- 100ms later, well within the 350ms debounce window
  local consumed2 = router:handle_input({ 'key', 1 })
  assert_eq(consumed2, true, 'debounced repeat must still be consumed (event handled)')
  assert_eq(router.index, 2, 'CRITICAL: a rapid repeated next() must not skip page 2 (index must stay 2, not jump to 3)')

  -- Nach Ablauf des Debounce-Fensters funktioniert die Navigation wieder normal.
  now = 1500
  router:handle_input({ 'key', 1 })
  assert_eq(router.index, 3, 'navigation must resume normally once the debounce window has passed')
end

-- 2. Dasselbe fuer Footer-Touch-Navigation (monitor_touch auf der
--    "WEITER"-Zone).
do
  local router = ui_router.new({
    pages = { { name = 'A' }, { name = 'B' }, { name = 'C' } },
  })
  router.footer.next = { x1 = 10, x2 = 15, y = 20 }
  assert_eq(router.index, 1, 'router should start on page 1')

  now = 5000
  router:handle_input({ 'monitor_touch', 'monitor_0', 12, 20 })
  assert_eq(router.index, 2, 'first touch on the next zone must advance to page 2')

  now = 5050
  router:handle_input({ 'monitor_touch', 'monitor_0', 12, 20 })
  assert_eq(router.index, 2, 'CRITICAL: a rapid repeated touch on the next zone must not skip page 2')

  now = 5500
  router:handle_input({ 'monitor_touch', 'monitor_0', 12, 20 })
  assert_eq(router.index, 3, 'touch navigation must resume normally once the debounce window has passed')
end

print("ui_router_page_nav_debounce_test.lua: ok")
