local M={}; M.__index=M
function M.new() return setmetatable({_q={}},M) end
function M:push(...) self._q[#self._q+1]={...} end
function M:peek() return self._q[1] end
function M:pop()
  if #self._q==0 then return nil end
  local e=self._q[1]; table.remove(self._q,1); return table.unpack(e)
end
function M:pull(f)
  while #self._q>0 do
    local e=self._q[1]; table.remove(self._q,1)
    if e[1]=="terminate" then error("Terminated",0) end
    if not f or f=="" or e[1]==f then return table.unpack(e) end
  end
end
function M:pull_raw(f)
  while #self._q>0 do
    local e=self._q[1]; table.remove(self._q,1)
    if not f or f=="" or e[1]==f then return table.unpack(e) end
  end
end
function M:size()  return #self._q end
function M:empty() return #self._q==0 end
function M:clear() self._q={} end
return M
