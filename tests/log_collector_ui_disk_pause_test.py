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


def test_log_collector_rotates_next_disk_after_successful_write():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    # advance_disk_after_write still exists (called on disk-full switch)
    assert "advance_disk_after_write" in text
    # New behavior: stay on current disk until full, only switch on error.
    # write_log no longer calls advance_disk_after_write() after a success.
    assert "if ok then" in text
    assert "switch_next_disk()" in text
    assert "Next    Disk #" in text
    assert "Switch %-5s" in text


def test_log_collector_prune_does_not_delete_active_log_files():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "name:match(\"%.log%.%d+$\")" in text
    assert "name:match(\"%.old$\")" in text
    assert "name:match(\"%.bak$\")" in text
    assert "aggressive" not in text
    assert "name:match(\"%.log$\")" not in text


def test_log_collector_refreshes_modems_after_startup():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "MODEM_REFRESH_SECONDS" in text
    assert "refresh_collector_modems" in text
    assert "ModemRefresh" in text
    assert "refresh_collector_modems(false)" in text


def test_log_collector_has_pause_button_and_input_handlers():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "PAUSE DISK WRITES" in text
    assert "RESUME DISK WRITES" in text
    assert "monitor_touch" in text
    assert "mouse_click" in text
    assert "paused_dropped" in text
    assert "ACKs withheld so senders retry" in text


def test_log_collector_pause_redraw_is_forward_declared():
    text = LOG_COLLECTOR.read_text(encoding="utf-8")
    assert "local draw" in text
    assert "if draw then draw() end" in text
    assert "draw = function()" in text
