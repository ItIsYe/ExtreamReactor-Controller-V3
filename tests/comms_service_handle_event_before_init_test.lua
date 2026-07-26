package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer den gemeldeten Node-Absturz "attempt to index field
-- 'comms' (a nil value)" (Fix 2026-07-27, siehe services/comms_service.lua
-- handle_event()/tick()). self.comms wird erst durch init() gesetzt, aber
-- einige Aufrufer (z.B. nodes/support/runtime.lua's run_event_loop()) rufen
-- handle_event()/tick() direkt auf, ausserhalb von service_manager's
-- eigenem Init-vor-Tick-Schutz. Fehlt bei einer Rolle der explizite
-- services:init()-Aufruf VOR dem Betreten der Event-Loop (wie es VALVE bis
-- zu diesem Fix tat, siehe nodes/valve/main.lua), stuerzte das allererste
-- empfangene modem_message-Event die gesamte Node ab, noch bevor init() je
-- lief. Dieser Test beweist direkt: handle_event()/tick() auf einer NOCH
-- NICHT initialisierten Instanz (self.comms == nil) duerfen niemals werfen
-- -- sie sind jetzt als reine No-Ops abgesichert (Defense-in-Depth; der
-- eigentliche Fix ist der ergaenzte services:init()-Aufruf in
-- nodes/valve/main.lua, der das fruehe Verwerfen von Nachrichten von
-- vornherein vermeidet).

local comms_service = require('services.comms_service')

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local svc = comms_service.new({ config = {}, log_prefix = 'TEST' })
assert_true(svc.comms == nil, 'a freshly constructed instance must not have comms set until init() runs')

-- 1. handle_event() mit einem echten modem_message-Event darf nicht werfen.
do
  local ok, err = pcall(svc.handle_event, svc, { 'modem_message', 'left', 6500, 6500, { type = 'HELLO' } })
  assert_true(ok, 'handle_event() before init() must not crash: ' .. tostring(err))
end

-- 2. tick() darf ebenfalls nicht werfen.
do
  local ok, err = pcall(svc.tick, svc, 1000)
  assert_true(ok, 'tick() before init() must not crash: ' .. tostring(err))
end

-- 3. Ein Nicht-modem_message-Event (z.B. "key") darf ebenfalls nicht werfen
--    (handle_event() muss den event[1]-Typ-Check trotz fehlendem comms
--    weiterhin korrekt durchlaufen).
do
  local ok, err = pcall(svc.handle_event, svc, { 'key', 42 })
  assert_true(ok, 'handle_event() with a non-modem_message event before init() must not crash: ' .. tostring(err))
end

print("comms_service_handle_event_before_init_test.lua: ok")
