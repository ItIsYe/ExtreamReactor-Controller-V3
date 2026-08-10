from pathlib import Path
import re
import zlib

ROOT = Path('.')

def read(path):
    return (ROOT / path).read_text(encoding='utf-8')

def write(path, text):
    (ROOT / path).write_text(text, encoding='utf-8')

def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one exact anchor, got {count}: {old[:100]!r}')
    write(path, text.replace(old, new, 1))

def regex_once(path, pattern, replacement, flags=0):
    text = read(path)
    new, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f'{path}: regex anchor count={count}: {pattern[:120]!r}')
    write(path, new)

def crc32_hex(data):
    return f'{zlib.crc32(data) & 0xffffffff:08x}'

# ---------------------------------------------------------------------------
# Root bootstrap: an interrupted install with a valid journal ref must resume
# from that exact immutable SHA. Normal installs still resolve beta -> SHA.
# ---------------------------------------------------------------------------
installer = 'installer'
old_sha_block = '''local sha = nil
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
'''
new_sha_block = '''local forced_ref = rawget(_G, "__xreactor_forced_ref")
local sha = nil
if forced_ref ~= nil then
  if type(forced_ref) ~= "string" or #forced_ref ~= 40 or not forced_ref:match("^%x+$") then
    error("Erzwungener Recovery-Ref ist kein gueltiger 40-stelliger Commit-SHA", 0)
  end
  sha = forced_ref
  p("Recovery-SHA: " .. sha:sub(1, 12) .. " (aus Installationsjournal)")
else
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
end
'''
replace_once(installer, old_sha_block, new_sha_block)
replace_once(installer,
'''  plan_validator_mod = plan_validator_mod,
  ref = ref,
})''',
'''  plan_validator_mod = plan_validator_mod,
  ref = ref,
  recovery_origin_ref = rawget(_G, "__xreactor_recovery_origin_ref"),
})''')

# ---------------------------------------------------------------------------
# Journal: carry immutable per-file expected metadata so early boot recovery
# can validate .xr_tmp before promotion.
# ---------------------------------------------------------------------------
journal = 'xreactor/installer/journal.lua'
anchor = '''local function serialize_string_array(list)
  local parts = {}
  for _, item in ipairs(list) do
    parts[#parts + 1] = string.format("%q", tostring(item))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
'''
insert = anchor + '''
local function serialize_expected_meta(meta)
  local keys = {}
  for path in pairs(meta or {}) do keys[#keys + 1] = path end
  table.sort(keys)
  local parts = { "{" }
  for _, path in ipairs(keys) do
    local entry = meta[path] or {}
    parts[#parts + 1] = "[" .. string.format("%q", tostring(path)) .. "]={size_bytes="
      .. tostring(tonumber(entry.size_bytes) or 0) .. ",hash="
      .. string.format("%q", tostring(entry.hash or "")) .. "},"
  end
  parts[#parts + 1] = "}"
  return table.concat(parts)
end
'''
replace_once(journal, anchor, insert)
replace_once(journal,
'''  parts[#parts + 1] = "  expected_files = " .. serialize_string_array(journal.expected_files or {}) .. ",\\n"
  parts[#parts + 1] = "}\\n"''',
'''  parts[#parts + 1] = "  expected_files = " .. serialize_string_array(journal.expected_files or {}) .. ",\\n"
  parts[#parts + 1] = "  expected_meta = " .. serialize_expected_meta(journal.expected_meta or {}) .. ",\\n"
  parts[#parts + 1] = "}\\n"''')
replace_once(journal,
'''  if type(result.generation) ~= "number" then return M.STATUS.CORRUPT, nil end
  if result.state == M.STATE.COMMITTED then''',
'''  if type(result.generation) ~= "number" then return M.STATUS.CORRUPT, nil end
  if result.expected_files ~= nil and type(result.expected_files) ~= "table" then return M.STATUS.CORRUPT, nil end
  if result.expected_meta ~= nil and type(result.expected_meta) ~= "table" then return M.STATUS.CORRUPT, nil end
  for _, rel in ipairs(result.expected_files or {}) do
    local meta = result.expected_meta and result.expected_meta[rel] or nil
    if meta ~= nil and (type(meta) ~= "table" or type(meta.size_bytes) ~= "number"
        or type(meta.hash) ~= "string" or not meta.hash:match("^[0-9a-f]+$")) then
      return M.STATUS.CORRUPT, nil
    end
  end
  if result.state == M.STATE.COMMITTED then''')
replace_once(journal,
'''    expected_files = {},
  }''',
'''    expected_files = {},
    expected_meta = {},
  }''')

