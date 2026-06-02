local manifest_lib = dofile("/xreactor/installer_manifest.lua")
local stage_lib = dofile("/xreactor/installer_stage.lua")
local startup_lib = dofile("/xreactor/installer_startup.lua")
local storage_lib = dofile("/xreactor/installer_storage.lua")
local installer_http = dofile("/xreactor/installer_http.lua")

local M = {}

local ROLE_CHOICES = {
  ["1"] = { key = "master", label = "MASTER" },
  ["2"] = { key = "rt", label = "RT" },
  ["3"] = { key = "energy", label = "ENERGY" },
  ["4"] = { key = "water", label = "WATER" },
  ["5"] = { key = "fuel", label = "FUEL" },
  ["6"] = { key = "reprocessing", label = "REPROCESSING" }
}

local ROLE_KEY_MAP = {
  MASTER = "master",
  RT = "rt",
  ENERGY = "energy",
  WATER = "water",
  FUEL = "fuel",
  REPROCESSING = "reprocessing"
}

local RUNTIME_MODULES = {
  "installer_main.lua",
  "installer_http.lua",
  "installer_manifest.lua",
  "installer_stage.lua",
  "installer_startup.lua",
  "installer_storage.lua"
}

local BETA_BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/"

local function sanitize_log_segment(value)
  local raw = tostring(value or "unknown")
  local lowered = string.lower(raw)
  local sanitized = lowered:gsub("[^a-z0-9_%-]+", "_")
  sanitized = sanitized:gsub("^_+", ""):gsub("_+$", "")
  if sanitized == "" then return "unknown" end
  return sanitized
end

local function append_query_param(url, key, value)
  local sep = tostring(url or ""):find("?", 1, true) and "&" or "?"
  return tostring(url or "") .. sep .. tostring(key or "q") .. "=" .. tostring(value or "")
end

local function normalize_free_space(value)
  if type(value) == "number" then
    if value < 0 then return math.huge end
    return value
  end
  if type(value) == "string" then
    local trimmed = tostring(value):match("^%s*(.-)%s*$")
    if trimmed == "unlimited" then return math.huge end
    local parsed = tonumber(trimmed)
    if parsed then
      if parsed < 0 then return math.huge end
      return parsed
    end
  end
  return nil
end

local function build_crc32_table()
  local table_crc = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if bit32.band(crc, 1) == 1 then crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320) else crc = bit32.rshift(crc, 1) end
    end
    table_crc[i] = crc
  end
  return table_crc
end

local CRC32_TABLE = build_crc32_table()

local function crc32_hash(content)
  local crc = 0xFFFFFFFF
  for i = 1, #content do
    local byte = string.byte(content, i)
    local idx = bit32.band(bit32.bxor(crc, byte), 0xFF)
    crc = bit32.bxor(bit32.rshift(crc, 8), CRC32_TABLE[idx])
  end
  return string.format("%08x", bit32.bxor(crc, 0xFFFFFFFF))
end

