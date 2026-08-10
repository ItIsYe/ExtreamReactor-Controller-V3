package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

package.loaded['core.ui'] = {
  clear = function() end,
  badge = function() end,
  text = function() end,
  getSize = function() return 80, 24 end,
}
setmetatable(package.loaded['core.ui'], { __index = function() return function() end end })
package.loaded['master.ui.widgets'] = { layout_button = function() end, fit = function(text) return tostring(text or '') end }

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

local sessions = m.sessions:get_sessions()
if sessions[1].view_key ~= 'overview' or not sessions[1].locked then error('M1 must be locked overview') end
if sessions[2].view_key ~= 'rt' or not sessions[2].locked then error('M2 must be locked rt') end
if sessions[3].view_key ~= 'energy' or not sessions[3].locked then error('M3 must be locked energy') end
if sessions[4].locked then error('M4 must stay operator-cyclable') end

print('master_multiview_three_monitor_layout_test.lua: ok')
