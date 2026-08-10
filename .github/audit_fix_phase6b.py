from pathlib import Path
import re, zlib

ROOT=Path('.')
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def write(p,s): (ROOT/p).write_text(s,encoding='utf-8')
def replace_once(p,old,new):
    s=read(p); n=s.count(old)
    if n!=1: raise SystemExit(f'{p}: anchor count={n}: {old[:140]!r}')
    write(p,s.replace(old,new,1))
def crc(data): return f'{zlib.crc32(data)&0xffffffff:08x}'

# ---------------------------------------------------------------------------
# RT main: split the one genuinely oversized init() scope into two top-level
# setup helpers without changing regulation/state semantics.
# ---------------------------------------------------------------------------
p='xreactor/nodes/rt/main.lua'
s=read(p)
init_marker='local function init()\n'
init_pos=s.find(init_marker)
if init_pos<0: raise SystemExit('rt init marker missing')
life_start=s.find('  make_lifecycle_ctx = function()\n',init_pos)
state_start=s.find('  local state_ctx = {\n',life_start)
state_end_marker='  node_state_machine:transition(constants.node_states.RUNNING)\n'
state_end=s.find(state_end_marker,state_start)
if min(life_start,state_start,state_end)<0: raise SystemExit('rt init split anchors missing')
state_end += len(state_end_marker)
life_chunk=s[life_start:state_start]
state_chunk=s[state_start:state_end]

def deindent(block):
    out=[]
    for line in block.splitlines(True):
        out.append(line[2:] if line.startswith('  ') else line)
    return ''.join(out)

helpers='''local function configure_lifecycle_context()\n''' + deindent(life_chunk) + '''end\n\nlocal function configure_state_machine()\n''' + deindent(state_chunk) + '''end\n\n'''
s=s[:init_pos]+helpers+s[init_pos:]
# Re-find chunks after insertion and replace the exact original nested region.
init_pos=s.find(init_marker,init_pos+len(helpers))
life_start=s.find('  make_lifecycle_ctx = function()\n',init_pos)
state_start=s.find('  local state_ctx = {\n',life_start)
state_end=s.find(state_end_marker,state_start)+len(state_end_marker)
if min(life_start,state_start,state_end)<0: raise SystemExit('rt nested chunks missing after helper insert')
s=s[:life_start]+'  configure_lifecycle_context()\n  configure_state_machine()\n\n'+s[state_end:]
write(p,s)

# ---------------------------------------------------------------------------
# MASTER RT shutdown workflow observability: project the real workflow object
# into the UI model and render a compact semantic verdict on every RT card.
# ---------------------------------------------------------------------------
ui='xreactor/master/ui_controller.lua'
replace_once(ui,
'''    for _, node in ipairs(rt_nodes) do
      local payload = type(node.payload) == "table" and node.payload or {}
''',
'''    for _, node in ipairs(rt_nodes) do
      local payload = type(node.payload) == "table" and node.payload or {}
      local shutdown = type(node.shutdown_workflow) == "table" and node.shutdown_workflow or {}
''')
replace_once(ui,
'''        target_source = first_text(node.rt_target_source, node.target_source, payload.rt_target_source, payload.target_source),
        alarms = normalize_alarm_list(node.alarms or payload.alarms),
''',
'''        target_source = first_text(node.rt_target_source, node.target_source, payload.rt_target_source, payload.target_source),
        shutdown_stage = first_text(shutdown.stage, node.shutdown_stage, payload.shutdown_stage),
        shutdown_outcome = first_text(shutdown.outcome, node.shutdown_outcome, payload.shutdown_outcome),
        shutdown_reason = first_text(shutdown.final_reason, shutdown.error, node.shutdown_reason, payload.shutdown_reason),
        shutdown_target_state = first_text(shutdown.target_state, node.shutdown_target_state, payload.shutdown_target_state),
        shutdown_requested_at = first_number(shutdown.requested_at, node.shutdown_requested_at, payload.shutdown_requested_at),
        shutdown_completed_at = first_number(shutdown.completed_at, node.shutdown_completed_at, payload.shutdown_completed_at),
        alarms = normalize_alarm_list(node.alarms or payload.alarms),
''')

