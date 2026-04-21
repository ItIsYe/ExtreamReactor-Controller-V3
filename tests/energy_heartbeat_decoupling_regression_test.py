from pathlib import Path

source = Path("xreactor/nodes/energy/main.lua").read_text(encoding="utf-8")

required_snippets = [
    "local matrix_sampling_service = require(\"services.matrix_sampling_service\")",
    "local matrix_snapshot_runtime = require(\"nodes.energy.matrix_snapshot_runtime\")",
    "local function send_presence_heartbeat",
    "local function minimal_presence_state",
    "comms:send_heartbeat(minimal_presence_state(ts_ms))",
    "comms:tick(ts_ms)",
    "local function run_heartbeat_pump",
    "enable_heartbeat = false",
    "heartbeat_timer = os.startTimer",
    "inter_service_hook = function(_, _, phase)",
    "run_heartbeat_pump(now_ms())",
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
