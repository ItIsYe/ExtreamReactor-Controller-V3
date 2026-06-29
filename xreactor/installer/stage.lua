-- installer/stage.lua
-- Dateien herunterladen und schreiben. Atomic write, Speicher-Check.

local M = {}
local WRITE_BUFFER = 1024

local function free_space()
  if not fs.getFreeSpace then return nil end
  local ok, v = pcall(fs.getFreeSpace, "/")
  if not ok then return nil end
  if type(v) == "string" then
    if v:lower() == "unlimited" then return math.huge end
    v = tonumber(v)
  end
  if type(v) == "number" then return v < 0 and math.huge or v end
  return nil
end

local function reclaim(needed)
  local free = free_space()
  if free and free >= needed then return true end
  if fs.exists("/xreactor_logs")       then pcall(fs.delete, "/xreactor_logs") end
  pcall(fs.makeDir, "/xreactor_logs")
  if fs.exists("/xreactor_backup_prev") then pcall(fs.delete, "/xreactor_backup_prev") end
  if fs.exists("/xreactor_stage")       then pcall(fs.delete, "/xreactor_stage") end
  free = free_space()
  return free == nil or free >= needed
end

function M.write(path, content)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  if not reclaim(#content + WRITE_BUFFER) then
    return false, "not enough space for " .. path
  end
  local tmp = path .. ".xr_tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "open failed: " .. tmp end
  local write_ok, write_err = pcall(function() f.write(content) end)
  pcall(f.close)
  if not write_ok then pcall(fs.delete, tmp); return false, tostring(write_err) end
  if fs.exists(path) then pcall(fs.delete, path) end
  local ok2, mv_err = pcall(fs.move, tmp, path)
  if not ok2 then pcall(fs.delete, tmp); return false, "move failed: " .. tostring(mv_err) end
  return true
end

function M.read(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local c = f.readAll(); f.close(); return c
end

function M.verify(path, entry)
  if not fs.exists(path) then return false, "missing: " .. path end
  local content = M.read(path)
  if not content then return false, "unreadable: " .. path end
  if entry and entry.size_bytes and #content ~= entry.size_bytes then
    return false, string.format("size mismatch %s: got %d expected %d",
      path, #content, entry.size_bytes)
  end
  if path:sub(-4) == ".lua" then
    local loader, lerr = load(content, "=" .. path, "t", {})
    if not loader then return false, "lua syntax: " .. path .. ": " .. tostring(lerr) end
  end
  return true
end

function M.install(files, install_root, http_mod, sha, progress_fn)
  local total = #files
  for i, item in ipairs(files) do
    local rel   = item.path
    local entry = item.entry or {}
    local dest  = install_root .. "/" .. rel
    local content = item.content
    if not content then
      local body, err = http_mod.download_file(rel, sha)
      if not body then return false, "download failed: " .. rel .. " — " .. tostring(err) end
      if http_mod.is_html(body) then return false, "unexpected HTML for: " .. rel end
      content = body
    end
    local ok, werr = M.write(dest, content)
    if not ok then return false, werr end
    local ok2, verr = M.verify(dest, entry)
    if not ok2 then return false, verr end
    if progress_fn then progress_fn(i, total, rel) end
  end
  return true
end

return M