dash='xreactor/master/ui/rt_dashboard.lua'
insert_anchor='''local function queue_text(rt)
'''
helper='''local function shutdown_verdict(rt)
  local stage = first_text(rt.shutdown_stage)
  local outcome = first_text(rt.shutdown_outcome)
  local reason = first_text(rt.shutdown_reason)
  if outcome == "SUCCESS" or stage == "COMPLETED" or reason == "SUCCESS_COMPLETED" then
    return "SD:OK"
  end
  if outcome == "FAILED" or stage == "FAILED" or (reason and reason:find("FAILED_", 1, true) == 1) then
    return "SD:FAIL " .. fit(reason or stage or outcome or "?", 18)
  end
  if outcome == "CANCELLED" or stage == "CANCELLED_DEMAND_RECOVERED" or reason == "CANCELLED_DEMAND_RECOVERED" then
    return "SD:CANCELLED"
  end
  if stage then return "SD:" .. fit(stage, 18) end
  return "SD:-"
end

'''
replace_once(dash,insert_anchor,helper+insert_anchor)
replace_once(dash,
'''    mock.data_row(mon,  x, by+6, math.max(10, w-1), "QUEUE", queue_text(rt), { label_w = label_w })
''',
'''    mock.data_row(mon,  x, by+6, math.max(10, w-1), "QUEUE / SD",
      queue_text(rt) .. " | " .. shutdown_verdict(rt), { label_w = label_w })
''')

# ---------------------------------------------------------------------------
# Rewrite the 13 stale Lua guards to the current modular API/semantics.
# ---------------------------------------------------------------------------
write('tests/comms_stability_defaults_regression_test.lua', '''package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local comms=require('core.comms')
local master=dofile('xreactor/master/config.lua')
local energy=dofile('xreactor/nodes/energy/config.lua')
local mc=assert(master.comms,'master comms missing'); local ec=assert(energy.comms,'energy comms missing')
assert(mc.peer_down_grace_s==3.0 and mc.peer_up_debounce_s==2.5 and mc.peer_up_min_observations==3,'master peer hysteresis defaults drifted')
assert(ec.peer_down_grace_s==10.0 and ec.peer_up_debounce_s==3.0 and ec.peer_up_min_observations==3,'energy peer hysteresis defaults drifted')
assert(energy.matrix_metric_poll_interval==3.0,'energy matrix poll interval drifted')
local sanitized=comms.sanitize_config({peer_timeout_s=1,peer_down_grace_s=-5,peer_up_debounce_s=-1,peer_up_min_observations=0})
assert(sanitized.peer_down_grace_s>=0 and sanitized.peer_up_debounce_s>=0 and sanitized.peer_up_min_observations>=1,'comms sanitizer must keep stability bounds safe')
print('comms_stability_defaults_regression_test.lua: ok')
''')

write('tests/energy_master_connection_scope_regression_test.lua', '''local f=assert(io.open('xreactor/nodes/energy/main.lua','r'));local s=f:read('*a');f:close()
for _,token in ipairs({
  'local role_logic             = require("nodes.support.role_logic")',
  'role_logic.master_peer_state(comms, constants.roles.MASTER)',
  'role_logic.is_master_connected({',
  'master_role = constants.roles.MASTER',
  'last_seen_ts = runtime.master_seen_ts',
}) do assert(s:find(token,1,true),'missing shared master-connection contract: '..token) end
assert(not s:find('local master_peer_state',1,true),'energy must not reintroduce shadowed forward-declaration master helpers')
print('energy_master_connection_scope_regression_test.lua: ok')
''')

write('tests/lifecycle_logging_contract_guard_test.lua', '''local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local boot=read('xreactor/start.lua')
assert(boot:find('[BOOT] XReactor',1,true),'bootstrap must emit role/release lifecycle identity')
local contracts={
  ['xreactor/nodes/energy/main.lua']={'utils.init_logger','"Startup"','log("Initializing..."'},
  ['xreactor/nodes/rt/main.lua']={'RT-Node starting','RT-Node ready'},
  ['xreactor/nodes/fuel/main.lua']={'support_runtime.init_logging','Monitor-Erstinit'},
  ['xreactor/master/runtime_loop.lua']={'init_runtime','runtime'},
}
for p,tokens in pairs(contracts) do local s=read(p); for _,t in ipairs(tokens) do assert(s:find(t,1,true),p..' missing lifecycle/log contract '..t) end end
print('lifecycle_logging_contract_guard_test.lua: ok')
''')

