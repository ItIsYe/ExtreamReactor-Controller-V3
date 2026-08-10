from pathlib import Path
p=Path('.github/audit_fix_phase6b.py')
s=p.read_text(encoding='utf-8')
start=s.index("ui='xreactor/master/ui_controller.lua'\n")
end=s.index("\ndash='xreactor/master/ui/rt_dashboard.lua'", start)
replacement='''ui='xreactor/master/ui_controller.lua'\nreplace_once(ui,\n\'\'\'        local rt_node = node.rt or { status = normalize_status(node.status), mode = node.mode, assignment_state = node.assignment_state }\n\'\'\',\n\'\'\'        local rt_node = node.rt or { status = normalize_status(node.status), mode = node.mode, assignment_state = node.assignment_state }\n        local shutdown = type(node.shutdown_workflow) == "table" and node.shutdown_workflow or {}\n        local node_payload = type(node.payload) == "table" and node.payload or {}\n        rt_node.shutdown_stage = first_nonempty(shutdown.stage, node.shutdown_stage, node_payload.shutdown_stage)\n        rt_node.shutdown_outcome = first_nonempty(shutdown.outcome, node.shutdown_outcome, node_payload.shutdown_outcome)\n        rt_node.shutdown_reason = first_nonempty(shutdown.final_reason, shutdown.error, node.shutdown_reason, node_payload.shutdown_reason)\n        rt_node.shutdown_target_state = first_nonempty(shutdown.target_state, node.shutdown_target_state, node_payload.shutdown_target_state)\n        rt_node.shutdown_requested_at = pick_number(shutdown.requested_at, node.shutdown_requested_at, node_payload.shutdown_requested_at)\n        rt_node.shutdown_completed_at = pick_number(shutdown.completed_at, node.shutdown_completed_at, node_payload.shutdown_completed_at)\n\'\'\')\n'''
s=s[:start]+replacement+s[end:]
p.write_text(s,encoding='utf-8')
print('phase6b UI patch anchor corrected')
