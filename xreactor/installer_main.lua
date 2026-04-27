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

local function build_crc32_table()
  local table_crc = {}
  for i = 0, 255 do
    local crc = i
    for _ = 1, 8 do
      if bit32.band(crc, 1) == 1 then
        crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
      else
        crc = bit32.rshift(crc, 1)
      end
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
  local ctx = {
    constants = constants,
    fs = fs
  }

  function ctx.safe_mkdir(path)
    if fs.exists(path) then
      return fs.isDir(path)
    end
    local ok = pcall(fs.makeDir, path)
    return ok and fs.exists(path) and fs.isDir(path)
  end

  function ctx.timestamp()
    if os and os.date then
      return os.date("!%H:%M:%S")
    end
    if os and os.time then
      return tostring(os.time())
    end
    return "unknown-time"
  end

  function ctx.log_line(message)
    local ok = pcall(function()
      ctx.safe_mkdir(constants.LOG_DIR)
      local file = fs.open(constants.LOG_PATH, "a")
      if not file then
        return
      end
      file.write(string.format("[%s] %s\n", ctx.timestamp(), tostring(message)))
      file.close()
    end)
    if not ok then
      return
    end
  end

  function ctx.info(message)
    print(message)
    ctx.log_line(message)
  end

  function ctx.warn(message)
    print(message)
    ctx.log_line("WARN: " .. tostring(message))
  end

  function ctx.error_msg(message)
    print(message)
    ctx.log_line("ERROR: " .. tostring(message))
  end

  function ctx.fatal(message)
    ctx.warn(message)
    error(message, 0)
  end

  function ctx.read_file(path)
    local file = fs.open(path, "r")
    if not file then
      return nil
    end
    local content = file.readAll()
    file.close()
    return content
  end

  function ctx.write_file(path, data)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
      fs.makeDir(dir)
    end

    local h = fs.open(path, "w")
    if not h then
      return false, "open failed"
    end

    h.write(data)
    h.close()
    return true
  end

  function ctx.download_url(url)
    return installer_http.download_url(http, url, constants.DOWNLOAD_RETRIES, constants.DOWNLOAD_RETRY_DELAY_SECONDS, ctx.warn)
  end

  function ctx.compile_lua(path, content)
    if type(loadfile) == "function" then
      return loadfile(path)
    end
    return load(content or "", "=" .. tostring(path), "t", {})
  end

  function ctx.validate_download(path)
    if not fs.exists(path) then
      ctx.error_msg("Download validation failed: missing file " .. tostring(path))
      return false, "missing file"
    end
    if fs.getSize(path) <= 0 then
      fs.delete(path)
      ctx.error_msg("Download validation failed: empty file " .. tostring(path))
      return false, "empty file"
    end
    local content = ctx.read_file(path)
    if not content then
      fs.delete(path)
      ctx.error_msg("Download validation failed: unreadable file " .. tostring(path))
      return false, "unreadable file"
    end
    if installer_http.is_html_content(content) then
      fs.delete(path)
      ctx.error_msg("Download validation failed: HTML content for " .. tostring(path))
      return false, "html content"
    end
    if path:sub(-4) == ".lua" then
      local loader, err = ctx.compile_lua(path, content)
      if not loader then
        fs.delete(path)
        ctx.error_msg("Download validation failed: Lua parse error for " .. tostring(path) .. " (" .. tostring(err) .. ")")
        return false, "lua parse error"
      end
    end
    return true
  end

  function ctx.hash_matches(entry, content)
    local computed = crc32_hash(content)
    if not entry.hash then
      return true, computed
    end
    return string.lower(computed) == string.lower(entry.hash), computed
  end

  function ctx.size_matches(entry, content)
    if not entry.size_bytes then
      return true, #content
    end
    local actual_size = #content
    return tonumber(entry.size_bytes) == actual_size, actual_size
  end

  function ctx.download_file(remote_path, target_path, entry)
    local url = constants.BASE_URL .. remote_path
    ctx.info("Downloading " .. remote_path)
    local body, err = ctx.download_url(url)
    if not body then
      return false, err
    end
    local resolved_entry = entry or {}
    local size_ok, actual_size = ctx.size_matches(resolved_entry, body)
    if not size_ok then
      return false, string.format(
        "size mismatch for %s (url=%s expected=%s actual=%s)",
        tostring(remote_path),
        tostring(url),
        tostring(resolved_entry.size_bytes),
        tostring(actual_size)
      )
    end
    local hash_ok, actual_hash = ctx.hash_matches(resolved_entry, body)
    if not hash_ok then
      return false, string.format(
        "hash mismatch for %s (url=%s expected=%s actual=%s manifest=%s release=%s source_ref=%s)",
        tostring(remote_path),
        tostring(url),
        tostring(resolved_entry.hash),
        tostring(actual_hash),
        tostring(ctx.manifest_id or "unknown"),
        tostring(ctx.release_id or "unknown"),
        tostring(ctx.source_ref or "unknown")
      )
    end
    local ok, write_err = ctx.write_file(target_path, body)
    if not ok then
      return false, write_err
    end
    local valid, valid_err = ctx.validate_download(target_path)
    if not valid then
      return false, valid_err
    end
    return true
  end

  function ctx.load_manifest()
    ctx.info("Downloading manifest from " .. tostring(constants.MANIFEST_URL))
    local body, err = ctx.download_url(constants.MANIFEST_URL)
    if not body then
      return nil, err
    end
    local loader, load_err = load(body, "=manifest", "t", {})
    if not loader then
      return nil, load_err
    end
    local ok, manifest = pcall(loader)
    if not ok then
      return nil, manifest
    end
    if type(manifest) ~= "table" then
      return nil, "Manifest invalid"
    end
    if type(manifest.base_files) ~= "table" or type(manifest.roles) ~= "table" then
      return nil, "Manifest missing base_files or roles"
    end
    ctx.manifest_id = manifest.manifest_id or manifest.manifest_version or "unknown"
    return manifest
  end

  function ctx.resolve_release_source()
    ctx.info("Downloading release metadata from " .. tostring(constants.RELEASE_URL))
    local body, err = ctx.download_url(constants.RELEASE_URL)
    if not body then
      return false, err
    end
    local loader, load_err = load(body, "=release", "t", {})
    if not loader then
      return false, load_err
    end
    local ok, release = pcall(loader)
    if not ok then
      return false, release
    end
    if type(release) ~= "table" then
      return false, "release metadata invalid"
    end

    ctx.release_id = tostring(release.release_id or "unknown")
    local commit_sha = tostring(release.commit_sha or "")
    if commit_sha ~= "" and commit_sha ~= "beta" then
      constants.BASE_URL = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/" .. commit_sha .. "/xreactor/"
      constants.MANIFEST_URL = constants.BASE_URL .. "manifest.lua"
      constants.RELEASE_URL = constants.BASE_URL .. "release.lua"
      ctx.source_ref = commit_sha
      ctx.info("Pinned installer source to immutable commit " .. commit_sha)
      return true
    end

    ctx.source_ref = "beta"
    ctx.warn("Release commit_sha missing or mutable branch reference; installer keeps beta source")
    return true
  end

  function ctx.log_install_identity(manifest, role_label, mode, expected)
    local release = ctx.read_file(constants.INSTALL_ROOT .. "/release.lua")
    local release_id = "unknown"
    if release then
      local loader = load(release, "=release", "t", {})
      if loader then
        local ok, data = pcall(loader)
        if ok and type(data) == "table" then
          release_id = tostring(data.release_id or data.commit_sha or "unknown")
        end
      end
    end
    local file_count = 0
    for _ in pairs(expected) do
      file_count = file_count + 1
    end
    ctx.info(string.format(
      "Identity: mode=%s role=%s release=%s manifest=%s files=%d",
      tostring(mode),
      tostring(role_label),
      tostring(ctx.release_id or release_id),
      tostring(ctx.manifest_id or manifest.manifest_id or manifest.manifest_version or "unknown"),
      file_count
    ))
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

