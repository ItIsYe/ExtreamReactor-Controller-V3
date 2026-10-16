package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local rt2_master_link = require('nodes.rt.rt2_master_link')

local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

-- Never seen a MASTER message -> not connected.
do
  local link = rt2_master_link.new()
  assert_true(not link.is_connected(0), 'never having seen MASTER must mean not connected')
end

-- Recently seen -> connected.
do
  local link = rt2_master_link.new({ timeout_ms = 12000 })
  link.note_seen(100000)
  assert_true(link.is_connected(105000), 'a message 5s ago must still count as connected')
end

-- Older than timeout -> not connected.
do
  local link = rt2_master_link.new({ timeout_ms = 12000 })
  link.note_seen(100000)
  assert_true(not link.is_connected(113000), 'no message for 13s (> 12s timeout) must count as disconnected')
end

-- A single missed heartbeat within the timeout window must not flip the
-- link -- the debounce is the timeout window itself, not "last message
-- exists at all".
do
  local link = rt2_master_link.new({ timeout_ms = 12000 })
  link.note_seen(0)
  link.note_seen(2000) -- normal heartbeat
  -- next heartbeat "missed" (would have been ~4000), but we're still
  -- within timeout_ms of the last real one.
  assert_true(link.is_connected(8000), 'one missed heartbeat inside the timeout window must not be treated as down')
end

print('rt2_master_link_test.lua: ok')
