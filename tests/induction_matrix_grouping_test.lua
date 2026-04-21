package.path = './xreactor/?.lua;./xreactor/?/init.lua;' .. package.path

package.loaded['adapters.induction_matrix'] = nil

local matrix = require('adapters.induction_matrix')

local groups = matrix.group_ports({
  {
    id = 'matrix-a-port-0',
    alias = 'A0',
    adapter = { name = 'inductionPort_0', group_key = 'name_prefix:inductionPort' }
  },
  {
    id = 'matrix-a-port-1',
    alias = 'A1',
    adapter = { name = 'inductionPort_1', group_key = 'name_prefix:inductionPort' }
  },
  {
    id = 'matrix-b-port-0',
    alias = 'B0',
    adapter = { name = 'otherPort_0', group_key = 'name_prefix:otherPort' }
  }
})

if #groups ~= 2 then
  error('expected two logical matrix groups, got ' .. tostring(#groups))
end

local first = groups[1]
local second = groups[2]
if first.key ~= 'name_prefix:inductionPort' then
  error('expected induction group key ordering to be stable')
end
if first.representative.name ~= 'inductionPort_0' then
  error('expected lexicographically-first representative port for induction group')
end
if #first.ports ~= 2 then
  error('expected both induction ports to collapse into one logical matrix')
end
if second.key ~= 'name_prefix:otherPort' then
  error('expected second group key for other matrix ports')
end
if #second.ports ~= 1 then
  error('expected only one port in secondary group')
end

local key, source = matrix.build_group_key('inductionPort_7', {}, nil)
if key ~= 'name_prefix:inductionPort' or source ~= 'name_heuristic' then
  error('expected fallback name-based grouping heuristic for inductionPort_* naming')
end

print('induction_matrix_grouping_test.lua: ok')