# ---------------------------------------------------------------------------
# installer/init.lua: complete-or-abort config backup with exact file-set
# verification, persistent original recovery backup, expected file metadata,
# and immutable local install metadata.
# ---------------------------------------------------------------------------
init = 'xreactor/installer/init.lua'
backup_block = r'''local function list_files_recursive\(dir, prefix, out\).*?local function load_recovery_config_backup\(\).*?\nend\n\n-- Fix \(2026-07-16\): CRITICAL\. INSTALL-P0'''
new_backup_block = '''local function sorted_keys(map)
  local keys = {}
  for key in pairs(map or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function list_files_recursive(dir, prefix, out, errors)
  prefix = prefix or ""
  out = out or {}
  errors = errors or {}
  local ok_exists, exists = pcall(fs.exists, dir)
  if not ok_exists then
    errors[#errors + 1] = "exists failed: " .. tostring(dir) .. " (" .. tostring(exists) .. ")"
    return out, errors
  end
  if not exists then return out, errors end
  local ok_isdir, is_dir = pcall(fs.isDir, dir)
  if not ok_isdir or not is_dir then
    errors[#errors + 1] = "not readable directory: " .. tostring(dir)
    return out, errors
  end
  local ok_list, entries = pcall(fs.list, dir)
  if not ok_list or type(entries) ~= "table" then
    errors[#errors + 1] = "list failed: " .. tostring(dir) .. " (" .. tostring(entries) .. ")"
    return out, errors
  end
  table.sort(entries)
  for _, name in ipairs(entries) do
    local full = dir .. "/" .. name
    local rel = (prefix == "" and name or (prefix .. "/" .. name))
    local ok_child_dir, child_is_dir = pcall(fs.isDir, full)
    if not ok_child_dir then
      errors[#errors + 1] = "isDir failed: " .. tostring(full)
    elseif child_is_dir then
      list_files_recursive(full, rel, out, errors)
    else
      out[#out + 1] = rel
    end
  end
  return out, errors
end

local function make_backup_bundle(files_map, expected_paths)
  expected_paths = expected_paths or sorted_keys(files_map)
  return { version = 2, count = #expected_paths, expected_paths = expected_paths, files = files_map or {} }
end

local function normalize_backup_bundle(value)
  if type(value) ~= "table" then return nil, "backup is not a table" end
  if value.version == 2 then
    if type(value.files) ~= "table" or type(value.expected_paths) ~= "table" or type(value.count) ~= "number" then
      return nil, "v2 backup shape invalid"
    end
    local seen = {}
    if value.count ~= #value.expected_paths then return nil, "v2 backup count mismatch" end
    for _, rel in ipairs(value.expected_paths) do
      if type(rel) ~= "string" or rel == "" or seen[rel] then return nil, "v2 backup path list invalid" end
      seen[rel] = true
      if type(value.files[rel]) ~= "string" then return nil, "v2 backup missing content for " .. tostring(rel) end
    end
    for rel, content in pairs(value.files) do
      if not seen[rel] or type(content) ~= "string" then return nil, "v2 backup contains unexpected file " .. tostring(rel) end
    end
    return make_backup_bundle(value.files, value.expected_paths)
  end

  -- Backward compatibility for a recovery file written by pre-v515 code.
  local files = {}
  for rel, content in pairs(value) do
    if type(rel) ~= "string" or type(content) ~= "string" then
      return nil, "legacy backup entry invalid"
    end
    files[rel] = content
  end
  return make_backup_bundle(files, sorted_keys(files))
end

local function serialize_config_backup(bundle)
  local parts = { "return {\\n", "  version = 2,\\n",
    "  count = " .. tostring(bundle.count or 0) .. ",\\n", "  expected_paths = {\\n" }
  for _, rel in ipairs(bundle.expected_paths or {}) do
    parts[#parts + 1] = "    " .. string.format("%q", rel) .. ",\\n"
  end
  parts[#parts + 1] = "  },\\n  files = {\\n"
  for _, rel in ipairs(bundle.expected_paths or {}) do
    parts[#parts + 1] = "    [" .. string.format("%q", rel) .. "] = "
      .. string.format("%q", bundle.files[rel]) .. ",\\n"
  end
  parts[#parts + 1] = "  },\\n}\\n"
  return table.concat(parts)
end

local function decode_config_backup(src)
  if type(src) ~= "string" or src == "" then return nil, "unreadable" end
  local loader, lerr = load(src, "=config_backup", "t", {})
  if not loader then return nil, "parse: " .. tostring(lerr) end
  local ok, result = pcall(loader)
  if not ok then return nil, "invalid: " .. tostring(result) end
  return normalize_backup_bundle(result)
end

local function backup_config_dir()
  local files_map, errors = {}, {}
  local ok_exists, exists = pcall(fs.exists, CONFIG_DIR)
  if not ok_exists then return make_backup_bundle({}, {}), { "exists failed: " .. tostring(CONFIG_DIR) } end
  if not exists then return make_backup_bundle({}, {}), errors end

  local files
  files, errors = list_files_recursive(CONFIG_DIR, "", {}, errors)
  local expected_paths = {}
  for _, rel in ipairs(files) do
    if not config_restore_denied(rel) then
      expected_paths[#expected_paths + 1] = rel
      local path = CONFIG_DIR .. "/" .. rel
      local ok_open, handle = pcall(fs.open, path, "r")
      if not ok_open or not handle then
        errors[#errors + 1] = "open failed: " .. path .. " (" .. tostring(handle) .. ")"
      else
        local ok_read, content = pcall(handle.readAll)
        local ok_close, close_err = pcall(handle.close)
        if not ok_read or type(content) ~= "string" then
          errors[#errors + 1] = "read failed: " .. path .. " (" .. tostring(content) .. ")"
        end
        if not ok_close then
          errors[#errors + 1] = "close failed: " .. path .. " (" .. tostring(close_err) .. ")"
        end
        if ok_read and type(content) == "string" and ok_close then files_map[rel] = content end
      end
    end
  end
  table.sort(expected_paths)
  return make_backup_bundle(files_map, expected_paths), errors
end

local function load_recovery_config_backup()
  if not fs.exists(RECOVERY_CONFIG_BACKUP) then return nil, "missing" end
  local src = stage_mod.read(RECOVERY_CONFIG_BACKUP)
  return decode_config_backup(src)
end

local function backup_bundles_equal(a, b)
  if not a or not b or a.count ~= b.count or #a.expected_paths ~= #b.expected_paths then return false end
  for i, rel in ipairs(a.expected_paths) do
    if b.expected_paths[i] ~= rel or b.files[rel] ~= a.files[rel] then return false end
  end
  return true
end

-- Fix (2026-07-16): CRITICAL. INSTALL-P0'''
regex_once(init, backup_block, new_backup_block, re.S)

