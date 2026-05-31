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

local manifest = load_table("xreactor/manifest.lua")
local master_entries = ((manifest.roles or {}).master) or {}

local entry = nil
for _, candidate in ipairs(master_entries) do
  if candidate.path == "master/rt_sync.lua" then
    entry = candidate
    break
  end
end

if not entry then
  error("manifest missing roles.master entry for master/rt_sync.lua")
end

local handle = io.open("xreactor/master/rt_sync.lua", "rb")
if not handle then
  error("missing file xreactor/master/rt_sync.lua")
end
local content = handle:read("*a")
handle:close()

local actual_size = #content
local expected_size = tonumber(entry.size_bytes) or -1
if actual_size ~= expected_size then
  error(string.format("master/rt_sync.lua size mismatch (manifest=%d actual=%d)", expected_size, actual_size))
end

local actual_hash = crc32_hash(content)
if tostring(entry.hash) ~= tostring(actual_hash) then
  error(string.format("master/rt_sync.lua hash mismatch (manifest=%s actual=%s)", tostring(entry.hash), tostring(actual_hash)))
end

print("master_rt_sync_manifest_regression_test.lua: ok")
