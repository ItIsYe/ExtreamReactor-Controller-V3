from pathlib import Path

p = Path('.github/audit_fix_phase6b.py')
s = p.read_text(encoding='utf-8')

# Patch the phase script's UI-controller product edit to the current node-loop.
start = s.index("ui='xreactor/master/ui_controller.lua'\n")
end = s.index("\ndash='xreactor/master/ui/rt_dashboard.lua'", start)
ui_replacement = '''ui='xreactor/master/ui_controller.lua'\nreplace_once(ui,\n\'\'\'        local rt_node = node.rt or { status = normalize_status(node.status), mode = node.mode, assignment_state = node.assignment_state }\n\'\'\',\n\'\'\'        local rt_node = node.rt or { status = normalize_status(node.status), mode = node.mode, assignment_state = node.assignment_state }\n        local shutdown = type(node.shutdown_workflow) == "table" and node.shutdown_workflow or {}\n        local node_payload = type(node.payload) == "table" and node.payload or {}\n        rt_node.shutdown_stage = first_nonempty(shutdown.stage, node.shutdown_stage, node_payload.shutdown_stage)\n        rt_node.shutdown_outcome = first_nonempty(shutdown.outcome, node.shutdown_outcome, node_payload.shutdown_outcome)\n        rt_node.shutdown_reason = first_nonempty(shutdown.final_reason, shutdown.error, node.shutdown_reason, node_payload.shutdown_reason)\n        rt_node.shutdown_target_state = first_nonempty(shutdown.target_state, node.shutdown_target_state, node_payload.shutdown_target_state)\n        rt_node.shutdown_requested_at = pick_number(shutdown.requested_at, node.shutdown_requested_at, node_payload.shutdown_requested_at)\n        rt_node.shutdown_completed_at = pick_number(shutdown.completed_at, node.shutdown_completed_at, node_payload.shutdown_completed_at)\n\'\'\')\n'''
s = s[:start] + ui_replacement + s[end:]

# Patch the phase script's dashboard edit to current mux.card/data_row structure.
dash_start = s.index("dash='xreactor/master/ui/rt_dashboard.lua'\n")
dash_end = s.index("\n# ---------------------------------------------------------------------------\n# Rewrite the 13 stale Lua guards", dash_start)
dash_replacement = '''dash='xreactor/master/ui/rt_dashboard.lua'\ninsert_anchor=\'\'\'local function render_rt_card(mon, x, y, w, rt, hits)\n\'\'\'\nhelper=\'\'\'local function shutdown_verdict(rt)\n  local stage = tostring(first_text(rt and rt.shutdown_stage))\n  local outcome = tostring(first_text(rt and rt.shutdown_outcome))\n  local reason = tostring(first_text(rt and rt.shutdown_reason))\n  if outcome == "SUCCESS" or stage == "COMPLETED" or reason == "SUCCESS_COMPLETED" then\n    return "SD:OK"\n  end\n  if outcome == "FAILED" or stage == "FAILED" or reason:find("FAILED_", 1, true) == 1 then\n    local detail = reason ~= "-" and reason or (stage ~= "-" and stage or outcome)\n    return "SD:FAIL " .. safe_text(detail, "?"):sub(1, 18)\n  end\n  if outcome == "CANCELLED" or stage == "CANCELLED_DEMAND_RECOVERED" or reason == "CANCELLED_DEMAND_RECOVERED" then\n    return "SD:CANCELLED"\n  end\n  if stage ~= "-" then return "SD:" .. safe_text(stage, "-"):sub(1, 18) end\n  return "SD:-"\nend\n\n\'\'\'\nreplace_once(dash,insert_anchor,helper+insert_anchor)\nreplace_once(dash,\n\'\'\'  mux.data_row(mon, bx, by + 6, bw, { label = "QUEUE", value = safe_text(rt.queue_state, "idle") .. " | " .. safe_text(rt.queue_step, "-"), status = "muted" })\n\'\'\',\n\'\'\'  mux.data_row(mon, bx, by + 6, bw, { label = "QUEUE / SD", value = safe_text(rt.queue_state, "idle") .. " | " .. safe_text(rt.queue_step, "-") .. " | " .. shutdown_verdict(rt), status = "muted" })\n\'\'\')\n'''
s = s[:dash_start] + dash_replacement + s[dash_end:]

p.write_text(s, encoding='utf-8')
print('phase6b current UI/dashboard patch anchors corrected')
