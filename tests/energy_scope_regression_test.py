from pathlib import Path
import re

SOURCE = Path("xreactor/nodes/energy/main.lua").read_text(encoding="utf-8")


def idx(pattern: str, *, regex: bool = False) -> int:
    if regex:
        match = re.search(pattern, SOURCE)
        if not match:
            raise AssertionError(f"pattern missing: {pattern}")
        return match.start()
    pos = SOURCE.find(pattern)
    if pos == -1:
        raise AssertionError(f"text missing: {pattern}")
    return pos


master_peer_decl = idx("local master_peer_state")
is_master_decl = idx("local is_master_connected")
build_status = idx(r"local function build_status_payload\(", regex=True)
build_ui = idx(r"local function build_ui_model\(", regex=True)

if is_master_decl > build_status:
    raise AssertionError("is_master_connected forward declaration must be before build_status_payload")
if master_peer_decl > build_ui:
    raise AssertionError("master_peer_state forward declaration must be before build_ui_model")

is_master_assignment = idx(r"is_master_connected\s*=\s*function\(", regex=True)
if is_master_assignment < build_status:
    raise AssertionError("is_master_connected assignment moved before build_status_payload unexpectedly")

master_peer_assignment = idx(r"master_peer_state\s*=\s*function\(", regex=True)
if master_peer_assignment < build_ui:
    raise AssertionError("master_peer_state assignment moved before build_ui_model unexpectedly")

idx(r"is_master_connected\(", regex=True)
idx(r"master_peer_state\(", regex=True)

print("energy_scope_regression_test.py: ok")
