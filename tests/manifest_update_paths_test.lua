
local function load_table(path)
  local chunk, err = loadfile(path)
  if not chunk then
    error("failed loading " .. tostring(path) .. ": " .. tostring(err))
  end
  local ok, result = pcall(chunk)
  if not ok then
    error("failed executing " .. tostring(path) .. ": " .. tostring(result))
  end
  if type(result) ~= "table" then
    error("expected table from " .. tostring(path))
  end
  return result
end

local manifest = load_table("xreactor/manifest.lua")

local required_base = {
  ["adapters/monitor.lua"] = false,
  ["core/network.lua"] = false,
}
for _, entry in ipairs(manifest.base_files or {}) do
  if required_base[entry.path] ~= nil then
    required_base[entry.path] = true
  end
end
for path, present in pairs(required_base) do
  if not present then
    error("manifest missing base file: " .. path)
  end
end

local required_master = {
  ["master/ui/multiview.lua"] = false,
}
for _, entry in ipairs(((manifest.roles or {}).master) or {}) do
  if required_master[entry.path] ~= nil then
    required_master[entry.path] = true
  end
end
for path, present in pairs(required_master) do
  if not present then
    error("manifest missing master role file: " .. path)
  end
end

print("manifest_update_paths_test.lua: ok")
