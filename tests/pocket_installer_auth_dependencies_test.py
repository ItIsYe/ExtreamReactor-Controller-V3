from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "installer_pocket").read_text(encoding="utf-8")
client = (root / "xreactor/optional/pocket_client.lua").read_text(encoding="utf-8")

for dependency in (
    "core/protocol.lua",
    "core/utils.lua",
    "core/logger.lua",
    "shared/constants.lua",
):
    assert dependency in source, f"Pocket installer must install auth dependency {dependency}"

assert "{ timeout = 15 }" in source, "Pocket installer HTTP downloads need the standard timeout"
assert "/xreactor/config/network_auth.lua" in source, "Pocket installer must provision the shared secret"
assert "protocol.sign_message(message, AUTH_SECRET)" in client
assert "protocol.verify_message_auth(message, AUTH_SECRET)" in client

print("pocket_installer_auth_dependencies_test.py: ok")
