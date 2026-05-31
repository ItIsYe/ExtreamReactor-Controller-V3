package.path = './xreactor/?.lua;./xreactor/?/init.lua;' .. package.path

package.loaded['adapters.induction_matrix'] = nil

local matrix = require('adapters.induction_matrix')

local groups = matrix.group_ports({
  {
    id = 'matrix-a-port-0',
    alias = 'A0',
    adapter = { name = 'inductionPort_0', group_key = 'peripheral_name:inductionPort_0', group_key_source = 'peripheral_name_fallback' }
  },
  {
    id = 'matrix-b-port-0',
    alias = 'B0',
    adapter = { name = 'inductionPort_1', group_key = 'peripheral_name:inductionPort_1', group_key_source = 'peripheral_name_fallback' }
  },
  {
    id = 'matrix-c-port-0',
    alias = 'C0',
    adapter = { name = 'inductionPort_2', group_key = 'matrix_id:shared-a', group_key_source = 'api:getMatrixId' }
  },
  {
    id = 'matrix-c-port-1',
    alias = 'C1',
    adapter = { name = 'inductionPort_3', group_key = 'matrix_id:shared-a', group_key_source = 'api:getMatrixId' }
  }
})

if #groups ~= 3 then
  error('expected three logical matrix groups, got ' .. tostring(#groups))
end

local first = groups[1]
local second = groups[2]
local third = groups[3]
if first.key ~= 'matrix_id:shared-a' then
  error('expected matrix-id grouped entry to sort first')
end
if first.representative.name ~= 'inductionPort_2' then
  error('expected lexicographically-first representative port for shared matrix-id group')
end
if #first.ports ~= 2 then
  error('expected two ports to collapse into one logical matrix for shared matrix-id')
end
if second.key ~= 'peripheral_name:inductionPort_0' or #second.ports ~= 1 then
  error('expected per-port fallback grouping for inductionPort_0')
end
if third.key ~= 'peripheral_name:inductionPort_1' or #third.ports ~= 1 then
  error('expected per-port fallback grouping for inductionPort_1')
end

local key, source = matrix.build_group_key('inductionPort_7', {}, nil)
if key ~= 'peripheral_name:inductionPort_7' or source ~= 'peripheral_name_fallback' then
  error('expected per-port fallback grouping when no identity/topology API is available')
end

print('induction_matrix_grouping_test.lua: ok')
