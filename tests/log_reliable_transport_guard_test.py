from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UTILS = ROOT / "xreactor" / "core" / "utils.lua"
COLLECTOR = ROOT / "xreactor" / "nodes" / "log_collector" / "main.lua"
COMMS_SERVICE = ROOT / "xreactor" / "services" / "comms_service.lua"


def test_sender_uses_event_ids_pending_retries_and_acks():
    text = UTILS.read_text(encoding="utf-8")
    assert "REMOTE_LOG_PENDING_LIMIT" in text
    assert "REMOTE_LOG_MAX_SENDS" in text
    assert "event_id" in text
    assert "seq" in text
    assert "boot_id" in text
    assert "make_boot_id" in text
    assert "LOG_ACK" in text
    assert "pending_order" in text
    assert "retry_pending" in text
    assert "handle_remote_log_message" in text
    assert "flush_remote_logs" in text


def test_sender_transmits_logs_on_all_detected_modems():
    text = UTILS.read_text(encoding="utf-8")
    assert "discover_log_modems" in text
    assert "wireless" in text
    assert "wired" in text
    assert "for _, entry in ipairs(remote_log_state.modems)" in text
    assert "entry.modem.transmit(CONFIG.REMOTE_LOG_CHANNEL" in text


def test_comms_service_routes_log_ack_before_protocol_receive():
    text = COMMS_SERVICE.read_text(encoding="utf-8")
    assert "utils.handle_remote_log_message" in text
    assert "return true" in text
    assert "utils.flush_remote_logs" in text


def test_comms_service_flushes_retries_without_forcing_every_tick():
    utils_text = UTILS.read_text(encoding="utf-8")
    service_text = COMMS_SERVICE.read_text(encoding="utf-8")
    assert "function utils.flush_remote_logs(force)" in utils_text
    assert "retry_pending(force == true)" in utils_text
    assert "utils.flush_remote_logs()" in service_text
    assert "utils.flush_remote_logs(true)" not in service_text


def test_collector_dedupes_and_acks_log_events():
    text = COLLECTOR.read_text(encoding="utf-8")
    assert "DEDUPE_LIMIT" in text
    assert "remember_event" in text
    assert "has_seen" in text
    assert "LOG_ACK" in text
    assert "send_ack" in text
    assert "duplicates" in text
    assert "ack_sent" in text
    assert "status = status or \"written\"" in text


def test_collector_does_not_ack_paused_writes():
    text = COLLECTOR.read_text(encoding="utf-8")
    assert "Disk writes paused; ACKs withheld so senders retry" in text
    assert "return false, \"paused\"" in text
    assert "send_ack(message, \"written\")" in text
    assert "send_ack(message, \"duplicate\")" in text
