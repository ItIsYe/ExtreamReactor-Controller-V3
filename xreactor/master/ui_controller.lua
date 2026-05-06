diff --git a/xreactor/master/ui_controller.lua b/xreactor/master/ui_controller.lua
index c23b089c4b112854219d606f81f7dcd19ada849e..088859911ac5de4c6deec38f9374fd5ffb91f58f 100644
--- a/xreactor/master/ui_controller.lua
+++ b/xreactor/master/ui_controller.lua
@@ -73,62 +73,64 @@ function M.new(opts)
         status = controller.constants.status_levels.WARNING
       end
     end
     return status
   end
 
   local function draw()
     local now = os.epoch("utc")
     if now - controller.state.last_draw < 400 then return end
     controller.state.last_draw = now
 
     local alert_counts = controller.alert_service and controller.alert_service:get_counts() or { INFO = 0, WARN = 0, CRITICAL = 0 }
     local alert_summary = controller.alert_service and controller.alert_service:get_summary() or ""
     local alert_active = controller.alert_service and controller.alert_service:get_active() or {}
     local alert_history = controller.alert_service and controller.alert_service:get_history() or {}
     local alert_top = controller.alert_service and controller.alert_service:get_top_critical(3) or {}
     local alert_metrics = controller.alert_service and controller.alert_service:get_metrics() or {}
     local alert_mutes = controller.alert_service and controller.alert_service:get_mutes() or {}
 
     local overview_data = {
       nodes = {}, power_target = (controller.calc.get_power_target and controller.calc.get_power_target()) or controller.state.power_target, alarms = controller.alarms, tiles = {},
       system_status = compute_system_status(), profile_list = { "BASELOAD", "PEAK", "IDLE" },
       active_profile = (controller.calc.get_active_profile and controller.calc.get_active_profile()) or controller.state.active_profile,
       auto_profile = (controller.calc.get_auto_profile and controller.calc.get_auto_profile()) or controller.state.auto_profile,
       rt_global_off_hold = (controller.calc.get_rt_global_off_hold and controller.calc.get_rt_global_off_hold()) or controller.state.rt_global_off_hold,
-      alert_counts = alert_counts, alert_summary = alert_summary, alert_top = alert_top
+      alert_counts = alert_counts, alert_summary = alert_summary, alert_top = alert_top,
+      energy_overview = { percent = 0, status = "OFFLINE" }
     }
     local rt_data = {
       rt_nodes = {}, ramp_profile = controller.sequencer.ramp_profile, sequence_state = controller.sequencer.state,
       queue = controller.sequencer.queue, active_step = controller.sequencer.active, control_mode = nil,
       alert_counts = alert_counts, alert_top = alert_top,
       rt_global_off_hold = overview_data.rt_global_off_hold
     }
     local energy_data = {
       stored = 0, capacity = 0, input = 0, output = 0, stores = {}, nodes = {}, matrices = {}, top_matrices = {},
       trend_values = controller.trend_cache.energy, trend_arrow = controller.trend_cache.energy_arrow,
-      trend_dirty = controller.trends:is_dirty("energy"), now_ms = now, alert_counts = alert_counts, alert_top = alert_top
+      trend_dirty = controller.trends:is_dirty("energy"), now_ms = now, alert_counts = alert_counts, alert_top = alert_top,
+      resources = { fuel_total = 0, water_total = 0, reprocessing_state = "-" }, support_nodes = {}
     }
     local resource_data = {
       fuel = { reserve = 0, minimum = 0, sources = {}, total = 0 },
       water = { total = 0, buffers = {}, target = nil }, reprocessor = {}, node_details = {},
       comms = controller.comms:get_diagnostics() or {}
     }
 
     for _, node in pairs(controller.nodes) do
       local reasons = node.health and node.health.reasons or {}
       local reason_list = type(reasons) == "table" and (#reasons > 0 and reasons or controller.health.reasons_list({ reasons = reasons })) or {}
       local reason_text = type(reason_list) == "table" and table.concat(reason_list, ",") or nil
       local bindings_summary = node.bindings_summary
       if not bindings_summary and node.health and type(node.health.bindings) == "table" then
         bindings_summary = controller.health.summarize_bindings(node.health.bindings)
       end
       local age = node.last_seen_age or (node.last_seen and math.max(0, math.floor((now - node.last_seen) / 1000)) or nil)
       overview_data.nodes[#overview_data.nodes + 1] = {
         id = node.id, role = node.role, status = node.status or controller.constants.status_levels.OFFLINE,
         node_role_map = ("%s = %s"):format(tostring(node.id or "UNKNOWN"), tostring(node.role or "UNKNOWN")),
         last_seen = node.last_seen_str, last_seen_age = age, mode = node.mode, reasons = reason_text, bindings = bindings_summary,
         managed = node.managed ~= false, stale = node.stale == true
       }
       resource_data.node_details[#resource_data.node_details + 1] = {
         id = node.id, role = node.role, status = node.status or controller.constants.status_levels.OFFLINE,
         reasons = reason_text, bindings = bindings_summary, last_seen_age = age, down_since = node.down_since,
@@ -196,50 +198,68 @@ function M.new(opts)
       elseif node.role == controller.constants.roles.REPROCESSOR_NODE then
         resource_data.reprocessor = node.reprocessor or {}
       end
     end
 
     table.sort(rt_data.rt_nodes, function(a, b) return (a.id or "") < (b.id or "") end)
     table.sort(energy_data.stores, function(a, b) return (a.id or "") < (b.id or "") end)
     table.sort(energy_data.nodes, function(a, b) return (a.id or "") < (b.id or "") end)
     table.sort(energy_data.matrices, function(a, b) return (a.percent or 0) > (b.percent or 0) end)
     table.sort(resource_data.fuel.sources, function(a, b) return (a.id or "") < (b.id or "") end)
 
     local fuel_total = 0
     for _, src in ipairs(resource_data.fuel.sources or {}) do fuel_total = fuel_total + (src.amount or 0) end
     resource_data.fuel.total = fuel_total
     resource_data.fuel.mix_status = (#(resource_data.fuel.sources or {}) > 1) and "MIXED" or "SINGLE"
     if energy_data.capacity > 0 then
       local pct = (energy_data.stored / energy_data.capacity) * 100
       if pct <= controller.config.energy_crit_pct then energy_data.status = "EMERGENCY"
       elseif pct <= controller.config.energy_warn_pct then energy_data.status = "WARNING"
       else energy_data.status = "OK" end
     else
       energy_data.status = "OFFLINE"
     end
     for i = 1, math.min(3, #energy_data.matrices) do energy_data.top_matrices[#energy_data.top_matrices + 1] = energy_data.matrices[i] end
 
+
+    overview_data.energy_overview.percent = energy_data.capacity > 0 and ((energy_data.stored / energy_data.capacity) * 100) or 0
+    overview_data.energy_overview.status = energy_data.status
+    energy_data.resources = {
+      fuel_total = resource_data.fuel.total or 0,
+      water_total = resource_data.water.total or 0,
+      reprocessing_state = resource_data.reprocessor.state or resource_data.reprocessor.mode or "-"
+    }
+    for _, node in ipairs(resource_data.node_details or {}) do
+      local role = tostring(node.role or "")
+      if role ~= controller.constants.roles.RT_NODE and role ~= controller.constants.roles.ENERGY_NODE then
+        energy_data.support_nodes[#energy_data.support_nodes + 1] = {
+          id = node.id, role = node.role, status = node.status, last_seen_age = node.last_seen_age,
+          note = node.reasons or node.bindings or ""
+        }
+      end
+    end
+
     local modes, mode_list = {}, {}
     for _, rt in ipairs(rt_data.rt_nodes) do if rt.mode then modes[rt.mode] = true end end
     for mode in pairs(modes) do mode_list[#mode_list + 1] = mode end
     table.sort(mode_list)
     if #mode_list == 1 then rt_data.control_mode = mode_list[1] elseif #mode_list > 1 then rt_data.control_mode = "MIXED" end
 
     local tile_map = {
       { label = "RT", role = controller.constants.roles.RT_NODE },
       { label = "ENERGY", role = controller.constants.roles.ENERGY_NODE },
       { label = "FUEL", role = controller.constants.roles.FUEL_NODE },
       { label = "WATER", role = controller.constants.roles.WATER_NODE },
       { label = "REPROCESSOR", role = controller.constants.roles.REPROCESSOR_NODE }
     }
     local status_rank = {
       [controller.constants.status_levels.EMERGENCY] = 1,
       [controller.constants.status_levels.WARNING] = 2,
       [controller.constants.status_levels.LIMITED] = 3,
       [controller.constants.status_levels.OK] = 4,
       [controller.constants.status_levels.OFFLINE] = 5,
       [controller.constants.status_levels.MANUAL] = 6
     }
     for _, entry in ipairs(tile_map) do
       local tile_status = controller.constants.status_levels.OFFLINE
       for _, node in pairs(controller.nodes) do
         if node.role == entry.role then
