from pathlib import Path
import re, zlib

ROOT = Path('.')
def read(p): return (ROOT/p).read_text(encoding='utf-8')
def write(p,s): (ROOT/p).write_text(s,encoding='utf-8')
def replace_once(p,old,new):
    s=read(p); n=s.count(old)
    if n!=1: raise SystemExit(f'{p}: anchor count={n}: {old[:120]!r}')
    write(p,s.replace(old,new,1))
def regex_once(p,pat,repl,flags=0):
    s=read(p); out,n=re.subn(pat,lambda _m:repl,s,count=1,flags=flags)
    if n!=1: raise SystemExit(f'{p}: regex count={n}: {pat[:120]!r}')
    write(p,out)
def crc(data): return f'{zlib.crc32(data)&0xffffffff:08x}'

# ---------------------------------------------------------------------------
# LOGGER: distinguish pcall success from actual file-I/O success. Never turn a
# failed flush back into DISK_OK; keep the bounded emergency buffer non-fatal.
# ---------------------------------------------------------------------------
logger='xreactor/core/logger.lua'
flush_pattern=r'''local function flush_buffer_to_dir\(target_dir\)\n.*?\nend\n\nlocal function flush_if_needed\(force\)\n.*?\nend\n\nlocal function normalize_level'''
flush_new='''local function flush_buffer_to_dir(target_dir)
  local path = string.format("%s/%s.log", target_dir, state.log_name or "xreactor")
  local dir_ok, dir_reason = ensure_dir(target_dir)
  if not dir_ok then
    state.disk_error = "ensure_dir:" .. tostring(dir_reason)
    return false, state.disk_error
  end

  local pending_bytes = estimate_buffer_bytes()
  local preflight_ok, preflight_reason = preflight_write(target_dir, path, pending_bytes)
  if not preflight_ok then
    state.disk_error = "preflight:" .. tostring(preflight_reason)
    return false, state.disk_error
  end

  local rotate_ok, rotate_reason = rotate_log_if_needed(path, target_dir)
  if not rotate_ok then
    -- Rotation failure alone does not forbid appending to the current file.
    -- Keep the diagnostic but continue with the write attempt.
    state.disk_error = "rotate:" .. tostring(rotate_reason)
  end

  local file
  local open_ok, open_result = pcall(fs.open, path, "a")
  if open_ok then file = open_result end
  if not file then
    cleanup_log_workspace(target_dir, state.log_name and (state.log_name .. ".log") or nil, true)
    local retry_ok, retry_result = pcall(fs.open, path, "a")
    if retry_ok then file = retry_result end
    if not file then
      local _, free_now = get_free_space(target_dir)
      local failure = open_ok and "open-returned-nil" or ("open-error:" .. summarize_error(open_result))
      if retry_ok == false then
        failure = failure .. "|retry-error:" .. summarize_error(retry_result)
      elseif not retry_result then
        failure = failure .. "|retry-returned-nil"
      end
      state.disk_error = "open:" .. failure
      state.disk_error_free = free_now
      state.disk_writes_suppressed = (state.disk_writes_suppressed or 0) + #state.buffer
      return false, state.disk_error
    end
  end

  for index, line in ipairs(state.buffer) do
    local write_ok, write_err = pcall(file.write, line .. "\\n")
    if not write_ok then
      local _, free_now = get_free_space(target_dir)
      pcall(file.close)
      state.disk_error = "write:" .. summarize_error(write_err)
      state.disk_error_free = free_now
      state.disk_writes_suppressed = (state.disk_writes_suppressed or 0) + (#state.buffer - index + 1)
      return false, state.disk_error
    end
  end

  local close_ok, close_err = pcall(file.close)
  if not close_ok then
    local _, free_now = get_free_space(target_dir)
    state.disk_error = "close:" .. summarize_error(close_err)
    state.disk_error_free = free_now
    return false, state.disk_error
  end

  state.disk_error = nil
  state.disk_error_free = nil
  state.log_dir = target_dir
  state.log_path = path
  return true
end

local function call_flush_buffer_to_dir(target_dir)
  local call_ok, flushed, reason = pcall(flush_buffer_to_dir, target_dir)
  if not call_ok then return false, tostring(flushed) end
  if flushed ~= true then return false, tostring(reason or state.disk_error or "flush failed") end
  return true
end

local function enter_emergency_buffer(reason)
  if not state.warn_once then
    state.warn_once = true
    safe_print("WARN: LOGGING_DISABLED_NONFATAL mode=EMERGENCY_BUFFER_ONLY")
  end
  state.degraded_mode = "EMERGENCY_BUFFER_ONLY"
  state.degraded_reason = tostring(reason or "write unavailable")
  state.emergency_drop = false
  while #state.buffer > (state.emergency_buffer_limit or 32) do
    table.remove(state.buffer, 1)
  end
  state.last_flush = os.clock()
  return true
end

local function accept_local_fallback(reason)
  state.log_source = "runtime-fallback-local"
  state.degraded_mode = "LOCAL_FALLBACK"
  state.degraded_reason = tostring(reason or "primary target unavailable")
  state.emergency_drop = false
  state.buffer = {}
  state.last_flush = os.clock()
  if not state.warn_once then
    state.warn_once = true
    safe_print("WARN: LOGGER_DEGRADED mode=LOCAL_FALLBACK_NONFATAL")
  end
  return true
end

local function flush_if_needed(force)
  if not state.enabled then return true end
  if #state.buffer == 0 then return true end
  local elapsed = os.clock() - (state.last_flush or 0)
  if not force and #state.buffer < CONFIG.FLUSH_LINES and elapsed < CONFIG.FLUSH_INTERVAL then
    return true
  end

  if is_disk_path(state.log_dir) then
    local path = string.format("%s/%s.log", state.log_dir, state.log_name or "xreactor")
    local pending = estimate_buffer_bytes()
    local target_ok, target_reason = preflight_write(state.log_dir, path, pending)
    if not target_ok then
      local recovered_ok, recovered_reason = runtime_recover_space(state.log_dir, path, pending)
      if not recovered_ok then
        local fallback_ok, fallback_reason = call_flush_buffer_to_dir(DEFAULT_LOG_DIR)
        if fallback_ok then
          return accept_local_fallback(tostring(target_reason) .. " | " .. tostring(recovered_reason))
        end
        return enter_emergency_buffer(tostring(target_reason) .. " | recover="
          .. tostring(recovered_reason) .. " | fallback=" .. tostring(fallback_reason))
      end
    end
  end

  local ok, err = call_flush_buffer_to_dir(state.log_dir or CONFIG.LOG_DIR)
  if not ok and state.log_dir ~= DEFAULT_LOG_DIR then
    local fallback_ok, fallback_err = call_flush_buffer_to_dir(DEFAULT_LOG_DIR)
    if fallback_ok then return accept_local_fallback(err) end
    err = tostring(err) .. " | fallback=" .. tostring(fallback_err)
  end

  if not ok then return enter_emergency_buffer(err) end

  state.buffer = {}
  state.last_flush = os.clock()
  state.degraded_mode = "DISK_OK"
  state.degraded_reason = nil
  state.emergency_drop = false
  return true
end

local function normalize_level'''
regex_once(logger,flush_pattern,flush_new,re.S)
replace_once(logger,
'''    state.startup_action = "none"
    state.emergency_drop = false
''',
'''    state.startup_action = "none"
    state.emergency_drop = false
    state.degraded_mode = "DISK_OK"
    state.degraded_reason = nil
    state.warn_once = false
''')