write('tests/master_rt_shutdown_oscillation_guard_test.lua', '''local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local ops=read('xreactor/master/runtime_ops_rt.lua')
local coalescer=read('xreactor/master/rt_sync_coalescer.lua')
for _,t in ipairs({'shutdown_candidate_stability_ms','shutdown_restart_cooldown_ms','advance_shutdown_candidate','CANCELLED_DEMAND_RECOVERED'}) do
  assert((ops..coalescer):find(t,1,true),'missing shutdown anti-oscillation contract '..t)
end
assert(coalescer:find('workflow.cancelled_at',1,true),'cancel timestamp required for restart cooldown')
assert(coalescer:find('debounce_stability',1,true) and coalescer:find('debounce_cooldown',1,true),'both stability and cooldown gates required')
print('master_rt_shutdown_oscillation_guard_test.lua: ok')
''')

write('tests/master_rt_shutdown_workflow_semantic_guards_test.lua', '''local f=assert(io.open('xreactor/master/runtime_ops_rt.lua','r'));local s=f:read('*a');f:close()
local required={'workflow.stage = "REQUESTED"','workflow.stage = "WAITING_STATE"','workflow.stage = "COMPLETED"',
'workflow.final_reason = "SUCCESS_COMPLETED"','workflow_fail("FAILED_TIMEOUT"','workflow_fail("FAILED_REJECTED"',
'workflow_fail("FAILED_INVALID_STATE"','workflow_fail("FAILED_ACK_MISSING"','workflow.final_reason = "FAILED_UNKNOWN"'}
for _,t in ipairs(required) do assert(s:find(t,1,true),'missing current shutdown semantic token '..t) end
local completed=assert(s:find('workflow.stage = "COMPLETED"',1,true)); local statecheck=assert(s:find('if node.state == (workflow.target_state or target_shutdown_state) then',1,true))
assert(completed>statecheck,'COMPLETED must remain behind actual target-state verification')
print('master_rt_shutdown_workflow_semantic_guards_test.lua: ok')
''')

# Keep the valuable command-handler behavior body; only retarget token source.
p='tests/master_rt_shutdown_workflow_semantics_guard_test.lua'
s=read(p).replace("io.open('xreactor/master/main.lua', 'r')","io.open('xreactor/master/runtime_ops_rt.lua', 'r')")
s=s.replace("xreactor/master/main.lua","xreactor/master/runtime_ops_rt.lua").replace('in master/main.lua','in runtime_ops_rt.lua')
write(p,s)

write('tests/master_timeout_grace_guard_test.lua', '''local f=assert(io.open('xreactor/master/runtime_ops_rt.lua','r'));local s=f:read('*a');f:close()
for _,t in ipairs({'state_confirm_timeout_ms','command_timeout_grace_ms','workflow.state_confirmed_at','FAILED_ACK_MISSING','FAILED_TIMEOUT','WAITING_STATE'}) do
  assert(s:find(t,1,true),'missing timeout/grace workflow contract '..t)
end
local grace=assert(s:find('workflow.state_confirmed_at and (now - workflow.state_confirmed_at) >= command_timeout_grace_ms',1,true))
local ackfail=assert(s:find('workflow_fail("FAILED_ACK_MISSING"',1,true))
assert(ackfail>grace,'ACK-missing failure must occur only after state confirmation grace')
print('master_timeout_grace_guard_test.lua: ok')
''')

write('tests/master_ui_shutdown_field_consistency_guard_test.lua', '''local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local producer=read('xreactor/master/runtime_ops_rt.lua'); local projection=read('xreactor/master/ui_controller.lua'); local view=read('xreactor/master/ui/rt_dashboard.lua')
for _,field in ipairs({'stage','outcome','final_reason','target_state','requested_at','completed_at'}) do assert(producer:find('workflow.'..field,1,true),'producer missing workflow.'..field) end
for _,field in ipairs({'shutdown_stage','shutdown_outcome','shutdown_reason','shutdown_target_state','shutdown_requested_at','shutdown_completed_at'}) do assert(projection:find(field,1,true),'UI projection missing '..field) end
assert(view:find('shutdown_verdict',1,true) and view:find('QUEUE / SD',1,true),'RT dashboard must surface shutdown workflow verdict')
print('master_ui_shutdown_field_consistency_guard_test.lua: ok')
''')