local function run_install(ctx)
  ctx.info("Selected action: Neuinstallation")
  local role = select_role()
  if not role then
    ctx.fatal("Invalid role selection")
  end
  ctx.info("Selected role: " .. role.label)

  local source_ok, source_err = ctx.resolve_release_source()
  if not source_ok then
    ctx.fatal("Release metadata error: " .. tostring(source_err))
  end

  local manifest, err = ctx.load_manifest()
  if not manifest then
    ctx.fatal("Manifest error: " .. tostring(err))
  end
  if manifest.source_ref and tostring(manifest.source_ref) ~= "beta" and tostring(manifest.source_ref) ~= tostring(ctx.source_ref) then
    ctx.warn(string.format(
      "Manifest source_ref mismatch (release source=%s manifest source_ref=%s)",
      tostring(ctx.source_ref),
      tostring(manifest.source_ref)
    ))
  end

  local expected = manifest_lib.select_expected_files(manifest, role.label, ctx.constants.INCLUDE_DEV_FILES)
  local storage_plan = storage_lib.estimate_required_storage(ctx.fs, ctx.constants.INSTALL_ROOT, expected, "install", ctx.constants)
  local preflight_ok, preflight_err = storage_lib.preflight_storage(ctx, storage_plan, { allow_cleanup = true, cleanup_logs = true, cleanup_backup = true })
  if not preflight_ok then
    ctx.fatal("Storage preflight failed: " .. tostring(preflight_err))
  end

  local stage_ok, stage_err = stage_lib.stage_expected_files(ctx, expected)
  if not stage_ok then
    ctx.fatal(tostring(stage_err))
  end
  stage_lib.ensure_role_config(ctx, ctx.constants.STAGE_ROOT, role.label)
  stage_and_verify(ctx, expected)

  stage_lib.activate_stage(ctx)
  startup_lib.ensure_startup_script(ctx)
  ctx.log_install_identity(manifest, role.label, "install", expected)
  ctx.info("Installation complete")
