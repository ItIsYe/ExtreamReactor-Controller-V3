from pathlib import Path
import re
import zlib

ROOT = Path('.')

def read(path):
    return (ROOT / path).read_text(encoding='utf-8')

def write(path, content):
    (ROOT / path).write_text(content, encoding='utf-8')

def replace_once(path, old, new):
    content = read(path)
    count = content.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected exactly one anchor, found {count}: {old[:160]!r}')
    write(path, content.replace(old, new, 1))

def crc32(path):
    data = (ROOT / path).read_bytes()
    return len(data), f'{zlib.crc32(data) & 0xffffffff:08x}'

# ---------------------------------------------------------------------------
# 1) FUEL + REPROCESSOR: the shipped convention name "me_bridge" is a
# default, not a user-selected strict binding. If that conventional name is
# absent, allow the already-existing capability scan to find meBridge_0 etc.
# Truly custom explicit names remain strict/fail-visible.
# ---------------------------------------------------------------------------
replace_once(
    'xreactor/nodes/fuel/logistics_router.lua',
    '''  if peripheral.isPresent(bridge_name) then\n    bridge_found_name = bridge_name\n  elseif not cfg.me_bridge then\n    -- Nur automatisch per Methodensignatur suchen, wenn KEIN expliziter\n    -- Name konfiguriert ist -- ein manuell gesetzter, aber (noch) nicht\n    -- angeschlossener Name soll weiterhin klar als "absent" gemeldet\n    -- werden, statt stillschweigend eine andere ME Bridge zu binden.\n    bridge_found_name = find_me_bridge_by_methods()\n  end\n''',
    '''  if peripheral.isPresent(bridge_name) then\n    bridge_found_name = bridge_name\n  elseif cfg.me_bridge == nil or cfg.me_bridge == ""\n      or cfg.me_bridge == "me_bridge" or cfg.me_bridge == "meBridge" then\n    -- "me_bridge"/"meBridge" are shipped convention defaults, not proof of\n    -- an intentional strict peripheral binding. Advanced Peripherals normally\n    -- exposes generated names such as meBridge_0, so fall back to the method\n    -- signature for those default values. A genuinely custom configured name\n    -- remains strict and is never silently replaced by another bridge.\n    bridge_found_name = find_me_bridge_by_methods()\n  end\n''')

replace_once(
    'xreactor/nodes/reprocessor/feed_router.lua',
    '''  if peripheral.isPresent(name) then\n    found_name = name\n  elseif not cfg.me_bridge then\n    found_name = find_me_bridge_by_methods()\n  end\n''',
    '''  if peripheral.isPresent(name) then\n    found_name = name\n  elseif cfg.me_bridge == nil or cfg.me_bridge == ""\n      or cfg.me_bridge == "me_bridge" or cfg.me_bridge == "meBridge" then\n    -- Shipped convention defaults are eligible for capability fallback; only\n    -- genuinely custom names are strict bindings.\n    found_name = find_me_bridge_by_methods()\n  end\n''')

# Extend the existing FUEL regression with the real shipped-default scenario.
p = 'tests/fuel_logistics_me_bridge_discovery_by_methods_test.lua'
s = read(p)
anchor = '''-- 2. Der konfigurierte Default-Name "me_bridge" ist direkt vorhanden --\n--    weiterhin der bevorzugte, schnelle Pfad (kein Scan noetig).\ndo\n'''
insert = '''-- 2. Der AUSGELIEFERTE Config-Default setzt me_bridge="me_bridge". Wenn\n--    genau dieser Konventionsname nicht existiert, muss trotzdem meBridge_0\n--    per Methodensignatur gefunden werden; sonst blockiert der Default selbst\n--    den Autodiscovery-Fallback.\ndo\n  set_peripheral_mock({\n    ["meBridge_0"] = { getItem = true, exportItemToPeripheral = true, importItemFromPeripheral = true },\n  }, {})\n\n  local router = logistics_router.new({ config = { logistics = { enabled = true, reactors = {}, me_bridge = "me_bridge" } } })\n  router:refresh_peripherals()\n\n  assert_true(router._state.bridge ~= nil, 'shipped me_bridge default must still allow method-signature fallback')\n  assert_eq(router._state.bridge.name, 'meBridge_0', 'default fallback should bind the actual generated peripheral name')\nend\n\n-- 3. Der konfigurierte Default-Name "me_bridge" ist direkt vorhanden --\n--    weiterhin der bevorzugte, schnelle Pfad (kein Scan noetig).\ndo\n'''
if s.count(anchor) != 1:
    raise SystemExit('fuel ME bridge test anchor drifted')
