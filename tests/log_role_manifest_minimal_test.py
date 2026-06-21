from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "xreactor" / "manifest.lua"
INSTALLER_MANIFEST = ROOT / "xreactor" / "installer_manifest.lua"

EXPECTED_LOG_FILES = {
    "installer_http.lua",
    "installer_main.lua",
    "installer_manifest.lua",
    "installer_stage.lua",
    "installer_startup.lua",
    "installer_storage.lua",
    "release.lua",
    "start.lua",
    "shared/build_info.lua",
    "shared/constants.lua",
    "nodes/log_collector/main.lua",
}

FORBIDDEN_LOG_FILES = {
    "core/comms.lua",
    "core/network.lua",
    "core/registry.lua",
    "core/logger.lua",
    "core/safety.lua",
    "services/comms_service.lua",
    "services/discovery_service.lua",
    "services/telemetry_service.lua",
    "master/main.lua",
    "nodes/rt/main.lua",
    "nodes/energy/main.lua",
}


def parse_manifest_paths():
    text = MANIFEST.read_text(encoding="utf-8")
    return set(re.findall(r'path\s*=\s*"([^"]+)"', text))


def test_log_role_expected_files_are_documented_manifest_paths():
    paths = parse_manifest_paths()
    missing = sorted(EXPECTED_LOG_FILES - paths)
    assert not missing, "LOG expected files missing from manifest: " + ", ".join(missing)


def test_log_role_forbidden_heavy_files_are_not_explicit_log_required():
    text = MANIFEST.read_text(encoding="utf-8")
    for path in FORBIDDEN_LOG_FILES:
        pattern = re.compile(r'path\s*=\s*"' + re.escape(path) + r'"[^\n]*required_for\s*=\s*\{[^\n]*("LOG"|"LOG_COLLECTOR")')
        assert not pattern.search(text), f"heavy/non-LOG file is explicitly required for LOG: {path}"


def test_installer_manifest_has_special_log_role_selection():
    text = INSTALLER_MANIFEST.read_text(encoding="utf-8")
    assert "is_log_role" in text
    assert "entry.always == true" in text
    assert "not log_role" in text
