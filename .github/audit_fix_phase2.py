from pathlib import Path
import re, zlib

ROOT = Path('.')
SELF = ROOT / '.github/audit_fix_phase2.py'

def read(path):
    return (ROOT / path).read_text(encoding='utf-8')

def write(path, text):
    (ROOT / path).write_text(text, encoding='utf-8')

def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one anchor, got {count}: {old[:100]!r}')
    write(path, text.replace(old, new, 1))

# ---------------------------------------------------------------------------
# 1) FUEL/REPROCESSOR redstone router: do not mutate bindings during an
# active transaction, and revalidate the target path immediately before export.
# ---------------------------------------------------------------------------
rp = 'xreactor/nodes/fuel/redstone_router.lua'
replace_once(rp,
'''      tree_valid = nil,
      tree_errors = {},
      tree_configured = false,
''',
'''      tree_valid = nil,
      tree_errors = {},
      tree_configured = false,
      refresh_deferred = false,
''')

replace_once(rp,
'''function M:refresh()
  local cfg = self.config.logistics or self.config or {}
''',
'''function M:refresh()
  -- Discovery may fire while a valve transaction is between confirmed OPEN
  -- and the export callback. Rebuilding integrator wrappers or block_all() in
  -- that window races the transaction state machine. Defer the refresh until
  -- the transaction has reached a terminal state instead.
  if self._state.transaction then
    self._state.refresh_deferred = true
    self.log("DEBUG", "RedstoneRouter: refresh deferred while transaction is active")
    return false, "busy"
  end
  self._state.refresh_deferred = false

  local cfg = self.config.logistics or self.config or {}
''')

helper_anchor = '''local VALVE_PHASE_TIMEOUT_MS = 15000
'''
helper = '''function M:_path_runtime_ready(path)
  local peers = self.comms and self.comms:get_peers() or {}
  for _, valve in ipairs(path or {}) do
    if valve.integrator then
      local binding = self._state.integrators[valve.integrator]
      if not binding then
        return false, "integrator_missing:" .. tostring(valve.integrator)
      end
      if binding.network then
        local peer = peers[valve.integrator]
        if not peer then
          return false, "peer_missing:" .. tostring(valve.integrator)
        end
        if peer.down == true or peer.stale == true then
          return false, "peer_stale:" .. tostring(valve.integrator)
        end
      else
        if not peripheral or type(peripheral.isPresent) ~= "function"
            or not peripheral.isPresent(valve.integrator) then
          return false, "peripheral_missing:" .. tostring(valve.integrator)
        end
      end
    end
  end
  return true
end

''' + helper_anchor
replace_once(rp, helper_anchor, helper)

replace_once(rp,
'''function M:tick(now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  local tx = self._state.transaction
  if not tx then return end
''',
'''function M:tick(now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  local tx = self._state.transaction
  if not tx then
    if self._state.refresh_deferred then
      self._state.refresh_deferred = false
      self:refresh()
    end
    return
  end
''')

replace_once(rp,
'''  if tx.state == "WAIT_SETTLE" then
    if now_ms >= tx.settle_until then
      if tx.action_fn then
        local ok, err = pcall(tx.action_fn)
''',
'''  if tx.state == "WAIT_SETTLE" then
    if now_ms >= tx.settle_until then
      -- The OPEN ACK proves the valve state at ACK time, not indefinitely.
      -- Re-check that every runtime binding in the selected path is still
      -- present/fresh immediately before moving material.
      local ready, readiness_error = self:_path_runtime_ready(tx.path)
      if not ready then
        self:_fail_transaction("path_not_ready:" .. tostring(readiness_error))
        return
      end
      if tx.action_fn then
        local ok, err = pcall(tx.action_fn)
''')

