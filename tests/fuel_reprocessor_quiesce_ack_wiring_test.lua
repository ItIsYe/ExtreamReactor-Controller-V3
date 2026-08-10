local function read(p) local f=assert(io.open(p,'r')); local s=f:read('*a');f:close();return s end
local root=os.getenv('REPO_ROOT') or '.'
for _,p in ipairs({'xreactor/nodes/fuel/main.lua','xreactor/nodes/reprocessor/main.lua'}) do
  local s=read(root..'/'..p)
  assert(s:find(':begin_quiesce("UPDATE_QUIESCE")',1,true), p..' must begin confirmed valve quiesce')
  assert(s:find(':poll_quiesce()',1,true), p..' must wait for current BLOCKED acknowledgements')
end
print('fuel_reprocessor_quiesce_ack_wiring_test.lua: ok')
