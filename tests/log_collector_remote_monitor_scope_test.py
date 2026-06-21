from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG_COLLECTOR = ROOT / "xreactor" / "nodes" / "log_collector" / "main.lua"
MASTER_MONITOR_MANAGER = ROOT / "xreactor" / "core" / "monitor_manager.lua"


def test_log_collector_has_remote_monitor_ui_support():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "getNamesRemote" in text
    assert "callRemote" in text
    assert "xreactor.log_monitor" in text
    assert "log_monitor.txt" in text


def test_master_monitor_manager_not_changed_for_log_collector_remote_monitor():
    text = MASTER_MONITOR_MANAGER.read_text(encoding="utf-8")
    assert "getNamesRemote" not in text
    assert "callRemote" not in text
    assert "remote_modem" not in text