# ---------------------------------------------------------------------------
# 2) RT turbine coil state is confirmed only after a successful hardware write.
# ---------------------------------------------------------------------------
tp = 'xreactor/nodes/rt/turbine_control.lua'
replace_once(tp,
'''  if engaged == ctrl.inductor_engaged then return true, true, measured_api end
  if not caps.setInductorEngaged then
    ctrl.inductor_engaged = engaged
    return true, true, "inductor-write-unavailable"
  end

  ctrl.inductor_engaged = engaged
  state.last_change_ts = now
  local ok, applied = pcall(setInductor, turbine, caps, engaged)
  if ok and applied then
    local reason = is_overspeed and "OVERSPEED_BRAKE" or "TARGET_TRACKING"
    if ctrl.mode == "OVERSPEED_BRAKE" then reason = "OVERSPEED_BRAKE" end
    ctrl.last_coil_reason = reason
  end
  return ok, applied, measured_api
''',
'''  if engaged == ctrl.inductor_engaged then return true, true, measured_api end
  if not caps.setInductorEngaged then
    -- Desired state is not a confirmed hardware state. Keep the last
    -- confirmed/read-back value so the next control tick continues trying.
    return false, false, "inductor-write-unavailable"
  end

  local ok, applied = pcall(setInductor, turbine, caps, engaged)
  if ok and applied then
    ctrl.inductor_engaged = engaged
    state.last_change_ts = now
    local reason = is_overspeed and "OVERSPEED_BRAKE" or "TARGET_TRACKING"
    if ctrl.mode == "OVERSPEED_BRAKE" then reason = "OVERSPEED_BRAKE" end
    ctrl.last_coil_reason = reason
  end
  return ok, applied, measured_api
''')

replace_once(tp,
'''  if not (caps and caps.setInductorEngaged) then
    ctrl.inductor_engaged = true
    return false, "inductor-write-unavailable"
  end
''',
'''  if not (caps and caps.setInductorEngaged) then
    -- Do not mark the brake as engaged without a successful actuator write.
    return false, "inductor-write-unavailable"
  end
''')

# ---------------------------------------------------------------------------
# 3) ENERGY last-good values stay visible, but are explicitly stale until a
# successful read. MASTER must not drive auto-profile from stale-only ENERGY.
# ---------------------------------------------------------------------------
sp = 'xreactor/nodes/energy/storage_snapshot_runtime.lua'
replace_once(sp,
'''    local total, capacity, input, output = 0, 0, 0, 0
    local stores = {}
''',
'''    local total, capacity, input, output = 0, 0, 0, 0
    local stores = {}
    local any_stale = false
''')

replace_once(sp,
'''      if st.skip_remaining > 0 then
        st.skip_remaining = st.skip_remaining - 1
        stored, in_rate, out_rate = st.last_good.stored, st.last_good.input, st.last_good.output
        cap = st.cached_capacity
      else
''',
'''      if st.skip_remaining > 0 then
        st.skip_remaining = st.skip_remaining - 1
        stored, in_rate, out_rate = st.last_good.stored, st.last_good.input, st.last_good.output
        cap = st.cached_capacity
        -- Backoff means we are deliberately serving cached last-good values
        -- after repeated failures; those values must remain visibly stale.
        had_error = (st.fail_count or 0) > 0
      else
''')

replace_once(sp,
'''      total = total + stored
      capacity = capacity + cap
      input = input + in_rate
      output = output + out_rate
''',
'''      if had_error then any_stale = true end
      total = total + stored
      capacity = capacity + cap
      input = input + in_rate
      output = output + out_rate
''')

replace_once(sp,
'''    runtime.snapshot = {
      ts = ts or runtime.now_ms(),
      stale = false,
''',
'''    runtime.snapshot = {
      ts = ts or runtime.now_ms(),
      stale = any_stale,
''')

replace_once(sp,
'''      stale = (snapshot.ts or 0) <= 0 or (max_age_ms > 0 and age > max_age_ms)
''',
'''      stale = snapshot.stale == true or (snapshot.ts or 0) <= 0 or (max_age_ms > 0 and age > max_age_ms)
''')

hp = 'xreactor/shared/health_codes.lua'
replace_once(hp,
'''  PROTO_MISMATCH = "PROTO_MISMATCH",
  COMMS_DOWN = "COMMS_DOWN"
''',
'''  PROTO_MISMATCH = "PROTO_MISMATCH",
  COMMS_DOWN = "COMMS_DOWN",
  STALE_DATA = "STALE_DATA"
''')

statusp = 'xreactor/nodes/energy/status_payload.lua'
replace_once(statusp,
'''    energy.storage_snapshot_freshness_ms = energy.freshness_ms
    energy.storage_snapshot_stale = energy.stale == true
    energy.aggregate_stored = total_stored
''',
'''    energy.storage_snapshot_freshness_ms = energy.freshness_ms
    energy.storage_snapshot_stale = energy.stale == true
    energy.data_stale = (effective_storage_count > 0 and energy.storage_snapshot_stale)
      or (effective_matrix_count > 0 and energy.matrix_snapshot_stale)
    energy.aggregate_stored = total_stored
''')