write('tests/reactor_rod_config_clamp_regression_test.lua', '''package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local rc=require('nodes.rt.reactor_control')
local function clamp(v,a,b)return math.max(a,math.min(b,v))end
local ctx={config={rails={reactor_rods={min=130,max=-20}}},CONFIG={ROD_MIN=0,ROD_MAX=100},safety={clamp=clamp}}
local lo,hi=rc.get_effective_regulator_rod_caps(ctx)
assert(lo==0 and hi==100,'inverted/out-of-range config must normalize to physical rod range')
ctx.config.rails.reactor_rods={min=85,max=20}; lo,hi=rc.get_effective_regulator_rod_caps(ctx)
assert(lo==20 and hi==85,'configured cap order must normalize deterministically')
assert(rc.clamp_rods(ctx,-50,false)==0 and rc.clamp_rods(ctx,200,false)==100,'normal rod targets must stay within physical rails')
print('reactor_rod_config_clamp_regression_test.lua: ok')
''')

write('tests/rt_control_tick_wiring_regression_test.lua', '''local f=assert(io.open('xreactor/nodes/rt/main.lua','r'));local s=f:read('*a');f:close()
local start=assert(s:find('local function control_tick()',1,true)); local stop=assert(s:find('-- ── Command-Handler',start,true)); local b=s:sub(start,stop)
local order={
  'if rt_update_quiescing then return end',
  'module_lifecycle.update_module_states(make_lifecycle_ctx())',
  'module_lifecycle.process_startup(make_lifecycle_ctx())',
  'reactor_control.updateReactorControl(ctx)',
  'turbine_control.updateControl(ctx)',
  'writeback_ctx()',
}
local last=0; for _,t in ipairs(order) do local i=assert(b:find(t,1,true),'missing control tick delegation '..t); assert(i>last,'control tick safety/order drift at '..t); last=i end
print('rt_control_tick_wiring_regression_test.lua: ok')
''')

write('tests/rt_dashboard_shutdown_verdict_semantics_test.lua', '''local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local ui=read('xreactor/master/ui/rt_dashboard.lua'); local proj=read('xreactor/master/ui_controller.lua')
for _,token in ipairs({'SD:OK','SD:FAIL','SD:CANCELLED','shutdown_verdict(rt)','QUEUE / SD'}) do assert(ui:find(token,1,true),'dashboard missing semantic shutdown verdict '..token) end
for _,token in ipairs({'shutdown_stage','shutdown_outcome','shutdown_reason'}) do assert(proj:find(token,1,true),'UI model missing shutdown field '..token) end
assert(ui:find('stage == "COMPLETED"',1,true),'COMPLETED stage must render as success')
assert(ui:find('stage == "FAILED"',1,true),'FAILED stage must render as failure')
assert(ui:find('stage == "CANCELLED_DEMAND_RECOVERED"',1,true),'cancelled demand recovery must remain distinct from failure')
print('rt_dashboard_shutdown_verdict_semantics_test.lua: ok')
''')

write('tests/rt_turbine_readback_source_regression_test.lua', '''local f=assert(io.open('xreactor/nodes/rt/turbine_control.lua','r'));local s=f:read('*a');f:close()
local st=assert(s:find('function M.read_turbine_flow(ctx, turbine, caps)',1,true)); local en=assert(s:find('local function turbine_has_flow_setter',st,true)); local b=s:sub(st,en)
local max=assert(b:find('getFluidFlowRateMax',1,true)); local flow=assert(b:find('getFluidFlowRate',max+1,true)); assert(max<flow,'flow readback must prefer configured max before instantaneous flow')
assert(b:find('FLOW_UNAVAILABLE',1,true),'unavailable flow must remain explicit')
print('rt_turbine_readback_source_regression_test.lua: ok')
''')

write('tests/rt_turbine_tick_coverage_regression_test.lua', '''local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local s=read('xreactor/nodes/rt/turbine_control.lua')
for _,t in ipairs({'INDUCTOR_UPDATE_FAILED_NONFATAL','SET_ACTIVE_FAILED_NONFATAL','OVERSPEED_BRAKE_FLOW_ZERO','enforce_overspeed_brake_coil','for _, name in ipairs(ctx.config.turbines or {}) do'}) do assert(s:find(t,1,true),'turbine control missing coverage/safety contract '..t) end
assert(s:find('update_inductor_for_rpm',1,true) and s:find('update_turbine_flow_state',1,true),'every turbine tick must retain coil and flow decisions')
print('rt_turbine_tick_coverage_regression_test.lua: ok')
''')