flow_pattern = r'''local config_backup\nlocal using_existing_recovery_backup = false\ndo\n.*?\nend\n\n-- Feature \(2026-07-01\): bestehende Auswahl optionaler Features'''
flow_new = '''local config_backup_bundle
local config_backup
local config_backup_paths
local using_existing_recovery_backup = false
do
  local status = nil
  if type(journal_mod.classify) == "function" then
    local ok_status, classified = pcall(function() return select(1, journal_mod.classify()) end)
    if ok_status then status = classified end
  end

  local interrupted = status == journal_mod.STATUS.VALID_INCOMPLETE
    or status == journal_mod.STATUS.CORRUPT or status == journal_mod.STATUS.UNREADABLE
  if interrupted then
    local recovered, rerr = load_recovery_config_backup()
    if not recovered then
      error("Vorherige Installation ist nicht sicher abgeschlossen, aber das originale Config-Recovery-Backup ist nicht lesbar ("
        .. tostring(rerr) .. "). Abbruch bevor Daten erneut geloescht werden.", 0)
    end
    config_backup_bundle = recovered
    using_existing_recovery_backup = true
    p("Unvollstaendige vorherige Installation erkannt: verwende unveraendert das bestehende Recovery-Backup.")
  else
    local errors
    config_backup_bundle, errors = backup_config_dir()
    if #errors > 0 then
      error("Config-Backup unvollstaendig -- Abbruch VOR dem ersten destruktiven Schritt: " .. table.concat(errors, "; "), 0)
    end
  end

  config_backup = config_backup_bundle.files
  config_backup_paths = config_backup_bundle.expected_paths
end

do
  local backup_count = config_backup_bundle.count or 0
  if not using_existing_recovery_backup then
    pcall(fs.makeDir, RECOVERY_DIR)
    local serialized = serialize_config_backup(config_backup_bundle)
    local ok_bak, bak_err = stage_mod.write(RECOVERY_CONFIG_BACKUP, serialized)
    if not ok_bak then
      error("Config-Backup fehlgeschlagen, breche vor Loeschen ab: " .. tostring(bak_err), 0)
    end
    local restored_bundle, verr = load_recovery_config_backup()
    if not restored_bundle or not backup_bundles_equal(config_backup_bundle, restored_bundle) then
      error("Config-Backup-Verifikation fehlgeschlagen (" .. tostring(verr or "Dateimenge/Inhalt weicht ab") .. ") -- breche vor Loeschen ab.", 0)
    end
    p("Config gesichert: " .. backup_count .. " Datei(en) -> " .. RECOVERY_CONFIG_BACKUP)
  end
end

-- Feature (2026-07-01): bestehende Auswahl optionaler Features'''
regex_once(init, flow_pattern, flow_new, re.S)