s = s.replace(anchor, insert, 1)
s = s.replace('-- 3. Ein EXPLIZIT konfigurierter me_bridge-Name', '-- 4. Ein EXPLIZIT konfigurierter me_bridge-Name', 1)
s = s.replace('-- 4. Kein passendes Peripheral im Netzwerk', '-- 5. Kein passendes Peripheral im Netzwerk', 1)
write(p, s)

write('tests/reprocessor_me_bridge_default_fallback_test.lua', '''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')\nlocal feed_router = require('nodes.reprocessor.feed_router')\n\nlocal bridge = {\n  getItem = function() return { amount = 0 } end,\n  exportItemToPeripheral = function() return 0 end,\n}\n_G.peripheral = {\n  getNames = function() return { 'meBridge_0' } end,\n  getMethods = function(name)\n    if name == 'meBridge_0' then return { 'getItem', 'exportItemToPeripheral' } end\n    return {}\n  end,\n  isPresent = function() return false end,\n  wrap = function(name) return name == 'meBridge_0' and bridge or nil end,\n}\nlocal rs = { refresh = function() end, tick = function() end }\nlocal router = feed_router.new({\n  config = { feed = { enabled = true, me_bridge = 'me_bridge', targets = {} } },\n  rs_router = rs,\n})\nrouter:refresh_peripherals()\nassert(router._state.bridge == bridge, 'shipped me_bridge default must fall back to generated ME bridge names')\nassert(router._state.bridge_name == 'meBridge_0', 'actual generated bridge name must be reported')\n\n-- A genuinely custom explicit name must remain strict.\nlocal strict = feed_router.new({\n  config = { feed = { enabled = true, me_bridge = 'plant_bridge', targets = {} } },\n  rs_router = rs,\n})\nstrict:refresh_peripherals()\nassert(strict._state.bridge == nil, 'custom missing bridge name must not silently bind a different bridge')\nprint('reprocessor_me_bridge_default_fallback_test.lua: ok')\n''')

# ---------------------------------------------------------------------------
# 2) Protocol fail-closed: invalid/missing protocol versions no longer inherit
# the current version, and reliable control messages must carry identifiers.
# Protocol constructors now also generate their own stable message IDs so a
# direct protocol.* caller produces a valid envelope.
# ---------------------------------------------------------------------------
replace_once('xreactor/core/protocol.lua', 'local protocol = {}\n', 'local protocol = {}\nlocal protocol_sequence = 0\n')
replace_once(
    'xreactor/core/protocol.lua',
    '''  return { major = constants.proto_ver.major, minor = constants.proto_ver.minor }\nend\n\nlocal function is_proto_compatible(ver)\n  local current = normalize_proto(constants.proto_ver)\n  local incoming = normalize_proto(ver)\n  if incoming.major ~= current.major then\n    return false, "proto_ver mismatch"\n  end\n  return true\nend\n''',
    '''  return nil\nend\n\nlocal function is_proto_compatible(ver)\n  local current = normalize_proto(constants.proto_ver)\n  local incoming = normalize_proto(ver)\n  if not incoming then\n    return false, "missing/invalid proto_ver"\n  end\n  if incoming.major ~= current.major then\n    return false, "proto_ver mismatch"\n  end\n  return true\nend\n''')
replace_once(
    'xreactor/core/protocol.lua',
    '''local function base_message(msg_type, sender_id, role, payload)\n  local ts = os.epoch("utc")\n  return {\n    type = msg_type,\n    message_id = nil,\n    sender_id = utils.normalize_node_id(sender_id),\n    src = utils.normalize_node_id(sender_id),\n    dst = nil,\n    node_id = utils.normalize_node_id(sender_id),\n''',
    '''local function base_message(msg_type, sender_id, role, payload)\n  local ts = os.epoch("utc")\n  local normalized_sender = utils.normalize_node_id(sender_id)\n  protocol_sequence = protocol_sequence + 1\n  return {\n    type = msg_type,\n    message_id = string.format("%s-%d-%d", tostring(normalized_sender), ts, protocol_sequence),\n    sender_id = normalized_sender,\n    src = normalized_sender,\n    dst = nil,\n    node_id = normalized_sender,\n''')
