package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

package.loaded['core.ui'] = {
  clear = function() end,
  badge = function() end,
  text = function() end,
  getSize = function() return 80, 24 end,
}
package.loaded['master.ui.widgets'] = { layout_button = function() end }

local multiview = require('master.ui.multiview')
local calls = {}
local m = multiview.new({
  views = {
    overview = { render = function() calls[#calls+1] = 'overview' end },
    rt = { render = function() calls[#calls+1] = 'rt' end },
    energy = { render = function() calls[#calls+1] = 'energy' end },
  },
  view_order = { 'overview', 'rt', 'energy' }
})

local monitors = {
  { id='M1', name='monitor_1', mon={} },
  { id='M2', name='monitor_2', mon={} },
  { id='M3', name='monitor_3', mon={} },
  { id='M4', name='monitor_4', mon={} },
}

m:render(monitors, { overview={}, rt={}, energy={} })

if m.layout.monitors.M1.view ~= 'overview' or not m.layout.monitors.M1.locked then error('M1 must be locked overview') end
if m.layout.monitors.M2.view ~= 'rt' or not m.layout.monitors.M2.locked then error('M2 must be locked rt') end
if m.layout.monitors.M3.view ~= 'energy' or not m.layout.monitors.M3.locked then error('M3 must be locked energy') end
if m.layout.monitors.M4.locked then error('M4 must stay operator-cyclable') end

print('master_multiview_three_monitor_layout_test.lua: ok')