replace_once(init,
'''local expected_paths = {}
for rel in pairs(expected) do expected_paths[#expected_paths + 1] = rel end
table.sort(expected_paths)''',
'''local expected_paths = {}
local expected_meta = {}
for rel, entry in pairs(expected) do
  expected_paths[#expected_paths + 1] = rel
  expected_meta[rel] = { size_bytes = tonumber(entry.size_bytes) or 0, hash = tostring(entry.hash or "") }
end
table.sort(expected_paths)''')

text = read(init)
needle = '  expected_files = expected_paths,\n})'
count = text.count(needle)
if count != 4:
    raise SystemExit(f'{init}: expected four journal expected_files anchors, got {count}')
text = text.replace(needle, '  expected_files = expected_paths,\n  expected_meta = expected_meta,\n})')
write(init, text)

replace_once(init,
'''  for rel, content in pairs(config_backup) do
    local dst = CONFIG_DIR .. "/" .. rel''',
'''  for _, rel in ipairs(config_backup_paths) do
    local content = config_backup[rel]
    local dst = CONFIG_DIR .. "/" .. rel''')
replace_once(init,
'''  if restored > 0 then p("Config wiederhergestellt: " .. restored .. " Datei(en)") end
  if #failed > 0 then''',
'''  if restored ~= #config_backup_paths then
    failed[#failed + 1] = "restore count mismatch expected=" .. tostring(#config_backup_paths) .. " actual=" .. tostring(restored)
  end
  if restored > 0 then p("Config wiederhergestellt: " .. restored .. " Datei(en)") end
  if #failed > 0 then''')
replace_once(init,
'''  else
    pcall(fs.delete, RECOVERY_CONFIG_BACKUP)
  end
end

-- Feature (2026-07-01): aktuelle''',
'''  end
end

-- Recovery-Backup bleibt bis NACH dem bestaetigten COMMITTED-Journal erhalten.
-- So kann ein Fehler in role/startup/release/install_meta nach erfolgreichem
-- Config-Restore das originale Sicherheitsnetz nicht vorzeitig vernichten.

-- Feature (2026-07-01): aktuelle''')

meta_block = '''-- Lokale, nicht manifestverwaltete Installationsmetadaten: release.lua ist
-- Quellmetadatum und darf weiterhin source_ref="beta" tragen; diese Datei
-- dokumentiert dagegen den tatsaechlich aufgeloesten, unveraenderlichen SHA.
do
  local meta_path = INSTALL_ROOT .. "/install_meta.lua"
  local installed_at = os.epoch and os.epoch("utc") or 0
  local recovery_origin = deps.recovery_origin_ref
  local meta_src = table.concat({
    "return {\\n",
    "  resolved_commit_sha = " .. string.format("%q", ref) .. ",\\n",
    "  installed_at = " .. tostring(installed_at) .. ",\\n",
    "  manifest_id = " .. string.format("%q", tostring(manifest.manifest_id or manifest.manifest_version)) .. ",\\n",
    "  installer_ref = " .. string.format("%q", ref) .. ",\\n",
    "  recovery_origin_ref = " .. (recovery_origin and string.format("%q", tostring(recovery_origin)) or "nil") .. ",\\n",
    "  role = " .. string.format("%q", role.label) .. ",\\n",
    "}\\n",
  })
  local ok_meta, err_meta = stage_mod.write(meta_path, meta_src)
  if not ok_meta or stage_mod.read(meta_path) ~= meta_src then
    error("install_meta.lua konnte nicht sicher geschrieben/verifiziert werden: " .. tostring(err_meta), 0)
  end
end

'''
replace_once(init,
'''-- Fix (2026-07-17): CRITICAL. INSTALL-P0.1 (Abschnitt 3, Fix-Punkt 5):''',
meta_block + '''-- Fix (2026-07-17): CRITICAL. INSTALL-P0.1 (Abschnitt 3, Fix-Punkt 5):''')
replace_once(init,
'''if not ok_commit then
  error("Installationsjournal (COMMITTED) konnte nicht geschrieben werden: " .. tostring(err_commit), 0)
end
journal_mod.clear()''',
'''if not ok_commit then
  error("Installationsjournal (COMMITTED) konnte nicht geschrieben werden: " .. tostring(err_commit), 0)
end
pcall(fs.delete, RECOVERY_CONFIG_BACKUP)
journal_mod.clear()''')

