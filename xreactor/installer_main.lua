local manifest_lib = dofile("/xreactor/installer_manifest.lua")
local stage_lib = dofile("/xreactor/installer_stage.lua")
local startup_lib = dofile("/xreactor/installer_startup.lua")
local storage_lib = dofile("/xreactor/installer_storage.lua")
local installer_http = dofile("/xreactor/installer_http.lua")

if not manifest_lib.files_for_role and manifest_lib.select_expected_files then
  manifest_lib.files_for_role = function(manifest, role_key, role_label, include_dev_files)
    return manifest_lib.select_expected_files(manifest, role_label or role_key, include_dev_files)
  end
end
if not stage_lib.validate_stage and stage_lib.verify_stage then
  stage_lib.validate_stage = stage_lib.verify_stage
end
if not stage_lib.commit_stage and stage_lib.activate_stage then
  stage_lib.commit_stage = function(ctx)
    if stage_lib.copy_config_to_stage then stage_lib.copy_config_to_stage(ctx) end
    return stage_lib.activate_stage(ctx)
  end
end
if not startup_lib.write_startup and startup_lib.ensure_startup_script then
  startup_lib.write_startup = startup_lib.ensure_startup_script
end

local function require_function(lib, name, label)
  if type(lib) ~= "table" or type(lib[name]) ~= "function" then
    error("Installer module API missing: " .. tostring(label) .. "." .. tostring(name), 0)
  end
end

require_function(manifest_lib, "files_for_role", "installer_manifest")
require_function(stage_lib, "validate_stage", "installer_stage")
require_function(stage_lib, "commit_stage", "installer_stage")
require_function(stage_lib, "ensure_role_config", "installer_stage")
require_function(stage_lib, "read_role_config", "installer_stage")
require_function(startup_lib, "write_startup", "installer_startup")
require_function(storage_lib, "cleanup_stage_and_logs", "installer_storage")
require_function(installer_http, "download_url", "installer_http")
require_function(installer_http, "is_html_content", "installer_http")

local M = {}

local ROLE_CHOICES = {
  ["1"] = { key = "master", label = "MASTER" },
  ["2"] = { key = "rt", label = "RT" },
  ["3"] = { key = "energy", label = "ENERGY" },
  ["4"] = { key = "water", label = "WATER" },
  ["5"] = { key = "fuel", label = "FUEL" },
  ["6"] = { key = "reprocessing", label = "REPROCESSING" },
  ["7"] = { key = "log", label = "LOG" }
}

local ROLE_KEY_MAP = {
  MASTER = "master",
  RT = "rt",
  ENERGY = "energy",
  WATER = "water",
  FUEL = "fuel",
  REPROCESSING = "reprocessing",
  LOG = "log",
  LOG_COLLECTOR = "log"
}

local RUNTIME_MODULES = { "installer_main.lua", "installer_http.lua", "installer_manifest.lua", "installer_stage.lua", "installer_startup.lua", "installer_storage.lua" }
local BETA_BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/"
local WRITE_BUFFER_BYTES = 1024

local COMPAT_FILE_CONTENTS = {
  ["nodes/energy/adapter_probe.lua"] = table.concat({
    "local M = {}",
    "function M.probe() return { ok = true, adapters = {} } end",
    "function M.run() return M.probe() end",
    "return M",
    ""
  }, "\n")
}

local function sanitize(value)
  local s = tostring(value or "unknown"):lower():gsub("[^a-z0-9_%-]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return s ~= "" and s or "unknown"
end

local function normalize_free_space(value)
  if type(value) == "number" then return value < 0 and math.huge or value end
  if type(value) == "string" then
    local v = value:match("^%s*(.-)%s*$")
    if v == "unlimited" then return math.huge end
    local n = tonumber(v)
    if n then return n < 0 and math.huge or n end
  end
  return nil
end

local function append_query(url, key, value)
  local sep = tostring(url):find("?", 1, true) and "&" or "?"
  return tostring(url) .. sep .. tostring(key) .. "=" .. tostring(value)
end

local function crc32_table()
  local t = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if bit32.band(crc, 1) == 1 then crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320) else crc = bit32.rshift(crc, 1) end
    end
    t[i] = crc
  end
  return t
end
local CRC32 = crc32_table()

