local ui = require("core.ui")
local colorset = require("shared.colors")
local widgets = require("master.ui.widgets")
local utils = require("core.utils")
local cache = {}

local function render(mon, model)
  local key = utils.safe_serialize(model) or tostring(model)
  if cache[mon] == key then return end
  cache[mon] = key
  local w, h = ui.getSize(mon)
  if not w or not h then
    return
  end
  widgets.card(mon, 1, 1, w, h, "RT DASHBOARD", "OK")
  ui.text(mon, 2, 2, "Ramp: " .. tostring(model.ramp_profile or "NORMAL"), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 3, "Sequence: " .. tostring(model.sequence_state or "IDLE"), colorset.get("text"), colorset.get("background"))
  ui.text(mon, 2, 4, "Control: " .. tostring(model.control_mode or "AUTO"), colorset.get("text"), colorset.get("background"))
  ui.badge(mon, 24, 4, (model.rt_global_off_hold and "RT-OFF ON" or "RT-OFF OFF"), model.rt_global_off_hold and "WARNING" or "OFFLINE")
  local row = 6
  local counts = model.alert_counts or {}
  local crit = counts.CRITICAL or 0
  local warn = counts.WARN or 0
  if crit > 0 or warn > 0 then
    ui.text(mon, 2, row, "Alerts", colorset.get("WARNING"), colorset.get("background"))
    ui.badge(mon, 10, row, "CRIT " .. tostring(crit), crit > 0 and "EMERGENCY" or "OFFLINE")
    ui.badge(mon, 20, row, "WARN " .. tostring(warn), warn > 0 and "WARNING" or "OFFLINE")
    row = row + 1
    local top = model.alert_top or {}
    if #top > 0 then
      for i = 1, math.min(3, #top) do
        ui.text(mon, 4, row, top[i].title or top[i].message or "CRITICAL", colorset.get("EMERGENCY"), colorset.get("background"))
        row = row + 1
      end
    else
      ui.text(mon, 4, row, "Warnings active", colorset.get("WARNING"), colorset.get("background"))
      row = row + 1
    end
  end
  for _, rt in ipairs(model.rt_nodes or {}) do
    if row >= h - 3 then break end
    local status = rt.status or "OFFLINE"
    ui.panel(mon, 2, row, w - 3, 5, rt.id .. " (" .. tostring(rt.state or "OFF") .. ")", status)
    ui.bigNumber(mon, 4, row + 1, "Target", string.format("%.0f", rt.target or 0), "RF/t", status)
    ui.bigNumber(mon, 22, row + 1, "Actual", string.format("%.0f", rt.actual_output or rt.output or 0), "RF/t", status)
    local dispatch = rt.assignment_state or ((rt.target or 0) > 0 and "active" or (rt.startup_active and "startup" or "standby"))
    ui.text(mon, 4, row + 2, "Mode:" .. tostring(rt.mode or "?") .. " State:" .. tostring(dispatch) .. " Reason:" .. tostring(rt.assignment_reason or "n/a"), colorset.get("text"), colorset.get("background"))
    if rt.shutdown_stage or rt.desired_node_state or rt.shutdown_workflow_stage then
      local stage = tostring(rt.shutdown_workflow_stage or "-")
      local verdict = "IDLE"
      if stage == "COMPLETED" then
        verdict = "COMPLETED"
      elseif stage == "CANCELLED_DEMAND_RECOVERED" then
        verdict = "CANCELLED"
      elseif stage == "FAILED" then
        verdict = "FAILED"
      elseif stage == "REQUESTED" then
        verdict = "REQUESTED"
      elseif stage == "WAITING_STATE" then
        verdict = "WAITING_STATE"
      elseif stage == "REQUEST_STATE" then
        verdict = "REQUEST_STATE"
      elseif stage == "RAMPDOWN" then
        verdict = "RAMPDOWN"
      end
      local extra = " verdict=" .. verdict
      if rt.shutdown_workflow_reason then
        extra = extra .. " reason=" .. tostring(rt.shutdown_workflow_reason)
      end
      if rt.shutdown_workflow_error then
        extra = extra .. " err=" .. tostring(rt.shutdown_workflow_error)
      end
      if rt.shutdown_requested_at or rt.shutdown_accepted_at or rt.shutdown_completed_at then
        extra = extra .. " t_req=" .. tostring(rt.shutdown_requested_at or "-") .. " t_ack=" .. tostring(rt.shutdown_accepted_at or "-") .. " t_done=" .. tostring(rt.shutdown_completed_at or "-")
      end
      ui.text(mon, 4, row + 3, "Shutdown:" .. tostring(rt.shutdown_stage or "-") .. " -> " .. tostring(rt.desired_node_state or "-")
        .. " wf=" .. stage .. extra, colorset.get("LIMITED"), colorset.get("background"))
    end
    local modules = rt.modules or {}
    local module_names = {}
    for name in pairs(modules) do
      table.insert(module_names, name)
    end
    table.sort(module_names)
    local mrow = row + 3
    local col = 4
    for _, name in ipairs(module_names) do
      local mod = modules[name]
      local active = model.active_step and model.active_step.node_id == rt.id and model.active_step.module_id == name
      local bar_status = active and "LIMITED" or status
      ui.text(mon, col, mrow, name .. ":" .. tostring(mod.state or "OFF"), colorset.get("text"), colorset.get("background"))
      ui.progress(mon, col + 12, mrow, 12, mod.progress or 0, bar_status)
      mrow = mrow + 1
      if mrow >= row + 4 then break end
    end
    row = row + 6
  end
end

return { render = render }