# ---------------------------------------------------------------------------
# RT monitor: adapter snapshot is authoritative; raw wrapping is fallback only.
# ---------------------------------------------------------------------------
mon='xreactor/nodes/rt/monitor_ui.lua'
old='''function M.collect_turbine_rpm_stats(devices, read_turbine_rpm, get_device_caps)
  local min_rpm, max_rpm, sum_rpm, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.turbines or {}) do
    -- Fix (2026-07-06): derselbe doppelte Fehler wie in
    -- build_turbine_status_details() — entry.peripheral existiert nie,
    -- und get_device_caps braucht entry.name (echten Peripheral-Namen),
    -- nicht entry.id (interne Registry-ID). Das war die direkte Ursache
    -- fuer "RPM -" im Overview, da avg_rpm hier immer nil blieb.
    local turbine = entry.name and peripheral.wrap(entry.name) or nil
    local rpm = read_turbine_rpm(turbine, get_device_caps("turbine", entry.name))
    if type(rpm) == "number" then
      count = count + 1
      sum_rpm = sum_rpm + rpm
      if not min_rpm or rpm < min_rpm then min_rpm = rpm end
      if not max_rpm or rpm > max_rpm then max_rpm = rpm end
    end
  end
  return min_rpm, max_rpm, count > 0 and (sum_rpm / count) or nil
end
'''
new='''function M.collect_turbine_rpm_stats(devices, turbine_adapter, read_turbine_rpm, get_device_caps, log_prefix)
  local min_rpm, max_rpm, sum_rpm, count = nil, nil, 0, 0
  for _, entry in ipairs(devices.turbines or {}) do
    local info = turbine_adapter and type(turbine_adapter.inspect) == "function"
      and entry and entry.name and turbine_adapter.inspect(entry.name, log_prefix) or nil
    local rpm = type(info) == "table" and info.rpm or nil
    if type(rpm) ~= "number" and entry and entry.name
        and type(peripheral) == "table" and type(peripheral.wrap) == "function" then
      local turbine = peripheral.wrap(entry.name)
      local caps = get_device_caps and get_device_caps("turbine", entry.name) or {}
      rpm = read_turbine_rpm and read_turbine_rpm(turbine, caps) or nil
    end
    if type(rpm) == "number" then
      count = count + 1
      sum_rpm = sum_rpm + rpm
      if not min_rpm or rpm < min_rpm then min_rpm = rpm end
      if not max_rpm or rpm > max_rpm then max_rpm = rpm end
    end
  end
  return min_rpm, max_rpm, count > 0 and (sum_rpm / count) or nil
end
'''
replace_once(mon,old,new)
old='''  for _, entry in ipairs(devices.turbines or {}) do
    -- Fix (2026-07-06): entry.peripheral existiert NIE in der Registry-
    -- Struktur (siehe core/registry.lua registry:register() — Eintraege
    -- haben nur id/name/type/signature, kein gewrapptes Peripheral-
    -- Objekt). read_turbine_rpm/read_turbine_flow brauchen aber das
    -- echte, gewrappte Objekt (turbine.getRotorSpeed() etc.), nicht nur
    -- den Namen — mit turbine=nil gaben sie immer nil/"-" zurueck. Das
    -- war der eigentliche Grund fuer IST=0.0, Balken=0%, RPM=-, obwohl
    -- die Registry selbst (fuer Overview-Zaehler) korrekt befuellt war.
    local turbine = entry.name and peripheral.wrap(entry.name) or nil
    -- Fix (2026-07-06): get_device_caps(ctx, kind, name) erwartet den
    -- ECHTEN CC:Tweaked-Peripheral-Namen als drittes Argument (fuer
    -- peripheral.isPresent(name)/build_capabilities(name) intern in
    -- turbine_control.lua) — entry.id ist aber die interne, generierte
    -- Registry-ID (z.B. "turbine:BigReactors-Turbine_5:1"), kein gueltiger
    -- Peripheral-Name. Mit dem falschen Namen liefert peripheral.
    -- isPresent() false, caps bleibt leer/nutzlos, wodurch read_turbine_
    -- rpm/flow trotz jetzt korrekt gewrapptem turbine-Objekt weiterhin
    -- keine funktionierenden Capability-Checks durchfuehren konnten.
    local caps = get_device_caps("turbine", entry.name)
    local info = turbine_adapter and type(turbine_adapter.inspect) == "function" and entry and entry.name and turbine_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local energy = num(info.energy, nil)
    if energy then total_output = total_output + energy end
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      rpm = info.rpm or read_turbine_rpm(turbine, caps),
      flow = info.flow or read_turbine_flow(turbine, caps),
      energy = energy,
      active = info.active,
      inductor = info.coil_engaged,
    }
  end
'''
new='''  for _, entry in ipairs(devices.turbines or {}) do
    local info = turbine_adapter and type(turbine_adapter.inspect) == "function"
      and entry and entry.name and turbine_adapter.inspect(entry.name, log_prefix) or nil
    if type(info) ~= "table" then info = {} end
    local rpm, flow = info.rpm, info.flow
    if (type(rpm) ~= "number" or type(flow) ~= "number") and entry and entry.name
        and type(peripheral) == "table" and type(peripheral.wrap) == "function" then
      local turbine = peripheral.wrap(entry.name)
      local caps = get_device_caps and get_device_caps("turbine", entry.name) or {}
      if type(rpm) ~= "number" and read_turbine_rpm then rpm = read_turbine_rpm(turbine, caps) end
      if type(flow) ~= "number" and read_turbine_flow then flow = read_turbine_flow(turbine, caps) end
    end
    local energy = num(info.energy, nil)
    if energy then total_output = total_output + energy end
    list[#list + 1] = {
      id = entry.id,
      bound = entry.bound ~= false,
      rpm = rpm,
      flow = flow,
      energy = energy,
      active = info.active,
      inductor = info.coil_engaged,
    }
  end
'''
replace_once(mon,old,new)
replace_once(mon,
'''  local min_rpm, max_rpm, avg_rpm = M.collect_turbine_rpm_stats(ctx.devices, ctx.read_turbine_rpm, ctx.get_device_caps)
''',
'''  local min_rpm, max_rpm, avg_rpm = M.collect_turbine_rpm_stats(
    ctx.devices, ctx.turbine_adapter, ctx.read_turbine_rpm, ctx.get_device_caps, ctx.log_prefix)
''')

