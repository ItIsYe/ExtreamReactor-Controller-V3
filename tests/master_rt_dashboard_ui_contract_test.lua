package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

local calls = { header = nil, sections = {} }
package.loaded['core.mockup_ui'] = setmetatable({
  clear = function() end,
  header = function(_, opts) calls.header = opts and opts.title or nil end,
  section = function(_, _, _, _, title) calls.sections[#calls.sections + 1] = title end,
  data_row = function() end,
  status_dot = function() end,
  card = function() end,
  outlined_progress = function() end,
}, { __index = function() return function() end end })
package.loaded['shared.colors'] = { get = function() return 1 end }

local rt = require('master.ui.rt_dashboard')
local mon = { getSize = function() return 80, 32 end }
rt.render(mon, {
  rt_nodes = { {id=52,state='RUNNING',status='OK',target=35,actual_output=34,mode='MASTER'} },
  queue = {}, rt_active=1, assigned=1, master_control=1, local_control=0, unassigned=0,
})

if calls.header ~= 'RT FLEET' then error('missing RT fleet header') end
local required = { 'RT-FLOTTE', 'SEQUENCER / QUEUE' }
for _, section in ipairs(required) do
  local seen = false
  for _, title in ipairs(calls.sections) do if title == section then seen = true break end end
  if not seen then error('missing RT section: ' .. section) end
end
print('master_rt_dashboard_ui_contract_test.lua: ok')
