package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local M=require('master.rt_sync_coalescer')
local function T(v,m) if not v then error(m or"true") end end
T(type(M.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS)=="number","cooldown number")
T(M.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS>0,"cooldown positive")
T(type(M.DEFAULT_SHUTDOWN_CANDIDATE_STABILITY_MS)=="number","stability number")
T(M.DEFAULT_SHUTDOWN_CANDIDATE_STABILITY_MS>0,"stability positive")
T(M.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS>M.DEFAULT_SHUTDOWN_CANDIDATE_STABILITY_MS,"cooldown>stability")
print("master_shutdown_cooldown_stability_semantics_test.lua: ok")
