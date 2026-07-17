package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Pflicht-Test fuer INSTALL-P0.2 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Abschnitt 4 "Runtime und Installer laufen
-- parallel"). Treibt das echte core/update_handshake.lua-Modul direkt: die
-- Zustandsfolge UPDATE_REQUESTED -> QUIESCE_REQUESTED -> SAFE_OUTPUTS_
-- APPLIED -> RUNTIME_STOPPED muss in dieser Reihenfolge durchlaufen werden,
-- SAFE_OUTPUTS_APPLIED darf nur aus QUIESCE_REQUESTED heraus gesetzt werden
-- (kein Ueberspringen), und wait_for_runtime_stopped() muss sowohl den
-- Erfolgs- als auch den Timeout-Fall korrekt melden.

local update_handshake = require('core.update_handshake')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- 1. Neu erstellter Handshake ist IDLE, kein Quiesce angefordert.
do
  local h = update_handshake.new()
  assert_eq(h.state, update_handshake.STATE.IDLE, 'new handshake must start IDLE')
  assert_true(not update_handshake.is_quiesce_requested(h), 'fresh handshake must not report quiesce requested')
  assert_true(not update_handshake.is_runtime_stopped(h), 'fresh handshake must not report runtime stopped')
end

-- 2. request_quiesce() fuehrt zu QUIESCE_REQUESTED (durchlaeuft UPDATE_
--    REQUESTED, landet aber sichtbar bei QUIESCE_REQUESTED).
do
  local h = update_handshake.new()
  update_handshake.request_quiesce(h)
  assert_eq(h.state, update_handshake.STATE.QUIESCE_REQUESTED, 'request_quiesce must set QUIESCE_REQUESTED')
  assert_true(update_handshake.is_quiesce_requested(h), 'is_quiesce_requested must be true after request_quiesce')
  assert_true(h.requested_at ~= nil, 'request_quiesce must record a requested_at timestamp')
end

-- 3. mark_safe_outputs_applied() darf NUR aus QUIESCE_REQUESTED heraus
--    wirken -- ein verfrueher/falscher Aufruf (z.B. IDLE) darf den Zustand
--    NICHT veraendern (kein Ueberspringen der Reihenfolge).
do
  local h = update_handshake.new()
  update_handshake.mark_safe_outputs_applied(h)
  assert_eq(h.state, update_handshake.STATE.IDLE,
    'mark_safe_outputs_applied() from IDLE must be a no-op -- the sequence must not be skippable')

  update_handshake.request_quiesce(h)
  update_handshake.mark_safe_outputs_applied(h)
  assert_eq(h.state, update_handshake.STATE.SAFE_OUTPUTS_APPLIED,
    'mark_safe_outputs_applied() from QUIESCE_REQUESTED must transition to SAFE_OUTPUTS_APPLIED')
end

-- 4. mark_runtime_stopped() setzt RUNTIME_STOPPED, is_runtime_stopped() wird
--    wahr.
do
  local h = update_handshake.new()
  update_handshake.request_quiesce(h)
  update_handshake.mark_safe_outputs_applied(h)
  update_handshake.mark_runtime_stopped(h)
  assert_eq(h.state, update_handshake.STATE.RUNTIME_STOPPED, 'mark_runtime_stopped must set RUNTIME_STOPPED')
  assert_true(update_handshake.is_runtime_stopped(h), 'is_runtime_stopped must be true after mark_runtime_stopped')
  assert_true(not update_handshake.is_quiesce_requested(h), 'is_quiesce_requested must be false once RUNTIME_STOPPED')
end

-- 5. wait_for_runtime_stopped(): true, wenn der Zustand rechtzeitig erreicht
--    wird (hier: sofort, kein Polling-Delay noetig), false bei Timeout.
do
  local h = update_handshake.new()
  update_handshake.request_quiesce(h)
  update_handshake.mark_safe_outputs_applied(h)
  update_handshake.mark_runtime_stopped(h)

  local now = 1000
  local os_epoch = os.epoch
  local os_sleep = os.sleep
  os.epoch = function() return now end
  os.sleep = function(s) now = now + (s * 1000) end

  local ok = update_handshake.wait_for_runtime_stopped(h, 5)
  os.epoch = os_epoch
  os.sleep = os_sleep
  assert_true(ok, 'wait_for_runtime_stopped must return true once RUNTIME_STOPPED is already set')
end

do
  local h = update_handshake.new()
  update_handshake.request_quiesce(h)
  -- Zustand bleibt absichtlich bei QUIESCE_REQUESTED -- Rolle bestaetigt nie.

  local now = 1000
  local os_epoch = os.epoch
  local os_sleep = os.sleep
  os.epoch = function() return now end
  os.sleep = function(s) now = now + (s * 1000) end

  local ok = update_handshake.wait_for_runtime_stopped(h, 2)
  os.epoch = os_epoch
  os.sleep = os_sleep
  assert_true(not ok, 'wait_for_runtime_stopped must return false (timeout) if RUNTIME_STOPPED is never reached')
end

-- 6. wait_for_runtime_stopped(nil, ...) (kein Handshake konfiguriert) muss
--    sofort true liefern -- bestehende Aufrufer ohne Handshake duerfen nicht
--    blockieren.
do
  assert_true(update_handshake.wait_for_runtime_stopped(nil, 5), 'a nil handshake must not block the caller')
end

-- 7. reset() bringt den Handshake zurueck auf IDLE, fuer den naechsten Zyklus.
do
  local h = update_handshake.new()
  update_handshake.request_quiesce(h)
  update_handshake.mark_safe_outputs_applied(h)
  update_handshake.mark_runtime_stopped(h)
  update_handshake.reset(h)
  assert_eq(h.state, update_handshake.STATE.IDLE, 'reset() must return the handshake to IDLE')
  assert_true(h.requested_at == nil, 'reset() must clear requested_at')
end

print('core_update_handshake_test.lua: ok')