local function build_context(constants)
  constants.BASE_URL = BETA_BASE_URL
  constants.MANIFEST_URL = BETA_BASE_URL .. "manifest.lua"
  constants.RELEASE_URL = BETA_BASE_URL .. "release.lua"

  local ctx = { constants = constants, fs = fs, source_ref = "beta" }

  function ctx.safe_mkdir(path)
    if fs.exists(path) then return fs.isDir(path) end
    local ok = pcall(fs.makeDir, path)
    return ok and fs.exists(path) and fs.isDir(path)
  end

  function ctx.timestamp()
    if os and os.date then return os.date("!%H:%M:%S") end
    if os and os.time then return tostring(os.time()) end
    return "unknown-time"
  end

  function ctx.cache_bust_token(kind, remote_path, attempt)
    local release = sanitize_log_segment(ctx.release_id or "unknown")
    local manifest = sanitize_log_segment(ctx.manifest_id or "unknown")
    local path_segment = sanitize_log_segment(remote_path or kind or "root")
    local time_token = "0"
    if os and type(os.epoch) == "function" then
      local ok, value = pcall(os.epoch, "utc")
      if ok and value then time_token = tostring(value) end
    elseif os and type(os.time) == "function" then
      local ok, value = pcall(os.time)
      if ok and value then time_token = tostring(value) end
    end
    return table.concat({ sanitize_log_segment(kind or "download"), release, manifest, path_segment, tostring(attempt or 1), time_token }, "-")
  end

  function ctx.cache_busted_url(url, kind, remote_path, attempt)
    return append_query_param(url, "xr_cb", ctx.cache_bust_token(kind, remote_path, attempt))
  end

  function ctx.log_line(message)
    pcall(function()
      ctx.safe_mkdir(constants.LOG_DIR)
      local file = fs.open(constants.LOG_PATH, "a")
      if not file then return end
      file.write(string.format("[%s] %s\n", ctx.timestamp(), tostring(message)))
      file.close()
    end)
  end

  function ctx.set_log_target(role_label)
    local role_segment = sanitize_log_segment(role_label)
    constants.LOG_PATH = string.format("%s/installer_%s.log", constants.LOG_DIR, role_segment)
    ctx.safe_mkdir(constants.LOG_DIR)
  end

  function ctx.info(message) print(message); ctx.log_line(message) end
  function ctx.warn(message) print(message); ctx.log_line("WARN: " .. tostring(message)) end
  function ctx.error_msg(message) print(message); ctx.log_line("ERROR: " .. tostring(message)) end
  function ctx.fatal(message) ctx.warn(message); error(message, 0) end

  function ctx.read_file(path)
    local file = fs.open(path, "r")
    if not file then return nil end
    local content = file.readAll()
    file.close()
    return content
  end

  function ctx.write_file(path, data)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local h = fs.open(path, "w")
    if not h then return false, "open failed" end
    h.write(data)
    h.close()
    return true
  end

  function ctx.free_space()
    if not fs.getFreeSpace then return nil end
    return normalize_free_space(fs.getFreeSpace("/"))
  end

  function ctx.download_versioned_url(url, kind, remote_path)
    if type(url) ~= "string" or url == "" then return nil, "invalid url" end
    local retries = tonumber(constants.DOWNLOAD_RETRIES) or 1
    local delay = tonumber(constants.DOWNLOAD_RETRY_DELAY_SECONDS) or 0
    local last_error = nil
    for attempt = 1, retries do
      local attempt_url = ctx.cache_busted_url(url, kind, remote_path, attempt)
      local body, err = installer_http.download_url(http, attempt_url, 1, delay, nil)
      if body then return body, attempt_url end
      last_error = tostring(err or ("Failed to download " .. tostring(attempt_url)))
      if attempt < retries then
        ctx.warn(string.format("Download attempt %d/%d failed for %s (%s)", attempt, retries, tostring(remote_path or url), tostring(last_error)))
        if os and type(os.sleep) == "function" and delay > 0 then os.sleep(delay) end
      end
    end
    return nil, tostring(last_error or ("Failed to download " .. tostring(url)))
  end

  function ctx.compile_lua(path, content)
    if type(loadfile) == "function" then return loadfile(path) end
    return load(content or "", "=" .. tostring(path), "t", {})
  end

  function ctx.validate_download(path)
    if not fs.exists(path) then ctx.error_msg("Download validation failed: missing file " .. tostring(path)); return false, "missing file" end
    if fs.getSize(path) <= 0 then fs.delete(path); ctx.error_msg("Download validation failed: empty file " .. tostring(path)); return false, "empty file" end
    local content = ctx.read_file(path)
    if not content then fs.delete(path); ctx.error_msg("Download validation failed: unreadable file " .. tostring(path)); return false, "unreadable file" end
    if installer_http.is_html_content(content) then fs.delete(path); ctx.error_msg("Download validation failed: HTML content for " .. tostring(path)); return false, "html content" end
    if path:sub(-4) == ".lua" then
      local loader, err = ctx.compile_lua(path, content)
      if not loader then fs.delete(path); ctx.error_msg("Download validation failed: Lua parse error for " .. tostring(path) .. " (" .. tostring(err) .. ")"); return false, "lua parse error" end
    end
    return true
  end

  function ctx.hash_matches(entry, content)
    local computed = crc32_hash(content)
    if not entry.hash then return true, computed end
    return string.lower(computed) == string.lower(entry.hash), computed
  end

  function ctx.size_matches(entry, content)
    if not entry.size_bytes then return true, #content end
    local actual_size = #content
    return tonumber(entry.size_bytes) == actual_size, actual_size
  end

  function ctx.download_file(remote_path, target_path, entry)
    local url = constants.BASE_URL .. remote_path
    ctx.info("Downloading " .. remote_path)
    local body, resolved_url_or_err = ctx.download_versioned_url(url, "file", remote_path)
    if not body then return false, resolved_url_or_err end
    local resolved_entry = entry or {}
    local size_ok, actual_size = ctx.size_matches(resolved_entry, body)
    if not size_ok then return false, string.format("size mismatch for %s (url=%s expected=%s actual=%s)", tostring(remote_path), tostring(resolved_url_or_err), tostring(resolved_entry.size_bytes), tostring(actual_size)) end
    local hash_ok, actual_hash = ctx.hash_matches(resolved_entry, body)
    if not hash_ok then return false, string.format("hash mismatch for %s (url=%s expected=%s actual=%s manifest=%s release=%s source_ref=%s)", tostring(remote_path), tostring(resolved_url_or_err), tostring(resolved_entry.hash), tostring(actual_hash), tostring(ctx.manifest_id or "unknown"), tostring(ctx.release_id or "unknown"), tostring(ctx.source_ref or "unknown")) end
    local ok, write_err = ctx.write_file(target_path, body)
    if not ok then return false, write_err end
    local valid, valid_err = ctx.validate_download(target_path)
    if not valid then return false, valid_err end
    return true
  end

  function ctx.load_manifest()
    ctx.info("Downloading manifest from " .. tostring(constants.MANIFEST_URL))
    local body, err = ctx.download_versioned_url(constants.MANIFEST_URL, "manifest", "manifest.lua")
    if not body then return nil, err end
    ctx.manifest_metadata_body = body
    local loader, load_err = load(body, "=manifest", "t", {})
    if not loader then return nil, load_err end
    local ok, manifest = pcall(loader)
    if not ok then return nil, manifest end
    if type(manifest) ~= "table" then return nil, "Manifest invalid" end
    if type(manifest.base_files) ~= "table" or type(manifest.roles) ~= "table" then return nil, "Manifest missing base_files or roles" end
    ctx.manifest_id = manifest.manifest_id or manifest.manifest_version or "unknown"
    return manifest
  end

  function ctx.resolve_release_source()
    ctx.info(string.format("Downloading release metadata from %s (mode=%s role=%s)", tostring(constants.RELEASE_URL), tostring(ctx.install_mode or "unknown"), tostring(ctx.target_role or "unknown")))
    local body, err = ctx.download_versioned_url(constants.RELEASE_URL, "release", "release.lua")
    if not body then return false, err end
    local loader, load_err = load(body, "=release", "t", {})
    if not loader then return false, load_err end
    local ok, release = pcall(loader)
    if not ok then return false, release end
    if type(release) ~= "table" then return false, "release metadata invalid" end
    ctx.release_metadata_body = body
    ctx.release_id = tostring(release.release_id or "unknown")
    local commit_sha = tostring(release.commit_sha or "")
    if commit_sha ~= "" and commit_sha ~= "beta" then return false, string.format("release metadata commit pin is not allowed in beta install strategy (commit_sha=%s)", tostring(commit_sha)) end
    local release_source_ref = tostring(release.source_ref or "beta")
    if release_source_ref ~= "" and release_source_ref ~= "beta" then return false, string.format("release metadata source_ref is not allowed in beta install strategy (source_ref=%s)", tostring(release_source_ref)) end
    constants.BASE_URL = BETA_BASE_URL
    constants.MANIFEST_URL = constants.BASE_URL .. "manifest.lua"
    constants.RELEASE_URL = constants.BASE_URL .. "release.lua"
    ctx.source_ref = "beta"
    ctx.info("Installer source fixed to beta branch")
    return true
  end

  function ctx.log_install_identity(manifest, role_label, mode, expected)
    local file_count = 0
    for _ in pairs(expected or {}) do file_count = file_count + 1 end
    ctx.info(string.format("Identity: mode=%s role=%s release=%s manifest=%s files=%d low_space_replace=%s", tostring(mode), tostring(role_label), tostring(ctx.release_id or "unknown"), tostring(ctx.manifest_id or manifest.manifest_id or manifest.manifest_version or "unknown"), file_count, tostring(ctx.low_space_replace == true)))
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
  write("Select role: ")
  return ROLE_CHOICES[read()]
