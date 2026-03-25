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
if manifest.manifest_version ~= 6 then
  error("expected manifest version 6")
end
if manifest.manifest_id ~= "manifest-v6" then
  error("expected manifest_id manifest-v6")
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

print("manifest_role_filter_metadata_test.lua: ok")
