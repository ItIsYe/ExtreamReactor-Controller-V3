from pathlib import Path
import re, zlib

ROOT = Path(".")
WORKFLOW = ROOT / ".github/workflows/audit-fix-patcher.yml"
SCRIPT_SELF = ROOT / ".github/audit_fix.py"

def read(path):
    return (ROOT / path).read_text(encoding="utf-8")

def write(path, text):
    (ROOT / path).write_text(text, encoding="utf-8")

def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one occurrence, got {count}: {old[:80]!r}")
    write(path, text.replace(old, new, 1))

# 1) Shared utils must expose public helpers immediately after require().
utils_path = "xreactor/core/utils.lua"
old_utils = '''function utils.init_role_logger(role, node_id, opts)
  opts = opts or {}
  opts.prefix = role or opts.prefix
  opts.node_id = node_id or opts.node_id
  opts.log_name = opts.log_name or utils.build_log_name(role, node_id)
  -- Fix P4: number_or_nil zentral in utils -- war 3x dupliziert in
-- message_handlers.lua, rt_sync.lua (als number_or), command_handler.lua
function utils.number_or_nil(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then
    local n = tonumber(value)
    if n then return n end
  end
  return nil
end

-- Fix P3: payload_looks_rt war in message_handlers.lua UND rt_sync_coalescer.lua
-- dupliziert (leicht divergiert). Kanonische Version hier mit allen Bedingungen.
function utils.payload_looks_rt(payload)
  if type(payload) ~= "table" then return false end
  if type(payload.rt) == "table" then return true end
  if type(payload.turbines) == "table" or type(payload.reactors) == "table" or type(payload.modules) == "table" then return true end
  if payload.turbine_rpm ~= nil or payload.steam ~= nil or payload.ramp_state ~= nil then return true end
  -- message_handlers-Variante: mode+output+capabilities/bindings
  if payload.mode ~= nil and (payload.output ~= nil or payload.state ~= nil)
      and (payload.capabilities ~= nil or payload.bindings ~= nil) then return true end
  return false
end

return utils.init_logger(opts)
end
'''
new_utils = '''-- Public helpers must exist directly after require("core.utils"). They must
-- not depend on init_role_logger() having been called first.
function utils.number_or_nil(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then
    local n = tonumber(value)
    if n then return n end
  end
  return nil
end

function utils.payload_looks_rt(payload)
  if type(payload) ~= "table" then return false end
  if type(payload.rt) == "table" then return true end
  if type(payload.turbines) == "table" or type(payload.reactors) == "table" or type(payload.modules) == "table" then return true end
  if payload.turbine_rpm ~= nil or payload.steam ~= nil or payload.ramp_state ~= nil then return true end
  if payload.mode ~= nil and (payload.output ~= nil or payload.state ~= nil)
      and (payload.capabilities ~= nil or payload.bindings ~= nil) then return true end
  return false
end

function utils.init_role_logger(role, node_id, opts)
  opts = opts or {}
  opts.prefix = role or opts.prefix
  opts.node_id = node_id or opts.node_id
  opts.log_name = opts.log_name or utils.build_log_name(role, node_id)
  return utils.init_logger(opts)
end
'''
replace_once(utils_path, old_utils, new_utils)