end

local function stage_and_verify(ctx, expected)
  local stage_ok, stage_err = stage_lib.verify_stage(ctx, expected)
  if not stage_ok then
    ctx.fs.delete(ctx.constants.STAGE_ROOT)
    ctx.fatal("Staged validation failed: " .. tostring(stage_err))
  end
end

local function enforce_source_consistency(ctx, manifest)
  local release_source = tostring(ctx.source_ref or "")
  local manifest_source = tostring(manifest.source_ref or "")
  if release_source ~= "" and release_source ~= "beta" then ctx.fatal(string.format("Installer source_ref must be beta during normal install/update (got %s)", tostring(release_source))) end
  if manifest_source ~= "" and manifest_source ~= "beta" then ctx.fatal(string.format("Manifest source_ref must be beta during normal install/update (got %s)", tostring(manifest_source))) end
end

local function enforce_release_metadata_strategy(ctx, expected)
  if not expected["release.lua"] then ctx.fatal("Manifest expected files missing release.lua in beta install strategy") end
  if type(ctx.release_metadata_body) ~= "string" or ctx.release_metadata_body == "" then ctx.fatal("Release metadata body missing before stage download in beta install strategy") end
end

local function reboot_after_success(ctx, label)
  ctx.info(tostring(label or "Install/update") .. " complete; rebooting in 3 seconds")
  if os and type(os.sleep) == "function" then os.sleep(3) end
  if os and type(os.reboot) == "function" then os.reboot() end
