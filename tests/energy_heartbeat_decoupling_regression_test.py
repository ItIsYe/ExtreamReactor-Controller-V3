from pathlib import Path

source = Path("xreactor/nodes/energy/main.lua").read_text(encoding="utf-8")

required_snippets = [
    "local function send_presence_heartbeat",
    "comms:send_heartbeat({})",
    "enable_heartbeat = false",
    "heartbeat_timer = os.startTimer",
    "if now_ms() - last_heartbeat >= hb_interval_ms then",
]

for snippet in required_snippets:
    if snippet not in source:
        raise AssertionError(f"missing snippet: {snippet}")

telemetry_source = Path("xreactor/services/telemetry_service.lua").read_text(encoding="utf-8")
for snippet in [
    "enable_heartbeat = opts.enable_heartbeat ~= false",
    "if self.enable_heartbeat and heartbeat_elapsed >= heartbeat_interval_ms then",
]:
    if snippet not in telemetry_source:
        raise AssertionError(f"missing snippet in telemetry service: {snippet}")

print("energy_heartbeat_decoupling_regression_test.py: ok")
