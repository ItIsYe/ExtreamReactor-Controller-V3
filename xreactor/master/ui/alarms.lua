-- MASTER Meldungen: nur View und lokaler Touch-Zustand; keine Alarmregeln.
-- Zeile 1 und die vom AUX-Proxy abgezogenen Footerzeilen bleiben frei.
local ui = require("core.ui")
local colorset = require("shared.colors")
local widgets = require("master.ui.widgets")
local M = { MUTE_MINUTES = 60 }
M.EVENT_LABEL = { raise="KOMMT", again="KOMMT", clear="GEHT", ack="QUITT.",
  auto_ack="AUTO-Q.", severity="KLASSE", muted="GESPERRT" }
local CLASS = {
  CRITICAL={short="S", label="STOERUNG", color="EMERGENCY"},
  WARN={short="W", label="WARNUNG", color="WARNING"},
  INFO={short="M", label="MELDUNG", color="LIMITED"},
}
local FILTERS = { "ALLE", "STOER.", "WARN.", "OFFEN" }
local states = setmetatable({}, {__mode="k"})
local function state_for(mon)
  local owner = (type(mon)=="table" and rawget(mon,"xr_session_mon")) or mon
  if not states[owner] then
    states[owner]={view="list", page=1, detail_page=1, filter=1, buttons={}}
  end
  return states[owner]
end
local function class_of(s)
  s=tostring(s or "INFO"):upper()
  return CLASS[s=="WARNING" and "WARN" or s] or CLASS.INFO
end
local function node_of(a)
  local s=type(a.source)=="table" and a.source or {}
  return tostring(s.node_id or s.role or "SYSTEM")
end
local function clock(ts, seconds)
  local n=tonumber(ts)
  if not n or n<=0 then return seconds and "--:--:--" or "--:--" end
  return os.date(seconds and "!%H:%M:%S" or "!%H:%M", math.floor(n/1000))
end
local function find(list,key)
  if key then for _,a in ipairs(list or {}) do if a.key==key then return a end end end
end
local function ack_label(a)
  return a.acknowledged and (a.ack_auto and "AUTO-Q." or "QUITT.") or "OFFEN"