replace_once(statusp,
'''    if runtime.devices.proto_mismatch then
      reasons[runtime.health.reasons.PROTO_MISMATCH] = true
      degrade_reasons[runtime.health.reasons.PROTO_MISMATCH] = true
    end
    if not runtime.is_master_connected() then
''',
'''    if runtime.devices.proto_mismatch then
      reasons[runtime.health.reasons.PROTO_MISMATCH] = true
      degrade_reasons[runtime.health.reasons.PROTO_MISMATCH] = true
    end
    if energy.data_stale then
      reasons[runtime.health.reasons.STALE_DATA] = true
      degrade_reasons[runtime.health.reasons.STALE_DATA] = true
    end
    if not runtime.is_master_connected() then
''')

mp = 'xreactor/master/runtime_ops_profile.lua'
replace_once(mp,
'''  local power, stored, capacity, water_total = 0, 0, 0, 0
  for _, node in pairs(runtime.state.nodes) do
''',
'''  local power, stored, capacity, water_total = 0, 0, 0, 0
  local seen_energy_nodes, fresh_energy_nodes = 0, 0
  for _, node in pairs(runtime.state.nodes) do
''')

replace_once(mp,
'''    elseif node.role == runtime.libs.constants.roles.ENERGY_NODE then
      stored = stored + (node.stored or 0)
      capacity = capacity + (node.capacity or 0)
''',
'''    elseif node.role == runtime.libs.constants.roles.ENERGY_NODE then
      seen_energy_nodes = seen_energy_nodes + 1
      if node.data_stale ~= true then
        fresh_energy_nodes = fresh_energy_nodes + 1
        stored = stored + (node.stored or 0)
        capacity = capacity + (node.capacity or 0)
      end
''')

replace_once(mp,
'''  runtime.refs.trends:push("water", water_total)
  if runtime.state.auto_profile then
''',
'''  runtime.refs.trends:push("water", water_total)
  local auto_profile_has_trustworthy_energy = not (seen_energy_nodes > 0 and fresh_energy_nodes == 0)
  if runtime.state.auto_profile and auto_profile_has_trustworthy_energy then
''')

# ---------------------------------------------------------------------------
# Regression tests.
# ---------------------------------------------------------------------------
write('tests/redstone_router_refresh_transaction_race_test.lua', r'''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local clock = 1000000
os.epoch = function() return clock end
local redstone_router = require('nodes.fuel.redstone_router')

local transmitted = {}
local modem = {
  isWireless = function() return true end,
  open = function() end,
  transmit = function(_, _, message) transmitted[#transmitted + 1] = message; return true end,
}
_G.peripheral = {
  find = function(kind) if kind == 'modem' then return modem end end,
  isPresent = function() return false end,
  wrap = function() return nil end,
}

local peers = { ['VALVE-A'] = { down = false, stale = false } }
local router = redstone_router.new({
  config = { logistics = { redstone_tree = {
    { side = 'top', integrator = 'VALVE-A', reactor = 'R1', label = 'R1' },
  } } },
  comms = { get_peers = function() return peers end },
  log = function() end,
  warn_once = function() end,
})
router:refresh()

local function ack_current(high)
  local key = 'VALVE-A|top'
  local entry = assert(router._state.pending_valve_acks[key], 'pending valve command required')
  router:handle_valve_ack({
    type = 'VALVE_ACK', command_id = entry.command_id,
    src = entry.dst, dst = entry.src, applied = true, high = high,
  })
end

local exported = false
assert(router:begin_transaction('R1', function() exported = true end, 500))
local tx = router._state.transaction
local ok_refresh, why = router:refresh()
assert(ok_refresh == false and why == 'busy', 'refresh must defer during active transaction')
assert(router._state.transaction == tx, 'refresh must not replace active transaction')
assert(router._state.refresh_deferred == true, 'deferred refresh marker required')

ack_current(true)
router:tick(clock)
assert(router._state.transaction.state == 'WAIT_OPEN_ACKS')
ack_current(false)
router:tick(clock)
assert(router._state.transaction.state == 'WAIT_SETTLE')

-- The valve was confirmed open, then disappeared before the physical export.
peers['VALVE-A'] = { down = true, stale = true }
clock = clock + 500
router:tick(clock)
assert(exported == false, 'export must not run after route peer becomes stale')
assert(router._state.transaction == nil, 'stale route must abort transaction')

-- Next idle tick applies the deferred discovery refresh safely.
router:tick(clock + 1)
assert(router._state.refresh_deferred == false, 'deferred refresh must be consumed after transaction')

print('redstone_router_refresh_transaction_race_test.lua: ok')
''')

