local function read_file(path)
  local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local function extract(src, a, b)
  local i = assert(src:find(a, 1, true)); local j = assert(src:find(b, i, true)); return src:sub(i, j - 1)
end
local root = os.getenv("REPO_ROOT") or "."
local src = read_file(root .. "/xreactor/installer/init.lua")
local snippet = extract(src, "local CONFIG_DIR", "-- Fix (2026-07-16): CRITICAL. INSTALL-P0")

local function build_backup(fs_impl)
  _G.fs = fs_impl
  local harness = [[
local INSTALL_ROOT = "/xreactor"
local stage_mod = { read = function() return nil end }
]] .. snippet .. [[
return backup_config_dir
]]
  local chunk = assert(load(harness, "=config_backup_helpers", "t"))
  return chunk()()
end

local function base_fs()
  return {
    exists = function(path) return path == "/xreactor/config" or path == "/xreactor/config/a.lua" end,
    isDir = function(path) return path == "/xreactor/config" end,
    list = function() return { "a.lua" } end,
    open = function(path)
      return { readAll = function() return "return {}\n" end, close = function() end }
    end,
  }
end

do
  local fsx = base_fs(); fsx.list = function() error("list boom") end
  local bundle, errors = build_backup(fsx)
  assert(#errors == 1 and bundle.count == 0, "fs.list failure must be fatal/visible")
end

do
  local fsx = base_fs(); fsx.open = function() return nil end
  local bundle, errors = build_backup(fsx)
  assert(#errors == 1 and bundle.count == 1 and bundle.files["a.lua"] == nil, "open failure must be visible")
end

do
  local fsx = base_fs(); fsx.open = function()
    return { readAll = function() error("read boom") end, close = function() end }
  end
  local _, errors = build_backup(fsx)
  assert(#errors >= 1, "read failure must be visible")
end

do
  local fsx = base_fs(); fsx.open = function()
    return { readAll = function() return "return {}\n" end, close = function() error("close boom") end }
  end
  local _, errors = build_backup(fsx)
  assert(#errors >= 1, "close failure must be visible")
end

do
  local fsx = base_fs(); fsx.list = function() return {} end
  local bundle, errors = build_backup(fsx)
  assert(#errors == 0 and bundle.count == 0, "real empty config directory must be a valid zero-file backup")
end

local error_pos = assert(src:find("Config-Backup unvollstaendig", 1, true))
local delete_pos = assert(src:find("pcall(fs.delete, INSTALL_ROOT)", 1, true))
assert(error_pos < delete_pos, "backup errors must be handled before destructive install-root delete")
print("installer_config_backup_fail_closed_test.lua: ok")