end
function M.detail_lines(a)
  local out={
    class_of(a.severity).label.." | "..node_of(a),
    (a.active==false and "WEG" or "AN").." | "..ack_label(a).." | x"..tostring(tonumber(a.count) or 1),
    tostring(a.title or a.code or "Meldung"),
  }
  if a.message and a.message~="" then out[#out+1]=tostring(a.message) end
  local d=type(a.details)=="table" and a.details or {}
  for _,s in ipairs(type(d.lines)=="table" and d.lines or {}) do out[#out+1]=tostring(s) end
  if d.reasons then out[#out+1]="Grund: "..tostring(d.reasons) end
  out[#out+1]="Gekommen: "..clock(a.ts_came or a.ts_first).." UTC"
  if a.active==false then out[#out+1]="Gegangen: "..clock(a.ts_gone).." UTC" end
  if a.acknowledged then
    out[#out+1]="Quittiert: "..clock(a.ack_ts).." UTC"..(a.ack_auto and " (automatisch)" or "")
  else out[#out+1]="Quittieren bestaetigt Kenntnisnahme, behebt keinen Fehler." end
  return out
end
local function wrap(lines,width)
  local out={}
  for _,raw in ipairs(lines) do
    for part in (tostring(raw):gsub("\r","").."\n"):gmatch("([^\n]*)\n") do
      while #part>width do
        local cut=part:sub(1,width+1):match("^.*() ")
        if not cut or cut<=1 then cut=width+1 end
        out[#out+1]=part:sub(1,cut-1)
        part=part:sub(cut):gsub("^ +","")
      end
      out[#out+1]=part
    end
  end
  return out
end
-- Vollstaendige Zeilen statt clear/overlay: kein Flackern, keine Textreste.
-- Direkte Monitor-blits veraendern term.redirect nicht. Keine Hardwareabfragen.
local function frame(mon,w,h)
  local rows,fg0,bg0={},colorset.get("text"),colorset.get("background")
  for y=2,h do rows[y]={}; for x=1,w do rows[y][x]={" ",fg0,bg0} end end
  local f={}
  function f.text(x,y,text,width,fg,bg)
    if not rows[y] or x<1 or x>w then return end
    width=math.min(width or #tostring(text),w-x+1)
    if width<1 then return end
    local s=widgets.pad(text,width)
    for i=1,width do rows[y][x+i-1]={s:sub(i,i),fg or fg0,bg or bg0} end
  end
  function f.flush()
    local digits={}; for n=0,15 do digits[2^n]=("0123456789abcdef"):sub(n+1,n+1) end
    for y=2,h do
      local t,fg,bg={},{},{}
      for x=1,w do
        local cell=rows[y][x]; t[x]=cell[1]; fg[x]=digits[cell[2]] or "0"; bg[x]=digits[cell[3]] or "f"
      end
      if type(mon.blit)=="function" and type(mon.setCursorPos)=="function" then
        mon.setCursorPos(1,y); mon.blit(table.concat(t),table.concat(fg),table.concat(bg))
      else
        if ui.invalidate then ui.invalidate(mon) end
        ui.text(mon,1,y,table.concat(t),fg0,bg0)
      end
    end
  end
  return f
end
local function button(f,st,key,x,y,w,label,enabled,height,data,primary)
  local bg=colorset.get(enabled and (primary and "accent" or "panel") or "background")
  local fg=colorset.get(enabled and (primary and "background" or "text") or "muted")
  for row=y,y+(height or 1)-1 do f.text(x,row,"",w,fg,bg) end
  local s=widgets.fit(label,w)
  f.text(x+math.floor((w-#s)/2),y,s,#s,fg,bg)
  if enabled then st.buttons[#st.buttons+1]={key=key,x=x,y=y,w=w,h=height or 1,data=data} end
end
local function pagination(f,st,x,y,w,total,per,detail)
  local field=detail and "detail_page" or "page"
  local pages=math.max(1,math.ceil(total/per))
  st[field]=math.max(1,math.min(st[field],pages))
  f.text(x,y,(detail and "DETAIL " or "SEITE ")..st[field].."/"..pages,w-12,colorset.get("muted"))
  button(f,st,detail and "detail_prev" or "prev",x+w-11,y,5,"<",st[field]>1)
  button(f,st,detail and "detail_next" or "next",x+w-5,y,5,">",st[field]<pages,1,nil,true)
  return (st[field]-1)*per+1
end
local function selected(st) return find(st.model.active,st.selected_key) end
local function eligible(st,kind,target)
  local a=target and find(st.model.active,target.key) or selected(st)
  if target and (not a or a.id~=target.id) then return false end
  if kind=="ack" then return a and not a.acknowledged and a.id~=nil end
  if kind=="mute" then return a~=nil end
  if kind=="forget" then return a and a.code=="NODE_COMMS_DOWN" and a.active~=false
    and type(a.source)=="table" and a.source.node_id~=nil end
  if kind=="unmute" then return (tonumber(st.model.muted_count) or 0)>0 end
  if kind=="ack_all" then
    for _,v in ipairs(st.model.active or {}) do if not v.acknowledged then return true end end
  end
  return false
end
local function action(st,kind,target)
  if not eligible(st,kind,target) then return nil end
  local a=target and find(st.model.active,target.key) or selected(st)
  if kind=="ack" then return {type="alert_ack",id=a.id} end
  if kind=="mute" then return {type="alert_mute_key",key=a.key,minutes=M.MUTE_MINUTES} end
  if kind=="forget" then return {type="alert_forget_node",node_id=a.source.node_id} end
  if kind=="unmute" then return {type="alert_unmute_keys"} end
  if kind=="ack_all" then return {type="alert_ack_all"} end
end
local function header(f,st,w)
  local counts=st.model.counts or {}
  local c,a,n=tonumber(counts.CRITICAL) or 0,tonumber(counts.WARN) or 0,tonumber(counts.UNACKED) or 0
  if st.compact then f.text(2,3,"S:"..c.." AN  W:"..a.." AN  OFFEN:"..n,w-2)
  else
    local labels,values,names={"STOERUNGEN","WARNUNGEN","ZU QUITTIEREN"},{c,a,n},{"EMERGENCY","WARNING","accent"}
    local x,width=2,math.floor((w-4)/3)
    for i=1,3 do
      local cw=i==3 and w-x or width
      f.text(x,3," "..labels[i],cw,nil,colorset.get("panel"))
      f.text(x,3," ",1,nil,colorset.get(names[i]))
      f.text(x,4," "..values[i]..(i==3 and " OFFEN" or " ANSTEHEND"),cw,nil,colorset.get("panel"))
      x=x+cw+1
    end
  end
  local muted=tonumber(st.model.muted_count) or 0
  if muted>0 then f.text(2,st.compact and 4 or 5,muted.." URSACHE(N) GESPERRT - siehe MEHR",w-2,colorset.get("LIMITED")) end
end
local function tabs(f,st,w,y)
  button(f,st,"list",2,y,8,"LISTE",true,1,nil,st.view=="list")
  button(f,st,"history",11,y,9,"VERLAUF",true,1,nil,st.view=="history")
  button(f,st,"filter",21,y,w-21,w<39 and FILTERS[st.filter] or "FILTER:"..FILTERS[st.filter],st.view=="list")
end
local function detail(f,st,a,x,top,w,bottom)
  if not a then f.text(x,top,"Eintrag antippen fuer Einzelheiten",w,colorset.get("muted")); return end
  local lines=wrap(M.detail_lines(a),w)
  local per=math.max(1,bottom-top)
  local first=pagination(f,st,x,bottom,w,#lines,per,true)
  for i=0,per-1 do f.text(x,top+i,lines[first+i] or "",w,first+i==1 and colorset.get(class_of(a.severity).color) or nil) end
end
local function actions(f,st,a,x,y,w)
  local bw=math.floor(w*0.64)
  local label=a and not a.acknowledged and widgets.fit(node_of(a),math.max(1,bw-11)).." QUITTIEREN" or "QUITTIERT"
  if not a then label="KEINE AUSWAHL" end
  button(f,st,"ack",x,y,bw,label,eligible(st,"ack"),2,a and {key=a.key,id=a.id},true)
  button(f,st,"more",x+bw+1,y,w-bw-1,"MEHR ...",true,2)
end
local function render_list(f,st,w,h)
  local list={}
  for _,a in ipairs(st.model.active or {}) do
    if st.filter==1 or (st.filter==2 and class_of(a.severity)==CLASS.CRITICAL)
      or (st.filter==3 and class_of(a.severity)==CLASS.WARN) or (st.filter==4 and not a.acknowledged) then list[#list+1]=a end
  end
  local a=selected(st)
  if st.compact and st.detail_open and a then
    button(f,st,"back",2,5,10,"< LISTE",true)
    detail(f,st,a,2,7,w-2,h-3); actions(f,st,a,2,h-1,w-2); return
  end
  tabs(f,st,w,st.compact and 5 or 6)
  local top=st.compact and 7 or 8
  local width=st.wide and math.floor(w*0.56) or w-2
  local page_y=st.wide and h-3 or (st.compact and h-3 or h-9)
  local per=math.max(1,math.floor((page_y-top)/2))
  local first=pagination(f,st,2,page_y,width,#list,per)
  for i=0,per-1 do
    local item=list[first+i]
    if item then
      local y,cls=top+i*2,class_of(item.severity)
      local bg=colorset.get(item.key==st.selected_key and "panel" or "background")
      f.text(2,y,"",width,nil,bg); f.text(2,y+1,"",width,nil,bg)
      f.text(2,y," "..cls.short.." ",3,colorset.get("background"),colorset.get(cls.color))
      f.text(6,y,node_of(item).."  "..tostring(item.title or item.code or "Meldung"),width-4,nil,bg)
      f.text(2,y+1,(item.key==st.selected_key and "> " or "  ")..clock(item.ts_came or item.ts_first)
        .." UTC | "..(item.active==false and "WEG" or "AN").." | "..ack_label(item)
        .." | x"..tostring(tonumber(item.count) or 1),width,colorset.get("muted"),bg)
      st.buttons[#st.buttons+1]={key="select",x=2,y=y,w=width,h=2,data=item.key}
    end
  end
  if #list==0 then
    f.text(2,top,st.filter==1 and "Keine sichtbaren Meldungen" or "Keine Treffer fuer diesen Filter",width)
    if (tonumber(st.model.muted_count) or 0)>0 then f.text(2,top+2,"Ursachen sind weiterhin gesperrt.",width,colorset.get("LIMITED")) end
  end
  if st.wide then
    local x=width+5
    for y=8,h do f.text(x-2,y," ",1,nil,colorset.get("panel")) end
    detail(f,st,a,x,8,w-x,h-3); actions(f,st,a,x,h-1,w-x)
  elseif not st.compact then
    detail(f,st,a,2,h-7,w-2,h-3); actions(f,st,a,2,h-1,w-2)
  else button(f,st,"more",2,h-1,w-2,"MEHR / SPERREN",true,2) end
end
local function render_history(f,st,w,h)
  tabs(f,st,w,st.compact and 5 or 6)
  local top=st.compact and 7 or 8
  local per=math.max(1,math.floor((h-3-top)/2))
  local history=st.model.history or {}
  local first=pagination(f,st,2,h-3,w-2,#history,per)
  for i=0,per-1 do
    local e=history[first+i]
    if e then
      local cls=class_of(e.severity)
      f.text(2,top+i*2,clock(e.event_ts or e.ts_last,true).." UTC "..(M.EVENT_LABEL[e.event] or tostring(e.event or "?")).." "..cls.short,w-2,colorset.get(cls.color))
      f.text(2,top+i*2+1,node_of(e).." / "..tostring(e.title or e.code or "Meldung"),w-2)
    end
  end
  if #history==0 then f.text(2,top,"Noch kein Verlauf",w-2,colorset.get("muted")) end
  button(f,st,"more",2,h-1,w-2,"MEHR / SPERREN",true,2)
end
local function render_menu(f,st,w,h)
  local a=selected(st)
  f.text(2,5,"MEHR"..(a and " / "..node_of(a) or " / ALLE MELDUNGEN"),w-2,colorset.get("accent"))
  local n=0; for _,v in ipairs(st.model.active or {}) do if not v.acknowledged then n=n+1 end end
  local options={{"ack_all","ALLE QUITTIEREN ("..n..")"},{"mute","URSACHE 60 MIN SPERREN"},
    {"unmute","ALLE SPERREN AUFHEBEN ("..(tonumber(st.model.muted_count) or 0)..")"},{"forget","OFFLINE-NODE VERGESSEN"}}
  local bh=h>=20 and 2 or 1
  local row=6
  for _,opt in ipairs(options) do
    if opt[1]~="forget" or eligible(st,"forget") then
      button(f,st,"ask",2,row,w-2,opt[2],eligible(st,opt[1]),bh,
        {kind=opt[1],target=(opt[1]=="mute" or opt[1]=="forget") and a and {key=a.key,id=a.id} or nil})
      row=row+bh+1
    end
  end
  button(f,st,"close_menu",2,h-1,w-2,"< ZUR ANSICHT",true,2)
end
local function render_confirmation(f,st,w,h)
  local p=st.pending
  local messages={
    mute={"URSACHE 60 MIN SPERREN?","Diese Ursache wird ausgeblendet und waehrend der Sperre nicht neu gemeldet. Der Fehler bleibt bestehen."},
    forget={"OFFLINE-NODE VERGESSEN?","Die Node wird aus MASTERs Liste entfernt. Nur fuer eine abgebaute oder bewusst entfernte Node verwenden."},
    unmute={"ALLE SPERREN AUFHEBEN?","Alle Ursachensperren werden aufgehoben. Die Ursachen koennen wieder gemeldet werden."},
    ack_all={"ALLE OFFENEN QUITTIEREN?","Betrifft alle offenen Meldungen, auch ausserhalb des Filters. Behebt keine Fehler."},
  }
  local msg=messages[p.kind]; local content={msg[1]}
  if p.target then local a=find(st.model.active,p.target.key); content[#content+1]="Betrifft: "..(a and node_of(a) or "nicht mehr verfuegbar") end
  if p.kind=="ack_all" or p.kind=="unmute" then
    local n=tonumber(st.model.muted_count) or 0
    if p.kind=="ack_all" then n=0; for _,a in ipairs(st.model.active or {}) do if not a.acknowledged then n=n+1 end end end
    content[#content+1]="Aktuell betroffen: "..n
  end
  content[#content+1]=msg[2]
  local lines=wrap(content,w-2); local per=math.max(1,h-9)
  local first=pagination(f,st,2,h-3,w-2,#lines,per,true)
  for i=0,per-1 do f.text(2,6+i,lines[first+i] or "",w-2) end
  local bw=math.floor((w-3)/2)
  button(f,st,"cancel",2,h-1,bw,"ABBRECHEN",true,2)
  button(f,st,"confirm",bw+3,h-1,w-bw-3,"BESTAETIGEN",eligible(st,p.kind,p.target),2,nil,true)
end
function M.render(mon,model)
  local st=state_for(mon)
  st.buttons={}; st.model=model or {}
  local w,h=ui.getSize(mon)
  if not w or not h or w<1 or h<2 then return end
  st.compact=w<52 or h<26; st.wide=w>=90 and h>=24
  if st.wide then st.compact=false end
  local f=frame(mon,w,h)
  if w<30 or h<14 then
    f.text(1,2,"Monitor zu klein",w); f.text(1,3,"Min. 30x14 Nutzzeichen",w)
    f.text(1,4,"Groesse/Skalierung anpassen",w); f.flush(); return
  end
  if st.selected_key and not selected(st) then st.selected_key=nil; st.detail_open=false; st.detail_page=1 end
  header(f,st,w)
  if st.pending then render_confirmation(f,st,w,h)
  elseif st.menu then render_menu(f,st,w,h)
  elseif st.view=="history" then render_history(f,st,w,h)
  else render_list(f,st,w,h) end
  f.flush()
end
function M.hit_test(mon,x,y)
  if type(x)~="number" or type(y)~="number" then return nil end
  local st=state_for(mon)
  for _,b in ipairs(st.buttons) do
    if x>=b.x and x<b.x+b.w and y>=b.y and y<b.y+b.h then
      -- Zweiter Tipp vor dem Redraw darf keine alte Aktionszone treffen.
      st.buttons={}
      local k=b.key
      if k=="ack" then return action(st,k,b.data)
      elseif k=="select" then
        if st.selected_key~=b.data then st.detail_page=1 end
        st.selected_key=b.data; st.detail_open=true
      elseif k=="list" or k=="history" then st.view=k; st.page=1; st.detail_open=false
      elseif k=="filter" then
        st.filter=st.filter % #FILTERS+1; st.page=1; st.selected_key=nil; st.detail_open=false; st.detail_page=1
      elseif k=="prev" then st.page=math.max(1,st.page-1)
      elseif k=="next" then st.page=st.page+1
      elseif k=="detail_prev" then st.detail_page=math.max(1,st.detail_page-1)
      elseif k=="detail_next" then st.detail_page=st.detail_page+1
      elseif k=="back" then st.detail_open=false
      elseif k=="more" then st.menu=true
      elseif k=="close_menu" then st.menu=false
      elseif k=="ask" then st.pending=b.data; st.detail_page=1
      elseif k=="cancel" then st.pending=nil; st.detail_page=1
      elseif k=="confirm" then
        local p=st.pending; st.pending=nil; st.menu=false; st.detail_page=1
        return p and action(st,p.kind,p.target) or nil
      end
      return nil
    end
  end
end
M.handle_input=M.hit_test
return M