# 2) Generic comms ACKs must match original target and this node.
comms_path = "xreactor/core/comms.lua"
old_ack = '''local function handle_ack(message)
  local ack_for = message.ack_for
  if not ack_for then return end
  local entry = state.inflight[ack_for]
  if not entry then return end
  if message.type == constants.message_types.ACK_DELIVERED then
'''
new_ack = '''local function handle_ack(message)
  local ack_for = message.ack_for
  if not ack_for then return end
  local entry = state.inflight[ack_for]
  if not entry then return end

  -- ACK identity is part of the delivery proof. A matching ack_for alone is
  -- insufficient: another peer must never be able to complete this inflight
  -- command. Broadcast messages have no unique expected source, so source
  -- matching is only enforceable for addressed messages.
  local expected_src = entry.message and entry.message.dst or nil
  local actual_src = message.src or message.sender_id
  if expected_src ~= nil
      and utils.normalize_node_id(actual_src) ~= utils.normalize_node_id(expected_src) then
    log(("Ignoring ACK %s from unexpected source %s (expected %s)"):format(
      tostring(ack_for), tostring(actual_src), tostring(expected_src)), "WARN")
    return
  end
  if message.dst ~= nil
      and utils.normalize_node_id(message.dst) ~= utils.normalize_node_id(state.node_id) then
    log(("Ignoring ACK %s addressed to %s (local %s)"):format(
      tostring(ack_for), tostring(message.dst), tostring(state.node_id)), "WARN")
    return
  end

  if message.type == constants.message_types.ACK_DELIVERED then
'''
replace_once(comms_path, old_ack, new_ack)

# 3) Installer recovery.
init_path = "xreactor/installer/init.lua"
marker = '''local function backup_config_dir()
  local files_map = {}
  if not fs.exists(CONFIG_DIR) then return files_map end
  for _, rel in ipairs(list_files_recursive(CONFIG_DIR)) do
    if not config_restore_denied(rel) then
      local f = fs.open(CONFIG_DIR .. "/" .. rel, "r")
      if f then
        files_map[rel] = f.readAll()
        f.close()
      end
    end
  end
  return files_map
end
'''
addition = marker + '''
local function load_recovery_config_backup()
  if not fs.exists(RECOVERY_CONFIG_BACKUP) then return nil, "missing" end
  local src = stage_mod.read(RECOVERY_CONFIG_BACKUP)
  if type(src) ~= "string" or src == "" then return nil, "unreadable" end
  local loader, lerr = load(src, "=config_backup", "t", {})
  if not loader then return nil, "parse: " .. tostring(lerr) end
  local ok, result = pcall(loader)
  if not ok or type(result) ~= "table" then
    return nil, "invalid: " .. tostring(result)
  end
  return result
end
'''
replace_once(init_path, marker, addition)

old_select = '''local config_backup = backup_config_dir()
do
  local backup_count = 0
'''
new_select = '''local config_backup
local using_existing_recovery_backup = false
do
  local status = nil
  if type(journal_mod.classify) == "function" then
    local ok_status, classified = pcall(function()
      return select(1, journal_mod.classify())
    end)
    if ok_status then status = classified end
  end

  if status == journal_mod.STATUS.VALID_INCOMPLETE then
    local recovered, rerr = load_recovery_config_backup()
    if not recovered then
      error("Vorherige Installation ist unvollstaendig, aber das originale Config-Recovery-Backup ist nicht lesbar (" ..
        tostring(rerr) .. "). Abbruch bevor Daten erneut geloescht werden.", 0)
    end
    config_backup = recovered
    using_existing_recovery_backup = true
    p("Unvollstaendige vorherige Installation erkannt: verwende unveraendert das bestehende Recovery-Backup.")
  else
    config_backup = backup_config_dir()
  end
end

do
  local backup_count = 0
'''
replace_once(init_path, old_select, new_select)

old_backup_if = '''  if backup_count > 0 then
    pcall(fs.makeDir, RECOVERY_DIR)
    local serialized = serialize_config_backup(config_backup)
    local ok_bak, bak_err = stage_mod.write(RECOVERY_CONFIG_BACKUP, serialized)
'''
new_backup_if = '''  if backup_count > 0 and not using_existing_recovery_backup then
    pcall(fs.makeDir, RECOVERY_DIR)
    local serialized = serialize_config_backup(config_backup)
    local ok_bak, bak_err = stage_mod.write(RECOVERY_CONFIG_BACKUP, serialized)
'''
replace_once(init_path, old_backup_if, new_backup_if)

