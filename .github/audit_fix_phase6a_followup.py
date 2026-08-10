from pathlib import Path
import re, zlib

ROOT=Path('.')
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def write(p,s): (ROOT/p).write_text(s,encoding='utf-8')
def replace_once(p,old,new):
    s=read(p); n=s.count(old)
    if n!=1: raise SystemExit(f'{p}: anchor count={n}: {old[:120]!r}')
    write(p,s.replace(old,new,1))
def crc(data): return f'{zlib.crc32(data)&0xffffffff:08x}'

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

# Multiview public state lives in monitor_sessions now, not an obsolete layout
# table. Assert the same three locked primary roles and unlocked AUX behavior.
p='tests/master_multiview_three_monitor_layout_test.lua'
replace_once(p,
"package.loaded['master.ui.widgets'] = { layout_button = function() end }",
"package.loaded['master.ui.widgets'] = { layout_button = function() end, fit = function(text) return tostring(text or '') end }")
replace_once(p,
'''if m.layout.monitors.M1.view ~= 'overview' or not m.layout.monitors.M1.locked then error('M1 must be locked overview') end
if m.layout.monitors.M2.view ~= 'rt' or not m.layout.monitors.M2.locked then error('M2 must be locked rt') end
if m.layout.monitors.M3.view ~= 'energy' or not m.layout.monitors.M3.locked then error('M3 must be locked energy') end
if m.layout.monitors.M4.locked then error('M4 must stay operator-cyclable') end
''',
'''local sessions = m.sessions:get_sessions()
if sessions[1].view_key ~= 'overview' or not sessions[1].locked then error('M1 must be locked overview') end
if sessions[2].view_key ~= 'rt' or not sessions[2].locked then error('M2 must be locked rt') end
if sessions[3].view_key ~= 'energy' or not sessions[3].locked then error('M3 must be locked energy') end
if sessions[4].locked then error('M4 must stay operator-cyclable') end
''')

# RT dashboard migrated from core.ui panels to core.mockup_ui header/sections.
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

# Product fix: modem_like override candidates must carry the same wireless
# classification as the fully classified modem entry. Without this, an
# explicitly configured wireless modem was accepted as a wired override.
p='xreactor/core/network.lua'
replace_once(p,
'''        local entry = {
          name = name,
          type = type_name,
          wireless = wireless,
          wrapped = wrapped
        }
        discovered.all[#discovered.all + 1] = entry
''',
'''        local entry = {
          name = name,
          type = type_name,
          wireless = wireless,
          wrapped = wrapped
        }
        for _, candidate in ipairs(discovered.modem_like) do
          if candidate.name == name then candidate.wireless = wireless end
        end
        discovered.all[#discovered.all + 1] = entry
''')

# Channel opening is idempotent; verify both configured channels, not call count.
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

# monitor_manager registry legitimately needs fs/textutils. The fixture stays
# focused on no implicit-self forwarding for wrapped peripheral methods.
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
_G.textutils = _G.textutils or {
  serialize = function() return '{}' end,
  unserialize = function() return nil end,
}
local monitor_adapter = require('adapters.monitor')
local ui = require('core.ui')
local monitor_manager = require('core.monitor_manager')
''')

# Phase6a main script already bumped to v518; include network.lua in that same
# release's manifest without changing any semantic flags.
manifest=read('xreactor/manifest.lua')
data=(ROOT/'xreactor/core/network.lua').read_bytes()
lines=manifest.splitlines(True); idx=[i for i,l in enumerate(lines) if 'path = "core/network.lua"' in l]
if len(idx)!=1: raise SystemExit(f'network manifest entry count={len(idx)}')
i=idx[0]; line=lines[i]
line,n1=re.subn(r'size_bytes\s*=\s*\d+',f'size_bytes = {len(data)}',line,count=1)
line,n2=re.subn(r'hash\s*=\s*"[0-9a-f]+"',f'hash = "{crc(data)}"',line,count=1)
if n1!=1 or n2!=1: raise SystemExit('network manifest entry shape changed')
lines[i]=line; write('xreactor/manifest.lua',''.join(lines))

print('phase6a followup fixtures/product updated')
