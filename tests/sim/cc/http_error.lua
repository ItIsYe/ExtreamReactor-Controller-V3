local M={}
function M.make_stub(profile,opts)
  opts=opts or {}
  if profile=="success" then return {body=opts.body or "ok",status=opts.status or 200,headers=opts.headers or {}}
  elseif profile=="error" then return {error=opts.message or "HTTP error "..(opts.status or 500)}
  elseif profile=="timeout" then return {error="timeout"}
  elseif profile=="corrupt" then
    local b=opts.body or ""; return {body=b:sub(1,math.floor(#b/2)),status=200}
  elseif profile=="not_found" then return {error="HTTP/1.1 404 Not Found"}
  else return {body=opts.body or "",status=opts.status or 200} end
end
function M.make_sequence(stubs,http_sim)
  local i=0
  return function(url) i=i+1; http_sim.stub(url,stubs[i] or stubs[#stubs]) end
end
return M
