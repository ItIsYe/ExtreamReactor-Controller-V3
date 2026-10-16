#!/usr/bin/env python3
"""Jedes capacity_*-Feld, das MASTER aus dem Payload liest, muss die RT-Node
auch senden -- und umgekehrt.

Warum das ein eigener Test ist: die Kette Node -> Payload -> MASTER -> UI
laeuft ueber vier Dateien und reine Feldnamen. Bricht sie in der Mitte,
faellt kein Test um und nichts stuerzt ab -- die Anzeige zeigt einfach
still eine Null. Genau so lagen zwei Felder lange tot:

  capacity_sustainable_turbines  MASTER las es, zeigte "x von y Turbinen
                                 tragen" -- die Node sendete es nie.
  capacity_required_turbines     Die Node sendete es, ui_controller.lua las
                                 es -- message_handlers.lua legte es nie
                                 ins rt-Modell, also stand dort "x/0".

Geprueft wird deshalb der Feldname selbst, quer ueber die Dateien.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RT_MAIN = REPO / "xreactor/nodes/rt/main.lua"
RT_ENGINE = REPO / "xreactor/nodes/rt/rt2_engine.lua"
MASTER_HANDLERS = REPO / "xreactor/master/message_handlers.lua"
MASTER_UI = REPO / "xreactor/master/ui_controller.lua"

failures = []


def read(path):
    return path.read_text(encoding="utf-8")


def strip_comments(text):
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("--"))


def check(condition, message):
    if not condition:
        failures.append(message)


main_src = strip_comments(read(RT_MAIN))
engine_src = strip_comments(read(RT_ENGINE))
handlers_src = strip_comments(read(MASTER_HANDLERS))
ui_src = strip_comments(read(MASTER_UI))

# ── 1. Was MASTER aus dem Payload liest, muss die Node senden ────────────

master_reads = set(re.findall(r"payload\.(capacity_\w+)", handlers_src))
node_writes = set(re.findall(r"payload\.(capacity_\w+)\s*=", main_src))

for field in sorted(master_reads - node_writes):
    check(False,
          f"MASTER liest payload.{field}, aber nodes/rt/main.lua sendet es nicht "
          f"-- die Anzeige bleibt still auf 0")

# ── 2. Was die Node sendet, muss MASTER auch uebernehmen ────────────────
#
# Sonst ist das Feld auf der Leitung, kommt aber nie im rt-Modell an.

for field in sorted(node_writes - master_reads):
    check(False,
          f"nodes/rt/main.lua sendet payload.{field}, aber "
          f"master/message_handlers.lua uebernimmt es nicht")

# ── 3. Was die MASTER-Oberflaeche aus rt_data liest, muss dort ankommen ──

ui_reads = set(re.findall(r"rt_data\.(capacity_\w+)", ui_src))
handler_writes = set(re.findall(r"rt\.(capacity_\w+)\s*=", handlers_src))

for field in sorted(ui_reads - handler_writes):
    check(False,
          f"master/ui_controller.lua liest rt_data.{field}, aber "
          f"master/message_handlers.lua legt es nie ins rt-Modell")

# ── 4. Was main.lua sendet, muss rt2_engine.status_fields() liefern ──────

engine_fields = set(re.findall(r"^\s{4}(capacity_\w+)\s*=", engine_src, re.M))
for field in sorted(node_writes):
    source = f"v2.{field}"
    check(source in main_src or field in engine_fields,
          f"main.lua sendet payload.{field}, aber rt2_engine.status_fields() "
          f"liefert kein {field}")

# ── 5. Kein Feld aus v1s Lernverfahren darf zurueckkommen ───────────────
#
# capacity_stable_samples war v1s Zaehler; seit dem rt2-Regler fuellt ihn
# niemand mehr. Er hat die Farbwahl des RT-Schirms dauerhaft auf Rot
# genagelt, ohne dass etwas abstuerzte.

RETIRED = ["capacity_stable_samples", "capacity_sample_output"]
for name in RETIRED:
    for path in (RT_MAIN, RT_ENGINE, MASTER_HANDLERS, MASTER_UI,
                 REPO / "xreactor/nodes/rt/monitor_ui.lua",
                 REPO / "xreactor/nodes/rt/mockup_pages.lua",
                 REPO / "xreactor/master/runtime_ops_rt.lua"):
        body = strip_comments(read(path))
        check(name not in body,
              f"{path.relative_to(REPO)} benutzt {name} -- das Feld stammt aus "
              f"v1s Lernverfahren und wird von niemandem mehr gefuellt")

if failures:
    print("capacity_payload_chain_test.py: FAIL")
    for message in failures:
        print(" - " + message)
    sys.exit(1)

print("capacity_payload_chain_test.py: ok")
sys.exit(0)
