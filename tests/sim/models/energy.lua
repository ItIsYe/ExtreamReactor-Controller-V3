local M={}
local D={capacity=1000000,stored=0,max_input=50000,max_output=50000,num_ports=6,block_name="SIM-Energy"}
function M.new(opts)
  opts=opts or {}; local cfg={}
  for k,v in pairs(D) do cfg[k]=opts[k]~=nil and opts[k] or v end
  local s={stored=math.min(cfg.capacity,opts.stored or cfg.stored),
    last_input=0,last_output=0,topology_ver=1,ports={}}
  for i=1,cfg.num_ports do s.ports[i]={direction="input",enabled=true} end
  local function tick(inp,out)
    inp=math.max(0,math.min(cfg.max_input,inp or 0))
    out=math.max(0,math.min(cfg.max_output,out or 0))
    local ns=math.min(cfg.capacity,s.stored+inp)
    s.last_input=ns-s.stored
    ns=math.max(0,ns-out)
    s.last_output=(s.stored+s.last_input)-ns
    s.stored=ns
  end
  local api={}; api.tick=tick
  function api.getEnergyStored() return s.stored end
  function api.getMaxEnergyStored() return cfg.capacity end
  function api.getLastTickInput() return s.last_input end
  function api.getLastTickOutput() return s.last_output end
  function api.getEnergyFilledPercentage() return s.stored/cfg.capacity*100 end
  function api.getConnectedEnergyBlocks()
    return {{name=cfg.block_name,energy=s.stored,max=cfg.capacity}}
  end
  function api.invalidateTopology()
    s.topology_ver=s.topology_ver+1; s.ports={}
    for i=1,cfg.num_ports do s.ports[i]={direction="input",enabled=true} end
  end
  function api.getTopologyVersion() return s.topology_ver end
  function api._state() return s end; function api._cfg() return cfg end
  return api
end
return M