# ---------------------------------------------------------------------------
# NEEDS_MOCK tests: make the fixtures faithfully represent current APIs.
# ---------------------------------------------------------------------------
# Comms retention: peer_retention_s has a documented minimum 10s; preserve
# host os helpers instead of replacing the whole table.
p='tests/comms_peer_retention_cleanup_test.lua'
replace_once(p,
'''local now = 0
_G.os = {
  epoch = function() return now end
}
''',
'''local now = 0
os.epoch = function() return now end
''')
replace_once(p,'peer_retention_s = 3','peer_retention_s = 10')
replace_once(p,'now = 6000','now = 11000')

# UI mocks: unknown drawing primitives are harmless no-ops; panel capture and
# getSize remain explicit so layout contracts still assert real sections.
for p in ['tests/master_energy_ui_contract_test.lua','tests/master_overview_ui_contract_test.lua','tests/master_rt_dashboard_ui_contract_test.lua']:
    s=read(p)
    marker="package.loaded['core.ui'] = {"
    start=s.find(marker)
    if start<0: raise SystemExit(f'{p}: ui marker missing')
    # insert a metatable after the first closing table assignment; patterns differ,
    # so use the shared colors assignment as stable boundary.
    boundary="package.loaded['shared.colors']"
    b=s.find(boundary,start)
    if b<0: raise SystemExit(f'{p}: colors boundary missing')
    block=s[start:b]
    if "setmetatable(package.loaded['core.ui']" not in block:
      s=s[:b]+"setmetatable(package.loaded['core.ui'], { __index = function() return function() end end })\n"+s[b:]
    write(p,s)

