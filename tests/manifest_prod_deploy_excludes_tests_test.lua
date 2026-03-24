local function load_table(path)
  local chunk, err = loadfile(path)
  if not chunk then
    error("failed loading " .. tostring(path) .. ": " .. tostring(err))
  end
  local ok, result = pcall(chunk)
  if not ok then
    error("failed executing " .. tostring(path) .. ": " .. tostring(result))
  end
  return result
end

local manifest = load_table("xreactor/manifest.lua")

local function assert_no_tests(entries, scope)
  for _, entry in ipairs(entries or {}) do
    if type(entry.path) == "string" and entry.path:match("^tests/") then
      error(scope .. " should not deploy test file: " .. entry.path)
    end
  end
end

assert_no_tests(manifest.base_files, "base_files")
for role, entries in pairs(manifest.roles or {}) do
  assert_no_tests(entries, "roles." .. tostring(role))
end

if type(manifest.dev_files) ~= "table" then
  error("manifest.dev_files must exist and be a table")
end

print("manifest_prod_deploy_excludes_tests_test.lua: ok")
