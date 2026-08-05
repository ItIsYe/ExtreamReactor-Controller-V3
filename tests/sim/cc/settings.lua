-- tests/sim/cc/settings.lua  Phase 4.5
-- In-Memory Settings-Stub.

local function new(initial)
  local data = {}
  if initial then for k,v in pairs(initial) do data[k]=v end end
  local s = {}
  function s.get(key, default) return data[key] ~= nil and data[key] or default end
  function s.set(key, value)   data[key] = value end
  function s.unset(key)        data[key] = nil end
  function s.getNames()
    local r={}; for k in pairs(data) do r[#r+1]=k end; table.sort(r); return r
  end
  function s.load(path) end  -- no-op in sim
  function s.save(path) end
  return s
end

return { new = new }
