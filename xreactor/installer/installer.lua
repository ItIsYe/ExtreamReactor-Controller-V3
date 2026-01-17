local BASE_DIR = "/xreactor"
local REPO_BASE_URL_MAIN = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/main"
local REPO_BASE_URL_FALLBACK = "https://raw.github.com/ItIsYe/ExtreamReactor-Controller-V3/main"
local RELEASE_REMOTE = "xreactor/installer/release.lua"
local MANIFEST_REMOTE = "xreactor/installer/manifest.lua"
local MANIFEST_LOCAL = BASE_DIR .. "/.manifest"
local MANIFEST_CACHE = BASE_DIR .. "/.manifest_cache"
local BACKUP_BASE = "/xreactor_backup"
local NODE_ID_PATH = BASE_DIR .. "/config/node_id.txt"
local UPDATE_STAGING = "/xreactor_update_tmp"
local INSTALLER_VERSION = "1.1"
local INSTALLER_MIN_BYTES = 200
local INSTALLER_SANITY_MARKER = "local function main"

local roles = {
  MASTER = "MASTER",
  RT_NODE = "RT-NODE",
  ENERGY_NODE = "ENERGY-NODE",
  FUEL_NODE = "FUEL-NODE",
  WATER_NODE = "WATER-NODE",
  REPROCESSOR_NODE = "REPROCESSOR-NODE"
}

local role_targets = {
  [roles.MASTER] = { path = "master", config = "master/config.lua" },
  [roles.RT_NODE] = { path = "nodes/rt", config = "nodes/rt/config.lua" },
  [roles.ENERGY_NODE] = { path = "nodes/energy", config = "nodes/energy/config.lua" },
  [roles.FUEL_NODE] = { path = "nodes/fuel", config = "nodes/fuel/config.lua" },
  [roles.WATER_NODE] = { path = "nodes/water", config = "nodes/water/config.lua" },
  [roles.REPROCESSOR_NODE] = { path = "nodes/reprocessor", config = "nodes/reprocessor/config.lua" }
}

local function ensure_dir(path)
  if path == "" then return end
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function trim(text)
  if not text then return "" end
  return text:match("^%s*(.-)%s*$")
end

local function normalize_node_id(value)
  if type(value) == "string" then
    local trimmed = trim(value)
    if trimmed ~= "" then
      return trimmed
    end
  elseif type(value) == "number" then
    return tostring(value)
  elseif type(value) == "table" then
    local candidate = value.id or value.node_id or value.value
    if type(candidate) == "string" then
      local trimmed = trim(candidate)
      if trimmed ~= "" then
        return trimmed
      end
    elseif type(candidate) == "number" then
      return tostring(candidate)
    end
    return tostring(value)
  end
  return nil
end

local function fallback_node_id()
  return tostring(os.getComputerLabel() or os.getComputerID())
end

local function read_file(path)
  if not fs.exists(path) then return nil end
  local file = fs.open(path, "r")
  if not file then return nil end
  local content = file.readAll()
  file.close()
  return content
end

local function write_atomic(path, content)
  ensure_dir(fs.getDir(path))
  local tmp = path .. ".tmp"
  local file = fs.open(tmp, "w")
  if not file then
    error("Unable to write file at " .. path)
  end
  file.write(content)
  file.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
end

local function normalize_newlines(content)
  if not content then return "" end
  return content:gsub("\r\n", "\n")
end

local function copy_file(src, dst)
  local content = read_file(src)
  if content == nil then return false end
  write_atomic(dst, content)
  return true
end