# ---------------------------------------------------------------------------
# Rewrite all six stale Python guards to current module boundaries.
# ---------------------------------------------------------------------------
write('tests/energy_scope_regression_test.py', '''from pathlib import Path
s=Path('xreactor/nodes/energy/main.lua').read_text(encoding='utf-8')
required=['local role_logic             = require("nodes.support.role_logic")','role_logic.master_peer_state(comms, constants.roles.MASTER)','role_logic.is_master_connected({','last_seen_ts = runtime.master_seen_ts']
for t in required:
    if t not in s: raise AssertionError(f'missing current ENERGY master-scope contract: {t}')
if 'local master_peer_state' in s or 'local is_master_connected' in s:
    raise AssertionError('ENERGY must use shared role_logic directly rather than shadowed forward declarations')
print('energy_scope_regression_test.py: ok')
''')

write('tests/energy_heartbeat_decoupling_regression_test.py', '''from pathlib import Path
main=Path('xreactor/nodes/energy/main.lua').read_text(encoding='utf-8')
hb=Path('xreactor/nodes/energy/heartbeat.lua').read_text(encoding='utf-8')
required_main=['local heartbeat_mod          = require("nodes.energy.heartbeat")','local matrix_mod             = require("nodes.energy.matrix")','local function send_heartbeat_if_due','get_last_heartbeat_ts','services = service_manager.new({ log_prefix = "ENERGY" })','matrix_services = service_manager.new({ log_prefix = "ENERGY_MATRIX" })']
for t in required_main:
    if t not in main: raise AssertionError(f'missing ENERGY heartbeat-decoupling contract: {t}')
for t in ['send_heartbeat_if_due','get_last_heartbeat_ts','services:tick']:
    if t not in hb: raise AssertionError(f'heartbeat thread missing contract: {t}')
if 'matrix_services:tick' in hb: raise AssertionError('heartbeat thread must not tick blocking matrix services')
print('energy_heartbeat_decoupling_regression_test.py: ok')
''')

write('tests/energy_persistent_topology_regression_test.py', '''from pathlib import Path
main=Path('xreactor/nodes/energy/main.lua').read_text(encoding='utf-8')
disc=Path('xreactor/nodes/energy/discovery_runtime.lua').read_text(encoding='utf-8')
cache=Path('xreactor/nodes/energy/matrix_topology_cache.lua').read_text(encoding='utf-8')
snap=Path('xreactor/nodes/energy/matrix_snapshot_runtime.lua').read_text(encoding='utf-8')
for t in ['matrix_topology_cache.new','topology_cache = topology_cache','on_topology_changed','discovery_force_rescan_interval']:
    if t not in main: raise AssertionError(f'main missing topology contract: {t}')
for t in ['topology_cache','matrix_runtime','matrix_groups']:
    if t not in disc: raise AssertionError(f'discovery runtime missing topology integration: {t}')
for t in ['forced_rescan_interval','peripheral_detach']:
    if t not in cache: raise AssertionError(f'topology cache missing invalidation contract: {t}')
for t in ['last_good_state','stale']:
    if t not in snap: raise AssertionError(f'matrix snapshot missing freshness contract: {t}')
print('energy_persistent_topology_regression_test.py: ok')
''')

write('tests/master_rt_dashboard_ui_contract_test.py', '''from pathlib import Path
s=Path('xreactor/master/ui/rt_dashboard.lua').read_text(encoding='utf-8')
for t in ['RT FLEET','RT-FLOTTE','SEQUENCER / QUEUE','prioritized_rt_nodes(model.rt_nodes','QUEUE / SD','shutdown_verdict(rt)']:
    if t not in s: raise AssertionError(f'missing current RT dashboard contract: {t}')
print('master_rt_dashboard_ui_contract_test.py: ok')
''')

write('tests/release_manifest_rt_guard_test.py', '''#!/usr/bin/env python3
from pathlib import Path
import re
root=Path('.')
release=(root/'xreactor/release.lua').read_text(encoding='utf-8')
manifest=(root/'xreactor/manifest.lua').read_text(encoding='utf-8')
installer=(root/'installer').read_text(encoding='utf-8')
init=(root/'xreactor/installer/init.lua').read_text(encoding='utf-8')
rt=(root/'xreactor/nodes/rt/main.lua').read_text(encoding='utf-8')
paths=set(re.findall(r'path\s*=\s*"([^"]+)"',manifest))
def field(src,name):
    m=re.search(rf'{name}\s*=\s*"([^"]*)"',src)
    if not m: raise AssertionError(f'missing {name}')
    return m.group(1)
assert field(release,'source_ref')=='beta' and field(manifest,'source_ref')=='beta'
assert field(release,'commit_sha') in ('','beta')
for p in ['nodes/rt/discovery_runtime.lua','nodes/rt/health_payload.lua','nodes/rt/main.lua']:
    assert p in paths, f'manifest missing RT runtime file {p}'
for mod in re.findall(r'require\s*\(\s*["\']([\w\._]+)["\']\s*\)',rt):
    rel=mod.replace('.','/')+'.lua'
    if (root/'xreactor'/rel).exists(): assert rel in paths, f'RT require missing from manifest: {rel}'
for t in ['__xreactor_forced_ref','Erzwungener Recovery-Ref','recovery_origin_ref']:
    assert t in installer or t in init, f'installer immutable-ref contract missing {t}'
for t in ['resolved_commit_sha','installed_at','manifest_id','installer_ref']:
    assert t in init, f'installed commit metadata missing {t}'
print('release_manifest_rt_guard_test.py: ok')
''')