replace_once(
    'xreactor/core/protocol.lua',
    '''  if type(message.payload) ~= "table" then return false, "missing payload" end\n  local ok, err = is_proto_compatible(message.proto_ver)\n''',
    '''  if type(message.payload) ~= "table" then return false, "missing payload" end\n  if message.type == constants.message_types.COMMAND then\n    if type(message.message_id) ~= "string" or message.message_id == "" then\n      return false, "missing message_id"\n    end\n  elseif message.type == constants.message_types.ACK_DELIVERED\n      or message.type == constants.message_types.ACK_APPLIED then\n    if type(message.message_id) ~= "string" or message.message_id == "" then\n      return false, "missing message_id"\n    end\n    if type(message.ack_for) ~= "string" or message.ack_for == "" then\n      return false, "missing ack_for"\n    end\n  end\n  local ok, err = is_proto_compatible(message.proto_ver)\n''')

write('tests/protocol_fail_closed_validation_test.lua', '''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')\nlocal constants = require('shared.constants')\nlocal protocol = require('core.protocol')\n\nlocal function base(t)\n  return {\n    type = t, message_id = 'm-1', sender_id = 'RT-1', src = 'RT-1', role = 'RT-NODE',\n    ts = os.epoch('utc'), proto_ver = constants.proto_ver, payload = {},\n  }\nend\n\nlocal missing_proto = base(constants.message_types.STATUS); missing_proto.proto_ver = nil\nlocal ok, err = protocol.validate(missing_proto)\nassert(ok == false and err == 'missing/invalid proto_ver', 'missing proto version must fail closed')\n\nlocal invalid_proto = base(constants.message_types.STATUS); invalid_proto.proto_ver = 'garbage'\nok, err = protocol.validate(invalid_proto)\nassert(ok == false and err == 'missing/invalid proto_ver', 'invalid proto version must fail closed')\n\nlocal cmd = base(constants.message_types.COMMAND); cmd.message_id = nil\nok, err = protocol.validate(cmd)\nassert(ok == false and err == 'missing message_id', 'COMMAND without message_id must be rejected')\n\nlocal ack = base(constants.message_types.ACK_APPLIED); ack.ack_for = nil\nok, err = protocol.validate(ack)\nassert(ok == false and err == 'missing ack_for', 'reliable ACK without ack_for must be rejected')\n\nlocal built = protocol.command('MASTER-1', 'MASTER', 'RT-1', { target = 'SET_MODE', value = 'AUTO' })\nassert(type(built.message_id) == 'string' and built.message_id ~= '', 'protocol constructors must emit message IDs')\nok, err = protocol.validate(built)\nassert(ok == true, 'protocol.command envelope should validate: ' .. tostring(err))\nprint('protocol_fail_closed_validation_test.lua: ok')\n''')

# ---------------------------------------------------------------------------
# 3) RT capacity topology generations. A learned maximum belongs to one exact
# set of bound turbines. Any add/remove/rename invalidates the old maximum so
# a smaller permanent topology can be learned instead of retaining a stale
# historical peak forever.
# ---------------------------------------------------------------------------
replace_once(
    'xreactor/nodes/rt/capacity_learning.lua',
    '''-- Leerer Initialzustand.\nfunction M.new_state()\n  return { ready = false, max_output = 0, at_target = 0, total_turbines = 0, reason = "INIT" }\nend\n''',
    '''local function topology_signature(turbines)\n  local ids = {}\n  for index, turbine in ipairs(type(turbines) == "table" and turbines or {}) do\n    ids[#ids + 1] = tostring(turbine.id or turbine.name or ("#" .. tostring(index)))\n  end\n  table.sort(ids)\n  return table.concat(ids, "|")\nend\n\n-- Leerer Initialzustand.\nfunction M.new_state()\n  return {\n    ready = false, max_output = 0, at_target = 0, total_turbines = 0, reason = "INIT",\n    topology_signature = nil, topology_generation = 0, topology_changed_at = nil,\n  }\nend\n''')