old_restore_tail = '''  if #failed > 0 then
    p("WARN: Config-Wiederherstellung unvollstaendig: " .. table.concat(failed, ", "))
    p("WARN: Recovery-Backup bleibt erhalten: " .. RECOVERY_CONFIG_BACKUP)
  else
    pcall(fs.delete, RECOVERY_CONFIG_BACKUP)
  end
end
'''
new_restore_tail = '''  if #failed > 0 then
    p("WARN: Config-Wiederherstellung unvollstaendig: " .. table.concat(failed, ", "))
    p("WARN: Recovery-Backup bleibt erhalten: " .. RECOVERY_CONFIG_BACKUP)
    error("Config-Wiederherstellung unvollstaendig -- Installation wird NICHT als COMMITTED markiert.", 0)
  else
    pcall(fs.delete, RECOVERY_CONFIG_BACKUP)
  end
end
'''
replace_once(init_path, old_restore_tail, new_restore_tail)

# 4) Root bootstrap needs immutable SHA.
bootstrap_path = "installer"
old_sha = '''-- SHA aufloesen
local sha = nil
local ok_sha, r_sha = pcall(http.get, GITHUB_API)
if ok_sha and r_sha then
  local ok2, body = pcall(r_sha.readAll); pcall(r_sha.close)
  if ok2 and type(body) == "string" then
    sha = body:match('\"sha\"%s*:%s*\"(%x+)\"')
  end
end
p(sha and ("SHA: " .. sha:sub(1, 12)) or "WARN: SHA nicht aufloesbar")

-- Fix (2026-07-16): CRITICAL. INSTALL-P0 aus docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md (Abschnitt 14). EIN einziger Referenzpunkt
-- ("ref": entweder die aufgeloeste SHA, oder bei Aufloesungsfehler
-- explizit "beta") fuer den GESAMTEN Lauf -- sowohl fuer die hier
-- heruntergeladenen Installermodule als auch (via deps.ref) fuer
-- installer/init.lua's eigenen Download aller uebrigen Dateien.
local ref = sha or "beta"
'''
new_sha = '''-- SHA aufloesen. Ohne unveraenderlichen Commit-Ref wird NICHT auf den
-- beweglichen beta-Branch zurueckgefallen: sonst koennen Installermodule
-- und Nutzdateien innerhalb desselben Laufs aus verschiedenen Commits stammen.
local sha = nil
for attempt = 1, 4 do
  local ok_sha, r_sha = pcall(http.get, GITHUB_API)
  if ok_sha and r_sha then
    local ok2, body = pcall(r_sha.readAll); pcall(r_sha.close)
    if ok2 and type(body) == "string" then
      sha = body:match('\"sha\"%s*:%s*\"(%x+)\"')
      if sha then break end
    end
  end
  if attempt < 4 then
    p("  Branch-SHA nicht aufloesbar, erneut in " .. (attempt * 2) .. "s ...")
    os.sleep(attempt * 2)
  end
end
if not sha then
  error("GitHub Branch-SHA konnte nicht aufgeloest werden. Installation aus Sicherheitsgruenden abgebrochen; bitte spaeter erneut versuchen.", 0)
end
p("SHA: " .. sha:sub(1, 12))

-- Der gesamte Lauf ist an exakt diesen Commit gebunden.
local ref = sha
'''
replace_once(bootstrap_path, old_sha, new_sha)

# 5) Remote update handling.
remote_path = "xreactor/core/remote_update.lua"
old_cmd_token = '''local function command_token(opts)
  local message = opts and opts.message or nil
  local payload = type(message) == "table" and message.payload or nil
  local command = type(payload) == "table" and payload.command or nil
  if type(command) == "table" then return command.token end
  return opts and opts.token or nil
end
'''
new_cmd_token = '''local function command_token(opts)
  local message = opts and opts.message or nil
  if type(message) == "table" then
    if message.token ~= nil then return message.token end
    if type(message.command) == "table" and message.command.token ~= nil then
      return message.command.token
    end
  end
  local payload = type(message) == "table" and message.payload or nil
  local command = type(payload) == "table" and payload.command or nil
  if type(command) == "table" and command.token ~= nil then return command.token end
  return opts and opts.token or nil
end
'''
replace_once(remote_path, old_cmd_token, new_cmd_token)

