local M = {}

local SKIP = {
  ["nodes/energy/adapter_probe.lua"] = true,
  ["nodes/rt/commands.lua"] = true
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
  return type(manifest) == "table" and (tostring(manifest.hash_algo or "") == "none" or tostring(manifest.source_ref or "") == "beta")
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
