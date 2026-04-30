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
if type(manifest.manifest_version) ~= "number" then
  error("expected numeric manifest_version")
end
local expected_manifest_id = "manifest-v" .. tostring(manifest.manifest_version)
if manifest.manifest_id ~= expected_manifest_id then
  error("expected manifest_id " .. expected_manifest_id)
end

local has_always = false
for _, entry in ipairs(manifest.base_files or {}) do
  if entry.always == true then
    has_always = true
    break
  end
end
if not has_always then
  error("expected at least one base file to declare always=true")
end

local required = {
  master = "MASTER",
  rt = "RT",
  energy = "ENERGY",
  water = "WATER",
  fuel = "FUEL",
  reprocessing = "REPROCESSING"
}

for role_key, role_label in pairs(required) do
  local entries = (manifest.roles or {})[role_key] or {}
  local found = false
  for _, entry in ipairs(entries) do
    if type(entry.required_for) == "table" then
      for _, marker in ipairs(entry.required_for) do
        if marker == role_label then
          found = true
        end
      end
    end
  end
  if not found then
    error("expected role metadata marker for " .. role_key)
  end
end


local function contains_path(entries, wanted)
  for _, entry in ipairs(entries or {}) do
    if entry.path == wanted then
      return true
    end
  end
  return false
end

local base_paths = manifest.base_files or {}
if contains_path(base_paths, "core/alert_rules.lua") then
  error("core/alert_rules.lua should not be in base_files")
end
if contains_path(base_paths, "adapters/reactor.lua") then
  error("adapters/reactor.lua should not be in base_files")
end
if contains_path(base_paths, "adapters/energy_storage.lua") then
  error("adapters/energy_storage.lua should not be in base_files")
end

if not contains_path((manifest.roles or {}).master, "core/alert_rules.lua") then
  error("expected master role to include core/alert_rules.lua")
end
if not contains_path((manifest.roles or {}).rt, "adapters/reactor.lua") then
  error("expected rt role to include adapters/reactor.lua")
end
if not contains_path((manifest.roles or {}).energy, "adapters/energy_storage.lua") then
  error("expected energy role to include adapters/energy_storage.lua")
end

print("manifest_role_filter_metadata_test.lua: ok")