old_run = '''  local ok_run, run_err
  if type(shell) == "table" and type(shell.run) == "function" then
    ok_run, run_err = pcall(shell.run, path)
  else
    ok_run, run_err = pcall(dofile, path)
  end

  -- Aufräumen
  pcall(fs.delete, path)

  if not ok_run then
    log("ERROR", "Remote-Update: Installer-Lauf fehlgeschlagen: " .. tostring(run_err))
    return false, tostring(run_err)
  end
'''
new_run = '''  local ok_run, run_err
  if type(shell) == "table" and type(shell.run) == "function" then
    local ok_call, result = pcall(shell.run, path)
    ok_run = ok_call and result ~= false
    run_err = ok_call and (result == false and "installer returned false" or nil) or result
  else
    ok_run, run_err = pcall(dofile, path)
  end

  -- Unattended mode must never leak into later manual installer runs.
  _G.__xreactor_remote_update = nil

  -- Aufräumen
  pcall(fs.delete, path)

  if not ok_run then
    log("ERROR", "Remote-Update: Installer-Lauf fehlgeschlagen: " .. tostring(run_err))
    return false, tostring(run_err)
  end
'''
replace_once(remote_path, old_run, new_run)

support_path = "xreactor/nodes/support/command_handler.lua"
old_support = '''    require("core.remote_update").handle_command({
      log_prefix = (ctx and ctx.log_prefix) or "SUPPORT",
      utils = ctx and ctx.utils,
      send_ack = (ctx and ctx.comms) and function() ctx.comms:send_ack(msg, true, { updating = true }) end or nil,
    })
'''
new_support = '''    require("core.remote_update").handle_command({
      log_prefix = (ctx and ctx.log_prefix) or "SUPPORT",
      utils = ctx and ctx.utils,
      message = msg,
      token = msg.token,
      send_ack = (ctx and ctx.comms) and function() ctx.comms:send_ack(msg, true, { updating = true }) end or nil,
    })
'''
replace_once(support_path, old_support, new_support)

# 6) CI and version guard.
ci_path = ".github/workflows/offline-tests.yml"
ci = read(ci_path)
for obsolete in ['            "CI_MASTER_PLAN.md"\n', '            "AGENTS.md"\n']:
    if obsolete not in ci:
        raise SystemExit(f"{ci_path}: missing expected obsolete requirement {obsolete!r}")
    ci = ci.replace(obsolete, "", 1)
write(ci_path, ci)

version_path = "tools/check_version_bump.py"
v_before = read(version_path)
vtext = v_before.replace(
'''    parser = argparse.ArgumentParser()
    parser.add_argument("--no-bump-required", action="store_true")
    args = parser.parse_args()

    cur = get_version("HEAD")
    prev = get_version("HEAD~1")
''',
'''    parser = argparse.ArgumentParser()
    parser.add_argument("--no-bump-required", action="store_true")
    parser.add_argument("--base", default=None, help="base git ref/sha to compare")
    parser.add_argument("--head", default=None, help="head git ref/sha to compare")
    args = parser.parse_args()

    head_ref = args.head or "HEAD"
    base_ref = args.base or "HEAD~1"
    cur = get_version(head_ref)
    prev = get_version(base_ref)
''', 1)
if vtext == v_before:
    raise SystemExit(f"{version_path}: version guard anchor not found")
write(version_path, vtext)

recorder_test = ROOT / "tests/sim_recorder_contract_test.lua"
if recorder_test.exists():
    recorder_test.unlink()

# Regression tests.
write("tests/utils_public_helpers_init_order_test.lua", r'''package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

local utils = require("core.utils")

assert(type(utils.number_or_nil) == "function",
  "number_or_nil must exist immediately after require(core.utils)")
assert(type(utils.payload_looks_rt) == "function",
  "payload_looks_rt must exist immediately after require(core.utils)")
assert(utils.number_or_nil("42") == 42)
assert(utils.number_or_nil("not-a-number") == nil)
assert(utils.payload_looks_rt({ turbines = {} }) == true)
assert(utils.payload_looks_rt({ mode = "MASTER", output = 1, capabilities = {} }) == true)
assert(utils.payload_looks_rt({ foo = "bar" }) == false)

print("utils_public_helpers_init_order_test: OK")
''')