write('tests/rt_inductor_confirmed_state_regression_test.lua', r'''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local turbine_control = require('nodes.rt.turbine_control')
local calls = 0
local fail_first = true
local turbine = {
  setInductorEngaged = function(value)
    calls = calls + 1
    if fail_first then fail_first = false; error('simulated actuator failure') end
    assert(value == true)
  end,
}
local ctx = {
  turbine_ctrl_store = {},
  config = { rails = { coil = { cooldown_s = 0, ema_alpha = 1, engage_rpm = 850, disengage_rpm = 750, overspeed_band = 20 } } },
  CONFIG = { TARGET_RPM = 900, COIL_ENGAGE_RPM = 850, COIL_DISENGAGE_RPM = 750 },
  rails = {
    new_state = function() return { last_change_ts = 0 } end,
    smooth = function(_, _, value) return value end,
  },
  safe_wrapped_call = function(obj, method, ...) return pcall(obj[method], ...) end,
  warn_once = function() end,
}
local caps = { setInductorEngaged = true, getInductorEngaged = false }

local ok1, applied1 = turbine_control.update_inductor_for_rpm(ctx, 'T1', turbine, caps, 950, 900)
assert(ok1 == false or applied1 == false, 'failed actuator write must be reported')
assert(turbine_control.get_turbine_ctrl(ctx, 'T1').inductor_engaged == false,
  'failed write must not be cached as confirmed engaged')

local ok2, applied2 = turbine_control.update_inductor_for_rpm(ctx, 'T1', turbine, caps, 950, 900)
assert(ok2 == true and applied2 == true, 'second control tick must retry actuator write')
assert(calls == 2, 'actuator must be retried after failure')
assert(turbine_control.get_turbine_ctrl(ctx, 'T1').inductor_engaged == true,
  'state becomes confirmed only after successful write')

local src = assert(io.open('xreactor/nodes/rt/turbine_control.lua', 'r')):read('*a')
assert(not src:find('if not %(caps and caps%.setInductorEngaged%) then%s+ctrl%.inductor_engaged = true'),
  'overspeed fallback must not fake a confirmed brake state')

print('rt_inductor_confirmed_state_regression_test.lua: ok')
''')

write('tests/energy_stale_last_good_regression_test.lua', r'''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local snapshot_runtime = require('nodes.energy.storage_snapshot_runtime')
local now = 1000
local failing = false
local adapter = {
  getStored = function() if failing then return nil, 'read failed' end return 100 end,
  getInput = function() if failing then return nil, 'read failed' end return 10 end,
  getOutput = function() if failing then return nil, 'read failed' end return 5 end,
  getCapacity = function() return 200 end,
}
local runtime = snapshot_runtime.new({
  now_ms = function() return now end,
  config = { capacity_interval_s = 5, status_interval = 5 },
  devices = { storages = { { id = 'S1', name = 'S1', adapter = adapter } } },
  utils = { deep_copy = function(v) return v end },
  record_error = function() end,
})

local good = runtime.sample_storage_stats(now)
assert(good.stale == false and good.total.stored == 100)
failing = true
for _ = 1, 4 do
  now = now + 100
  local stale = runtime.sample_storage_stats(now)
  assert(stale.total.stored == 100, 'last-good value should remain visible')
  assert(stale.stale == true, 'failed read must mark aggregate stale')
  assert(stale.stores[1].ok == false, 'failed store must be marked not ok')
end
now = now + 100
local backed_off = runtime.sample_storage_stats(now)
assert(backed_off.total.stored == 100, 'backoff keeps last-good value')
assert(backed_off.stale == true, 'backoff over failed device must remain stale')
assert(backed_off.stores[1].ok == false, 'backoff must not pretend the store recovered')
local reported = runtime.read_storage_stats({ max_age_ms = 10000 })
assert(reported.stale == true, 'read_storage_stats must propagate snapshot stale state')

local f = assert(io.open('xreactor/nodes/energy/status_payload.lua', 'r'))
local status_src = f:read('*a'); f:close()
assert(status_src:find('energy.data_stale', 1, true), 'ENERGY payload must publish data_stale')
assert(status_src:find('STALE_DATA', 1, true), 'ENERGY health must degrade on stale data')

print('energy_stale_last_good_regression_test.lua: ok')
''')

