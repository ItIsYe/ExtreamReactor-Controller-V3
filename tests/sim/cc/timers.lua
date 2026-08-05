local M={}; M.__index=M
function M.new(k) return setmetatable({_k=k,_nid=1,_t={}},M) end
function M:start(s)
  local t=math.max(1,math.ceil(s/0.05))
  local id=self._nid; self._nid=self._nid+1
  self._t[id]=self._k.now_ticks()+t; return id
end
function M:cancel(id) self._t[id]=nil end
function M:fired(q)
  local now=self._k.now_ticks(); local ids={}
  for id,at in pairs(self._t) do if at<=now then ids[#ids+1]=id end end
  table.sort(ids)
  for _,id in ipairs(ids) do self._t[id]=nil; q:push("timer",id) end
  return #ids
end
function M:pending() return next(self._t)~=nil end
function M:count() local n=0; for _ in pairs(self._t) do n=n+1 end; return n end
return M