write("tests/comms_ack_identity_regression_test.lua", r'''package.path = "xreactor/?.lua;xreactor/?/init.lua;" .. package.path

local constants = require("shared.constants")
local comms = require("core.comms")

local now = 100000
os.epoch = function() return now end

local sent = {}
local network = {
  id = "MASTER-1",
  role = constants.roles.MASTER,
  channels = { control = constants.channels.CONTROL, status = constants.channels.STATUS },
}
function network:send(channel, message)
  sent[#sent + 1] = { channel = channel, message = message }
  return true
end

comms.init({
  network = network,
  node_id = "MASTER-1",
  role = constants.roles.MASTER,
  config = { ack_timeout_s = 3, max_retries = 1 },
  logger = function() end,
})

local entry = comms.send("RT-1", constants.message_types.COMMAND,
  { command = { target = "SET_SETPOINTS" } },
  { require_ack = true, require_applied = true, message_id = "cmd-identity-1" })
assert(entry, "command should queue")
comms.tick()
assert(comms.get_diagnostics().inflight_count == 1, "command must be inflight")

local function ack(src, dst)
  return {
    type = constants.message_types.ACK_APPLIED,
    message_id = "ack-" .. src .. "-" .. dst,
    ack_for = "cmd-identity-1",
    src = src,
    sender_id = src,
    node_id = src,
    dst = dst,
    role = constants.roles.RT_NODE,
    ts = now,
    timestamp = now,
    proto_ver = constants.proto_ver,
    payload = { result = { ok = true } },
  }
end

comms.receive(ack("RT-OTHER", "MASTER-1"))
comms.tick()
assert(comms.get_diagnostics().inflight_count == 1,
  "ACK from another peer must not complete command")

comms.receive(ack("RT-1", "SOMEONE-ELSE"))
comms.tick()
assert(comms.get_diagnostics().inflight_count == 1,
  "ACK addressed to another node must not complete command")

comms.receive(ack("RT-1", "MASTER-1"))
comms.tick()
assert(comms.get_diagnostics().inflight_count == 0,
  "matching src/dst ACK must complete command")

print("comms_ack_identity_regression_test: OK")
''')

write("tests/installer_recovery_commit_guard_test.lua", r'''local f = assert(io.open("xreactor/installer/init.lua", "r"))
local src = f:read("*a"); f:close()

assert(src:find("using_existing_recovery_backup", 1, true),
  "installer retry must distinguish an existing recovery backup")
assert(src:find("VALID_INCOMPLETE", 1, true),
  "installer retry must detect incomplete previous transaction")
assert(src:find("verwende unveraendert das bestehende Recovery%-Backup"),
  "installer retry must reuse original recovery backup")
assert(src:find("Installation wird NICHT als COMMITTED markiert", 1, true),
  "partial config restore must abort before COMMITTED")

local b = assert(io.open("installer", "r"))
local bootstrap = b:read("*a"); b:close()
assert(bootstrap:find("local ref = sha", 1, true))
assert(not bootstrap:find('local ref = sha or "beta"', 1, true),
  "bootstrap must not fall back to a moving branch ref")

print("installer_recovery_commit_guard_test: OK")
''')

write("tests/remote_update_shell_result_guard_test.lua", r'''local f = assert(io.open("xreactor/core/remote_update.lua", "r"))
local src = f:read("*a"); f:close()

assert(src:find("result ~= false", 1, true),
  "shell.run false must be treated as installer failure")
assert(src:find("_G.__xreactor_remote_update = nil", 1, true),
  "remote-update mode must be cleared after installer attempt")
assert(src:find("message.command", 1, true),
  "legacy command token shape must remain supported")

print("remote_update_shell_result_guard_test: OK")
''')

