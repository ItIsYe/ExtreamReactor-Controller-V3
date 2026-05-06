diff --git a/xreactor/master/ui/overview.lua b/xreactor/master/ui/overview.lua
index 14ec82f86abe21b3e69e6de64f27afac9803ffd4..39d79cb83b455868c72635e35b31241266564f14 100644
--- a/xreactor/master/ui/overview.lua
+++ b/xreactor/master/ui/overview.lua
@@ -1,125 +1,75 @@
 local ui = require("core.ui")
 local colorset = require("shared.colors")
-local constants = require("shared.constants")
 local utils = require("core.utils")
 
 local cache = {}
 local button_cache = setmetatable({}, { __mode = "k" })
 
-local function build_profile_buttons(mon, x, y, profiles, active, auto_enabled, rt_hold_active)
-  local buttons = {}
-  local cursor = x
-  ui.text(mon, cursor, y, "PROFILE:", colorset.get("text"), colorset.get("background"))
-  cursor = cursor + 9
-  for _, name in ipairs(profiles) do
-    local status = (active == name) and "OK" or "OFFLINE"
-    local label = name
-    ui.badge(mon, cursor, y, label, status)
-    table.insert(buttons, { type = "profile", name = name, x1 = cursor, x2 = cursor + #label + 1, y = y })
-    cursor = cursor + #label + 3
+local function build_controls(mon, y, model)
+  local buttons, x = {}, 3
+  for _, name in ipairs(model.profile_list or {}) do
+    local status = (model.active_profile == name) and "OK" or "OFFLINE"
+    ui.badge(mon, x, y, name, status)
+    table.insert(buttons, { type = "profile", name = name, x1 = x, x2 = x + #name + 1, y = y })
+    x = x + #name + 3
   end
-  local auto_status = auto_enabled and "LIMITED" or "OFFLINE"
-  ui.badge(mon, cursor, y, "AUTO", auto_status)
-  table.insert(buttons, { type = "auto", name = "AUTO", x1 = cursor, x2 = cursor + 5, y = y })
-  cursor = cursor + 7
-  local rt_status = rt_hold_active and "WARNING" or "OFFLINE"
-  local rt_label = rt_hold_active and "RT-OFF ON" or "RT-OFF"
-  ui.badge(mon, cursor, y, rt_label, rt_status)
-  table.insert(buttons, { type = "rt_hold", name = "RT_OFF", x1 = cursor, x2 = cursor + #rt_label + 1, y = y })
+  ui.badge(mon, x, y, "AUTO", model.auto_profile and "LIMITED" or "OFFLINE")
+  table.insert(buttons, { type = "auto", x1 = x, x2 = x + 5, y = y })
+  x = x + 7
+  local rt_label = model.rt_global_off_hold and "RT-HOLD" or "RT-OFF"
+  ui.badge(mon, x, y, rt_label, model.rt_global_off_hold and "WARNING" or "OFFLINE")
+  table.insert(buttons, { type = "rt_hold", x1 = x, x2 = x + #rt_label + 1, y = y })
   return buttons
 end
 
 local function render(mon, model)
   local key = utils.safe_serialize(model) or tostring(model)
   if cache[mon] == key then return end
   cache[mon] = key
   local w, h = ui.getSize(mon)
-  if not w or not h then
-    return
-  end
-  ui.panel(mon, 1, 1, w, h, nil, model.system_status)
-
-  ui.text(mon, 2, 1, "SYSTEM", colorset.get("text"), colorset.get("background"))
-  ui.badge(mon, 10, 1, model.system_status or "OK", model.system_status or "OK")
-  local counts = model.alert_counts or {}
-  local crit = counts.CRITICAL or 0
-  local warn = counts.WARN or 0
-  if crit > 0 or warn > 0 then
-    ui.badge(mon, 22, 1, "CRIT " .. tostring(crit), crit > 0 and "EMERGENCY" or "OFFLINE")
-    ui.badge(mon, 32, 1, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OFFLINE")
-  end
-
-  local tiles = model.tiles or {}
-  local tile_y = 3
-  local tile_h = 4
-  local tile_w = math.floor((w - 2) / math.max(1, #tiles))
-  for idx, tile in ipairs(tiles) do
-    local x = 2 + (idx - 1) * tile_w
-    ui.panel(mon, x, tile_y, tile_w - 1, tile_h, tile.label, tile.status)
-    ui.text(mon, x + 1, tile_y + 1, tile.detail or "", colorset.get("text"), colorset.get("background"))
-    ui.badge(mon, x + 1, tile_y + 2, tile.status or "OFFLINE", tile.status or "OFFLINE")
-  end
-
-  local node_y = tile_y + tile_h + 1
-  local profile_y = h - 6
-  local node_rows = math.max(0, profile_y - node_y - 1)
-  if node_rows > 0 then
-    ui.text(mon, 2, node_y, "Nodes", colorset.get("text"), colorset.get("background"))
-    local rows = {}
-    for _, node in ipairs(model.nodes or {}) do
-      local mode = "-"
-      if node.role == constants.roles.RT_NODE then
-        mode = (node.mode == "MASTER" and "MANAGED") or (node.mode or "AUTONOM")
-      end
-      local last_seen = node.last_seen or "--:--"
-      if node.last_seen_age then
-        last_seen = last_seen .. (" (%ds)"):format(node.last_seen_age)
-      end
-      local details = {}
-      if node.reasons and node.reasons ~= "" then
-        table.insert(details, node.reasons)
-      end
-      if node.bindings and node.bindings ~= "" then
-        table.insert(details, node.bindings)
-      end
-      local suffix = #details > 0 and (" " .. table.concat(details, " ")) or ""
-      local managed = node.managed == false and "UNMANAGED" or "MANAGED"
-      local stale = node.stale and " STALE" or ""
-      local role_map = node.node_role_map or string.format("%s = %s", node.id or "NODE", node.role or "UNKNOWN")
-      local label = string.format("%s %s %s %s %s%s%s", role_map, node.status or "OFFLINE", mode, managed, last_seen, stale, suffix)
-      table.insert(rows, { text = label, status = node.status })
-    end
-    ui.list(mon, 2, node_y + 1, w - 3, rows, { max_rows = node_rows })
-  end
+  ui.panel(mon, 1, 1, w, h, "MONITOR 1 - UEBERSICHT & STEUERUNG", model.system_status or "OK")
 
-  button_cache[mon] = build_profile_buttons(mon, 2, profile_y, model.profile_list or {}, model.active_profile, model.auto_profile, model.rt_global_off_hold)
+  ui.panel(mon, 2, 2, w - 2, 3, "Systemstatus", model.system_status or "OK")
+  ui.badge(mon, 4, 3, model.system_status or "OK", model.system_status or "OK")
+  local c = model.alert_counts or {}
+  ui.badge(mon, 16, 3, "CRIT " .. tostring(c.CRITICAL or 0), (c.CRITICAL or 0) > 0 and "EMERGENCY" or "OFFLINE")
+  ui.badge(mon, 27, 3, "WARN " .. tostring(c.WARN or 0), (c.WARN or 0) > 0 and "WARNING" or "OFFLINE")
 
-  local power_y = profile_y + 1
-  ui.text(mon, 2, power_y, "Power Target", colorset.get("text"), colorset.get("background"))
-  ui.bigNumber(mon, 16, power_y, "", string.format("%.0f", model.power_target or 0), "RF/t", model.system_status)
+  ui.panel(mon, 2, 6, w - 2, 3, "Globale Steuerung", "LIMITED")
+  button_cache[mon] = build_controls(mon, 7, model)
 
-  local alert_rows = {}
-  local top_alerts = model.alert_top or {}
+  ui.panel(mon, 2, 10, w - 2, 5, "Aktive Meldungen", (c.CRITICAL or 0) > 0 and "EMERGENCY" or ((c.WARN or 0) > 0 and "WARNING" or "OK"))
+  local top = model.alert_top or {}
   for i = 1, 3 do
-    local alert = top_alerts[i]
+    local alert = top[i]
+    local y = 10 + i
     if alert then
-      table.insert(alert_rows, { text = alert.title or alert.message or "--", status = alert.severity == "CRITICAL" and "EMERGENCY" or "WARNING" })
+      local sev = alert.severity == "CRITICAL" and "EMERGENCY" or (alert.severity == "WARN" and "WARNING" or "LIMITED")
+      ui.badge(mon, 4, y, tostring(alert.severity or "INFO"), sev)
+      ui.text(mon, 13, y, tostring(alert.title or alert.message or "Alert"), colorset.get("text"), colorset.get("background"))
     else
-      table.insert(alert_rows, { text = "--", status = "OFFLINE" })
+      ui.text(mon, 4, y, "Keine aktiven Alerts", colorset.get("text"), colorset.get("background"))
     end
   end
-  ui.text(mon, 2, h - 3, "Top Alerts", colorset.get("text"), colorset.get("background"))
-  ui.list(mon, 2, h - 2, w - 2, alert_rows, { max_rows = 3 })
+
+  ui.panel(mon, 2, 16, w - 2, 4, "KPI", "OK")
+  ui.bigNumber(mon, 4, 17, "Leistung Soll", string.format("%.0f", model.power_target or 0), "RF/t", model.system_status)
+  local energy = model.energy_overview or {}
+  ui.bigNumber(mon, 28, 17, "Energie", string.format("%.1f%%", energy.percent or 0), "", energy.status or "OK")
+
+  local node_y = 21
+  ui.panel(mon, 2, node_y, w - 2, h - node_y, "Node-Status", "OK")
+  local rows = {}
+  for _, node in ipairs(model.nodes or {}) do
+    rows[#rows + 1] = { text = string.format("%s %-10s %-8s mode:%s seen:%ss", tostring(node.id), tostring(node.role), tostring(node.status), tostring(node.mode or "-"), tostring(node.last_seen_age or -1)), status = node.status }
+  end
+  ui.list(mon, 3, node_y + 1, w - 4, rows, { max_rows = h - node_y - 2 })
 end
 
 local function hit_test(mon, x, y)
-  local buttons = button_cache[mon] or {}
-  for _, btn in ipairs(buttons) do
-    if y == btn.y and x >= btn.x1 and x <= btn.x2 then
-      return btn
-    end
+  for _, btn in ipairs(button_cache[mon] or {}) do
+    if y == btn.y and x >= btn.x1 and x <= btn.x2 then return btn end
   end
-  return nil
 end
 
 return { render = render, hit_test = hit_test }
