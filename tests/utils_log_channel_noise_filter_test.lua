-- tests/utils_log_channel_noise_filter_test.lua
--
-- Regression test for a real-world bug found via uploaded field logs
-- (2026-09-02): utils.handle_remote_log_message() (called by every role's
-- comms_service:handle_event() BEFORE a modem_message ever reaches
-- core.comms' normal protocol pipeline) only ever recognized LOG_ACK as
-- "log-channel noise to swallow". On any node whose log channel (6503)
-- shares a modem with its normal control/status channels -- the common
-- single-modem case, see discover_log_modems()'s fallback -- every OTHER
-- node's LOG_EVENT/LOG_EVENT_BATCH (sent on every utils.log() call,
-- system-wide) leaked straight into comms.receive()/validate() and was
-- rejected as "missing sender_id" (LOG_EVENT payloads never carry one).
-- 20k+ occurrences across every role (RT/FUEL/ENERGY/VALVE) in ~15
-- minutes of real play, competing for tick time with actual comms
-- processing on the same hot path used for STATUS/HEARTBEAT/COMMAND --
-- the most likely cause of reported MASTER<->RT/FUEL/VALVE instability.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.fs = {
  exists = function() return false end,
  open = function() return nil end,
}
_G.os.getComputerID = function() return 99 end

local utils = require('core.utils')

-- A real LOG_EVENT payload (see core/utils.lua's send_remote_log()) --
-- deliberately has no sender_id/src, since it was never meant to be
-- validated as a normal protocol message.
local log_event = {
  type = 'LOG_EVENT',
  proto = 'xreactor-log-v2',
  node_id = 'RT-1',
  role = 'RT',
  prefix = 'RT',
  level = 'INFO',
  message = 'some log line',
  seq = 1,
  boot_id = 'RT-1:boot:1:0:1',
  event_id = 'RT-1:boot:1:0:1:1',
  ts = 0,
  ack = true,
}
if not utils.handle_remote_log_message(log_event) then
  error('CRITICAL: LOG_EVENT must be recognized and swallowed as log-channel noise, not fall through to comms.receive()')
end

-- A real LOG_EVENT_BATCH wrapper (see flush_log_batch()).
local log_event_batch = { type = 'LOG_EVENT_BATCH', entries = { log_event } }
if not utils.handle_remote_log_message(log_event_batch) then
  error('CRITICAL: LOG_EVENT_BATCH must be recognized and swallowed as log-channel noise, not fall through to comms.receive()')
end

-- LOG_PING (already fixed) and LOG_ACK (pre-existing) must still work.
if not utils.handle_remote_log_message({ type = 'LOG_PING', collector_node = 'LOG-1', ts = 0 }) then
  error('expected LOG_PING to still be swallowed')
end
if not utils.handle_remote_log_message({ type = 'LOG_ACK', event_id = 'x', ts = 0 }) then
  error('expected LOG_ACK to still be swallowed')
end

-- A genuine protocol message (e.g. STATUS/HEARTBEAT) must NOT be
-- swallowed here -- it has to fall through to comms.receive() as before.
if utils.handle_remote_log_message({ type = 'STATUS', src = 'RT-1', role = 'RT-NODE', ts = 0, payload = {} }) then
  error('CRITICAL: a real protocol message must not be swallowed as log-channel noise')
end

print('utils_log_channel_noise_filter_test.lua: ok')