replace_once(
    'xreactor/nodes/rt/capacity_learning.lua',
    '''  local learning = ctx.capacity_learning\n  local log = type(ctx.log) == "function" and ctx.log or function() end\n\n  local measured, at_target, total = measure(turbines)\n''',
    '''  local learning = ctx.capacity_learning\n  local log = type(ctx.log) == "function" and ctx.log or function() end\n\n  local signature = topology_signature(turbines)\n  if learning.topology_signature ~= signature then\n    local had_learned_value = learning.ready == true or (tonumber(learning.max_output) or 0) > 0\n    local previous = learning.topology_signature\n    learning.topology_signature = signature\n    learning.topology_generation = (tonumber(learning.topology_generation) or 0) + 1\n    learning.topology_changed_at = os and os.epoch and os.epoch("utc") or nil\n    if previous ~= nil or had_learned_value then\n      learning.ready = false\n      learning.max_output = 0\n      learning.reason = "TOPOLOGY_CHANGED"\n      pcall(log, "WARN", string.format(\n        "RT capacity topology changed generation=%d old=%s new=%s; learned maximum invalidated",\n        learning.topology_generation, tostring(previous), tostring(signature)))\n    else\n      learning.reason = "TOPOLOGY_INIT"\n    end\n  end\n\n  local measured, at_target, total = measure(turbines)\n''')
replace_once(
    'xreactor/nodes/rt/status_snapshot.lua',
    '''    capacity_sample_output = capacity_max,\n    turbine_rpm = ctx.targets.rpm,\n''',
    '''    capacity_sample_output = capacity_max,\n    capacity_topology_generation = capacity and capacity.topology_generation or 0,\n    capacity_topology_signature = capacity and capacity.topology_signature or nil,\n    capacity_topology_changed_at = capacity and capacity.topology_changed_at or nil,\n    turbine_rpm = ctx.targets.rpm,\n''')

write('tests/rt_capacity_topology_invalidation_test.lua', '''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')\nlocal learning = require('nodes.rt.capacity_learning')\nlocal ctx = { capacity_learning = learning.new_state(), log = function() end }\nlocal function turbine(id, energy)\n  return { id = id, name = id, rpm = 900, energy = energy, coil_engaged = true }\nend\n\nlocal first = learning.update(ctx, { turbine('T1', 100), turbine('T2', 100) })\nassert(first.ready == true and first.max_output == 200, 'initial topology should learn 200 output')\nlocal generation = first.topology_generation\n\n-- One turbine disappears permanently. The old 200 value must not survive; the\n-- new one-turbine topology is measured independently as 100.\nlocal second = learning.update(ctx, { turbine('T1', 100) })\nassert(second.topology_generation == generation + 1, 'topology generation must increment after removal')\nassert(second.topology_signature == 'T1', 'new topology signature must reflect the remaining turbine')\nassert(second.ready == true and second.max_output == 100, 'removed turbine must invalidate the stale historical peak')\n\n-- A non-topology performance dip must keep the existing learned maximum.\nlocal third = learning.update(ctx, { turbine('T1', 80) })\nassert(third.topology_generation == second.topology_generation, 'same topology must not create a new generation')\nassert(third.max_output == 100, 'transient lower output on same topology must not reduce learned maximum')\nprint('rt_capacity_topology_invalidation_test.lua: ok')\n''')

# ---------------------------------------------------------------------------
# 4) Shared UI Window backbuffer. Physical monitors are wrapped once and the
# entire frame (page + footer/error fallback) is rendered while hidden. Actual
# Window targets, including FUEL's existing buffer, are left alone to avoid
# double buffering or touching setVisible in the shared router.
# ---------------------------------------------------------------------------
replace_once(
    'xreactor/core/ui_router.lua',
    '''local function build_snapshot(page_name, model)\n''',
    '''local function prepare_render_target(self, mon, width, height)\n  -- Existing Window targets (notably FUEL) own their visibility lifecycle.\n  -- Physical CC:Tweaked monitors do not expose setVisible().\n  if type(mon) ~= "table" or type(mon.setVisible) == "function" then\n    return mon, false, false\n  end\n  if type(window) ~= "table" or type(window.create) ~= "function"\n      or type(width) ~= "number" or type(height) ~= "number"\n      or width < 1 or height < 1 then\n    self.shared_backbuffer = nil\n    return mon, false, false\n  end\n\n  local cached = self.shared_backbuffer\n  local created = false\n  if not cached or cached.parent ~= mon or cached.width ~= width or cached.height ~= height\n      or type(cached.target) ~= "table" then\n    local ok, target = pcall(window.create, mon, 1, 1, width, height, false)\n    if not ok or not target then\n      self.shared_backbuffer = nil\n      return mon, false, false\n    end\n    cached = { parent = mon, width = width, height = height, target = target }\n    self.shared_backbuffer = cached\n    created = true\n    ui.invalidate(target)\n  end\n  pcall(cached.target.setVisible, false)\n  return cached.target, true, created\nend\n\nlocal function publish_render_target(target, buffered)\n  if not buffered or not target then return end\n  pcall(target.setVisible, true)\n  if type(target.redraw) == "function" then pcall(target.redraw) end\nend\n\nlocal function build_snapshot(page_name, model)\n''')
