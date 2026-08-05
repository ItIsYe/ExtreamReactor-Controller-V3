package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local function T(v,m) if not v then error(m or"true") end end
-- logger.lua als Source-Check: startup_action Format muss disk=, executed=, removed= enthalten
local f=io.open("xreactor/core/logger.lua","r"); local src=f:read("*a"); f:close()
T(src:find("disk=",1,true)~=nil,"startup_action must include disk= field")
T(src:find("executed=",1,true)~=nil,"startup_action must include executed= field")
T(src:find("removed=",1,true)~=nil,"startup_action must include removed= field")
T(src:find("startup_min_required=",1,true)~=nil,"startup_action must include startup_min_required=")
T(src:find("startup_required_now=",1,true)~=nil,"startup_action must include startup_required_now=")
T(src:find("startup_action",1,true)~=nil,"startup_action field must be set")
-- preboot log pattern muss im Code referenziert werden
T(src:find("preboot",1,true)~=nil,"preboot log pattern must be referenced")
print("logger_startup_policy_test.lua: ok")