local function checksum(content)
  content = normalize_newlines(content)
  local sum = 0
  for i = 1, #content do
    sum = (sum + string.byte(content, i)) % 1000000007
  end
  return tostring(sum) .. ":" .. tostring(#content)
end

local function validate_hash_algo(manifest, release)
  local algo = manifest.hash_algo or release.hash_algo
  if algo ~= "sumlen-v1" then
    error("Unsupported hash algo: " .. tostring(algo))
  end
end

local function file_checksum(path)
  local content = read_file(path)
  if not content then return nil end
  return checksum(content)
end

local function compare_version(a, b)
  local function parse(version)
    local major, minor = tostring(version or "0"):match("^(%d+)%.?(%d*)$")
    return tonumber(major) or 0, tonumber(minor) or 0
  end
  local a_major, a_minor = parse(a)
  local b_major, b_minor = parse(b)
  if a_major ~= b_major then
    return a_major - b_major
  end
  return a_minor - b_minor
end

local function read_config(path, defaults)
  if not fs.exists(path) then
    return defaults or {}
  end
  local content = read_file(path)
  if not content then
    return defaults or {}
  end
  local loader = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      return data
    end
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return defaults or {}
end

local function read_config_from_content(content)
  if not content then return {} end
  local loader = load(content, "config", "t", {})
  if loader then
    local ok, data = pcall(loader)
    if ok and type(data) == "table" then
      return data
    end
  end
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local function write_config_file(path, tbl)
  write_atomic(path, "return " .. textutils.serialize(tbl))
end

local function merge_defaults(target, defaults)
  local changed = false
  for key, value in pairs(defaults or {}) do
    if target[key] == nil then
      target[key] = value
      changed = true
    elseif type(target[key]) == "table" and type(value) == "table" then
      local inner_changed = merge_defaults(target[key], value)
      changed = changed or inner_changed
    end
  end
  return changed
end

local function is_html_payload(content)
  if not content then return false end
  local head = content:sub(1, 200)
  if head:match("^%s*<!DOCTYPE") then return true end
  if head:match("^%s*<html") then return true end
  if head:find("<body") then return true end
  return false
end

local function download_url_checked(url)
  local response = http.get(url)
  if not response then
    return nil, { url = url, code = nil, reason = "timeout", html = false }
  end
  local code = response.getResponseCode and response.getResponseCode() or nil
  local content = response.readAll()
  response.close()
  if not content or content == "" then
    return nil, { url = url, code = code, reason = "empty", html = false }
  end
  local html = is_html_payload(content)
  if html then
    return nil, { url = url, code = code, reason = "html", html = true }
  end
  if code and code ~= 200 then
    return nil, { url = url, code = code, reason = "status", html = html }
  end
  return content, { url = url, code = code, reason = nil, html = html }
end

local function download_with_retries(urls, attempts, backoff_seconds)
  local last_meta = nil
  for attempt = 1, attempts do
    for _, url in ipairs(urls) do
      local content, meta = download_url_checked(url)
      if content then
        return content, meta
      end
      last_meta = meta
      print(("Download failed: %s (code=%s reason=%s)"):format(
        tostring(meta.url),
        tostring(meta.code),
        tostring(meta.reason)
      ))
    end
    if attempt < attempts then
      os.sleep(backoff_seconds * attempt)
    end
  end
  return nil, last_meta
end

local function download_file_with_retries(base_url, remote_path)
  local url = string.format("%s/%s", base_url, remote_path)
  return download_with_retries({ url }, 3, 1)
end

local function validate_installer_content(content)
  if not content or #content < INSTALLER_MIN_BYTES then
    return false, "content too short"
  end
  if not content:find(INSTALLER_SANITY_MARKER, 1, true) then
    return false, "sanity check failed"
  end
  local loader, err = load(content, "installer", "t", {})
  if not loader then
    return false, err or "syntax error"
  end
  return true
end

local function read_manifest_cache()
  if not fs.exists(MANIFEST_CACHE) then
    return nil
  end
  local content = read_file(MANIFEST_CACHE)
  if not content then
    return nil
  end
  local ok, data = pcall(textutils.unserialize, content)
  if not ok or type(data) ~= "table" then
    return nil
  end
  if type(data.manifest_content) ~= "string" then
    return nil
  end
  if type(data.release) ~= "table" or type(data.release.commit_sha) ~= "string" then
    return nil
  end
  if type(data.base_url) ~= "string" then
    return nil
  end
  return data
end

local function write_manifest_cache(manifest_content, release, base_url)
  local payload = {
    manifest_content = manifest_content,
    release = release,
    base_url = base_url
  }
  write_atomic(MANIFEST_CACHE, textutils.serialize(payload))
end

local function download_release()
  local urls = {
    string.format("%s/%s", REPO_BASE_URL_MAIN, RELEASE_REMOTE),
    string.format("%s/%s", REPO_BASE_URL_FALLBACK, RELEASE_REMOTE)
  }
  local content = select(1, download_with_retries(urls, 3, 1))
  if not content then
    return nil, "Release download failed"
  end
  local loader = load(content, "release", "t", {})
  if not loader then
    return nil, "Release load failed"
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then
    return nil, "Release parse failed"
  end
  if type(data.commit_sha) ~= "string" then
    return nil, "Release missing commit_sha"
  end
  if type(data.hash_algo) ~= "string" then
    return nil, "Release missing hash_algo"
  end
  data.manifest_path = data.manifest_path or MANIFEST_REMOTE
  return data
end

local function parse_manifest(content)
  local loader = load(content, "manifest", "t", {})
  if not loader then
    return nil, "Manifest load failed"
  end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
    return nil, "Manifest parse failed"
  end
  return data
end

local function download_manifest()
  local release, release_err = download_release()
  if not release then
    return nil, release_err
  end
  local base_urls = {
    ("https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/%s"):format(release.commit_sha),
    ("https://raw.github.com/ItIsYe/ExtreamReactor-Controller-V3/%s"):format(release.commit_sha)
  }
  local urls = {
    string.format("%s/%s", base_urls[1], release.manifest_path),
    string.format("%s/%s", base_urls[2], release.manifest_path)
  }
  local content, meta = download_with_retries(urls, 3, 1)
  if not content then
    return nil, "Manifest download failed"
  end
  local manifest, manifest_err = parse_manifest(content)
  if not manifest then
    return nil, manifest_err
  end
  validate_hash_algo(manifest, release)
  local base_url = base_urls[1]
  if meta and meta.url then
    base_url = meta.url:gsub("/" .. release.manifest_path .. "$", "")
  end
  return content, manifest, release, base_url
end

local function ensure_base_dirs()
  ensure_dir(BASE_DIR)
  ensure_dir(BASE_DIR .. "/config")
  ensure_dir(BASE_DIR .. "/core")
  ensure_dir(BASE_DIR .. "/master")
  ensure_dir(BASE_DIR .. "/master/ui")
  ensure_dir(BASE_DIR .. "/nodes")
  ensure_dir(BASE_DIR .. "/nodes/rt")
  ensure_dir(BASE_DIR .. "/nodes/energy")
  ensure_dir(BASE_DIR .. "/nodes/fuel")
  ensure_dir(BASE_DIR .. "/nodes/water")
  ensure_dir(BASE_DIR .. "/nodes/reprocessor")
  ensure_dir(BASE_DIR .. "/shared")
  ensure_dir(BASE_DIR .. "/installer")
end

local function is_config_file(path)
  return path:match("/config%.lua$") ~= nil
end

local function prompt(msg, default)
  write(msg .. (default and (" [" .. default .. "]") or "") .. ": ")
  local input = read()
  if input == "" then return default end
  return input
end

local function confirm(prompt_text, default)
  local hint = default and "Y/n" or "y/N"
  local input = prompt(prompt_text .. " (" .. hint .. ")", default and "y" or "n")
  input = input:lower()
  if input == "" then return default end
  return input == "y" or input == "yes"
end

local last_detection = { reactors = {}, turbines = {}, modems = {} }

local function is_wireless_modem(name)
  local ok, result = pcall(peripheral.call, name, "isWireless")
  if ok then return result end
  return false
end

local function scan_peripherals()
  local reactors = {}
  local turbines = {}
  local modems = {}
  for _, name in ipairs(peripheral.getNames()) do
    local peripheral_type = peripheral.getType(name)
    if peripheral_type == "BigReactors-Reactor" then
      table.insert(reactors, name)
    elseif peripheral_type == "BigReactors-Turbine" then
      table.insert(turbines, name)
    elseif peripheral_type == "modem" then
      table.insert(modems, name)
    end
  end
  last_detection = { reactors = reactors, turbines = turbines, modems = modems }
  return last_detection
end

local function detect_modems()
  local wireless = {}
  local wired = {}
  for _, name in ipairs(scan_peripherals().modems) do
    if is_wireless_modem(name) then
      table.insert(wireless, name)
    else
      table.insert(wired, name)
    end
  end
  return { wireless = wireless, wired = wired }
end

local function select_primary_modem(modems)
  if #modems.wireless > 0 then
    return modems.wireless[1]
  end
  if #modems.wired > 0 then
    return modems.wired[1]
  end
  return nil
end

local function choose_role()
  print("Select role:")
  local list = {
    roles.MASTER,
    roles.RT_NODE,
    roles.ENERGY_NODE,
    roles.FUEL_NODE,
    roles.WATER_NODE,
    roles.REPROCESSOR_NODE
  }
  for i, r in ipairs(list) do
    print(string.format("%d) %s", i, r))
  end
  local choice = tonumber(prompt("Role number", 1)) or 1
  return list[choice] or roles.MASTER
end

local function write_startup(role)
  local target = role_targets[role]
  write_atomic("/startup.lua", [[shell.run("/xreactor/]] .. target.path .. [[/main.lua")]])
end

local function print_detected(label, items)
  print(label .. ":")
  if #items == 0 then
    print(" - (none)")
    return
  end
  for _, name in ipairs(items) do
    print(" - " .. name)
  end
end

local function prompt_use_detected()
  scan_peripherals()
  write("Use detected peripherals? [Y/n]: ")
  local input = read()
  input = input:lower()
  if input == "" then return true end
  return input == "y" or input == "yes"
end

local function write_config(role, wireless, wired, extras)
  local cfg_path = BASE_DIR .. "/" .. role_targets[role].config
  local defaults = read_config(cfg_path, {})
  defaults.role = role
  defaults.wireless_modem = wireless
  defaults.wired_modem = wired
  if defaults.node_id == nil then
    defaults.node_id = fallback_node_id()
  end
  local normalized_node_id = normalize_node_id(defaults.node_id)
  if not normalized_node_id then
    normalized_node_id = fallback_node_id()
  end
  defaults.node_id = normalized_node_id
  if role == roles.MASTER then
    defaults.monitor_auto = true
    defaults.ui_scale_default = extras.ui_scale_default or 0.5
  elseif role == roles.RT_NODE then
    defaults.reactors = extras.reactors
    defaults.turbines = extras.turbines
    defaults.modem = extras.modem
    if extras.node_id then
      defaults.node_id = normalize_node_id(extras.node_id) or fallback_node_id()
    end
  end
  write_config_file(cfg_path, defaults)
end

local function build_rt_node_id()
  local id_str = tostring(os.getComputerID())
  local suffix = id_str:sub(-4)
  return "RT-" .. suffix
end

local function find_existing_role()
  for role, target in pairs(role_targets) do
    local cfg_path = BASE_DIR .. "/" .. target.config
    if fs.exists(cfg_path) then
      local cfg = read_config(cfg_path, {})
      if cfg.role == role then
        return role, cfg_path, cfg
      end
    end
  end
  return nil, nil, nil
end

local function collect_known_node_id_sources(role, cfg_path)
  local sources = {
    { label = "legacy_file", path = BASE_DIR .. "/data/node_id.txt" },
    { label = "legacy_file", path = BASE_DIR .. "/node_id.txt" },
    { label = "legacy_file", path = BASE_DIR .. "/config/node_id.txt" }
  }
  if cfg_path then
    table.insert(sources, { label = "config", path = cfg_path })
  end
  for _, target in pairs(role_targets) do
    local path = BASE_DIR .. "/" .. target.config
    if path ~= cfg_path then
      table.insert(sources, { label = "config", path = path })
    end
  end
  return sources
end

local function ensure_node_id(role, cfg_path)
  if fs.exists(NODE_ID_PATH) then
    local existing = trim(read_file(NODE_ID_PATH))
    local normalized = normalize_node_id(existing)
    if normalized then
      if normalized ~= existing then
        write_atomic(NODE_ID_PATH, normalized)
        print("normalized node_id from file")
      end
      return true
    end
  end
  print("node_id missing → attempting migration")
  local sources = collect_known_node_id_sources(role, cfg_path)
  for _, source in ipairs(sources) do
    if fs.exists(source.path) then
      if source.label == "config" then
        local cfg = read_config(source.path, {})
        local normalized = normalize_node_id(cfg.node_id)
        if normalized then
          write_atomic(NODE_ID_PATH, normalized)
          print("migrated node_id from config")
          return true
        end
      else
        local content = trim(read_file(source.path))
        local normalized = normalize_node_id(content)
        if normalized then
          write_atomic(NODE_ID_PATH, normalized)
          print("migrated node_id from legacy_file")
          return true
        end
      end
    end
  end

  local generated = fallback_node_id()
  write_atomic(NODE_ID_PATH, generated)
  print("generated new node_id")
  return true
end

local function create_backup_dir()
  ensure_dir(BACKUP_BASE)
  local stamp = os.date("%Y%m%d_%H%M%S")
  local path = BACKUP_BASE .. "/" .. stamp
  ensure_dir(path)
  return path
end

local function backup_files(base_dir, paths)
  for _, path in ipairs(paths) do
    if fs.exists(path) then
      local target = base_dir .. path
      ensure_dir(fs.getDir(target))
      copy_file(path, target)
    end
  end
end

local function rollback_from_backup(base_dir, paths, created)
  for _, path in ipairs(paths) do
    local backup_path = base_dir .. path
    if fs.exists(backup_path) then
      ensure_dir(fs.getDir(path))
      copy_file(backup_path, path)
    end
  end
  for _, path in ipairs(created) do
    if fs.exists(path) then
      fs.delete(path)
    end
  end
end

local function update_files(manifest)
  local updates = {}
  for path, expected_hash in pairs(manifest.files) do
    if not is_config_file(path) then
      local local_hash = file_checksum("/" .. path)
      if local_hash ~= expected_hash then
        table.insert(updates, { path = path, hash = expected_hash })
      end
    end
  end
  table.sort(updates, function(a, b) return a.path < b.path end)
  return updates
end

local function build_staging_path(path)
  return UPDATE_STAGING .. "/" .. path
end

local function stage_updates(entries, base_url)
  ensure_dir(UPDATE_STAGING)
  local staged = {}
  for _, entry in ipairs(entries) do
    local content, meta = download_file_with_retries(base_url, entry.path)
    if not content then
      return nil, ("Download failed for %s (url=%s code=%s reason=%s html=%s)"):format(
        entry.path,
        tostring(meta.url),
        tostring(meta.code),
        tostring(meta.reason),
        tostring(meta.html)
      )
    end
    local actual = checksum(content)
    if actual ~= entry.hash then
      local retry_content, retry_meta = download_file_with_retries(base_url, entry.path)
      if retry_content then
        content = retry_content
        actual = checksum(content)
      end
      if actual ~= entry.hash then
        return nil, ("Checksum mismatch for %s (expected=%s actual=%s url=%s code=%s reason=%s html=%s)"):format(
          entry.path,
          entry.hash,
          actual,
          tostring((retry_meta and retry_meta.url) or meta.url),
          tostring((retry_meta and retry_meta.code) or meta.code),
          tostring((retry_meta and retry_meta.reason) or meta.reason),
          tostring((retry_meta and retry_meta.html) or meta.html)
        )
      end
    end
    local staging_path = build_staging_path(entry.path)
    write_atomic(staging_path, content)
    local verify = file_checksum(staging_path)
    if verify ~= entry.hash then
      return nil, ("Staged hash mismatch for %s (expected=%s actual=%s)"):format(
        entry.path,
        entry.hash,
        verify
      )
    end
    staged[entry.path] = staging_path
  end
  return staged
end

local function apply_staged(entries, staged, created)
  for _, entry in ipairs(entries) do
    local target_path = "/" .. entry.path
    local staging_path = staged[entry.path]
    local content = read_file(staging_path)
    if content == nil then
      return false, "Missing staged file for " .. entry.path
    end
    if not fs.exists(target_path) then
      table.insert(created, target_path)
    end
    local write_ok, write_err = pcall(write_atomic, target_path, content)
    if not write_ok then
      return false, write_err
    end
  end
  return true
end

local function update_installer_if_required(manifest, base_url)
  local required = manifest.installer_min_version
  if required and compare_version(INSTALLER_VERSION, required) < 0 then
    print("Installer update required.")
    if not confirm("Update installer now?", true) then
      print("SAFE UPDATE aborted: installer update required.")
      return false
    end
    local installer_path = manifest.installer_path or "xreactor/installer/installer.lua"
    local expected = manifest.installer_hash
    if not expected then
      print("SAFE UPDATE aborted: installer hash missing.")
      return false
    end
    local url = string.format("%s/%s", base_url, installer_path)
    local content, meta = download_with_retries({ url }, 3, 1)
    if not content then
      print(("SAFE UPDATE aborted: installer download failed (url=%s code=%s reason=%s html=%s)"):format(
        tostring(meta.url),
        tostring(meta.code),
        tostring(meta.reason),
        tostring(meta.html)
      ))
      return false
    end
    if checksum(content) ~= expected then
      print("SAFE UPDATE aborted: installer checksum mismatch.")
      return false
    end
    local valid, valid_err = validate_installer_content(content)
    if not valid then
      print("SAFE UPDATE aborted: installer invalid (" .. tostring(valid_err) .. ").")
      return false
    end
    local target = "/" .. installer_path
    local temp = target .. ".new"
    write_atomic(temp, content)
    if fs.exists(target) then
      fs.delete(target)
    end
    fs.move(temp, target)
    print("Installer updated.")
    if not _G.__xreactor_installer_restarted then
      _G.__xreactor_installer_restarted = true
      local loader = loadfile(target)
      if loader then
        print("Restarting installer...")
        loader()
      else
        print("Installer updated, but restart failed. Please re-run installer.")
      end
    end
    return false
  end
  return true
end

local function migrate_config(role, cfg_path, manifest, base_url)
  local remote_path = "xreactor/" .. role_targets[role].config
  local expected_hash = manifest.files[remote_path]
  if not expected_hash then
    return false
  end
  local content, meta = download_file_with_retries(base_url, remote_path)
  if not content then
    error(("Config download failed (url=%s code=%s reason=%s html=%s)"):format(
      tostring(meta.url),
      tostring(meta.code),
      tostring(meta.reason),
      tostring(meta.html)
    ))
  end
  if checksum(content) ~= expected_hash then
    error("Config checksum mismatch for " .. remote_path)
  end
  local defaults = read_config_from_content(content)
  local existing = read_config(cfg_path, {})
  local original = textutils.serialize(existing)
  merge_defaults(existing, defaults)
  if existing.role ~= role then
    existing.role = role
  end
  local normalized_node_id = normalize_node_id(existing.node_id)
  if not normalized_node_id then
    normalized_node_id = fallback_node_id()
  end
  existing.node_id = normalized_node_id
  if textutils.serialize(existing) ~= original then
    write_config_file(cfg_path, existing)
    return true
  end
  return false
end

local function verify_integrity(manifest, role, cfg_path)
  local required = {
    "xreactor/core/network.lua",
    "xreactor/core/protocol.lua",
    "xreactor/shared/constants.lua",
    "xreactor/installer/installer.lua"
  }
  if role == roles.MASTER then
    table.insert(required, "xreactor/master/main.lua")
  else
    table.insert(required, "xreactor/nodes/rt/main.lua")
  end
  for _, path in ipairs(required) do
    if not fs.exists("/" .. path) then
      return false, "Missing " .. path
    end
  end
  if role and cfg_path and not fs.exists(cfg_path) then
    return false, "Missing config"
  end
  if not fs.exists(NODE_ID_PATH) then
    return false, "Missing node_id"
  end
  return true
end

local function safe_update()
  local role, cfg_path = find_existing_role()
  if not role then
    print("No existing role config found. Use FULL REINSTALL.")
    return
  end

  local manifest_content, manifest, release, base_url = download_manifest()
  while not manifest_content do
    local cache = read_manifest_cache()
    print("SAFE UPDATE: manifest download failed.")
    if cache then
      print("1) Use cached manifest (offline update)")
      print("2) Retry download")
      print("3) Cancel")
    else
      print("1) Retry download")
      print("2) Cancel")
    end
    local default_choice = cache and "2" or "1"
    local choice = tonumber(prompt("Select option", default_choice)) or tonumber(default_choice)
    if cache and choice == 1 then
      manifest_content = cache.manifest_content
      local parsed, parse_err = parse_manifest(manifest_content)
      if not parsed then
        print("Cached manifest invalid: " .. tostring(parse_err))
        return
      end
      manifest = parsed
      release = cache.release
      base_url = cache.base_url
      validate_hash_algo(manifest, release)
      break
    elseif (cache and choice == 2) or (not cache and choice == 1) then
      manifest_content, manifest, release, base_url = download_manifest()
    else
      print("SAFE UPDATE cancelled.")
      return
    end
  end
  ensure_base_dirs()

  local can_continue = update_installer_if_required(manifest, base_url)
  if not can_continue then
    return
  end

  local node_ok = ensure_node_id(role, cfg_path)
  if not node_ok then
    return
  end

  local updates = update_files(manifest)
  local staged, stage_err = stage_updates(updates, base_url)
  if not staged then
    local retry_release = download_release()
    if retry_release and retry_release.commit_sha ~= release.commit_sha then
      manifest_content, manifest, release, base_url = download_manifest()
      if manifest_content then
        updates = update_files(manifest)
        staged, stage_err = stage_updates(updates, base_url)
      end
    end
    if not staged then
      print("SAFE UPDATE failed. Error: " .. tostring(stage_err))
      return
    end
  end
  local backup_dir = create_backup_dir()
  local protected = { cfg_path, NODE_ID_PATH, "/startup.lua", MANIFEST_LOCAL, MANIFEST_CACHE }
  local update_paths = {}
  local created = {}
  for _, entry in ipairs(updates) do
    table.insert(update_paths, "/" .. entry.path)
  end

  backup_files(backup_dir, update_paths)
  backup_files(backup_dir, protected)

  local changed = 0
  local ok, err = apply_staged(updates, staged, created)
  if ok then
    changed = #updates
  end

  local migrated = false
  if ok then
    local success, result = pcall(migrate_config, role, cfg_path, manifest, base_url)
    if success then
      migrated = result
    else
      ok = false
      err = result
    end
  end

  if ok then
    local success, result = pcall(write_atomic, MANIFEST_LOCAL, manifest_content)
    if not success then
      ok = false
      err = result
    end
  end
  if ok then
    local cache_ok, cache_err = pcall(write_manifest_cache, manifest_content, release, base_url)
    if not cache_ok then
      ok = false
      err = cache_err
    end
  end

  if not ok then
    local rollback_paths = {}
    for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
    for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("SAFE UPDATE failed. Rolled back. Error: " .. tostring(err))
    print("Backup: " .. backup_dir)
    return
  end

  local integrity_ok, integrity_err = verify_integrity(manifest, role, cfg_path)
  if not integrity_ok then
    local rollback_paths = {}
    for _, path in ipairs(update_paths) do table.insert(rollback_paths, path) end
    for _, path in ipairs(protected) do table.insert(rollback_paths, path) end
    rollback_from_backup(backup_dir, rollback_paths, created)
    print("Integrity check failed: " .. tostring(integrity_err))
    print("Rollback complete. Backup: " .. backup_dir)
    return
  end

  print("SAFE UPDATE complete.")
  print("Changed files: " .. tostring(changed))
  if migrated then
    print("Config migration: updated defaults")
  end
  print("Backup: " .. backup_dir)
  print("Next steps: reboot or run the role entrypoint.")
end

local function full_reinstall()
  local manifest_content, manifest, release, base_url = download_manifest()
  if not manifest_content then
    print("FULL REINSTALL failed: manifest download failed.")
    return
  end
  ensure_base_dirs()
  local updates = {}
  for path in pairs(manifest.files) do
    table.insert(updates, path)
  end
  table.sort(updates)
  for _, path in ipairs(updates) do
    local content, meta = download_file_with_retries(base_url, path)
    if not content then
      error(("Download failed for %s (url=%s code=%s reason=%s html=%s)"):format(
        path,
        tostring(meta.url),
        tostring(meta.code),
        tostring(meta.reason),
        tostring(meta.html)
      ))
    end
    local expected = manifest.files[path]
    if checksum(content) ~= expected then
      error("Checksum mismatch for " .. path)
    end
    write_atomic("/" .. path, content)
  end
  if manifest.installer_path and manifest.installer_hash then
    local content, meta = download_file_with_retries(base_url, manifest.installer_path)
    if not content then
      error(("Installer download failed (url=%s code=%s reason=%s html=%s)"):format(
        tostring(meta.url),
        tostring(meta.code),
        tostring(meta.reason),
        tostring(meta.html)
      ))
    end
    if checksum(content) ~= manifest.installer_hash then
      error("Checksum mismatch for " .. manifest.installer_path)
    end
    write_atomic("/" .. manifest.installer_path, content)
  end

  local role = choose_role()
  local cfg_path = BASE_DIR .. "/" .. role_targets[role].config
  local modems = detect_modems()
  local wireless = select_primary_modem(modems)
  local wired = modems.wired[1]
  local extras = {}

  if not wireless then
    wireless = prompt("Primary modem side", nil)
  end
  if wireless and wired == wireless then
    wired = nil
  end

  if role == roles.RT_NODE then
    local label = build_rt_node_id()
    os.setComputerLabel(label)
  end

  if role == roles.MASTER then
    extras.ui_scale_default = tonumber(prompt("UI scale (0.5/1)", "0.5")) or 0.5
  elseif role == roles.RT_NODE then
    local detected = scan_peripherals()
    extras.modem = wireless
    local use_detected = #detected.reactors > 0
    if use_detected then
      print_detected("Detected Reactors", detected.reactors)
      print_detected("Detected Turbines", detected.turbines)
      print_detected("Detected Modems", detected.modems)
      use_detected = prompt_use_detected()
    else
      print("Warning: No reactors detected. Switching to manual entry.")
    end

    if use_detected then
      extras.reactors = detected.reactors
      extras.turbines = detected.turbines
      if #detected.turbines == 0 then
        print("No turbines detected. Reactor-only setup will be used.")
      end
    else
      local reactors = prompt("Reactor peripheral names (comma separated)", "")
      local turbines = prompt("Turbine peripheral names (comma separated)", "")
      extras.reactors = {}
      extras.turbines = {}
      for name in string.gmatch(reactors, "[^,]+") do table.insert(extras.reactors, trim(name)) end
      for name in string.gmatch(turbines, "[^,]+") do table.insert(extras.turbines, trim(name)) end
    end
    if not wireless then
      extras.modem = prompt("Modem peripheral name", nil)
    end
  end

  if role == roles.RT_NODE then
    extras.node_id = build_rt_node_id()
  end
  write_config(role, wireless, wired, extras)
  write_startup(role)
  write_atomic(MANIFEST_LOCAL, manifest_content)
  write_manifest_cache(manifest_content, release, base_url)

  print("FULL REINSTALL complete.")
  print("Next steps: reboot or run the role entrypoint.")
end

local function main()
  if not http then
    error("HTTP API is disabled. Enable it in ComputerCraft config to run the installer.")
  end
  print("=== XReactor Installer ===")
  if fs.exists(BASE_DIR) then
    print("Existing installation detected.")
    print("1) SAFE UPDATE")
    print("2) FULL REINSTALL")
    print("3) CANCEL")
    local choice = tonumber(prompt("Select option", "1")) or 1
    if choice == 1 then
      safe_update()
    elseif choice == 2 then
      full_reinstall()
    else
      print("Cancelled.")
    end
  else
    full_reinstall()
  end
end

main()
