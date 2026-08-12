package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local path = '/xreactor/config/role.lua'
local temp_path = path .. '.xr_tmp'
local backup_path = path .. '.xr_prev'
local files = {
  ['/xreactor'] = '<dir>',
  ['/xreactor/config'] = '<dir>',
  [path] = 'return { role = "OLD" }',
}
local commit_writes = 0
local open_writes = 0
local serialize_fails = false

_G.textutils = {
  serialize = function(value)
    if serialize_fails then error('simulated serializer failure', 0) end
    return 'return { role = ' .. string.format('%q', tostring(value.role)) .. ' }'
  end,
  unserialize = function() return nil end,
}

_G.fs = {
  exists = function(candidate) return files[candidate] ~= nil end,
  getDir = function(candidate) return candidate:match('^(.*)/[^/]+$') or '' end,
  makeDir = function(candidate) files[candidate] = '<dir>' end,
  delete = function(candidate) files[candidate] = nil end,
  open = function(candidate, mode)
    if mode == 'r' then
      if files[candidate] == nil or files[candidate] == '<dir>' then return nil end
      return { readAll = function() return files[candidate] end, close = function() end }
    end
    if mode ~= 'w' then return nil end
    open_writes = open_writes + 1
    local buffer = ''
    return {
      write = function(value) buffer = buffer .. tostring(value) end,
      close = function()
        if candidate == path then
          commit_writes = commit_writes + 1
          if commit_writes == 1 then
            -- First target write is corrupted after close. The verification
            -- must detect it and restore the previous exact bytes.
            files[candidate] = 'CORRUPTED'
            return
          end
        end
        files[candidate] = buffer
      end,
    }
  end,
}

package.loaded['core.utils'] = nil
local utils = require('core.utils')

local ok, err = utils.write_config(path, { role = 'NEW' })
assert(ok == false and tostring(err):find('commit_verify_failed', 1, true),
  'corrupted commit must fail verification: ' .. tostring(err))
assert(files[path] == 'return { role = "OLD" }',
  'failed commit must restore the previous exact configuration bytes')
assert(files[temp_path] == nil, 'failed transaction must remove its staging file')
assert(files[backup_path] == 'return { role = "OLD" }',
  'failed transaction should retain the verified recovery copy')

local writes_before_serialize_failure = open_writes
serialize_fails = true
local serialized_ok, serialized_err = utils.write_config(path, { role = 'BROKEN' })
assert(serialized_ok == false and tostring(serialized_err):find('serialize_failed', 1, true),
  'serialization failure must be reported before file I/O')
assert(open_writes == writes_before_serialize_failure,
  'serialization failure must not open or truncate any file')
assert(files[path] == 'return { role = "OLD" }',
  'serialization failure must preserve the committed configuration')

print('utils_write_config_rollback_test.lua: ok')
