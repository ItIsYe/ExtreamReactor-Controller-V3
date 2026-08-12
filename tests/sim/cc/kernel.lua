local k={}
k.TICK_S=0.05; k.MAX_TICKS=100000
local _n=0; local _s=0
function k.reset(s) _n=0;_s=s or 0;math.randomseed(_s) end
function k.tick()      _n=_n+1 end
function k.now_s()     return _n*k.TICK_S end
function k.now_ticks() return _n end
function k.now_ms()    return _n*k.TICK_S*1000 end
function k.epoch_ms()  return _n*50 end
function k.advance(n)  _n=_n+math.max(1,math.floor(n or 1)) end
function k.advance_s(s) k.advance(math.ceil(s/k.TICK_S)) end
function k.check_limit()
  if _n>=k.MAX_TICKS then
    error(("SIM: Tick-Limit %d erreicht (%.1fs)"):format(k.MAX_TICKS,k.now_s()),2)
  end
end
function k.seed() return _s end
return k
