-- nodes/rt/capacity_cache.lua
-- Persistent RT capacity-learning cache.

local M = {}

local function serialize_string(value)
  if value == nil then return "nil" end
  return string.format("%q", tostring(value))
end

function M.save(learning, opts)
  if type(learning) ~= "table" or learning.ready ~= true then return false, "not ready" end
  opts = opts or {}
  local path = opts.path
  if type(path) ~= "string" or path == "" then return false, "no path" end

  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  local tmp = path .. ".xr_tmp"
  local backup = path .. ".xr_prev"
  local ok, f = pcall(fs.open, tmp, "w")
  if not ok or not f then return false, "open failed" end

  local turbine_count = tonumber(opts.turbine_count) or 0
  local lines = {
    "-- RT capacity cache - auto-generated, do not edit",
    "return {",
    "  ready = true,",
    string.format("  max_output = %s,", tostring(learning.max_output or 0)),
    string.format("  turbine_count = %s,", tostring(turbine_count)),
    string.format("  reason = %q,", tostring(learning.reason or "LOADED_FROM_CACHE")),
    "  topology_signature = " .. serialize_string(learning.topology_signature) .. ",",
    string.format("  topology_generation = %s,", tostring(tonumber(learning.topology_generation) or 0)),
    string.format("  topology_changed_at = %s,", tostring(tonumber(learning.topology_changed_at) or "nil")),
    "}",
    "",
  }
  local content = table.concat(lines, "\n")
  local write_ok, write_err = pcall(f.write, content)
  pcall(f.close)
  if not write_ok then pcall(fs.delete, tmp); return false, "write failed: " .. tostring(write_err) end

  -- Verify the exact bytes before replacing a known-good cache.
  local verify = fs.open(tmp, "r")
  local verify_content = verify and verify.readAll() or nil
  if verify then verify.close() end
  if verify_content ~= content then pcall(fs.delete, tmp); return false, "verify failed" end

  local had_old = fs.exists(path)
  if had_old then
    if fs.exists(backup) then pcall(fs.delete, backup) end
    local moved = pcall(fs.move, path, backup)
    if not moved or not fs.exists(backup) then
      pcall(fs.delete, tmp)
      return false, "backup move failed"
    end
  end
  local moved_new = pcall(fs.move, tmp, path)
  if not moved_new or not fs.exists(path) then
    pcall(fs.delete, tmp)
    if had_old and fs.exists(backup) and not fs.exists(path) then pcall(fs.move, backup, path) end
    return false, "commit move failed"
  end
  if had_old and fs.exists(backup) then pcall(fs.delete, backup) end
  return true
end

function M.load(opts)
  opts = opts or {}
  local path = opts.path
  if type(path) ~= "string" or path == "" or not fs.exists(path) then return nil end

  local ok, data = pcall(dofile, path)
  if not ok or type(data) ~= "table" or data.ready ~= true
      or type(data.max_output) ~= "number" or data.max_output <= 0 then
    return nil
  end
  data.reason = data.reason or "LOADED_FROM_CACHE"
  data.topology_generation = tonumber(data.topology_generation) or 0
  return data
end

return M