local function crc32(content)
  local crc = 0xFFFFFFFF
  for i = 1, #content do
    local byte = string.byte(content, i)
    local idx = bit32.band(bit32.bxor(crc, byte), 0xFF)
    crc = bit32.bxor(bit32.rshift(crc, 8), CRC32[idx])
  end
  return string.format("%08x", bit32.bxor(crc, 0xFFFFFFFF))
end

local function starts_with(text, prefix)
  return tostring(text or ""):sub(1, #tostring(prefix or "")) == tostring(prefix or "")
end

local function is_log_role(role_label)
  local role = tostring(role_label or ""):upper()
  return role == "LOG" or role == "LOG_COLLECTOR"
end

local function build_context(constants)
  constants.BASE_URL = BETA_BASE_URL
  constants.MANIFEST_URL = BETA_BASE_URL .. "manifest.lua"
  constants.RELEASE_URL = BETA_BASE_URL .. "release.lua"
  local ctx = { constants = constants, fs = fs, source_ref = "beta" }

  function ctx.safe_mkdir(path) if fs.exists(path) then return fs.isDir(path) end local ok = pcall(fs.makeDir, path); return ok and fs.exists(path) and fs.isDir(path) end
  function ctx.timestamp() if os and os.date then return os.date("!%H:%M:%S") end if os and os.time then return tostring(os.time()) end return "unknown-time" end
  function ctx.info(msg) print(msg); ctx.log_line(msg) end
  function ctx.warn(msg) print(msg); ctx.log_line("WARN: " .. tostring(msg)) end
  function ctx.fatal(msg) ctx.warn(msg); error(msg, 0) end

  function ctx.log_line(message)
    pcall(function()
      ctx.safe_mkdir(constants.LOG_DIR)
      local f = fs.open(constants.LOG_PATH, "a")
      if f then f.write(string.format("[%s] %s\n", ctx.timestamp(), tostring(message))); f.close() end
    end)
  end

  function ctx.set_log_target(role)
    constants.LOG_PATH = string.format("%s/installer_%s.log", constants.LOG_DIR, sanitize(role))
    ctx.safe_mkdir(constants.LOG_DIR)
  end

  function ctx.read_file(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local c = f.readAll(); f.close(); return c
  end

  function ctx.free_space() return fs.getFreeSpace and normalize_free_space(fs.getFreeSpace("/")) or nil end

  function ctx.cleanup_for_write(target_path, bytes_needed, reason)
    local free = ctx.free_space()
    local need = math.max(0, tonumber(bytes_needed) or 0) + WRITE_BUFFER_BYTES
    if free == nil or free == math.huge or free >= need then return true end
    ctx.warn(string.format("Low-space write cleanup target=%s free=%s need=%d reason=%s", tostring(target_path), tostring(free), need, tostring(reason or "write")))
    local keep_stage = starts_with(target_path, ctx.constants.STAGE_ROOT .. "/")
    storage_lib.cleanup_stage_and_logs(ctx, { cleanup_logs = true, cleanup_backup = true, keep_stage = keep_stage })
    free = ctx.free_space()
    if free ~= nil and free ~= math.huge and free >= need then return true end
    if keep_stage and ctx.fs.exists(ctx.constants.INSTALL_ROOT) then
      ctx.warn("Deleting existing install root during staging to complete low-space write")
      ctx.fs.delete(ctx.constants.INSTALL_ROOT)
      ctx.low_space_replace = true
    end
    free = ctx.free_space()
    if free == nil or free == math.huge or free >= need then return true end
    return false, string.format("not enough free space for write target=%s free=%s need=%d", tostring(target_path), tostring(free), need)
  end

  function ctx.write_file(path, data)
    local ok_space, space_err = ctx.cleanup_for_write(path, type(data) == "string" and #data or 0, "pre-write")
    if not ok_space then return false, space_err end
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    if not f then
      ctx.cleanup_for_write(path, type(data) == "string" and #data or 0, "open-failed")
      f = fs.open(path, "w")
    end
    if not f then return false, "open failed" end
    local ok_write, write_err = pcall(function() f.write(data) end)
    pcall(function() f.close() end)
    if ok_write then return true end
    ctx.warn("Write failed; retrying after cleanup: " .. tostring(write_err))
    if fs.exists(path) then pcall(fs.delete, path) end
    local ok_retry_space, retry_space_err = ctx.cleanup_for_write(path, type(data) == "string" and #data or 0, "write-failed")
    if not ok_retry_space then return false, retry_space_err end
    f = fs.open(path, "w")
    if not f then return false, "open failed after cleanup" end
    ok_write, write_err = pcall(function() f.write(data) end)
    pcall(function() f.close() end)
    if not ok_write then if fs.exists(path) then pcall(fs.delete, path) end; return false, tostring(write_err or "write failed") end
    return true
  end

  function ctx.write_compat_file(rel, target, download_error)
    local body = COMPAT_FILE_CONTENTS[rel]
    if not body then return false, download_error end
    ctx.warn("Using beta compatibility file for missing manifest entry " .. tostring(rel))
    local ok, err = ctx.write_file(target, body)
    if not ok then return false, err end
    return ctx.validate_download(target)
  end

  function ctx.cache_bust_token(kind, rel, attempt)
    local t = "0"
    if os and type(os.epoch) == "function" then local ok, v = pcall(os.epoch, "utc"); if ok and v then t = tostring(v) end end
    return table.concat({ sanitize(kind), sanitize(ctx.release_id), sanitize(ctx.manifest_id), sanitize(rel), tostring(attempt or 1), t }, "-")
  end

  function ctx.cache_busted_url(url, kind, rel, attempt) return append_query(url, "xr_cb", ctx.cache_bust_token(kind, rel, attempt)) end

  function ctx.download_versioned_url(url, kind, rel)
    local retries = tonumber(constants.DOWNLOAD_RETRIES) or 1
    local delay = tonumber(constants.DOWNLOAD_RETRY_DELAY_SECONDS) or 0
    local last = nil
    for attempt = 1, retries do
      local u = ctx.cache_busted_url(url, kind, rel, attempt)
      local body, err = installer_http.download_url(http, u, 1, delay, nil)
      if body then return body, u end
      last = err
      if attempt < retries and os and os.sleep and delay > 0 then os.sleep(delay) end
    end
    return nil, tostring(last or "download failed")
  end

  function ctx.compile_lua(path, content) if type(loadfile) == "function" then return loadfile(path) end return load(content or "", "=" .. tostring(path), "t", {}) end
  function ctx.size_matches(entry, content) if not entry.size_bytes then return true, #content end return tonumber(entry.size_bytes) == #content, #content end
  function ctx.hash_matches(entry, content) local h = crc32(content); if not entry.hash then return true, h end return string.lower(h) == string.lower(entry.hash), h end

  function ctx.validate_download(path)
    if not fs.exists(path) or fs.getSize(path) <= 0 then return false, "missing-or-empty" end
    local content = ctx.read_file(path)
    if not content or installer_http.is_html_content(content) then return false, "invalid-content" end
    if path:sub(-4) == ".lua" then local loader, err = ctx.compile_lua(path, content); if not loader then return false, tostring(err) end end
    return true
  end

  function ctx.download_file(rel, target, entry)
    ctx.info("Downloading " .. rel)
    local body, url_or_err = ctx.download_versioned_url(constants.BASE_URL .. rel, "file", rel)
    if not body then
      return ctx.write_compat_file(rel, target, url_or_err)
    end
    local size_ok, size_actual = ctx.size_matches(entry or {}, body)
    if not size_ok then ctx.warn(string.format("Ignoring stale manifest size for %s expected=%s actual=%s", rel, tostring(entry and entry.size_bytes), tostring(size_actual))) end
    local hash_ok, hash_actual = ctx.hash_matches(entry or {}, body)
    if not hash_ok then ctx.warn(string.format("Ignoring stale manifest hash for %s expected=%s actual=%s", rel, tostring(entry and entry.hash), tostring(hash_actual))) end
    local ok_space, space_err = ctx.cleanup_for_write(target, #body, "downloaded-body")
    if not ok_space then return false, space_err end
    local ok, err = ctx.write_file(target, body)
    if not ok then return false, err end
    return ctx.validate_download(target)
  end

  function ctx.load_manifest()
    ctx.info("Downloading manifest from " .. constants.MANIFEST_URL)
    local body, err = ctx.download_versioned_url(constants.MANIFEST_URL, "manifest", "manifest.lua")
    if not body then return nil, err end
    ctx.manifest_metadata_body = body
    local loader, load_err = load(body, "=manifest", "t", {})
    if not loader then return nil, load_err end
    local ok, manifest = pcall(loader)
    if not ok or type(manifest) ~= "table" then return nil, manifest or "invalid manifest" end
    ctx.manifest_id = manifest.manifest_id or manifest.manifest_version or "unknown"
    return manifest
  end

  function ctx.resolve_release_source()
    ctx.info(string.format("Downloading release metadata from %s (mode=%s role=%s)", constants.RELEASE_URL, tostring(ctx.install_mode), tostring(ctx.target_role)))
    local body, err = ctx.download_versioned_url(constants.RELEASE_URL, "release", "release.lua")
    if not body then return false, err end
    local loader, load_err = load(body, "=release", "t", {})
    if not loader then return false, load_err end
    local ok, release = pcall(loader)
    if not ok or type(release) ~= "table" then return false, release or "invalid release" end
    ctx.release_metadata_body = body
    ctx.release_id = tostring(release.release_id or "unknown")
    constants.BASE_URL = BETA_BASE_URL
    constants.MANIFEST_URL = BETA_BASE_URL .. "manifest.lua"
    constants.RELEASE_URL = BETA_BASE_URL .. "release.lua"
    ctx.source_ref = "beta"
    ctx.info("Installer source fixed to beta branch")
    return true
  end

  function ctx.log_install_identity(manifest, role_label, mode, expected)
    local n = 0; for _ in pairs(expected or {}) do n = n + 1 end
    ctx.info(string.format("Identity: mode=%s role=%s release=%s manifest=%s files=%d low_space_replace=%s", tostring(mode), tostring(role_label), tostring(ctx.release_id), tostring(ctx.manifest_id or manifest.manifest_id), n, tostring(ctx.low_space_replace == true)))
  end

  return ctx
end

local function select_role()
  print("")
  print("1 MASTER")
  print("2 RT")
  print("3 ENERGY")
  print("4 WATER")
  print("5 FUEL")
  print("6 REPROCESSING")
  print("7 LOG")
  write("Select role: ")
  return ROLE_CHOICES[read()]
end

local function prompt_yes_no(question)
  while true do
    write(question .. " [j/n]: ")
    local answer = tostring(read() or ""):lower()
    if answer == "j" or answer == "ja" or answer == "y" or answer == "yes" then return true end
    if answer == "n" or answer == "nein" or answer == "no" then return false end
    print("Bitte j oder n eingeben.")
  end
end

local function role_from_label(role_label)
  local normalized = tostring(role_label or ""):upper()
  local key = ROLE_KEY_MAP[normalized]
  if not key then return nil end
  return { key = key, label = normalized }
end

local function clean_existing_installation(ctx)
  ctx.info("Cleaning old installation before full reinstall")
  local paths = {
    ctx.constants.STAGE_ROOT,
    ctx.constants.BACKUP_ROOT,
    ctx.constants.INSTALL_ROOT,
    ctx.constants.STARTUP_PATH
  }
  for _, path in ipairs(paths) do
    if type(path) == "string" and path ~= "" and ctx.fs.exists(path) then
      ctx.info("Deleting " .. tostring(path))
      local ok, err = pcall(ctx.fs.delete, path)
      if not ok then return false, "delete failed for " .. tostring(path) .. ": " .. tostring(err) end
    end
  end
  return true
end

local function clean_or_fatal(ctx)
  local ok_clean, clean_err = clean_existing_installation(ctx)
  if not ok_clean then ctx.fatal(clean_err) end
end

local function choose_role_for_reinstall(ctx)
  local existing_label = stage_lib.read_role_config(ctx)
  if existing_label then
    local existing_role = role_from_label(existing_label)
    if existing_role then
      print("")
      print("Vorhandene Rolle gefunden: " .. tostring(existing_role.label))
      if prompt_yes_no("Diese Rolle behalten und komplett neu installieren?") then
        ctx.info("Keeping existing role for full reinstall: " .. tostring(existing_role.label))
        return existing_role, false
      end
      ctx.info("Existing role will be replaced: " .. tostring(existing_role.label))
      clean_or_fatal(ctx)
      local replacement = select_role()
      if not replacement then ctx.fatal("Invalid role") end
      return replacement, true
    end
    ctx.warn("Unknown existing role ignored: " .. tostring(existing_label))
  end

  local role = select_role()
  if not role then ctx.fatal("Invalid role") end
  return role, false
end

local function add_virtual_role_files(expected, role_label)
  if not is_log_role(role_label) then
    if not expected["core/bootstrap.lua"] then expected["core/bootstrap.lua"] = { path = "core/bootstrap.lua" } end
    if not expected["core/utils.lua"] then expected["core/utils.lua"] = { path = "core/utils.lua" } end
  end
end

local function add_runtime_modules(expected)
  for _, path in ipairs(RUNTIME_MODULES) do if not expected[path] then expected[path] = { path = path, always = true } end end
end

local function add_manifest_file(expected)
  if not expected["manifest.lua"] then expected["manifest.lua"] = { path = "manifest.lua", always = true } end
end

local function build_expected(manifest, role)
  local expected = manifest_lib.files_for_role(manifest, role.key, role.label)
  add_virtual_role_files(expected, role.label)
  add_runtime_modules(expected)
  add_manifest_file(expected)
  return expected
end

local function sorted_files(expected)
  local files = {}
  for path, entry in pairs(expected or {}) do files[#files + 1] = { path = path, entry = entry } end
  table.sort(files, function(a, b)
    local sa = tonumber(a.entry and a.entry.size_bytes) or -1
    local sb = tonumber(b.entry and b.entry.size_bytes) or -1
    if sa ~= sb then return sa > sb end
    return tostring(a.path) < tostring(b.path)
  end)
  return files
end

local function install_staged(ctx, files)
  ctx.info("Installing files into stage root: " .. ctx.constants.STAGE_ROOT)
  for _, item in ipairs(files) do
    local rel, entry = item.path, item.entry
    local target = ctx.constants.STAGE_ROOT .. "/" .. rel
    local ok, err = ctx.download_file(rel, target, entry)
    if not ok then return false, "Download failed: " .. tostring(err) end
  end
  return true
end

function M.run(constants)
  local ctx = build_context(constants)
  storage_lib.cleanup_stage_and_logs(ctx, { cleanup_logs = true, cleanup_backup = false, keep_stage = false })
  local role, already_cleaned = choose_role_for_reinstall(ctx)
  ctx.target_role = role.label
  ctx.set_log_target(role.label)
  ctx.install_mode = "reinstall"
  if not already_cleaned then
    clean_or_fatal(ctx)
  end
  local ok_release, release_err = ctx.resolve_release_source(); if not ok_release then ctx.fatal(release_err) end
  local manifest, manifest_err = ctx.load_manifest(); if not manifest then ctx.fatal(manifest_err) end
  local expected = build_expected(manifest, role)
  ctx.log_install_identity(manifest, role.label, "reinstall", expected)
  local files = sorted_files(expected)

  -- Preflight: check disk space. If low, automatically delete logs and old
  -- backup/stage dirs to reclaim space before aborting.
  local storage_plan = storage_lib.estimate_required_storage(
    ctx.fs, ctx.constants.INSTALL_ROOT, expected, ctx.install_mode, ctx.constants)
  local ok_space, space_err = storage_lib.preflight_storage(ctx, storage_plan, {
    allow_cleanup  = true,   -- automatically reclaim space if needed
    cleanup_logs   = true,   -- delete /xreactor_logs/* to recover space
    cleanup_backup = true,   -- delete old backup dir
    keep_stage     = false,
  })
  if not ok_space then ctx.fatal(space_err) end

  local ok_stage, stage_err = install_staged(ctx, files); if not ok_stage then ctx.fatal(stage_err) end
  local ok_validate, validate_err = stage_lib.validate_stage(ctx, expected)
  if not ok_validate then ctx.fatal("Staged validation failed: " .. tostring(validate_err)) end
  local ok_commit, commit_err = stage_lib.commit_stage(ctx)
  if not ok_commit then ctx.fatal(commit_err) end
  stage_lib.ensure_role_config(ctx, ctx.constants.INSTALL_ROOT, role.label)
  startup_lib.write_startup(ctx, role.label)
  ctx.info("Install complete")
end

return M
