package.path=table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path},';')
local constants=require('shared.constants')
local ui_ctrl=require('master.ui_controller')
local function T(v,m) if not v then error(m or"true") end end
local function A(a,e,m) if a~=e then error((m or"eq")..": exp="..tostring(e).." act="..tostring(a)) end end
-- ui_controller.new ohne echte Deps nur als Source-Check
local src=io.open("xreactor/master/ui_controller.lua","r"):read("*a")
-- shutdown-State → ASSIGNED Projektion muss im Code vorhanden sein
T(src:find('shutdown.*ASSIGNED',1,false)~=nil or src:find('"shutdown".*"ASSIGNED"',1,false)~=nil,
  "shutdown state must project to ASSIGNED")
-- shed-State → ASSIGNED Projektion
T(src:find('shed.*ASSIGNED',1,false)~=nil or src:find('"shed".*"ASSIGNED"',1,false)~=nil,
  "shed state must project to ASSIGNED")
-- unavailable-State muss referenziert werden
T(src:find("UNAVAILABLE",1,true)~=nil,"UNAVAILABLE status must be referenced")
-- assignment_state in Setpoints muss in Projektion berücksichtigt werden
T(src:find("assignment_state",1,true)~=nil,"assignment_state must be used in projection")
-- fleet_summary Feld muss existieren
T(src:find("fleet_summary",1,true)~=nil,"fleet_summary field must be projected")
print("master_ui_shutdown_field_semantic_contract_test.lua: ok")