# ---------------------------------------------------------------------------
# start.lua: recover missing stage targets conservatively and resume a valid
# incomplete transaction from its original immutable ref.
# ---------------------------------------------------------------------------
start = 'xreactor/start.lua'
recovery_helpers = '''local function crc32_hex(content)
  if not bit32 then return nil end
  local crc = 0xFFFFFFFF
  for i = 1, #content do
    crc = bit32.bxor(crc, content:byte(i))
    for _ = 1, 8 do
      local mask = -(bit32.band(crc, 1))
      crc = bit32.bxor(bit32.rshift(crc, 1), bit32.band(0xEDB88320, mask))
    end
  end
  return string.format("%08x", bit32.bxor(crc, 0xFFFFFFFF))
end

local function read_recovery_file(path)
  local ok_open, handle = pcall(fs.open, path, "r")
  if not ok_open or not handle then return nil, "open failed" end
  local ok_read, content = pcall(handle.readAll)
  local ok_close = pcall(handle.close)
  if not ok_read or type(content) ~= "string" or not ok_close then return nil, "read/close failed" end
  return content
end

local function valid_lua_if_needed(path, content)
  if path:sub(-4) ~= ".lua" then return true end
  return load(content, "=recovery:" .. path, "t", {}) ~= nil
end

local function expected_file_valid(path, meta)
  local content = read_recovery_file(path)
  if not content then return false end
  if meta then
    if type(meta.size_bytes) ~= "number" or type(meta.hash) ~= "string" then return false end
    if #content ~= meta.size_bytes or crc32_hex(content) ~= meta.hash then return false end
  end
  return valid_lua_if_needed(path, content)
end

local function previous_file_valid(path)
  local content = read_recovery_file(path)
  return content ~= nil and valid_lua_if_needed(path, content)
end

local function ensure_parent(path)
  if not fs.getDir or not fs.makeDir then return end
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
end

local function recover_staged_files(journal)
  if type(journal) ~= "table" or type(journal.expected_files) ~= "table" then
    return false, { "journal has no expected file list" }
  end
  local errors = {}
  local meta_map = type(journal.expected_meta) == "table" and journal.expected_meta or {}
  for _, rel in ipairs(journal.expected_files) do
    local target = INSTALL_ROOT .. "/" .. rel
    if not fs.exists(target) then
      local tmp, prev = target .. ".xr_tmp", target .. ".xr_prev"
      local promoted = false
      if fs.exists(tmp) and meta_map[rel] and expected_file_valid(tmp, meta_map[rel]) then
        ensure_parent(target)
        local ok_move = pcall(fs.move, tmp, target)
        promoted = ok_move and fs.exists(target) and expected_file_valid(target, meta_map[rel])
      end
      if not promoted and fs.exists(prev) and previous_file_valid(prev) then
        ensure_parent(target)
        local ok_move = pcall(fs.move, prev, target)
        promoted = ok_move and fs.exists(target)
      end
      if not promoted then errors[#errors + 1] = "missing/unrecoverable: " .. rel end
    end
  end

  for _, rel in ipairs(journal.expected_files) do
    local target = INSTALL_ROOT .. "/" .. rel
    local meta = meta_map[rel]
    if not fs.exists(target) or not expected_file_valid(target, meta) then
      errors[#errors + 1] = "not current/verified: " .. rel
    end
  end
  return #errors == 0, errors
end

local function valid_commit_sha(value)
  return type(value) == "string" and #value == 40 and value:match("^%x+$") ~= nil
end

'''
replace_once(start,
'''-- Kontrollierter Resume: statt zu versuchen, chirurgisch nur die fehlenden''',
recovery_helpers + '''-- Kontrollierter Resume: statt zu versuchen, chirurgisch nur die fehlenden''')

