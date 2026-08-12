local function read(p)local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local boot=read('xreactor/start.lua')
assert(boot:find('[BOOT] XReactor',1,true),'bootstrap must emit role/release lifecycle identity')
local contracts={
  ['xreactor/nodes/energy/main.lua']={'utils.init_logger','"Startup"','log("Initializing..."'},
  ['xreactor/nodes/rt/main.lua']={'RT-Node starting','RT-Node ready'},
  ['xreactor/nodes/fuel/main.lua']={'support_runtime.init_logging','Monitor-Erstinit'},
  ['xreactor/master/runtime_loop.lua']={'init_runtime','runtime'},
}
for p,tokens in pairs(contracts) do local s=read(p); for _,t in ipairs(tokens) do assert(s:find(t,1,true),p..' missing lifecycle/log contract '..t) end end
print('lifecycle_logging_contract_guard_test.lua: ok')
