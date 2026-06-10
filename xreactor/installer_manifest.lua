local M = {}

local SKIP = {
  ["nodes/energy/adapter_probe.lua"] = true,
  ["nodes/rt/commands.lua"] = true,
  ["nodes/rt/controllers.lua"] = true,
  ["nodes/rt/discovery.lua"] = true,
  ["nodes/rt/ramp.lua"] = true,
  ["nodes/rt/safety.lua"] = true,
  ["nodes/rt/state.lua"] = true,
  ["nodes/rt/telemetry.lua"] = true
}

local EXTRA_BY_ROLE = {
  RT = {
    "adapters/reactor.lua",
    "adapters/turbine.lua",
    "core/control_rails.lua",
    "core/fluid.lua",
    "core/turbine_ctrl.lua",
    "core/turbine_regulator.lua",
    "nodes/rt/command_handler.lua",
    "nodes/rt/config_normalizer.lua",
    "nodes/rt/discovery_log.lua",
    "nodes/rt/discovery_runtime.lua",
    "nodes/rt/flow_apply_helpers.lua",
    "nodes/rt/health_payload.lua",
    "nodes/rt/module_lifecycle.lua",
    "nodes/rt/monitor_ui.lua",
    "nodes/rt/reactor_steam_guard.lua",
    "nodes/rt/startup_diagnostics.lua",
    "nodes/rt/state_handlers.lua",
    "nodes/rt/status_snapshot.lua"
  }
}

local function clean_entry(entry, strip)
  if type(entry) == "string" then entry = { path = entry } end
  if type(entry) ~= "table" or not entry.path or SKIP[entry.path] then return nil end
  local out = {
    path = entry.path,
    always = entry.always,
    required_for = entry.required_for
  }
  if not strip then
    out.size_bytes = entry.size_bytes
    out.hash = entry.hash
  end
  return out
end

local function strip_metadata(manifest)
  -- Strip size_bytes/hash only when hash_algo is explicitly "none".
  -- "beta" source_ref no longer implies stripped metadata now that
  -- regenerate_manifest_metadata.py maintains correct CRC32 values.
  return type(manifest) == "table" and tostring(manifest.hash_algo or "") == "none"
end

local function is_log_role(role_label)
  local role = tostring(role_label or ""):upper()
  return role == "LOG" or role == "LOG_COLLECTOR"
end

function M.should_exclude_prod_path(path)
  if type(path) ~= "string" then return true end
  if path:match("^tests/") or path:match("^docs/") then return true end
  return path == "README.md" or path == "MIGRATION.md"
end

function M.normalize_file_list(entries)
  local list = {}
  for _, entry in ipairs(entries or {}) do
    local out = clean_entry(entry, false)
    if out then list[#list + 1] = out end
  end
  return list
end

function M.role_matches(required_for, role_label)
  if type(required_for) ~= "table" then return false end
  for _, value in ipairs(required_for) do
    if tostring(value):upper() == tostring(role_label):upper() then return true end
  end
  return false
end

local function add(expected, entry)
  if entry and entry.path and not M.should_exclude_prod_path(entry.path) then
    expected[entry.path] = entry
  end
end

local function add_role_extras(expected, role_label)
  local extras = EXTRA_BY_ROLE[tostring(role_label or ""):upper()]
  for _, path in ipairs(extras or {}) do
    if not SKIP[path] then add(expected, { path = path, required_for = { tostring(role_label or "") } }) end
  end
end

function M.select_expected_files(manifest, role_label, include_dev_files)
  local expected = {}
  local strip = strip_metadata(manifest)
  local log_role = is_log_role(role_label)

  for _, raw in ipairs(manifest.base_files or {}) do
    local entry = clean_entry(raw, strip)
    if entry and (not log_role or entry.always == true) then add(expected, entry) end
  end

  for role_key, role_entries in pairs(manifest.roles or {}) do
    for _, raw in ipairs(role_entries or {}) do
      local entry = clean_entry(raw, strip)
      if entry then
        if type(entry.required_for) ~= "table" then entry.required_for = { string.upper(role_key) } end
        if entry.always == true or M.role_matches(entry.required_for, role_label) then add(expected, entry) end
      end
    end
  end

  add_role_extras(expected, role_label)

  if include_dev_files then
    for _, raw in ipairs(manifest.dev_files or {}) do add(expected, clean_entry(raw, strip)) end
  end

  return expected
end

function M.flatten_manifest(manifest, include_dev_files)
  local expected = {}
  for _, role_entries in pairs(manifest.roles or {}) do
    for _, raw in ipairs(role_entries or {}) do add(expected, clean_entry(raw, strip_metadata(manifest))) end
  end
  for _, raw in ipairs(manifest.base_files or {}) do add(expected, clean_entry(raw, strip_metadata(manifest))) end
  if include_dev_files then for _, raw in ipairs(manifest.dev_files or {}) do add(expected, clean_entry(raw, strip_metadata(manifest))) end end
  local list = {}
  for _, entry in pairs(expected) do list[#list + 1] = entry end
  table.sort(list, function(a, b) return tostring(a.path) < tostring(b.path) end)
  return list
end

return M