replace_once('xreactor/core/ui_router.lua', '    last_render_scale = nil,\n', '    last_render_scale = nil,\n    shared_backbuffer = nil,\n')
replace_once(
    'xreactor/core/ui_router.lua',
    '''    self.list_controls = nil\n    self.last_render_mon = nil\n    return\n  end\n  ui.begin_frame(mon)\n  -- Visibility buffering deliberately does not belong in the shared router.\n  -- A physical CC:Tweaked monitor has no setVisible() method. Roles that need\n  -- buffering must provide an actual Window target and own its lifecycle\n  -- outside this renderer (FUEL does this in nodes/fuel/monitor_ui.lua).\n''',
    '''    self.list_controls = nil\n    self.last_render_mon = nil\n    self.shared_backbuffer = nil\n    return\n  end\n  -- Shared physical-monitor buffering is established only after transition\n  -- detection below. Existing Window targets are deliberately not wrapped.\n''')
replace_once(
    'xreactor/core/ui_router.lua',
    '''    self.ui_diag.full_clears = self.ui_diag.full_clears + 1\n  end\n\n  -- Feature (2026-07-11): UI-P1.1. Ein Fehler in page.render() wurde\n''',
    '''    self.ui_diag.full_clears = self.ui_diag.full_clears + 1\n  end\n\n  local render_target, buffered, buffer_created = prepare_render_target(self, mon, cur_w, cur_h)\n  if buffer_created and not should_clear then\n    -- A newly-created hidden window starts without a trustworthy frame even if\n    -- the physical monitor/model itself did not transition. Force one complete\n    -- render into the new buffer before publishing it.\n    should_clear = true\n    self.ui_diag.full_clears = self.ui_diag.full_clears + 1\n  end\n  mon = render_target\n  ui.begin_frame(mon)\n\n  -- Feature (2026-07-11): UI-P1.1. Ein Fehler in page.render() wurde\n''')
replace_once(
    'xreactor/core/ui_router.lua',
    '''  local w, h = ui.getSize(mon)\n  if not w or not h then\n    return\n  end\n''',
    '''  local w, h = ui.getSize(mon)\n  if not w or not h then\n    publish_render_target(mon, buffered)\n    return\n  end\n''')
replace_once(
    'xreactor/core/ui_router.lua',
    '''    self.footer.next = { x1 = page_footer.right.x1, x2 = page_footer.right.x2, y = page_footer.right.y }\n    self.footer.indicator = nil\n    return\n  end\n''',
    '''    self.footer.next = { x1 = page_footer.right.x1, x2 = page_footer.right.x2, y = page_footer.right.y }\n    self.footer.indicator = nil\n    publish_render_target(mon, buffered)\n    return\n  end\n''')
replace_once(
    'xreactor/core/ui_router.lua',
    '''  self.footer.next = { x1 = start + #indicator - 1, x2 = start + #indicator - 1, y = h }\n  self.footer.indicator = { x1 = start, x2 = start + #indicator, y = h }\nend\n\nreturn router\n''',
    '''  self.footer.next = { x1 = start + #indicator - 1, x2 = start + #indicator - 1, y = h }\n  self.footer.indicator = { x1 = start, x2 = start + #indicator, y = h }\n  publish_render_target(mon, buffered)\nend\n\nreturn router\n''')

