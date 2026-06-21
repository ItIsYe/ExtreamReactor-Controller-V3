from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CONSTANTS = ROOT / "xreactor" / "shared" / "constants.lua"


def defined_message_types():
    text = CONSTANTS.read_text(encoding="utf-8")
    block_match = re.search(r"constants\.message_types\s*=\s*\{(?P<body>.*?)\n\}", text, re.S)
    assert block_match, "constants.message_types block not found"
    return set(re.findall(r"\n\s*([A-Z0-9_]+)\s*=", block_match.group("body")))


def referenced_message_types():
    refs = set()
    for path in (ROOT / "xreactor").rglob("*.lua"):
        text = path.read_text(encoding="utf-8")
        refs.update(re.findall(r"constants\.message_types\.([A-Z0-9_]+)", text))
    return refs


def test_message_type_references_are_defined():
    defined = defined_message_types()
    referenced = referenced_message_types()
    missing = sorted(referenced - defined)
    assert not missing, "undefined constants.message_types references: " + ", ".join(missing)