# Release bump to v513 and installer fingerprint.
release_path = ROOT / "xreactor/release.lua"
release = release_path.read_text(encoding="utf-8")
release = re.sub(r'release_id = "beta-v\d+"', 'release_id = "beta-v513"', release, count=1)
release = re.sub(r'manifest_id = "manifest-v\d+"', 'manifest_id = "manifest-v513"', release, count=1)
release = re.sub(r'manifest_version = \d+', 'manifest_version = 513', release, count=1)
installer_bytes = (ROOT / "installer").read_bytes()
installer_hash = f"{zlib.crc32(installer_bytes) & 0xffffffff:08x}"
release = re.sub(r'installer_core_hash = "[0-9a-f]+"',
                 f'installer_core_hash = "{installer_hash}"', release, count=1)
release = re.sub(r'installer_core_size_bytes = \d+',
                 f'installer_core_size_bytes = {len(installer_bytes)}', release, count=1)
release_path.write_text(release, encoding="utf-8")

# Preserve manifest comments and ordering while synchronising metadata.
manifest_path = ROOT / "xreactor/manifest.lua"
manifest = manifest_path.read_text(encoding="utf-8")
manifest = re.sub(r'(-- xreactor/manifest.lua -- manifest-v)\d+', r'\g<1>513', manifest, count=1)
manifest = re.sub(r'(\bmanifest_version\s*=\s*)\d+', r'\g<1>513', manifest, count=1)
manifest = re.sub(r'(\bmanifest_id\s*=\s*)"manifest-v\d+"', r'\g<1>"manifest-v513"', manifest, count=1)

lines = []
path_re = re.compile(r'path\s*=\s*"([^"]+)"')
for line in manifest.splitlines(True):
    m = path_re.search(line)
    if m:
        rel = m.group(1)
        file_path = ROOT / "xreactor" / rel
        if file_path.is_file():
            data = file_path.read_bytes()
            size = len(data)
            h = f"{zlib.crc32(data) & 0xffffffff:08x}"
            if re.search(r'\bsize_bytes\s*=', line):
                line = re.sub(r'(\bsize_bytes\s*=\s*)\d+', rf'\g<1>{size}', line, count=1)
            else:
                insert_at = m.end()
                line = line[:insert_at] + f', size_bytes = {size}' + line[insert_at:]
            if re.search(r'\bhash\s*=', line):
                line = re.sub(r'(\bhash\s*=\s*)"[0-9a-fA-F]*"', rf'\g<1>"{h}"', line, count=1)
            else:
                sm = re.search(r'\bsize_bytes\s*=\s*\d+', line)
                if not sm:
                    raise SystemExit(f"manifest metadata insertion failed for {rel}")
                line = line[:sm.end()] + f', hash = "{h}"' + line[sm.end():]
    lines.append(line)
manifest = "".join(lines)
manifest_path.write_text(manifest, encoding="utf-8")

count = len(path_re.findall(manifest))
release = release_path.read_text(encoding="utf-8")
release = re.sub(r'manifest_file_count = \d+', f'manifest_file_count = {count}', release, count=1)
release_path.write_text(release, encoding="utf-8")

# release.lua changed after count update: refresh its entry once more.
data = release_path.read_bytes()
size = len(data)
h = f"{zlib.crc32(data) & 0xffffffff:08x}"
manifest = manifest_path.read_text(encoding="utf-8")
pattern = r'(\{\s*path\s*=\s*"release\.lua"[^}\n]*\bsize_bytes\s*=\s*)\d+([^}\n]*\bhash\s*=\s*")[0-9a-fA-F]+(")'
manifest, n = re.subn(pattern, rf'\g<1>{size}\g<2>{h}\g<3>', manifest, count=1)
if n != 1:
    raise SystemExit("failed to refresh release.lua manifest metadata")
manifest_path.write_text(manifest, encoding="utf-8")

# Remove temporary automation files from final diff.
if WORKFLOW.exists():
    WORKFLOW.unlink()
if SCRIPT_SELF.exists():
    SCRIPT_SELF.unlink()
