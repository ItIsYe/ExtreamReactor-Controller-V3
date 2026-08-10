package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local path = '/xreactor/config/test.lua'
local original = 'return { version = 1, value = "old" }'
local files = { [path] = original }
local fail_commit = true

local function serialize(v)
  if type(v) == 'number' or type(v) == 'boolean' then return tostring(v) end
  if type(v) == 'string' then return string.format('%q', v) end
  if type(v) ~= 'table' then return 'nil' end
  local parts = {}
  for k, value in pairs(v) do
    local key = type(k) == 'string' and ('[' .. string.format('%q', k) .. ']') or ('[' .. tostring(k) .. ']')
    parts[#parts + 1] = key .. '=' .. serialize(value)
  end
  table.sort(parts)
  return '{' .. table.concat(parts, ',') .. '}'
end

_G.textutils = {
  serialize = serialize,
  unserialize = function(content)
    local loader = load('return ' .. content, '=unserialize', 't', {})
    if not loader then return nil end
    local ok, result = pcall(loader)
    return ok and result or nil
  end,
}
_G.fs = {
  exists = function(p) return files[p] ~= nil end,
  getDir = function(p) return p:match('^(.*)/[^/]+$') or '' end,
  makeDir = function() end,
  delete = function(p) files[p] = nil end,
  move = function(src, dst)
    if fail_commit and src == path .. '.xr_tmp' and dst == path then
      error('simulated commit move failure', 0)
    end
    if files[src] == nil then error('missing source ' .. tostring(src), 0) end
    files[dst] = files[src]
    files[src] = nil
  end,
  open = function(p, mode)
    if mode == 'r' then
      if files[p] == nil then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    elseif mode == 'w' then
      local buffer = ''
      return {
        write = function(value) buffer = buffer .. tostring(value) end,
        close = function() files[p] = buffer end,
      }
    end
    return nil
  end,
}

package.loaded['core.utils'] = nil
local utils = require('core.utils')
local ok, err = utils.write_config(path, { version = 2, value = 'new' })
if ok ~= false then error('failed final move must make write_config return false') end
if files[path] ~= original then
  error('old config must be restored byte-for-byte after failed commit; got ' .. tostring(files[path]))
end
if files[path .. '.xr_prev'] ~= nil then
  error('rollback should consume backup after restoring original config')
end

-- The migration path used to check only pcall success. A false return from
-- write_config therefore incorrectly set meta.migrated=true and used RAM-only
-- migrated values. Trigger the same failed atomic commit through load_config.
files[path] = original
fail_commit = true
local loaded, meta = utils.load_config(path, { version = 2, value = 'default', added = true })
if loaded.version ~= 1 or loaded.value ~= 'old' or loaded.added ~= nil then
  error('failed migration must return the original on-disk config, not RAM-only migrated values')
end
if meta.migrated == true then error('failed write_config must never be reported as migrated') end
if meta.migration_error == nil then error('failed migration should expose migration_error') end
if files[path] ~= original then error('migration failure must preserve original bytes') end

print('utils_write_config_atomic_rollback_test.lua: ok')