old_attempt = r'''local function attempt_recovery_resume\(\)\n.*?\nend\n\nlocal journal_status, install_journal = classify_install_journal\(\)'''
new_attempt = '''local function attempt_recovery_resume(journal, journal_status)
  local recovery_ref = journal and journal.ref or nil
  local url
  if valid_commit_sha(recovery_ref) then
    url = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/" .. recovery_ref .. "/installer"
    p("[BOOT] Recovery an originalen Commit gebunden: " .. recovery_ref:sub(1, 12))
  else
    -- Bei CORRUPT/UNREADABLE existiert kein vertrauenswuerdiger Original-Ref.
    -- Fail-safe Datenhaltung bleibt durch das externe Recovery-Backup erhalten;
    -- der Bootstrap darf dann einen NEU aufgeloesten beta-SHA verwenden, aber
    -- niemals Dateien eines beweglichen Branches mit einem alten Journal-SHA mischen.
    url = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer"
    p("[BOOT] WARN: Original-Ref nicht rekonstruierbar (" .. tostring(journal_status)
      .. ") -- starte dokumentierten, neu SHA-gepinnten Recovery-Lauf vom aktuellen beta-Head.")
  end

  local body
  local ok_http, r = pcall(http.get, url)
  if ok_http and r then
    local ok2, b = pcall(r.readAll); pcall(r.close)
    if ok2 and type(b) == "string" and #b > 0 then body = b end
  end
  if not body then error("Recovery-Installer-Download fehlgeschlagen", 0) end
  local tmp = "/xreactor_recovery_installer.tmp"
  local f = fs.open(tmp, "w")
  if not f then error("Kann Recovery-Installer nicht schreiben: " .. tmp, 0) end
  local ok_w = pcall(function() f.write(body) end)
  pcall(f.close)
  if not ok_w then error("Kann Recovery-Installer nicht schreiben: " .. tmp, 0) end
  _G.__xreactor_remote_update = true
  _G.__xreactor_forced_ref = valid_commit_sha(recovery_ref) and recovery_ref or nil
  _G.__xreactor_recovery_origin_ref = valid_commit_sha(recovery_ref)
    and recovery_ref or ("UNKNOWN_" .. tostring(journal_status))
  dofile(tmp)
end

local journal_status, install_journal = classify_install_journal()'''
regex_once(start, old_attempt, new_attempt, re.S)
replace_once(start,
'''  p("[BOOT] Rolle wird NICHT gestartet -- kontrollierter Recovery-Resume...")
  local ok_resume, resume_err = pcall(attempt_recovery_resume)''',
'''  p("[BOOT] Rolle wird NICHT gestartet -- kontrollierter Recovery-Resume...")
  if install_journal then
    local recovered_current, recovery_errors = recover_staged_files(install_journal)
    p("[BOOT] Stage-Recovery: " .. (recovered_current and "vollstaendig verifiziert" or
      ("unvollstaendig (" .. tostring(#recovery_errors) .. " Restpunkt(e)); Installer-Resume erforderlich")))
  end
  local ok_resume, resume_err = pcall(attempt_recovery_resume, install_journal, journal_status)''')

# Boot log surfaces the immutable installed SHA when metadata exists.
replace_once(start,
'''p("[BOOT] XReactor " .. role .. " | " .. rel_v)''',
'''local installed_sha = nil
local install_meta_path = INSTALL_ROOT .. "/install_meta.lua"
if fs.exists(install_meta_path) then
  local ok_meta, meta = pcall(dofile, install_meta_path)
  if ok_meta and type(meta) == "table" and valid_commit_sha(meta.resolved_commit_sha) then
    installed_sha = meta.resolved_commit_sha
  end
end
p("[BOOT] XReactor " .. role .. " | " .. rel_v
  .. (installed_sha and (" | " .. installed_sha:sub(1, 12)) or ""))''')

# Update the existing start guard test to use an actual immutable SHA and to
# assert that valid incomplete recovery downloads that exact ref.
test_start = 'tests/start_lua_incomplete_install_blocks_role_test.lua'
replace_once(test_start,
'''  local dofile_calls = {}
''',
'''  local dofile_calls = {}
  local requested_urls = {}
''')
replace_once(test_start,
'''    get = function()
      if http_should_succeed then''',
'''    get = function(url)
      requested_urls[#requested_urls + 1] = url
      if http_should_succeed then''')
replace_once(test_start,
'''  return ok, err, reboot_calls, sleep_calls, dofile_calls
end

local function journal(state, generation)
  return string.format(
    'return { state = %q, generation = %d, ref = "x", manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {} }\\n',
    state, generation or 0)
end''',
'''  return ok, err, reboot_calls, sleep_calls, dofile_calls, requested_urls
end

local TEST_SHA = string.rep("a", 40)
local function journal(state, generation)
  return string.format(
    'return { state = %q, generation = %d, ref = %q, manifest_id = "m", role = "RT-NODE", started_at = 1, expected_files = {}, expected_meta = {} }\\n',
    state, generation or 0, TEST_SHA)
end''')
replace_once(test_start,
'''  local ok, err, reboot_calls, sleep_calls, dofile_calls = run_guard(
    { [SLOT_A] = journal("VERIFYING", 1) }, true)''',
'''  local ok, err, reboot_calls, sleep_calls, dofile_calls, requested_urls = run_guard(
    { [SLOT_A] = journal("VERIFYING", 1) }, true)''')
