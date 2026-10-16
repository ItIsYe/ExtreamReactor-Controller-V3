package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
-- handle_hop_scan() must be a pure pass-through into an injected hop_timing
-- instance (nil-safe when none is configured), never touching valve/routing
-- state itself. See nodes/fuel/redstone_router.lua's comment above the
-- function and nodes/fuel/hop_timing.lua.
_G.peripheral={find=function() return nil end,isPresent=function() return false end,wrap=function() return nil end}
_G.redstone={setOutput=function() end}
package.loaded['nodes.fuel.redstone_router']=nil
local lib=require('nodes.fuel.redstone_router')

-- Without hop_timing configured: must not error.
local router_noop=lib.new({config={},log=function() end,warn_once=function() end})
router_noop:handle_hop_scan({type='HOP_SCAN',src='VALVE-1',items={['minecraft:uranium_ingot']=4},ts=123})

-- With hop_timing configured: message is forwarded verbatim.
local seen = {}
local fake_hop_timing = { record_scan = function(_self, node_id, items, ts) seen[#seen+1] = { node_id, items, ts } end }
local router = lib.new({config={},log=function() end,warn_once=function() end,hop_timing=fake_hop_timing})

router:handle_hop_scan({type='HOP_SCAN',src='VALVE-1',items={['minecraft:uranium_ingot']=4},ts=1000})
assert(#seen==1); assert(seen[1][1]=='VALVE-1'); assert(seen[1][2]['minecraft:uranium_ingot']==4); assert(seen[1][3]==1000)

-- Wrong type, missing src, non-table items: all ignored.
router:handle_hop_scan({type='VALVE_ACK',src='VALVE-1',items={},ts=1})
router:handle_hop_scan({type='HOP_SCAN',src='',items={},ts=1})
router:handle_hop_scan({type='HOP_SCAN',src='VALVE-1',items='not-a-table',ts=1})
router:handle_hop_scan('not-a-table')
assert(#seen==1, 'malformed HOP_SCAN messages must be ignored')

print('redstone_router_hop_scan_test.lua: ok')
