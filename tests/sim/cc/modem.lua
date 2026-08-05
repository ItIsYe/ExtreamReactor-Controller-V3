local M={}
function M.new(opts)
  opts=opts or {}
  local bus={_modems={},_messages={},_profile=opts.profile or "clean",
    _drop=opts.drop_rate or 0, _dup=opts.dup_rate or 0,_seed=opts.seed or 0}
  math.randomseed(bus._seed)
  local function profile(msgs)
    if bus._profile=="clean" then return msgs end
    local out={}
    for _,m in ipairs(msgs) do
      local r=math.random()
      if bus._profile=="drop" and r<bus._drop then
      elseif bus._profile=="duplicate" and r<bus._dup then out[#out+1]=m;out[#out+1]=m
      else out[#out+1]=m end
    end
    return out
  end
  function bus.make_modem(name,eq)
    local chs={}; bus._modems[name]={channels=chs,eq=eq}
    return {
      open=function(ch) chs[ch]=true end,
      close=function(ch) chs[ch]=nil end,
      isOpen=function(ch) return chs[ch]==true end,
      transmit=function(ch,reply,msg)
        table.insert(bus._messages,{from=name,channel=ch,reply=reply,message=msg,distance=1})
      end,
      isWireless=function() return true end,
    }
  end
  function bus.tick()
    local p=bus._messages; bus._messages={}
    local d=profile(p)
    for _,msg in ipairs(d) do
      for n,modem in pairs(bus._modems) do
        if n~=msg.from and modem.channels[msg.channel] then
          if modem.eq then
            modem.eq:push("modem_message",n,msg.channel,msg.reply,msg.message,msg.distance)
          end
        end
      end
    end
    return #d
  end
  function bus.set_profile(p,params) bus._profile=p; params=params or {}
    bus._drop=params.drop_rate or bus._drop; bus._dup=params.dup_rate or bus._dup
  end
  function bus.pending_count() return #bus._messages end
  return bus
end
return M
