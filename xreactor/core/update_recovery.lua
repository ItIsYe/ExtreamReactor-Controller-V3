local recovery = {}

local MARKER_PATH = "/xreactor/.update_in_progress"

local function read_file(path)
  if not fs.exists(path) then
    return nil
  end
  local handle = fs.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle.readAll()
  handle.close()
  return content
end

local function write_atomic(path, content)
  local tmp = path .. ".tmp"
  local handle = fs.open(tmp, "w")
  if not handle then
    error("Failed to open " .. tmp)
  end
  handle.write(content)
  handle.close()
  if fs.exists(path) then
    fs.delete(path)
  end
  fs.move(tmp, path)
end

local function ensure_dir(path)
  if path and path ~= "" and not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function crc32_hash(content)
  if content == nil then
    return nil
  end
  local crc = 0xffffffff
  for i = 1, #content do
    local byte = content:byte(i)
    crc = bit32.bxor(crc, byte)
    for _ = 1, 8 do
      local mask = bit32.band(crc, 1)
      crc = bit32.rshift(crc, 1)
      if mask == 1 then
        crc = bit32.bxor(crc, 0xedb88320)
      end
    end
  end
  return string.format("%08x", bit32.bnot(crc))
end

local function compute_hash(content, algo)
  if algo == "crc32" then
    return crc32_hash(content)
  end
  error("Unsupported hash algo: " .. tostring(algo))
end

local function file_checksum(path, algo)
  local content = read_file(path)
  if content == nil then
    return nil
  end
  return compute_hash(content, algo)
end

function recovery.read_marker()
  local content = read_file(MARKER_PATH)
  if not content then
    return nil
  end
  local data = textutils.unserialize(content)
  if type(data) ~= "table" then
    return nil
  end
  return data
end

function recovery.write_marker(data)
  local payload = textutils.serialize(data or {})
  write_atomic(MARKER_PATH, payload)
end

function recovery.clear_marker()
  if fs.exists(MARKER_PATH) then
    fs.delete(MARKER_PATH)
  end
end

local function rollback(marker)
  if not marker or not marker.backup_dir then
    return false, "missing backup"
  end
  local paths = marker.rollback_paths or {}
  for _, path in ipairs(paths) do
    local backup_path = marker.backup_dir .. path
    if fs.exists(backup_path) then
      ensure_dir(fs.getDir(path))
      fs.copy(backup_path, path)
    end
  end
  for _, path in ipairs(marker.created or {}) do
    if fs.exists(path) then
      fs.delete(path)
    end
  end
  return true
end

local function apply_staged(marker)
  if not marker.stage_dir or not fs.exists(marker.stage_dir) then
    return false, "missing stage"
  end
  local algo = marker.hash_algo or "crc32"
  for _, entry in ipairs(marker.updates or {}) do
    local staging_path = marker.stage_dir .. "/" .. entry.path
    if not fs.exists(staging_path) then
      return false, "missing staged file: " .. entry.path
    end
    local verify = file_checksum(staging_path, algo)
    if verify ~= entry.hash then
      return false, "staged hash mismatch: " .. entry.path
    end
  end
  for _, entry in ipairs(marker.updates or {}) do
    local staging_path = marker.stage_dir .. "/" .. entry.path
    local content = read_file(staging_path)
    if content == nil then
      return false, "missing staged content: " .. entry.path
    end
    local target_path = "/" .. entry.path
    ensure_dir(fs.getDir(target_path))
    write_atomic(target_path, content)
  end
  for _, entry in ipairs(marker.updates or {}) do
    local target_path = "/" .. entry.path
    local verify = file_checksum(target_path, algo)
    if verify ~= entry.hash then
      return false, "applied hash mismatch: " .. entry.path
    end
  end
  return true
end

function recovery.recover_if_needed()
  local marker = recovery.read_marker()
  if not marker then
    return false, "no marker"
  end
  local ok, err = apply_staged(marker)
  if ok then
    if marker.stage_dir and fs.exists(marker.stage_dir) then
      fs.delete(marker.stage_dir)
    end
    recovery.clear_marker()
    return true, "applied"
  end
  local rollback_ok = rollback(marker)
  recovery.clear_marker()
  return false, err or (rollback_ok and "rolled back" or "rollback failed")
end

return recovery