end

local function run_update(ctx)
  ctx.info("Selected action: Update")
  local source_ok, source_err = ctx.resolve_release_source()
  if not source_ok then
    ctx.fatal("Release metadata error: " .. tostring(source_err))
  end

  local manifest, err = ctx.load_manifest()
  if not manifest then
    ctx.fatal("Manifest error: " .. tostring(err))
  end
  if manifest.source_ref and tostring(manifest.source_ref) ~= "beta" and tostring(manifest.source_ref) ~= tostring(ctx.source_ref) then
    ctx.warn(string.format(
      "Manifest source_ref mismatch (release source=%s manifest source_ref=%s)",
      tostring(ctx.source_ref),
      tostring(manifest.source_ref)
    ))
  end

  local role_label = stage_lib.read_role_config(ctx)
  if not role_label then
    ctx.fatal("Role config missing; cannot update")
  end
  if not ROLE_KEY_MAP[role_label] then
    ctx.fatal("Unknown role in config: " .. tostring(role_label))
  end
  ctx.info("Selected role: " .. role_label)

  local expected = manifest_lib.select_expected_files(manifest, role_label, ctx.constants.INCLUDE_DEV_FILES)
  local storage_plan = storage_lib.estimate_required_storage(ctx.fs, ctx.constants.INSTALL_ROOT, expected, "update", ctx.constants)
  local preflight_ok, preflight_err = storage_lib.preflight_storage(ctx, storage_plan, { allow_cleanup = true, cleanup_logs = false, cleanup_backup = true })
  if not preflight_ok then
    ctx.fatal("Storage preflight failed: " .. tostring(preflight_err))
  end

  local stage_ok, stage_err = stage_lib.stage_expected_files(ctx, expected)
  if not stage_ok then
    ctx.fatal(tostring(stage_err))
  end
  stage_lib.copy_config_to_stage(ctx)
  stage_and_verify(ctx, expected)

  stage_lib.activate_stage(ctx)
  stage_lib.ensure_role_config(ctx, ctx.constants.INSTALL_ROOT, role_label)
  startup_lib.ensure_startup_script(ctx)
  ctx.log_install_identity(manifest, role_label, "update", expected)
  ctx.info("Update complete")
end

function M.run(constants)
  local ctx = build_context(constants)
  ctx.log_line("installer start")
  print("XReactor Installer")
  print("")
  print("1 - Neuinstallation")
  print("2 - Update")
  print("3 - Abbrechen")
  write("Select option: ")
  local choice = read()
  if choice == "1" then
    run_install(ctx)
  elseif choice == "2" then
    run_update(ctx)
  else
    ctx.info("Installer cancelled")
  end
end

return M
