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
  ["6"] = { key = "reprocessing", label = "REPROCESSING" },
  ["7"] = { key = "log", label = "LOG" }
}

local ROLE_KEY_MAP = { MASTER = "master", RT = "rt", ENERGY = "energy", WATER = "water", FUEL = "fuel", REPROCESSING = "reprocessing", LOG = "log" }
local RUNTIME_MODULES = { "installer_main.lua", "installer_http.lua", "installer_manifest.lua", "installer_stage.lua", "installer_startup.lua", "installer_storage.lua" }
local BETA_BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/xreactor/"
local WRITE_BUFFER_BYTES = 1024

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
    if not body then return false, url_or_err end
    local size_ok, size_actual = ctx.size_matches(entry or {}, body)
    if not size_ok then return false, string.format("size mismatch for %s expected=%s actual=%s", rel, tostring(entry and entry.size_bytes), tostring(size_actual)) end
    local hash_ok, hash_actual = ctx.hash_matches(entry or {}, body)
    if not hash_ok then return false, string.format("hash mismatch for %s expected=%s actual=%s", rel, tostring(entry and entry.hash), tostring(hash_actual)) end
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
  print(""); print("1 MASTER"); print("2 RT"); print("3 ENERGY"); print("4 WATER"); print("5 FUEL"); print("6 REPROCESSING"); print("7 LOG")
  write("Select role: ")
  return ROLE_CHOICES[read()]
end

local function add_virtual_role_files(expected, role_label)
  if not is_log_role(role_label) then
    expected["core/utils.lua"] = expected["core/utils.lua"] or { path = "core/utils.lua", always = true }
  end
  if is_log_role(role_label) then
    expected["nodes/log_collector/main.lua"] = { path = "nodes/log_collector/main.lua", required_for = { "LOG", "LOG_COLLECTOR" } }
  end
end

local function enforce_release_metadata_strategy(ctx, expected)
  if not expected["release.lua"] then ctx.fatal("Manifest expected files missing release.lua") end
  if type(ctx.release_metadata_body) ~= "string" or ctx.release_metadata_body == "" then ctx.fatal("Release metadata body missing") end
end

local function enforce_source_consistency(ctx, manifest)
  if tostring(ctx.source_ref or "beta") ~= "beta" then ctx.fatal("Installer source_ref must be beta") end
  if tostring(manifest.source_ref or "beta") ~= "beta" then ctx.fatal("Manifest source_ref must be beta") end
end

local function stage_and_verify(ctx, expected)
  local ok, err = stage_lib.verify_stage(ctx, expected)
  if not ok then if ctx.fs.exists(ctx.constants.STAGE_ROOT) then ctx.fs.delete(ctx.constants.STAGE_ROOT) end; ctx.fatal("Staged validation failed: " .. tostring(err)) end
end

local function reboot_after_success(ctx, label)
  ctx.info(tostring(label or "Install/update") .. " complete; rebooting in 3 seconds")
  if os and os.sleep then os.sleep(3) end
  if os and os.reboot then os.reboot() end
end

