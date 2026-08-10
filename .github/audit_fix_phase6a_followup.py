from pathlib import Path

ROOT=Path('.')
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def write(p,s): (ROOT/p).write_text(s,encoding='utf-8')
def replace_once(p,old,new):
    s=read(p); n=s.count(old)
    if n!=1: raise SystemExit(f'{p}: anchor count={n}: {old[:120]!r}')
    write(p,s.replace(old,new,1))

# Current ENERGY view contract (top-level + panel_box titles).
p='tests/master_energy_ui_contract_test.lua'
replace_once(p,
"local required = { 'MONITOR 3 - ENERGY & RESSOURCEN', 'Energy', 'Matrix-/Storage-Details', 'Fuel', 'Water / Reprocessing', 'Verbundene Support-Nodes' }",
"local required = { 'ENERGY', 'Energy Summary', 'Matrix / Storage', 'Ressourcen', 'Support-Nodes' }")

# Current OVERVIEW sections after the UI modularization.
p='tests/master_overview_ui_contract_test.lua'
replace_once(p,
"local required = { 'Systemstatus', 'Globale Steuerung', 'Aktive Meldungen', 'KPI', 'Node-Status' }",
"local required = { 'OVERVIEW', 'Systemlage', 'Steuerung', 'Meldungen', 'Kennzahlen', 'Top-Nodes' }")

# Multiview fixture stubs layout_button but the current footer/alert rendering
# legitimately uses widgets.fit(). Keep the test focused on monitor locking.
p='tests/master_multiview_three_monitor_layout_test.lua'
replace_once(p,
"package.loaded['master.ui.widgets'] = { layout_button = function() end }",
"package.loaded['master.ui.widgets'] = { layout_button = function() end, fit = function(text) return tostring(text or '') end }")

# RT dashboard migrated from core.ui panels to core.mockup_ui header/sections.
# Test that current semantic section contract, not obsolete panel titles.
p='tests/master_rt_dashboard_ui_contract_test.lua'
write(p,"""package.path = 'xreactor/?.lua;xreactor/?/init.lua;' .. package.path

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
""")

# Channel opening is an idempotent implementation detail; the contract is that
# both configured channels are opened. Do not fail if a future wrapper repeats
# an open harmlessly.
p='tests/network_modem_detection_test.lua'
replace_once(p,
'''  if #opened ~= 2 then
    error('expected 2 modem.open calls for channels')
  end
''',
'''  local seen = {}
  for _, channel in ipairs(opened) do seen[channel] = true end
  if not seen[6500] or not seen[6501] then
    error('expected both configured modem channels 6500/6501 to be opened')
  end
''')

# monitor_manager owns a registry that legitimately probes fs. This fixture is
# about wrapped method calling, so provide the minimum persistent-store API.
p='tests/wrapped_peripheral_guard_test.lua'
replace_once(p,
'''local monitor_adapter = require('adapters.monitor')
local ui = require('core.ui')
local monitor_manager = require('core.monitor_manager')
''',
'''_G.fs = _G.fs or {
  exists = function() return false end,
  open = function() return nil end,
  getDir = function() return '' end,
  makeDir = function() end,
}
local monitor_adapter = require('adapters.monitor')
local ui = require('core.ui')
local monitor_manager = require('core.monitor_manager')
''')

print('phase6a followup fixtures updated')
