local function read(path)
  local f=io.open(path,"r"); if not f then error("missing: "..path) end
  local c=f:read("*a"); f:close(); return c
end
local start_lua=read("xreactor/start.lua")
local release_lua=read("xreactor/release.lua")
-- start.lua muss die Role referenzieren
if not start_lua:find("role",1,true) and not start_lua:find("ENERGY",1,true) and not start_lua:find("MASTER",1,true) then
  error("startup identity log format missing")
end
if not release_lua:find("manifest_id",1,true) then error("release.lua missing manifest_id") end
if not release_lua:find("release_id",1,true) then error("release.lua missing release_id") end
print("runtime_identity_logging_test.lua: ok")