replace_once(test_start,
'''  if #dofile_calls ~= 1 then
    error("expected the downloaded recovery installer to be dofile()'d exactly once, got " .. #dofile_calls)
  end
end''',
'''  if #dofile_calls ~= 1 then
    error("expected the downloaded recovery installer to be dofile()'d exactly once, got " .. #dofile_calls)
  end
  if #requested_urls ~= 1 or not requested_urls[1]:find(TEST_SHA, 1, true) then
    error("recovery must download installer from the exact journal SHA")
  end
end''')

# Behavioral test for config backup helpers: every listing/open/read/close
# failure must be represented as an error, while a truly empty directory is
# distinguishable as a valid zero-file bundle.
config_test = '''local function read_file(path)
  local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local function extract(src, a, b)
  local i = assert(src:find(a, 1, true)); local j = assert(src:find(b, i, true)); return src:sub(i, j - 1)
end
local root = os.getenv("REPO_ROOT") or "."
local src = read_file(root .. "/xreactor/installer/init.lua")
local snippet = extract(src, "local CONFIG_DIR", "-- Fix (2026-07-16): CRITICAL. INSTALL-P0")

local function build_backup(fs_impl)
  _G.fs = fs_impl
  local harness = [[
local INSTALL_ROOT = "/xreactor"
local stage_mod = { read = function() return nil end }
]] .. snippet .. [[
return backup_config_dir
]]
  local chunk = assert(load(harness, "=config_backup_helpers", "t"))
  return chunk()()
end

local function base_fs()
  return {
    exists = function(path) return path == "/xreactor/config" or path == "/xreactor/config/a.lua" end,
    isDir = function(path) return path == "/xreactor/config" end,
    list = function() return { "a.lua" } end,
    open = function(path)
      return { readAll = function() return "return {}\\n" end, close = function() end }
    end,
  }
end

do
  local fsx = base_fs(); fsx.list = function() error("list boom") end
  local bundle, errors = build_backup(fsx)
  assert(#errors == 1 and bundle.count == 0, "fs.list failure must be fatal/visible")
end

do
  local fsx = base_fs(); fsx.open = function() return nil end
  local bundle, errors = build_backup(fsx)
  assert(#errors == 1 and bundle.count == 1 and bundle.files["a.lua"] == nil, "open failure must be visible")
end

do
  local fsx = base_fs(); fsx.open = function()
    return { readAll = function() error("read boom") end, close = function() end }
  end
  local _, errors = build_backup(fsx)
  assert(#errors >= 1, "read failure must be visible")
end

do
  local fsx = base_fs(); fsx.open = function()
    return { readAll = function() return "return {}\\n" end, close = function() error("close boom") end }
  end
  local _, errors = build_backup(fsx)
  assert(#errors >= 1, "close failure must be visible")
end

do
  local fsx = base_fs(); fsx.list = function() return {} end
  local bundle, errors = build_backup(fsx)
  assert(#errors == 0 and bundle.count == 0, "real empty config directory must be a valid zero-file backup")
end

local error_pos = assert(src:find("Config-Backup unvollstaendig", 1, true))
local delete_pos = assert(src:find("pcall(fs.delete, INSTALL_ROOT)", 1, true))
assert(error_pos < delete_pos, "backup errors must be handled before destructive install-root delete")
print("installer_config_backup_fail_closed_test.lua: ok")
'''
write('tests/installer_config_backup_fail_closed_test.lua', config_test)

