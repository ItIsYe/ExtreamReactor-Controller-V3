package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local feed_router = require('nodes.reprocessor.feed_router')

local bridge = {
  getItem = function() return { amount = 0 } end,
  exportItemToPeripheral = function() return 0 end,
}
_G.peripheral = {
  getNames = function() return { 'meBridge_0' } end,
  getMethods = function(name)
    if name == 'meBridge_0' then return { 'getItem', 'exportItemToPeripheral' } end
    return {}
  end,
  isPresent = function() return false end,
  wrap = function(name) return name == 'meBridge_0' and bridge or nil end,
}
local rs = { refresh = function() end, tick = function() end }
local router = feed_router.new({
  config = { feed = { enabled = true, me_bridge = 'me_bridge', targets = {} } },
  rs_router = rs,
})
router:refresh_peripherals()
assert(router._state.bridge == bridge, 'shipped me_bridge default must fall back to generated ME bridge names')
assert(router._state.bridge_name == 'meBridge_0', 'actual generated bridge name must be reported')

-- A genuinely custom explicit name must remain strict.
local strict = feed_router.new({
  config = { feed = { enabled = true, me_bridge = 'plant_bridge', targets = {} } },
  rs_router = rs,
})
strict:refresh_peripherals()
assert(strict._state.bridge == nil, 'custom missing bridge name must not silently bind a different bridge')
print('reprocessor_me_bridge_default_fallback_test.lua: ok')