write('tests/master_auto_profile_stale_energy_guard_test.lua', r'''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
local ops = require('master.runtime_ops_profile')
local constants = require('shared.constants')
os.epoch = function() return 5000 end

local trend_values = {}
local trends = {}
function trends:push(name, value)
  trend_values[name] = trend_values[name] or {}
  trend_values[name][#trend_values[name] + 1] = value
  return false
end
function trends:values(name) return trend_values[name] or {} end

local runtime = {
  libs = {
    constants = constants,
    profiles = {
      BASELOAD = { target = 0.6, ramp = 'NORMAL' },
      PEAK = { target = 1.0, ramp = 'FAST' },
      IDLE = { target = 0.2, ramp = 'SLOW' },
    },
  },
  state = {
    last_trend_sample = 0,
    nodes = {
      E1 = { role = constants.roles.ENERGY_NODE, stored = 0, capacity = 1000, data_stale = true },
    },
    auto_profile = true,
    active_profile = 'BASELOAD',
    power_target = 600,
    trend_cache = {},
  },
  refs = { trends = trends, sequencer = { ramp_profile = 'NORMAL' } },
  config = {},
  log = function() end,
  mark_rt_sync_dirty = function() end,
  flush_rt_sync_queue = function() end,
}

ops.sample_trends(runtime)
assert(runtime.state.active_profile == 'BASELOAD',
  'stale-only ENERGY data must not force a profile transition')
assert(runtime.state.power_target == 600,
  'stale-only ENERGY data must not change the current power target')

print('master_auto_profile_stale_energy_guard_test.lua: ok')
''')

# ---------------------------------------------------------------------------
# Release v514 + manifest metadata sync, preserving comments and ordering.
# ---------------------------------------------------------------------------
release_path = ROOT / 'xreactor/release.lua'
release = release_path.read_text(encoding='utf-8')
release = re.sub(r'release_id = "beta-v\d+"', 'release_id = "beta-v514"', release, count=1)
release = re.sub(r'manifest_id = "manifest-v\d+"', 'manifest_id = "manifest-v514"', release, count=1)
release = re.sub(r'manifest_version = \d+', 'manifest_version = 514', release, count=1)
release_path.write_text(release, encoding='utf-8')

manifest_path = ROOT / 'xreactor/manifest.lua'
manifest = manifest_path.read_text(encoding='utf-8')
manifest = re.sub(r'(-- xreactor/manifest.lua -- manifest-v)\d+', r'\g<1>514', manifest, count=1)
manifest = re.sub(r'(\bmanifest_version\s*=\s*)\d+', r'\g<1>514', manifest, count=1)
manifest = re.sub(r'(\bmanifest_id\s*=\s*)"manifest-v\d+"', r'\g<1>"manifest-v514"', manifest, count=1)
path_re = re.compile(r'path\s*=\s*"([^"]+)"')
lines = []
for line in manifest.splitlines(True):
    m = path_re.search(line)
    if m:
        fp = ROOT / 'xreactor' / m.group(1)
        if fp.is_file():
            data = fp.read_bytes(); size = len(data); h = f'{zlib.crc32(data) & 0xffffffff:08x}'
            if re.search(r'\bsize_bytes\s*=', line):
                line = re.sub(r'(\bsize_bytes\s*=\s*)\d+', rf'\g<1>{size}', line, count=1)
            else:
                pos = m.end(); line = line[:pos] + f', size_bytes = {size}' + line[pos:]
            if re.search(r'\bhash\s*=', line):
                line = re.sub(r'(\bhash\s*=\s*)"[0-9a-fA-F]*"', rf'\g<1>"{h}"', line, count=1)
            else:
                sm = re.search(r'\bsize_bytes\s*=\s*\d+', line)
                line = line[:sm.end()] + f', hash = "{h}"' + line[sm.end():]
    lines.append(line)
manifest = ''.join(lines)
manifest_path.write_text(manifest, encoding='utf-8')

# release.lua changed after version bump; refresh its manifest entry last.
data = release_path.read_bytes(); size = len(data); h = f'{zlib.crc32(data) & 0xffffffff:08x}'
manifest = manifest_path.read_text(encoding='utf-8')
pat = r'(\{\s*path\s*=\s*"release\.lua"[^}\n]*\bsize_bytes\s*=\s*)\d+([^}\n]*\bhash\s*=\s*")[0-9a-fA-F]+(")'
manifest, n = re.subn(pat, rf'\g<1>{size}\g<2>{h}\g<3>', manifest, count=1)
if n != 1: raise SystemExit('release.lua manifest refresh failed')
manifest_path.write_text(manifest, encoding='utf-8')

if SELF.exists(): SELF.unlink()
