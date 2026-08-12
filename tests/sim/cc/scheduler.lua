local M={}; M.__index=M
function M.new(k,eq) return setmetatable({_k=k,_eq=eq,_cos={}},M) end
function M:add(fn,name)
  local co=coroutine.create(fn); local q=self._eq.new()
  self._cos[#self._cos+1]={co=co,q=q,name=name or("co"..#self._cos),dead=false,err=nil}
end
function M:broadcast(...)
  local a={...}
  for _,e in ipairs(self._cos) do if not e.dead then e.q:push(table.unpack(a)) end end
end
function M:step()
  local any=false
  for _,e in ipairs(self._cos) do
    if e.dead then goto c end
    local ev={e.q:pop()}; if not ev[1] then goto c end
    local ok,val=coroutine.resume(e.co,table.unpack(ev))
    if not ok then e.dead=true;e.err=val;any=true
    elseif coroutine.status(e.co)=="dead" then e.dead=true;e.result=val;any=true end
    ::c::
  end
  return {any=any,all=self:_all_dead()}
end
function M:_all_dead()
  for _,e in ipairs(self._cos) do if not e.dead then return false end end
  return true
end
function M:errors()
  local r={}
  for _,e in ipairs(self._cos) do if e.err then r[#r+1]=e.name..": "..tostring(e.err) end end
  return r
end
local function run(k,eq,fns,sq,max,stop_any)
  local sch=M.new(k,eq)
  for i,fn in ipairs(fns) do sch:add(fn,"fn"..i) end
  for _,e in ipairs(sch._cos) do
    if coroutine.status(e.co)~="dead" then
      local ok,val=coroutine.resume(e.co)
      if not ok then e.dead=true;e.err=val end
    end
  end
  local t=0
  while t<(max or k.MAX_TICKS) do
    while not sq:empty() do local a={sq:pop()};if a[1] then sch:broadcast(table.unpack(a)) end end
    local st=sch:step()
    if stop_any and st.any then break end
    if st.all then break end
    t=t+1; k.tick()
  end
  local errs=sch:errors()
  if #errs>0 then error(table.concat(errs,"; "),0) end
end
function M.wait_for_any(k,eq,fns,q,n) run(k,eq,fns,q,n,true) end
function M.wait_for_all(k,eq,fns,q,n) run(k,eq,fns,q,n,false) end
return M