p='tests/master_multiview_three_monitor_layout_test.lua'
s=read(p)
b="package.loaded['master.ui.widgets']"
pos=s.find(b)
if pos<0: raise SystemExit('multiview widgets boundary missing')
s=s[:pos]+"setmetatable(package.loaded['core.ui'], { __index = function() return function() end end })\n"+s[pos:]
write(p,s)

# Explicit false is a meaningful isWireless() result; the old test accidentally
# removed the method when opts.isWireless=false.
p='tests/network_modem_detection_test.lua'
replace_once(p,
'''    isWireless = opts.isWireless and function(extra)
      if extra ~= nil then
        error('wrapped modem isWireless must not receive implicit self argument')
      end
      return opts.isWireless
    end or nil,
''',
'''    isWireless = opts.isWireless ~= nil and function(extra)
      if extra ~= nil then
        error('wrapped modem isWireless must not receive implicit self argument')
      end
      return opts.isWireless
    end or nil,
''')

p='tests/rt_module_lifecycle_control_rod_caps_test.lua'
replace_once(p,
'''    reactor_low_water = function() return false end,
''',
'''    reactor_low_water = function() return false end,
    evaluate_reactor_coolant = function()
      return { triggered = false, condition = 'OK', measurement_valid = true, source = 'test' }
    end,
''')

p='tests/rt_startup_diagnostics_timeout_test.lua'
replace_once(p,
'''    active_startup = 'module-1',
    startup_queue = { 'module-1', 'module-2' }
  }
''',
'''    active_startup = 'module-1',
    startup_queue = { 'module-1', 'module-2' }
  }
  ctx.set_active_startup = function(value) ctx.active_startup = value end
  ctx.set_startup_queue = function(value) ctx.startup_queue = value end
''')

p='tests/rt_monitor_ui_adapter_snapshot_test.lua'
# Make UI mock future-proof too; this test is about adapter/raw fallback, not
# whether every decorative widget was individually stubbed.
replace_once(p,
'''  package.loaded['core.ui'] = {
    getSize = function() return 20, 10 end,
    panel = function() end,
    badge = function() end,
    text = function() end,
    list = function() end,
  }
''',
'''  package.loaded['core.ui'] = setmetatable({
    getSize = function() return 20, 10 end,
    panel = function() end,
    badge = function() end,
    text = function() end,
    list = function() end,
  }, { __index = function() return function() end end })
''')

p='tests/wrapped_peripheral_guard_test.lua'
replace_once(p,
'''          return 10, 5
''',
'''          return 80, 24
''')

