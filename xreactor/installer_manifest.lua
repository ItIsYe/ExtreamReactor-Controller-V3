local M = {}

function M.normalize_file_list(entries)
  local list = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "string" then
      table.insert(list, { path = entry })
    elseif type(entry) == "table" and entry.path then
      table.insert(list, {
        path = entry.path,
        size_bytes = entry.size_bytes,
        hash = entry.hash,
        always = entry.always,
        required_for = entry.required_for
      })
    end
  end
  return list
end

function M.should_exclude_prod_path(path)
  if type(path) ~= "string" then
    return true
  end
  if path:match("^tests/") then
    return true
  end
  if path:match("^docs/") then
    return true
  end
  if path == "README.md" or path == "MIGRATION.md" then
    return true
  end
  return false
end

function M.merge_unique(entries, source, include_dev_files)
  for _, entry in ipairs(source or {}) do
    if entry.path and (include_dev_files or not M.should_exclude_prod_path(entry.path)) then
      entries[entry.path] = entry
    end
  end
end

function M.flatten_manifest(manifest, include_dev_files)
  local merged = {}
  local base_files = M.normalize_file_list(manifest.base_files)
  for _, entry in ipairs(base_files) do
    entry.__base = true
  end
  M.merge_unique(merged, base_files, include_dev_files)

  for role_key, role_entries in pairs(manifest.roles or {}) do
    for _, entry in ipairs(M.normalize_file_list(role_entries)) do
      if type(entry.required_for) ~= "table" then
        entry.required_for = { string.upper(role_key) }
      end
      M.merge_unique(merged, { entry }, include_dev_files)
    end
  end

  if include_dev_files then
    M.merge_unique(merged, M.normalize_file_list(manifest.dev_files), include_dev_files)
  end

  local list = {}
  for _, entry in pairs(merged) do
    table.insert(list, entry)
  end
  table.sort(list, function(a, b)
    return tostring(a.path) < tostring(b.path)
  end)
  return list
end

function M.role_matches(required_for, role_label)
  if type(required_for) ~= "table" then
    return false
  end
  for _, entry in ipairs(required_for) do
    if tostring(entry):upper() == tostring(role_label):upper() then
      return true
    end
  end
  return false
end

local function is_log_role(role_label)
  local role = tostring(role_label or ""):upper()
  return role == "LOG" or role == "LOG_COLLECTOR"
end

function M.select_expected_files(manifest, role_label, include_dev_files)
  local expected = {}
  local log_role = is_log_role(role_label)
  for _, entry in ipairs(M.flatten_manifest(manifest, include_dev_files)) do
    local include = entry.always == true or M.role_matches(entry.required_for, role_label)
    if not include and entry.__base == true and not log_role then
      include = true
    end
    if include then
      expected[entry.path] = entry
    end
  end
  return expected
end

function M.files_for_role(manifest, role_key, role_label, include_dev_files)
  local label = role_label or role_key
  return M.select_expected_files(manifest, label, include_dev_files)
end

return M
