local function E(t,a)local r={}for i,p in ipairs(t)do r[i]={path=p,always=a or nil}end return r end
local function A(t)return E(t,true)end
local function J(a,b)for _,v in ipairs(b)do a[#a+1]=v end return a end
local base=E{
"adapters/monitor.lua","core/bootstrap.lua","core/comms.lua","core/health.lua","core/network.lua","core/non_rt_config.lua","core/non_rt_payload.lua","core/protocol.lua","core/registry.lua","