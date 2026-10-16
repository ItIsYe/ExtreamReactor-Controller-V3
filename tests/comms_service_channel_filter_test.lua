package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.fs = _G.fs or {
  exists = function() return false end,
  open = function() return nil end,
}
_G.os.getComputerID = _G.os.getComputerID or function() return 99 end

-- Regression test for a real-world bug found via a second round of uploaded
-- field logs (2026-09-02, VALVE + FUEL), the same bug class already fixed
-- for the LOG channel (see utils_log_channel_noise_filter_test.lua): a
-- modem_message event carries no inherent routing -- any channel opened on
-- the modem a role's comms_service uses raises the SAME event, delivered to
-- every handler regardless of which channel it was meant for.
--
-- nodes/fuel/redstone_router.lua runs its own raw SET_VALVE/VALVE_ACK/
-- ROUTE_TEACH_PULSE protocol directly on constants.channels.VALVE (6504),
-- completely bypassing comms_service/core.comms. On the common single-modem
-- setup that channel is opened on the same modem as control/status, so
-- comms_service:handle_event() -- which used to process every modem_message
-- unconditionally -- forwarded these messages into comms.receive() too.
-- They carry `src` but no `role`/`payload` (never meant for this pipeline),
-- so they were rejected as "missing role", flooding VALVE/FUEL logs and
-- contributing real tick-time contention with actual STATUS/HEARTBEAT/
-- COMMAND traffic -- part of the reported MASTER<->RT/FUEL/VALVE
-- instability. Fix: comms_service:handle_event() now only forwards
-- modem_message events whose channel matches the role's own control/status
-- channels; everything else (VALVE, LOG, or any future sideband channel)
-- is dropped before it ever reaches comms.receive()/validateMessage().

local comms_service = require('services.comms_service')
local constants = require('shared.constants')

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local received = {}
local svc = comms_service.new({ config = {}, log_prefix = 'TEST' })
-- Avoid a full svc:init() (which needs a real modem/network stack) --
-- handle_event() only needs self.comms and self.config to be set, so stub
-- both directly, mirroring how comms_service_handle_event_before_init_test
-- exercises handle_event() without a real network.
svc.config.channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS }
svc.comms = { receive = function(message) received[#received + 1] = message end }

-- A SET_VALVE-shaped message arriving on the dedicated VALVE channel must
-- be dropped before reaching comms.receive() -- it is not this pipeline's
-- traffic, regardless of how it is shaped.
svc:handle_event({ 'modem_message', 'left', constants.channels.VALVE, constants.channels.VALVE,
  { type = 'SET_VALVE', src = 'node-64', dst = 'node-68', side = 'bottom', high = true, ts = 0 } })
assert_true(#received == 0, 'SET_VALVE on the VALVE channel must not reach comms.receive()')

-- A genuine control-channel message must still be forwarded as before.
svc:handle_event({ 'modem_message', 'left', constants.channels.CONTROL, constants.channels.CONTROL,
  { type = 'HELLO', src = 'node-1', role = 'RT-NODE', ts = 0, payload = {} } })
assert_true(#received == 1, 'a real message on the control channel must still reach comms.receive()')

-- Same for the status channel.
svc:handle_event({ 'modem_message', 'left', constants.channels.STATUS, constants.channels.STATUS,
  { type = 'STATUS', src = 'node-1', role = 'RT-NODE', ts = 0, payload = {} } })
assert_true(#received == 2, 'a real message on the status channel must still reach comms.receive()')

-- The LOG channel must still be dropped too (already covered by the
-- message-type filter, but now also covered by the channel filter as a
-- second, independent line of defense).
svc:handle_event({ 'modem_message', 'left', constants.channels.LOG, constants.channels.LOG,
  { type = 'LOG_EVENT', node_id = 'RT-1', role = 'RT', ts = 0 } })
assert_true(#received == 2, 'LOG channel traffic must not reach comms.receive()')

print("comms_service_channel_filter_test.lua: ok")
