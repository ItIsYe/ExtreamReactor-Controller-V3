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

local function collect(manifest)
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
local entries = collect(manifest)

if #entries == 0 then
  error("manifest has no file entries")
end

local seen = {}
local checked = 0
for _, entry in ipairs(entries) do
  local rel = entry.path
  if seen[rel] then
    error("duplicate manifest path: " .. tostring(rel))
  end
  seen[rel] = true

  local full = "xreactor/" .. tostring(rel)
  local handle = io.open(full, "rb")
  if not handle then
    error("manifest file missing on disk: " .. tostring(rel))
  end
  local content = handle:read("*a")
  handle:close()

  local actual_size = #content
  local expected_size = tonumber(entry.size_bytes) or -1
  if actual_size ~= expected_size then
    error(string.format("size mismatch for %s (manifest=%d actual=%d)", rel, expected_size, actual_size))
  end

  local actual_hash = crc32_hash(content)
  if tostring(entry.hash) ~= tostring(actual_hash) then
    error(string.format("hash mismatch for %s (manifest=%s actual=%s)", rel, tostring(entry.hash), tostring(actual_hash)))
  end
  checked = checked + 1
end

print(string.format("manifest_integrity_consistency_test.lua: ok (%d files)", checked))
