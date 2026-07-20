package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test fuer die "Weg 3"-Idee des Melders (Identify/Locate-Hilfe,
-- Fix 2026-07-20, siehe nodes/fuel/redstone_router.lua set_identify()):
-- sendet SET_IDENTIFY fire-and-forget (kein ACK-Tracking wie SET_VALVE)
-- ueber denselben dedizierten Ventil-Funkkanal an eine beliebige VALVE-
-- Node-ID -- unabhaengig davon, ob diese ID gerade Teil einer konfigurierten
-- Route ist (der Editor kann einen noch nicht gespeicherten Schritt
-- identifizieren wollen).

local transmitted = {}
local mock_modem = {
  isWireless = function() return true end,
  open = function() end,
  transmit = function(channel, reply_channel, message)
    table.insert(transmitted, { channel = channel, reply_channel = reply_channel, message = message })
    return true
  end,
}
_G.peripheral = {
  find = function(kind) if kind == 'modem' then return mock_modem end return nil end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

local redstone_router = require('nodes.fuel.redstone_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local router = redstone_router.new({
  config = { node_id = 'FUEL-1', logistics = { redstone_tree = {} } },
  log = function() end, warn_once = function() end,
})

-- 1. set_identify(id, true) sendet SET_IDENTIFY mit on=true an die
--    angegebene Ziel-ID -- auch wenn diese ID in keiner Route vorkommt.
do
  transmitted = {}
  local ok = router:set_identify('VALVE-9', true)
  assert_true(ok, 'set_identify must report success when a valve_modem is available')
  assert_eq(#transmitted, 1, 'exactly one message must be transmitted')
  local msg = transmitted[1].message
  assert_eq(msg.type, 'SET_IDENTIFY', 'the message type must be SET_IDENTIFY')
  assert_eq(msg.dst, 'VALVE-9', 'the message must target the requested node id')
  assert_eq(msg.src, 'FUEL-1', 'the message must carry this router\'s own node_id as src')
  assert_eq(msg.on, true, 'on=true must be forwarded verbatim')
end

-- 2. set_identify(id, false) sendet on=false.
do
  transmitted = {}
  router:set_identify('VALVE-9', false)
  assert_eq(transmitted[1].message.on, false, 'on=false must be forwarded verbatim')
end

-- 3. Ohne node_id: kein Sendeversuch, klarer Fehlschlag.
do
  transmitted = {}
  local ok = router:set_identify(nil, true)
  assert_true(not ok, 'set_identify without a node id must fail cleanly')
  assert_eq(#transmitted, 0, 'nothing must be transmitted without a target node id')
end

-- 4. Ohne verfuegbares Funkmodem (valve_modem == nil): kein Crash, klarer
--    Fehlschlag.
do
  local no_modem_router = redstone_router.new({
    config = { node_id = 'FUEL-1', logistics = { redstone_tree = {} } },
    log = function() end, warn_once = function() end,
  })
  no_modem_router.valve_modem = nil
  local ok = no_modem_router:set_identify('VALVE-9', true)
  assert_true(not ok, 'set_identify without a valve_modem must fail cleanly, not crash')
end

print("redstone_router_set_identify_test.lua: ok")
