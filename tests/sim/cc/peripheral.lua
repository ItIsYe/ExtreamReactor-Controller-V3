local M={}
function M.new(eq)
  local devices={}; local listeners={}
  local reg={}
  function reg.attach(name,dtype,methods,side)
    devices[name]={type=dtype,methods=methods or {},side=side or name}
    if eq then eq:push("peripheral",name) end
    for _,cb in ipairs(listeners) do if cb.on_attach then cb.on_attach(name,dtype) end end
  end
  function reg.detach(name)
    if devices[name] then devices[name]=nil
      if eq then eq:push("peripheral_detach",name) end
      for _,cb in ipairs(listeners) do if cb.on_detach then cb.on_detach(name) end end
    end
  end
  function reg.isPresent(n)  return devices[n]~=nil end
  function reg.getType(n)    local d=devices[n]; return d and d.type or nil end
  function reg.getMethods(n)
    local d=devices[n]; if not d then return {} end
    local m={}; for k in pairs(d.methods) do m[#m+1]=k end; table.sort(m); return m
  end
  function reg.call(n,method,...)
    local d=devices[n]
    if not d then error("Peripheral '"..tostring(n).."' not present",2) end
    local fn=d.methods[method]
    if not fn then error("Method '"..tostring(method).."' not found",2) end
    return fn(...)
  end
  function reg.wrap(n)
    local d=devices[n]; if not d then return nil end
    local p={}; for k,fn in pairs(d.methods) do p[k]=fn end; return p
  end
  function reg.find(dtype,filter)
    local r={}
    for n,d in pairs(devices) do
      if d.type==dtype then
        local p=reg.wrap(n)
        if not filter or filter(n,p) then r[#r+1]=p end
      end
    end
    return table.unpack(r)
  end
  function reg.getNames()
    local r={}; for n in pairs(devices) do r[#r+1]=n end; table.sort(r); return r
  end
  function reg.addListener(cb) listeners[#listeners+1]=cb end
  function reg._devices() return devices end
  return reg
end
return M
