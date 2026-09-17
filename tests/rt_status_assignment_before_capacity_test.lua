-- Regression test (user report 2026-09-17: "die nod ist in kapazitaet
-- lerne aber raktor ist aus"): both RT status displays -- the monitor
-- overview text (nodes/rt/mockup_pages.lua) and the physical "ampel"
-- traffic-light colour (nodes/rt/monitor_ui.lua) -- checked
-- model.capacity_ready BEFORE model.assignment_state in their local
-- rt_status() functions. A node the master had deliberately parked
-- (assignment_state == "shutdown"/"shed"/"standby", see
-- master/rt_sync.lua -- unlearned/0-capacity nodes always sort last and
-- get parked this way) therefore displayed "KAPAZITAET WIRD GELERNT" /
-- a LIMITED-coloured ampel instead of the correct "SYSTEM FAHRT
-- HERUNTER" / "WARTET AUF LASTZUWEISUNG" / muted state, even while the
-- reactor was simply switched off.
--
-- Both rt_status() functions are local (not exported), so this locks in
-- the fix at the source-ordering level: the assignment_state branches
-- must appear textually before the "if not model.capacity_ready" check.

local function read(p)
  local f = assert(io.open(p, 'r'))
  local s = f:read('*a')
  f:close()
  return s
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function check_ordering(path)
  local src = read(path)
  local rt_status_start = src:find('local function rt_status(', 1, true)
  assert_true(rt_status_start ~= nil, path .. ': rt_status() not found')
  local assignment_pos = src:find('model.assignment_state', rt_status_start, true)
  local capacity_pos = src:find('model.capacity_ready', rt_status_start, true)
  assert_true(assignment_pos ~= nil, path .. ': rt_status() no longer reads model.assignment_state')
  assert_true(capacity_pos ~= nil, path .. ': rt_status() no longer reads model.capacity_ready')
  assert_true(assignment_pos < capacity_pos,
    path .. ': rt_status() must check model.assignment_state before model.capacity_ready, '
    .. 'otherwise a master-parked node (shutdown/shed/standby) is misreported as "capacity learning"')
end

check_ordering('xreactor/nodes/rt/mockup_pages.lua')
check_ordering('xreactor/nodes/rt/monitor_ui.lua')

print('rt_status_assignment_before_capacity_test.lua: ok')
