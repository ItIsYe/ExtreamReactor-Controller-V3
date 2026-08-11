package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer core/ui_router.lua's Seiten-Navigation. Nur echte
-- Tastatur-Autorepeats (`key` mit is_held=true) duerfen unterdrueckt werden.
-- Monitor-Tipps sind bereits diskrete Benutzeraktionen und muessen auch bei
-- schneller Folge und Richtungswechsel vollstaendig verarbeitet werden.

local ui_router = require('core.ui_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

-- 1. CC:Tweaked kennzeichnet eine gehaltene Taste im dritten Event-Feld.
--    Dieser Wiederholungs-Event wird konsumiert, navigiert aber nicht. Zwei
--    getrennte Tastendruecke (is_held=false) duerfen direkt nacheinander
--    navigieren; eine beliebige Zeitheuristik waere hier falsch.
do
  local router = ui_router.new({
    pages = { { name = 'A' }, { name = 'B' }, { name = 'C' }, { name = 'D' } },
    key_next = { [1] = true },
    key_prev = { [2] = true },
  })
  assert_eq(router.index, 1, 'router should start on page 1')

  local consumed1 = router:handle_input({ 'key', 1, false })
  assert_eq(consumed1, true, 'first key press must be consumed')
  assert_eq(router.index, 2, 'first next() must advance to page 2')

  local consumed2 = router:handle_input({ 'key', 1, true })
  assert_eq(consumed2, true, 'held-key repeat must still be consumed')
  assert_eq(router.index, 2, 'held-key auto-repeat must not skip page 2')

  router:handle_input({ 'key', 1, false })
  assert_eq(router.index, 3, 'a separate key press must navigate without an arbitrary delay')

  router:handle_input({ 'key', 2, false })
  assert_eq(router.index, 2, 'an immediate intentional direction change must work')
end

-- 2. Jeder monitor_touch ist ein eigener Tipp. Schnelles Vor- und
--    Zurueckschalten darf keinen Tipp verlieren.
do
  local router = ui_router.new({
    pages = { { name = 'A' }, { name = 'B' }, { name = 'C' } },
  })
  router.footer.prev = { x1 = 1, x2 = 5, y = 20 }
  router.footer.next = { x1 = 10, x2 = 15, y = 20 }
  assert_eq(router.index, 1, 'router should start on page 1')

  router:handle_input({ 'monitor_touch', 'monitor_0', 12, 20 })
  assert_eq(router.index, 2, 'first touch on the next zone must advance to page 2')

  router:handle_input({ 'monitor_touch', 'monitor_0', 12, 20 })
  assert_eq(router.index, 3, 'second intentional touch must advance immediately to page 3')

  router:handle_input({ 'monitor_touch', 'monitor_0', 3, 20 })
  assert_eq(router.index, 2, 'immediate touch on the previous zone must return to page 2')

  router:handle_input({ 'monitor_touch', 'monitor_0', 3, 20 })
  assert_eq(router.index, 1, 'a second rapid previous touch must return to page 1')
end

print("ui_router_page_nav_debounce_test.lua: ok")