write('tests/ui_router_shared_window_backbuffer_test.lua', '''package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')\nlocal created = 0\nlocal visible_calls = {}\nlocal redraws = 0\nlocal last_window\n\npackage.loaded['shared.colors'] = { get = function() return 1 end }\npackage.loaded['core.ui'] = {\n  invalidate = function() end,\n  begin_frame = function() end,\n  getSize = function(mon) return mon.getSize() end,\n  clear = function(mon) assert(mon == last_window, 'clear must target hidden Window, not physical monitor') end,\n  text = function() end,\n  rightText = function(mon) assert(mon == last_window, 'footer must render into the Window') end,\n}\npackage.loaded['core.ui_router'] = nil\n_G.window = {\n  create = function(parent, x, y, w, h, visible)\n    created = created + 1\n    assert(visible == false, 'shared backbuffer must be created hidden')\n    local win = {\n      getSize = function() return w, h end,\n      getTextScale = function() return 1 end,\n      setVisible = function(value) visible_calls[#visible_calls + 1] = value end,\n      redraw = function() redraws = redraws + 1 end,\n    }\n    last_window = win\n    return win\n  end,\n}\n\nlocal router = require('core.ui_router')\nlocal physical = {\n  getSize = function() return 30, 12 end,\n  getTextScale = function() return 1 end,\n}\nlocal renders = 0\nlocal r = router.new({ pages = { { name = 'A', render = function(mon, model, should_clear)\n  renders = renders + 1\n  assert(mon == last_window, 'page must render into shared hidden Window')\n  if should_clear then package.loaded['core.ui'].clear(mon) end\nend } } })\n\nr:render(physical, { snapshot = 'one' })\nassert(created == 1 and renders == 1, 'first frame must create one reusable Window')\nassert(visible_calls[1] == false and visible_calls[2] == true, 'frame must hide then publish Window')\nassert(redraws == 1, 'published Window should redraw once')\n\nr:render(physical, { snapshot = 'two' })\nassert(created == 1 and renders == 2, 'normal update must reuse existing Window')\nassert(visible_calls[3] == false and visible_calls[4] == true, 'reused Window must still hide/publish atomically')\nassert(redraws == 2, 'second committed frame should publish once')\n\n-- Existing Window target (FUEL) must not be double-buffered or have its\n-- visibility lifecycle touched by the shared router.\nlocal external_visibility = 0\nlocal external = {\n  getSize = function() return 30, 12 end,\n  getTextScale = function() return 1 end,\n  setVisible = function() external_visibility = external_visibility + 1 end,\n}\nlocal r2 = router.new({ pages = { { name = 'B', render = function(mon) assert(mon == external) end } } })\nr2:render(external, { snapshot = 'fuel-window' })\nassert(created == 1, 'existing Window must not be wrapped again')\nassert(external_visibility == 0, 'shared router must not own visibility of an existing Window target')\nprint('ui_router_shared_window_backbuffer_test.lua: ok')\n''')

# ---------------------------------------------------------------------------
# Release/manifest v520. No new runtime file is added, so file_count remains
# unchanged; only hashes/sizes for edited runtime files and release.lua move.
# ---------------------------------------------------------------------------
release_path = 'xreactor/release.lua'
release = read(release_path)
release = release.replace('release_id = "beta-v519"', 'release_id = "beta-v520"')
release = release.replace('manifest_id = "manifest-v519"', 'manifest_id = "manifest-v520"')
release = release.replace('manifest_version = 519', 'manifest_version = 520')
if release == read(release_path):
    raise SystemExit('release v519 anchors missing')
write(release_path, release)

manifest_path = 'xreactor/manifest.lua'
manifest = read(manifest_path)
manifest = manifest.replace('-- xreactor/manifest.lua -- manifest-v519', '-- xreactor/manifest.lua -- manifest-v520', 1)
manifest = manifest.replace('manifest_version = 519', 'manifest_version = 520', 1)
manifest = manifest.replace('manifest_id = "manifest-v519"', 'manifest_id = "manifest-v520"', 1)

def sync_entry(text, rel):
    size, digest = crc32('xreactor/' + rel)
    lines = text.splitlines(True)
    matches = 0
    for i, line in enumerate(lines):
        if f'path = "{rel}"' in line:
            matches += 1
            line = re.sub(r'size_bytes\s*=\s*\d+', f'size_bytes = {size}', line)
            line = re.sub(r'hash\s*=\s*"[0-9a-fA-F]+"', f'hash = "{digest}"', line)
            lines[i] = line
    if matches != 1:
        raise SystemExit(f'manifest entry {rel}: expected 1, found {matches}')
    return ''.join(lines)

for rel in [
    'release.lua',
    'core/protocol.lua',
    'core/ui_router.lua',
    'nodes/fuel/logistics_router.lua',
    'nodes/reprocessor/feed_router.lua',
    'nodes/rt/capacity_learning.lua',
    'nodes/rt/status_snapshot.lua',
]:
    manifest = sync_entry(manifest, rel)
write(manifest_path, manifest)

print('phase7 patch applied')
