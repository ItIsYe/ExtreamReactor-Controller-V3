local function read_file(path)
  local handle = assert(io.open(path, 'r'))
  local content = handle:read('*a')
  handle:close()
  return content
end

local function extract(source, first_marker, last_marker)
  local first = assert(source:find(first_marker, 1, true))
  local last = assert(source:find(last_marker, first, true))
  return source:sub(first, last - 1)
end

local root = os.getenv('REPO_ROOT') or '.'
local source = read_file(root .. '/xreactor/installer/init.lua')
local helpers = extract(source, 'local CONFIG_DIR', '-- Der Bootstrap waehlt genau einen Ref')

local function backup_with(fs_impl)
  _G.fs = fs_impl
  local chunk = assert(load([[
local INSTALL_ROOT = '/xreactor'
]] .. helpers .. [[
return backup_config_dir
]], '=config_backup_helpers', 't', _ENV))
  local backup = chunk()
  return pcall(backup)
end

local function base_fs()
  return {
    exists = function(path)
      return path == '/xreactor/config' or path == '/xreactor/config/a.lua'
    end,
    isDir = function(path) return path == '/xreactor/config' end,
    list = function(path)
      if path == '/xreactor/config' then return { 'a.lua' } end
      return {}
    end,
    open = function(path, mode)
      if path ~= '/xreactor/config/a.lua' or mode ~= 'r' then return nil end
      return { readAll = function() return 'return {}\n' end, close = function() end }
    end,
  }
end

do
  local fs_mock = base_fs()
  fs_mock.list = function() error('list boom', 0) end
  local ok, err = backup_with(fs_mock)
  assert(ok == false and tostring(err):find('aufgelistet', 1, true),
    'fs.list failure must abort backup visibly: ' .. tostring(err))
end

do
  local fs_mock = base_fs()
  fs_mock.open = function() return nil end
  local ok, err = backup_with(fs_mock)
  assert(ok == false and tostring(err):find('gesichert', 1, true),
    'file open failure must abort backup visibly: ' .. tostring(err))
end

do
  local fs_mock = base_fs()
  fs_mock.open = function()
    return { readAll = function() error('read boom', 0) end, close = function() end }
  end
  local ok, err = backup_with(fs_mock)
  assert(ok == false and tostring(err):find('gelesen', 1, true),
    'file read failure must abort backup visibly: ' .. tostring(err))
end

do
  local fs_mock = base_fs()
  fs_mock.open = function()
    return { readAll = function() return 'return {}\n' end,
      close = function() error('close boom', 0) end }
  end
  local ok, err = backup_with(fs_mock)
  assert(ok == false and tostring(err):find('geschlossen', 1, true),
    'file close failure must abort backup visibly: ' .. tostring(err))
end

do
  local fs_mock = base_fs()
  fs_mock.list = function() return {} end
  local ok, backup = backup_with(fs_mock)
  assert(ok == true and type(backup) == 'table' and next(backup) == nil,
    'a genuinely empty config directory must remain a valid backup')
end

local backup_pos = assert(source:find('local config_backup = backup_config_dir()', 1, true))
local delete_pos = assert(source:find('pcall(fs.delete, INSTALL_ROOT)', 1, true))
assert(backup_pos < delete_pos,
  'complete config backup must finish before the install root can be deleted')

print('installer_config_backup_fail_closed_test.lua: ok')