end

local function refresh_installer_runtime(ctx)
  if _G.__XREACTOR_INSTALLER_SELF_REFRESHED then return false end
  ctx.info("Refreshing installer runtime modules from beta before action")
  local self_changed = false
  local changed = false
  for _, rel in ipairs(RUNTIME_MODULES) do
    local path = ctx.constants.INSTALL_ROOT .. "/" .. rel
    local body, err = ctx.download_versioned_url(ctx.constants.BASE_URL .. rel, "installer-runtime", rel)
    if not body then return false, "download failed for " .. rel .. " (" .. tostring(err) .. ")" end
    if installer_http.is_html_content(body) then return false, "unexpected HTML for " .. rel end
    if rel:sub(-4) == ".lua" then
      local loader, parse_err = load(body, "=" .. rel, "t", {})
      if not loader then return false, "lua parse error for " .. rel .. " (" .. tostring(parse_err) .. ")" end
    end
    local existing = ctx.read_file(path)
    if existing ~= body then
      local ok, write_err = ctx.write_file(path, body)
      if not ok then return false, "write failed for " .. rel .. " (" .. tostring(write_err) .. ")" end
      changed = true
      if rel == "installer_main.lua" then self_changed = true end
    end
  end
  if self_changed then
    ctx.info("Installer main updated; restarting installer runtime once")
    _G.__XREACTOR_INSTALLER_SELF_REFRESHED = true
    local reloaded = dofile(ctx.constants.INSTALL_ROOT .. "/installer_main.lua")
    reloaded.run(ctx.constants)
    return true
  end
  if changed then ctx.info("Installer runtime modules refreshed") end
  return false
end

local function prepare_low_space_replace(ctx, storage_plan, role_label, reason)
  local free = ctx.free_space and ctx.free_space() or nil
  if free == nil or free == math.huge then return false end
  local required = tonumber(storage_plan.required_bytes) or 0
  if free >= required then return false end

  ctx.warn(string.format("Low-space replace mode enabled role=%s free=%s required=%s reason=%s", tostring(role_label), tostring(free), tostring(required), tostring(reason or "low-space")))
  storage_lib.cleanup_stage_and_logs(ctx, { cleanup_logs = true, cleanup_backup = true })
  if ctx.fs.exists(ctx.constants.INSTALL_ROOT) then
    local old_size = storage_lib.measure_tree_size(ctx.fs, ctx.constants.INSTALL_ROOT)
    ctx.warn(string.format("Deleting existing install root before staging to free space: %s bytes=%d", tostring(ctx.constants.INSTALL_ROOT), old_size))
    ctx.fs.delete(ctx.constants.INSTALL_ROOT)
  end
  ctx.low_space_replace = true
  return true
end

local function preflight_or_replace(ctx, storage_plan, role_label, mode)
  local cleanup_logs = mode == "install"
  local preflight_ok, preflight_err = storage_lib.preflight_storage(ctx, storage_plan, { allow_cleanup = true, cleanup_logs = cleanup_logs, cleanup_backup = true })
  if preflight_ok then
    prepare_low_space_replace(ctx, storage_plan, role_label, "preflight-low-but-continuing")
    return true
  end
  if prepare_low_space_replace(ctx, storage_plan, role_label, preflight_err) then
    local refreshed = storage_lib.estimate_required_storage(ctx.fs, ctx.constants.INSTALL_ROOT, storage_plan.expected or {}, mode, ctx.constants)
    local ok_after, err_after = storage_lib.preflight_storage(ctx, refreshed, { allow_cleanup = true, cleanup_logs = false, cleanup_backup = true })
    if ok_after then return true end
    ctx.fatal("Storage preflight failed even after low-space replace: " .. tostring(err_after))
  end
  ctx.fatal("Storage preflight failed: " .. tostring(preflight_err))
end