# Generic stage-recovery behavior test. A .xr_tmp copy is promoted only when
# it matches journal size+CRC. A readable previous copy can restore a missing
# target, but does not make the new transaction COMMITTED/current by itself.
stage_test = '''local function read_file(path)
  local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local function extract(src, a, b)
  local i = assert(src:find(a, 1, true)); local j = assert(src:find(b, i, true)); return src:sub(i, j - 1)
end
local root = os.getenv("REPO_ROOT") or "."
local src = read_file(root .. "/xreactor/start.lua")
local snippet = extract(src, "local function crc32_hex", "-- Kontrollierter Resume:")
local chunk = assert(load([[local INSTALL_ROOT="/xreactor"\n]] .. snippet .. [[\nreturn recover_staged_files\n]], "=stage_recovery", "t"))
local recover = chunk()

local function fs_mock(initial)
  local files = {}; for k,v in pairs(initial or {}) do files[k]=v end
  return {
    files = files,
    exists = function(p) return files[p] ~= nil end,
    open = function(p, mode)
      if mode ~= "r" or files[p] == nil then return nil end
      return { readAll=function() return files[p] end, close=function() end }
    end,
    move = function(a,b) assert(files[a] ~= nil); files[b]=files[a]; files[a]=nil end,
    getDir = function(p) return p:match("^(.*)/[^/]+$") or "" end,
    makeDir = function() end,
  }
end

local good = "return { ok = true }\\n"
local meta = { size_bytes = 21, hash = "6378232e" }

do
  local fsx = fs_mock({ ["/xreactor/core/a.lua.xr_tmp"] = good })
  _G.fs = fsx
  local ok, errors = recover({ expected_files={"core/a.lua"}, expected_meta={ ["core/a.lua"] = meta } })
  assert(ok and #errors == 0 and fsx.files["/xreactor/core/a.lua"] == good, "valid tmp must be promoted")
end

do
  local fsx = fs_mock({ ["/xreactor/core/a.lua.xr_tmp"] = good .. "x" })
  _G.fs = fsx
  local ok = recover({ expected_files={"core/a.lua"}, expected_meta={ ["core/a.lua"] = meta } })
  assert(not ok and fsx.files["/xreactor/core/a.lua"] == nil, "CRC/size-mismatched tmp must never be promoted")
end

do
  local old = "return { old = true }\\n"
  local fsx = fs_mock({ ["/xreactor/core/a.lua.xr_prev"] = old })
  _G.fs = fsx
  local ok = recover({ expected_files={"core/a.lua"}, expected_meta={ ["core/a.lua"] = meta } })
  assert(not ok, "old previous copy is rollback material, not proof that new install is current")
  assert(fsx.files["/xreactor/core/a.lua"] == old, "readable previous copy must restore a missing main file")
end

print("start_generic_stage_recovery_test.lua: ok")
'''
write('tests/start_generic_stage_recovery_test.lua', stage_test)

metadata_test = '''local function read_file(path)
  local f = assert(io.open(path, "r")); local s=f:read("*a"); f:close(); return s
end
local root = os.getenv("REPO_ROOT") or "."
local installer = read_file(root .. "/installer")
local init = read_file(root .. "/xreactor/installer/init.lua")
local start = read_file(root .. "/xreactor/start.lua")
local journal = read_file(root .. "/xreactor/installer/journal.lua")
assert(installer:find("__xreactor_forced_ref", 1, true), "bootstrap must accept forced immutable recovery ref")
assert(start:find("Original-Ref nicht rekonstruierbar", 1, true), "fallback recovery policy must be explicit in boot log")
for _, token in ipairs({"resolved_commit_sha", "installed_at", "manifest_id", "installer_ref", "recovery_origin_ref"}) do
  assert(init:find(token, 1, true), "install metadata missing field " .. token)
end
assert(journal:find("expected_meta", 1, true), "journal must carry per-file recovery metadata")
print("installer_resolved_commit_metadata_test.lua: ok")
'''
write('tests/installer_resolved_commit_metadata_test.lua', metadata_test)

# Bump release/manifest to v515, recompute bootstrap fingerprint, then let the
# canonical manifest sync script update all changed runtime hashes/sizes and
# remove the hand-maintained manifest header comment.
release_path = ROOT / 'xreactor/release.lua'
release_text = release_path.read_text(encoding='utf-8')
for old, new in [
    ('release_id = "beta-v514"', 'release_id = "beta-v515"'),
    ('manifest_id = "manifest-v514"', 'manifest_id = "manifest-v515"'),
    ('manifest_version = 514', 'manifest_version = 515'),
]:
    if release_text.count(old) != 1: raise SystemExit(f'release anchor mismatch: {old}')
    release_text = release_text.replace(old, new, 1)
installer_bytes = (ROOT / 'installer').read_bytes()
release_text = re.sub(r'installer_core_hash = "[0-9a-f]+"', f'installer_core_hash = "{crc32_hex(installer_bytes)}"', release_text, count=1)
release_text = re.sub(r'installer_core_size_bytes = \d+', f'installer_core_size_bytes = {len(installer_bytes)}', release_text, count=1)
release_path.write_text(release_text, encoding='utf-8')

manifest_path = ROOT / 'xreactor/manifest.lua'
manifest_text = manifest_path.read_text(encoding='utf-8')
manifest_text = manifest_text.replace('manifest_version = 514', 'manifest_version = 515', 1)
manifest_text = manifest_text.replace('manifest_id = "manifest-v514"', 'manifest_id = "manifest-v515"', 1)
manifest_path.write_text(manifest_text, encoding='utf-8')

# Canonical rewrite recalculates every runtime entry and intentionally removes
# the stale/manual first-line comment.
import subprocess
subprocess.run(['python3', 'scripts/manifest_sync.py', '--write'], check=True)

print('phase3 patch applied')
