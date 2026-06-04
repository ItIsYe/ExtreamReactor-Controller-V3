local M = {}

local LEGACY_REMOVED_FILES = {
  ["nodes/energy/adapter_probe.lua"] = true
}

local function is_log_role(role_label)
  local role = tostring(role_label or ""):upper()
  return role == "LOG" or role == "LOG_COLLECTOR"
end

function M.normalize_file_list(entries)
  local list = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "string" then
      if not LEGACY_REMOVED_FILES[entry] then
        table.insert(list, { path = entry })
      end
    elseif type(entry) == "table" and entry.path and not LEGACY_REMOVED_FILES[entry.path] then
      table.insert(list, {
        path = entry.path,
        size_bytes = entry.size_bytes,
        hash = entry.hash,
        always = entry.always,
        required_for = entry.required_for,
        __base = entry.__base
      })
    end
  end
  return list
end

function M.strip_metadata(entry)
  entry.size_bytes = nil
  entry.hash = nil
  return entry
end

function M.should_strip_metadata(manifest)
  if type(manifest) ~= "table" then return false end
  if tostring(manifest.hash_algo or "") == "none" then return true end
  if tostring(manifest.source_ref or "") == "beta" then return true end
  return false
end

function M.should_exclude_prod_path(path)
  if type(path) ~= "string" then return true end
  if path:match("^tests/") then return true end
  if path:match("^docs/") then return true end
  if path == "README.md" or path == "MIGRATION.md" then return true end
  return false
end

function M.merge_unique(entries, source, include_dev_files, strip_metadata)
  for _, entry in ipairs(source or {}) do
    if entry.path and (include_dev_files or not M.should_exclude_prod_path(entry.path)) then
      if strip_metadata then M.strip_metadata(entry) end
      entries[entry.path] = entry
    end
  end
end

function M.flatten_manifest(manifest, include_dev_files)
  local merged = {}
  local strip_metadata = M.should_strip_metadata(manifest)
  local base_files = M.normalize_file_list(manifest.base_files)
  for _, entry in ipairs(base_files) do
    entry.__base = true
    if entry.always == nil then entry.always = true end
  end
  M.merge_unique(merged, base_files, include_dev_files, strip_metadata)

  for role_key, role_entries in pairs(manifest.roles or {}) do
    for _, entry in ipairs(M.normalize_file_list(role_entries)) do
      if type(entry.required_for) ~= "table" then
        entry.required_for = { string.upper(role_key) }
      end
      M.merge_unique(merged, { entry }, include_dev_files, strip_metadata)
    end
  end

  if include_dev_files then
    M.merge_unique(merged, M.normalize_file_list(manifest.dev_files), include_dev_files, strip_metadata)
  end

  local list = {}
  for _, entry in pairs(merged) do table.insert(list, entry) end
  table.sort(list, function(a, b) return tostring(a.path) < tostring(b.path) end)
  return list
end

function M.role_matches(required_for, role_label)
  if type(required_for) ~= "table" then return false end
  for _, entry in ipairs(required_for) do
    if tostring(entry):upper() == tostring(role_label):upper() then return true end
  end
  return false
end

function M.select_expected_files(manifest, role_label, include_dev_files)
  local expected = {}
  local log_role = is_log_role(role_label)
  for _, entry in ipairs(M.flatten_manifest(manifest, include_dev_files)) do
    local include = entry.always == true or M.role_matches(entry.required_for, role_label)
    if log_role and entry.__base == true and entry.always ~= true then
      include = false
    end
    if include then
      entry.__base = nil
      expected[entry.path] = entry
    end
  end
  return expected
end

return M
