-- tests/auto_update_ensure_temp_space_test.lua
--
-- Regression test: installer/auto_update.lua's run_update() writes the
-- freshly downloaded installer bootstrap to a temp file before dofile()-ing
-- it, gated by its own standalone free-space check (has_temp_space) --
-- separate from installer/stage.lua's reclaim(), which already got a
-- last-resort /xreactor_logs cleanup (explicit user request, see
-- installer_stage_space_diagnostic_test.lua). Reported: a node whose auto-
-- updater otherwise worked (quiesce succeeded) still failed every one of
-- its 4 download attempts with "insufficient space for temporary
-- installer", because logs had re-accumulated and this path had no
-- equivalent last-resort cleanup of its own. ensure_temp_space() mirrors
-- stage.lua's reclaim_logs() for this separate check.
--
-- auto_update.lua is a big module with a lot of HTTP-facing code; this
-- extracts just the relevant, self-contained helper region (same approach
-- installer_config_backup_fail_closed_test.lua already uses for
-- installer/init.lua) rather than driving the whole module.

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  return content
end

local function extract(source, first_marker, last_marker)
  local first = assert(source:find(first_marker, 1, true))
  local last = assert(source:find(last_marker, first, true))
  return source:sub(first, last - 1)
end

local root = os.getenv("REPO_ROOT") or "."
local source = read_file(root .. "/xreactor/installer/auto_update.lua")
local helpers = extract(source, "local STATUS_PATH = ", "local function run_update()")

local function load_helpers(fs_impl)
  _G.fs = fs_impl
  local chunk = assert(load(helpers .. [[
return { has_temp_space = has_temp_space, ensure_temp_space = ensure_temp_space }
]], "=auto_update_helpers", "t", _ENV))
  return chunk()
end

local function make_fs(total_quota, log_bytes)
  local files = { ["/xreactor_logs/master.log"] = string.rep("x", log_bytes) }
  local dirs = { ["/xreactor_logs"] = true }
  local function used_space()
    local total = 0
    for _, content in pairs(files) do total = total + #content end
    return total
  end
  return {
    exists = function(p) return files[p] ~= nil or dirs[p] == true end,
    isDir = function(p) return dirs[p] == true end,
    getFreeSpace = function() return total_quota - used_space() end,
    getSize = function(p) return files[p] and #files[p] or 0 end,
    list = function(p)
      if p ~= "/xreactor_logs" then return {} end
      local names = {}
      for path in pairs(files) do
        local prefix = "/xreactor_logs/"
        if path:sub(1, #prefix) == prefix then names[#names + 1] = path:sub(#prefix + 1) end
      end
      return names
    end,
    delete = function(p)
      if dirs[p] then
        dirs[p] = nil
        local prefix = p .. "/"
        for path in pairs(files) do
          if path:sub(1, #prefix) == prefix then files[path] = nil end
        end
      end
      files[p] = nil
    end,
  }
end

-- Clearing /xreactor_logs frees enough space -- ensure_temp_space() must
-- delete it and report success.
do
  local helpers_mod = load_helpers(make_fs(2000, 1500))
  local ok = helpers_mod.ensure_temp_space(1000)
  if not ok then error("expected ensure_temp_space() to succeed after auto-clearing /xreactor_logs") end
  if fs.exists("/xreactor_logs") then error("CRITICAL: /xreactor_logs must actually be deleted") end
end

-- Even clearing /xreactor_logs isn't enough -- must still report failure,
-- not loop or error out some other way.
do
  local helpers_mod = load_helpers(make_fs(500, 400))
  local ok = helpers_mod.ensure_temp_space(1124)
  if ok then error("expected ensure_temp_space() to still fail when even /xreactor_logs isn't enough") end
end

-- Sanity: has_temp_space() alone never touches /xreactor_logs.
do
  local helpers_mod = load_helpers(make_fs(500, 400))
  helpers_mod.has_temp_space(1124)
  if not fs.exists("/xreactor_logs") then error("has_temp_space() alone must never delete anything") end
end

print("auto_update_ensure_temp_space_test.lua: ok")
