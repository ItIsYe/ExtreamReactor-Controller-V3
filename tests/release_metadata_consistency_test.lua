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

local function collect_manifest_entries(manifest)
  local entries = {}
  local function add(group)
    for _, entry in ipairs(group or {}) do
      entries[#entries + 1] = entry
    end
  end
  add(manifest.base_files)
  add(manifest.dev_files)
  for _, role_entries in pairs(manifest.roles or {}) do
    add(role_entries)
  end
  return entries
end

local manifest = load_table("xreactor/manifest.lua")
local release = load_table("xreactor/release.lua")
local installer_file = assert(io.open("installer", "rb"))
local installer_content = installer_file:read("*a")
installer_file:close()

local manifest_entries = collect_manifest_entries(manifest)
if #manifest_entries == 0 then
  error("manifest has no entries")
end

if release.manifest_id ~= manifest.manifest_id then
  error("release manifest_id mismatch")
end
if tonumber(release.manifest_version) ~= tonumber(manifest.manifest_version) then
  error("release manifest_version mismatch")
end
if tostring(release.hash_algo) ~= tostring(manifest.hash_algo) then
  error("release hash_algo mismatch")
end
if tonumber(release.manifest_file_count) ~= #manifest_entries then
  error("release manifest_file_count mismatch")
end
if tostring(release.manifest_path) ~= "xreactor/manifest.lua" then
  error("release manifest_path mismatch")
end
if type(release.commit_sha) ~= "string" or not string.match(release.commit_sha, "^[0-9a-f]+$") then
  error("release commit_sha must be an immutable git sha")
end
if #release.commit_sha < 12 then
  error("release commit_sha too short")
end

local installer_hash = crc32_hash(installer_content)
if tostring(release.installer_core_hash) ~= installer_hash then
  error("release installer_core_hash mismatch")
end
if tonumber(release.installer_core_size_bytes) ~= #installer_content then
  error("release installer_core_size_bytes mismatch")
end

print("release_metadata_consistency_test.lua: ok")
