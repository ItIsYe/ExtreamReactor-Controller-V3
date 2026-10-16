local function read(p) local f=assert(io.open(p,'r')); local s=f:read('*a');f:close();return s end
local root=os.getenv('REPO_ROOT') or '.'

-- FUEL still uses the valve-path redstone_router and must confirm quiesce
-- via a fresh BLOCKED-ack round trip.
local s = read(root..'/xreactor/nodes/fuel/main.lua')
assert(s:find(':begin_quiesce("UPDATE_QUIESCE")',1,true), 'xreactor/nodes/fuel/main.lua must begin confirmed valve quiesce')
assert(s:find(':poll_quiesce()',1,true), 'xreactor/nodes/fuel/main.lua must wait for current BLOCKED acknowledgements')

-- REPROCESSOR no longer routes via valves (see nodes/reprocessor/
-- feed_router.lua's module comment -- routing is a Mekanism Logistical
-- Sorter color now, set synchronously per feed). Quiescing it is just
-- enter_standby(), with no async transaction to confirm -- see
-- install_p0_2_quiesce_wiring_test.lua for that wiring's own check.
local rs = read(root..'/xreactor/nodes/reprocessor/main.lua')
assert(not rs:find(':begin_quiesce(', 1, true),
  'xreactor/nodes/reprocessor/main.lua should no longer reference a valve-path quiesce (routing is Sorter-color based now)')

print('fuel_reprocessor_quiesce_ack_wiring_test.lua: ok')