local function refresh_installer_runtime(ctx)
  if _G.__XREACTOR_INSTALLER_SELF_REFRESHED then return false end
  ctx.info("Refreshing installer runtime modules from beta before action")
  local self_changed = false
  for _, rel in ipairs(RUNTIME_MODULES) do
    local path = ctx.constants.INSTALL_ROOT .. "/" .. rel
    local body, err = ctx.download_versioned_url(ctx.constants.BASE_URL .. rel, "installer-runtime", rel)
    if not body then return false, "download failed for " .. rel .. " (" .. tostring(err) .. ")" end
    if installer_http.is_html_content(body) then return false, "unexpected HTML for " .. rel end
    if rel:sub(-4) == ".lua" then local loader, parse_err = load(body, "=" .. rel, "t", {}); if not loader then return false, "lua parse error for " .. rel .. " (" .. tostring(parse_err) .. ")" end end
    local ok_space, space_err = ctx.cleanup_for_write(path, #body, "self-refresh")
    if not ok_space then return false, space_err end
    if ctx.read_file(path) ~= body then local ok, write_err = ctx.write_file(path, body); if not ok then return false, write_err end; if rel == "installer_main.lua" then self_changed = true end end
  end
  if self_changed then _G.__XREACTOR_INSTALLER_SELF_REFRESHED = true; dofile(ctx.constants.INSTALL_ROOT .. "/installer_main.lua").run(ctx.constants); return true end
  return false
end

local function prepare_low_space_replace(ctx, plan, role, reason)
  local free = ctx.free_space and ctx.free_space() or nil
  local required = tonumber(plan.required_bytes) or 0
  if free == nil or free == math.huge or free >= required then return false end
  ctx.warn(string.format("Low-space replace mode enabled role=%s free=%s required=%s reason=%s", tostring(role), tostring(free), tostring(required), tostring(reason)))
  storage_lib.cleanup_stage_and_logs(ctx, { cleanup_logs = true, cleanup_backup = true })
  if ctx.fs.exists(ctx.constants.INSTALL_ROOT) then ctx.warn("Deleting existing install root before staging"); ctx.fs.delete(ctx.constants.INSTALL_ROOT) end
  ctx.low_space_replace = true
  return true
end

local function preflight_or_replace(ctx, plan, role, mode)
  storage_lib.cleanup_stage_and_logs(ctx, { cleanup_logs = true, cleanup_backup = true })
  local ok, err = storage_lib.preflight_storage(ctx, plan, { allow_cleanup = true, cleanup_logs = true, cleanup_backup = true })
  if ok then prepare_low_space_replace(ctx, plan, role, "preflight-low-but-continuing"); return true end
  if prepare_low_space_replace(ctx, plan, role, err) then return true end
  ctx.fatal("Storage preflight failed: " .. tostring(err))
end

local function build_expected(ctx, manifest, role_label)
  local expected = manifest_lib.select_expected_files(manifest, role_label, ctx.constants.INCLUDE_DEV_FILES)
  add_virtual_role_files(expected, role_label)
  enforce_release_metadata_strategy(ctx, expected)
  return expected
end

local function run_install(ctx)
  local role = select_role(); if not role then ctx.fatal("Invalid role selection") end
  ctx.install_mode = "install"; ctx.target_role = role.label; ctx.set_log_target(role.label)
  ctx.info("Selected action: Neuinstallation"); ctx.info("Selected role: " .. role.label)
  local ok, err = ctx.resolve_release_source(); if not ok then ctx.fatal("Release metadata error: " .. tostring(err)) end
  local manifest, merr = ctx.load_manifest(); if not manifest then ctx.fatal("Manifest error: " .. tostring(merr)) end
  enforce_source_consistency(ctx, manifest)
  local expected = build_expected(ctx, manifest, role.label)
  local plan = storage_lib.estimate_required_storage(ctx.fs, ctx.constants.INSTALL_ROOT, expected, "install", ctx.constants); plan.expected = expected
  preflight_or_replace(ctx, plan, role.label, "install")
  local stage_ok, stage_err = stage_lib.stage_expected_files(ctx, expected); if not stage_ok then ctx.fatal(tostring(stage_err)) end
  stage_lib.ensure_role_config(ctx, ctx.constants.STAGE_ROOT, role.label)
  stage_and_verify(ctx, expected); stage_lib.activate_stage(ctx); stage_lib.ensure_role_config(ctx, ctx.constants.INSTALL_ROOT, role.label); startup_lib.ensure_startup_script(ctx)
  ctx.log_install_identity(manifest, role.label, "install", expected); reboot_after_success(ctx, "Installation"); return true
end

local function run_update(ctx)
  local role_label = stage_lib.read_role_config(ctx); if not role_label then ctx.fatal("Role config missing; cannot update") end
  if not ROLE_KEY_MAP[role_label] then ctx.fatal("Unknown role in config: " .. tostring(role_label)) end
  ctx.install_mode = "update"; ctx.target_role = role_label; ctx.set_log_target(role_label)
  ctx.info("Selected action: Update"); ctx.info("Selected role: " .. role_label)
  local ok, err = ctx.resolve_release_source(); if not ok then ctx.fatal("Release metadata error: " .. tostring(err)) end
  local manifest, merr = ctx.load_manifest(); if not manifest then ctx.fatal("Manifest error: " .. tostring(merr)) end
  enforce_source_consistency(ctx, manifest)
  local expected = build_expected(ctx, manifest, role_label)
  local plan = storage_lib.estimate_required_storage(ctx.fs, ctx.constants.INSTALL_ROOT, expected, "update", ctx.constants); plan.expected = expected
  preflight_or_replace(ctx, plan, role_label, "update")
  local stage_ok, stage_err = stage_lib.stage_expected_files(ctx, expected); if not stage_ok then ctx.fatal(tostring(stage_err)) end
  if not ctx.low_space_replace then stage_lib.copy_config_to_stage(ctx) end
  stage_lib.ensure_role_config(ctx, ctx.constants.STAGE_ROOT, role_label)
  stage_and_verify(ctx, expected); stage_lib.activate_stage(ctx); stage_lib.ensure_role_config(ctx, ctx.constants.INSTALL_ROOT, role_label); startup_lib.ensure_startup_script(ctx)
  ctx.log_install_identity(manifest, role_label, "update", expected); reboot_after_success(ctx, "Update"); return true
end

function M.run(constants)
  local ctx = build_context(constants); ctx.set_log_target("bootstrap"); ctx.log_line("installer start")
  local restarted, refresh_err = refresh_installer_runtime(ctx); if refresh_err then ctx.fatal("Installer self-refresh failed: " .. tostring(refresh_err)) end; if restarted then return true end
  print("XReactor Installer"); print(""); print("1 - Neuinstallation"); print("2 - Update"); print("3 - Abbrechen"); write("Select option: ")
  local choice = read()
  if choice == "1" then return run_install(ctx) end
  if choice == "2" then return run_update(ctx) end
  print("Aborted"); return false
end

return M
