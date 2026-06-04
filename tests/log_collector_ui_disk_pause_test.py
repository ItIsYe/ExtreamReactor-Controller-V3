from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG_COLLECTOR = ROOT / "xreactor" / "nodes" / "log_collector" / "main.lua"


def test_log_collector_shows_last_write_disk_identity():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "last_write_index" in text
    assert "last_write_mount" in text
    assert "last_write_path" in text
    assert "Writing Disk #" in text
    assert "* = last write target" in text


def test_log_collector_has_pause_button_and_input_handlers():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "PAUSE DISK WRITES" in text
    assert "RESUME DISK WRITES" in text
    assert "monitor_touch" in text
    assert "mouse_click" in text
    assert "paused_dropped" in text
    assert "Disk writes paused for backup/download" in text


def test_log_collector_pause_redraw_is_forward_declared():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "local draw" in text
    assert "if draw then draw() end" in text
    assert "draw = function()" in text