# Current bootstrap has no logger dependency; its own boot-output wrapper is
# deliberately non-fatal. Keep this as a behavioral test with a throwing print.
p='tests/startup_logger_nonfatal_test.lua'
write(p,'''local function read(path)
  local handle = assert(io.open(path, "r")); local content = handle:read("*a"); handle:close(); return content
end
local source = read("xreactor/start.lua")

local function run_start(role_should_fail)
  local role_src = 'return { role = "RT" }'
  local release_src = 'return { release_id = "test-release" }'
  local env = {}
  setmetatable(env, { __index = _G })
  env._G = env
  env.fs = {
    exists = function(path)
      return path == "/xreactor/config/role.lua" or path == "/xreactor/release.lua"
    end,
    open = function(path, mode)
      if mode ~= "r" then return nil end
      local src = path == "/xreactor/config/role.lua" and role_src
        or (path == "/xreactor/release.lua" and release_src or nil)
      if not src then return nil end
      return { readAll = function() return src end, close = function() end }
    end,
    delete = function() end,
  }
  env.os = setmetatable({
    sleep = function() end,
    reboot = function() end,
  }, { __index = os })
  env.print = function() error("boot output backend unavailable") end
  env.dofile = function(path)
    if path == "/xreactor/core/update_handshake.lua" then
      return { new = function() return {} end }
    end
    if path == "/xreactor/nodes/rt/main.lua" then
      if role_should_fail then error("role boom") end
      return true
    end
    error("unexpected dofile path " .. tostring(path))
  end
  local chunk = assert(load(source, "=xreactor/start.lua", "t", env))
  return pcall(chunk)
end

local ok, err = run_start(false)
if not ok then error("bootstrap output failure must remain non-fatal: " .. tostring(err)) end
local fail_ok, fail_err = run_start(true)
if fail_ok then error("role entrypoint failure must still fail bootstrap") end
if not tostring(fail_err):find("Failed: RT", 1, true) then
  error("role failure must keep explicit bootstrap failure identity: " .. tostring(fail_err))
end
print("startup_logger_nonfatal_test.lua: ok")
''')

# Remove every NEEDS_MOCK exclusion now that each test is self-contained.
skip='tests/known_failing_lua_tests.txt'
s=read(skip)
remove_names={
'comms_peer_retention_cleanup_test.lua','logger_runtime_degraded_nonfatal_test.lua',
'master_energy_ui_contract_test.lua','master_multiview_three_monitor_layout_test.lua',
'master_overview_ui_contract_test.lua','master_rt_dashboard_ui_contract_test.lua',
'network_modem_detection_test.lua','rt_module_lifecycle_control_rod_caps_test.lua',
'rt_monitor_ui_adapter_snapshot_test.lua','rt_startup_diagnostics_timeout_test.lua',
'startup_logger_nonfatal_test.lua','wrapped_peripheral_guard_test.lua'}
lines=[]
for line in s.splitlines():
    name=line.split('#',1)[0].strip()
    if name in remove_names: continue
    lines.append(line)
write(skip,'\n'.join(lines)+'\n')

# Release v518 + semantic-preserving manifest updates for product files only.
release=read('xreactor/release.lua')
for old,new in [('beta-v517','beta-v518'),('manifest-v517','manifest-v518'),('manifest_version = 517','manifest_version = 518')]:
    if release.count(old)!=1: raise SystemExit('release anchor '+old)
    release=release.replace(old,new,1)
write('xreactor/release.lua',release)
manifest=read('xreactor/manifest.lua')
manifest=manifest.replace('-- xreactor/manifest.lua -- manifest-v517','-- xreactor/manifest.lua -- manifest-v518',1)
manifest=manifest.replace('manifest_version = 517','manifest_version = 518',1)
manifest=manifest.replace('manifest_id = "manifest-v517"','manifest_id = "manifest-v518"',1)
for rel in ['core/logger.lua','nodes/rt/monitor_ui.lua','release.lua']:
    data=(ROOT/'xreactor'/rel).read_bytes(); lines=manifest.splitlines(True); idx=[i for i,l in enumerate(lines) if f'path = "{rel}"' in l]
    if len(idx)!=1: raise SystemExit(f'manifest entry {rel} count={len(idx)}')
    i=idx[0]; line=lines[i]
    line,n1=re.subn(r'size_bytes\s*=\s*\d+',f'size_bytes = {len(data)}',line,count=1)
    line,n2=re.subn(r'hash\s*=\s*"[0-9a-f]+"',f'hash = "{crc(data)}"',line,count=1)
    if n1!=1 or n2!=1: raise SystemExit('manifest shape '+rel)
    lines[i]=line; manifest=''.join(lines)
write('xreactor/manifest.lua',manifest)
print('phase6a patch applied')