local function run_install(ctx)
  local role = select_role()
  if not role then ctx.fatal("Invalid role selection") end
  ctx.install_mode = "install"
  ctx.target_role = role.label
  ctx.set_log_target(role.label)
  ctx.info("Installer log target: " .. tostring(ctx.constants.LOG_PATH))
  ctx.info("Selected action: Neuinstallation")
  ctx.info("Selected role: " .. role.label)

  local source_ok, source_err = ctx.resolve_release_source()
  if not source_ok then ctx.fatal("Release metadata error: " .. tostring(source_err)) end
  local manifest, err = ctx.load_manifest()
  if not manifest then ctx.fatal("Manifest error: " .. tostring(err)) end
  enforce_source_consistency(ctx, manifest)
  local expected = manifest_lib.select_expected_files(manifest, role.label, ctx.constants.INCLUDE_DEV_FILES)
  enforce_release_metadata_strategy(ctx, expected)
  local storage_plan = storage_lib.estimate_required_storage(ctx.fs, ctx.constants.INSTALL_ROOT, expected, "install", ctx.constants)
  storage_plan.expected = expected
  preflight_or_replace(ctx, storage_plan, role.label, "install")
  local stage_ok, stage_err = stage_lib.stage_expected_files(ctx, expected)
  if not stage_ok then ctx.fatal(tostring(stage_err)) end
  stage_lib.ensure_role_config(ctx, ctx.constants.STAGE_ROOT, role.label)
  stage_and_verify(ctx, expected)
  stage_lib.activate_stage(ctx)
  stage_lib.ensure_role_config(ctx, ctx.constants.INSTALL_ROOT, role.label)
  startup_lib.ensure_startup_script(ctx)
  ctx.log_install_identity(manifest, role.label, "install", expected)
  reboot_after_success(ctx, "Installation")
  return true
end

local function run_update(ctx)
  local role_label = stage_lib.read_role_config(ctx)
  if not role_label then ctx.fatal("Role config missing; cannot update") end
  if not ROLE_KEY_MAP[role_label] then ctx.fatal("Unknown role in config: " .. tostring(role_label)) end
  ctx.install_mode = "update"
  ctx.target_role = role_label
  ctx.set_log_target(role_label)
  ctx.info("Installer log target: " .. tostring(ctx.constants.LOG_PATH))
  ctx.info("Selected action: Update")
  local source_ok, source_err = ctx.resolve_release_source()
  if not source_ok then ctx.fatal("Release metadata error: " .. tostring(source_err)) end
  local manifest, err = ctx.load_manifest()
  if not manifest then ctx.fatal("Manifest error: " .. tostring(err)) end
  enforce_source_consistency(ctx, manifest)
  ctx.info("Selected role: " .. role_label)
  local expected = manifest_lib.select_expected_files(manifest, role_label, ctx.constants.INCLUDE_DEV_FILES)
  enforce_release_metadata_strategy(ctx, expected)
  local storage_plan = storage_lib.estimate_required_storage(ctx.fs, ctx.constants.INSTALL_ROOT, expected, "update", ctx.constants)
  storage_plan.expected = expected
  preflight_or_replace(ctx, storage_plan, role_label, "update")
  local stage_ok, stage_err = stage_lib.stage_expected_files(ctx, expected)
  if not stage_ok then ctx.fatal(tostring(stage_err)) end
  if not ctx.low_space_replace then stage_lib.copy_config_to_stage(ctx) end
  stage_lib.ensure_role_config(ctx, ctx.constants.STAGE_ROOT, role_label)
  stage_and_verify(ctx, expected)
  stage_lib.activate_stage(ctx)
  stage_lib.ensure_role_config(ctx, ctx.constants.INSTALL_ROOT, role_label)
  startup_lib.ensure_startup_script(ctx)
  ctx.log_install_identity(manifest, role_label, "update", expected)
  reboot_after_success(ctx, "Update")
  return true
end

function M.run(constants)
  local ctx = build_context(constants)
  ctx.set_log_target("bootstrap")
  ctx.log_line("installer start")
  local restarted, refresh_err = refresh_installer_runtime(ctx)
  if refresh_err then ctx.fatal("Installer self-refresh failed: " .. tostring(refresh_err)) end
  if restarted then return true end
  print("XReactor Installer")
  print("")
  print("1 - Neuinstallation")
  print("2 - Update")
  print("3 - Abbrechen")
  write("Select option: ")
  local choice = read()
  if choice == "1" then return run_install(ctx) end
  if choice == "2" then return run_update(ctx) end
  print("Aborted")
  return false
end

return M