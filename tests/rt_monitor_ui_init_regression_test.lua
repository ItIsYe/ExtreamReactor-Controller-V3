package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
_G.keys=_G.keys or {left=1,right=2,pageUp=3,pageDown=4}
_G.peripheral=_G.peripheral or {wrap=function() return nil end}
package.loaded['core.ui']={getSize=function() return 20,10 end,panel=function() end,
  badge=function() end,text=function() end,list=function() end}
package.loaded['core.ui_router']={new=function(opts)
  return {render=function(_,m,mo) if opts and opts.pages and opts.pages[1] then opts.pages[1].render(m,mo) end end,
          handle_input=function() end}
end}
package.loaded['shared.colors']={get=function() return 1 end}
local monitor_ui=require('nodes.rt.monitor_ui')
local function mk_mon()
  return {getSize=function() return 20,10 end,setTextScale=function() end,
    setBackgroundColor=function() end,clear=function() end,
    setCursorPos=function() end,write=function() end,
    setTextColor=function() end,isColor=function() return true end}
end
-- Test: adapter.find ist die primäre API (strategy="largest")
local find_called=false; local strategy_used=nil
local ok_find=pcall(monitor_ui.init,{
  find=function(preferred,strategy,scale,log_prefix)
    find_called=true; strategy_used=strategy; return mk_mon(),"top"
  end
},"top",0.5)
assert(find_called, "monitor_ui.init must call adapter.find when available")
assert(strategy_used=="largest", "adapter.find strategy must be 'largest', got: "..tostring(strategy_used))
-- adapter.wrap Fallback
local wrap_called=false
pcall(monitor_ui.init,{wrap=function(n) wrap_called=true; return mk_mon() end},"top",0.5)
assert(wrap_called, "monitor_ui.init must fall back to adapter.wrap")
-- Kein Crash bei nil-Adapter
pcall(monitor_ui.init, nil, nil, nil)
pcall(monitor_ui.init, {}, "missing", 1.0)
print("rt_monitor_ui_init_regression_test.lua: ok")