write('tests/rt_main_structure_guard_test.py', '''#!/usr/bin/env python3
import re
from pathlib import Path
p=Path('xreactor/nodes/rt/main.lua'); text=p.read_text(encoding='utf-8'); lines=text.splitlines(); line_count=len(lines)
if line_count>2400: raise SystemExit(f'rt main too large: {line_count} > 2400')
if '_G.turbine_ctrl =' in text: raise SystemExit('rt main must not mutate _G.turbine_ctrl directly')
starts=[]
for i,line in enumerate(lines,1):
    if re.match(r'^local function ',line) or re.match(r'^function ',line): starts.append((i,line))
starts.append((line_count+1,'<EOF>'))
for (i,name),(j,_) in zip(starts,starts[1:]):
    if j-i>250: raise SystemExit(f'rt main oversized function {name.strip()}: {j-i} > 250')
for helper in ['local function configure_lifecycle_context()','local function configure_state_machine()','configure_lifecycle_context()','configure_state_machine()']:
    if helper not in text: raise SystemExit(f'rt init structural delegation missing: {helper}')
cs=text.index('local function control_tick()'); ce=text.index('-- ── Command-Handler',cs); block=text[cs:ce]
for t in ['module_lifecycle.update_module_states','module_lifecycle.process_startup','reactor_control.updateReactorControl','turbine_control.updateControl','writeback_ctx()']:
    if t not in block: raise SystemExit(f'control_tick missing delegation {t}')
print('rt_main_structure_guard_test.py: ok')
''')

# Zero exclusions: all these guards must now execute in normal CI.
write('tests/known_failing_lua_tests.txt', '# No known failing Lua tests. New failures must be fixed or explicitly justified before adding an exclusion.\n')
write('tests/known_failing_python_tests.txt', '# No known failing Python tests. New failures must be fixed or explicitly justified before adding an exclusion.\n')

# Release v519 + semantic-preserving manifest updates.
release=read('xreactor/release.lua')
for old,new in [('beta-v518','beta-v519'),('manifest-v518','manifest-v519'),('manifest_version = 518','manifest_version = 519')]:
    if release.count(old)!=1: raise SystemExit('release anchor '+old)
    release=release.replace(old,new,1)
write('xreactor/release.lua',release)
manifest=read('xreactor/manifest.lua')
manifest=manifest.replace('-- xreactor/manifest.lua -- manifest-v518','-- xreactor/manifest.lua -- manifest-v519',1)
manifest=manifest.replace('manifest_version = 518','manifest_version = 519',1)
manifest=manifest.replace('manifest_id = "manifest-v518"','manifest_id = "manifest-v519"',1)
for rel in ['nodes/rt/main.lua','master/ui_controller.lua','master/ui/rt_dashboard.lua','release.lua']:
    data=(ROOT/'xreactor'/rel).read_bytes(); lines=manifest.splitlines(True); idx=[i for i,l in enumerate(lines) if f'path = "{rel}"' in l]
    if len(idx)!=1: raise SystemExit(f'manifest entry {rel} count={len(idx)}')
    i=idx[0]; line=lines[i]
    line,n1=re.subn(r'size_bytes\s*=\s*\d+',f'size_bytes = {len(data)}',line,count=1)
    line,n2=re.subn(r'hash\s*=\s*"[0-9a-f]+"',f'hash = "{crc(data)}"',line,count=1)
    if n1!=1 or n2!=1: raise SystemExit('manifest shape '+rel)
    lines[i]=line; manifest=''.join(lines)
write('xreactor/manifest.lua',manifest)
print('phase6b patch applied')
