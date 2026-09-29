#!/usr/bin/env python3
"""FUEL darf nach dem Start nicht auf die Hintergrund-Discovery warten, und
der teure Statuspayload darf nicht in jedem slow-Loop-Takt neu entstehen.

Betriebsmeldung (2026-09-29): "fuel braucht sehr lange bis er Daten hat und
wenn noetig reagiert". Zwei Ursachen, beide in nodes/fuel/main.lua, beide
ohne Absturz und ohne fallenden Test:

  Kaltstart   init() hat nur den Monitor gesucht. Die ME Bridge (storage_bus)
              fand erst services/discovery_service.lua -- mit vier Sekunden
              Startverzoegerung und aus der slow-Coroutine heraus. Bis dahin:
              NO_STORAGE, Reserve 0, leere Geraeteliste.
  Dauerlast   run_slow_loop ruft after_cycle alle 0.5 s, und dort stand ein
              ungedrosseltes refresh_status_payload(). Jeder Aufbau macht bis
              zu vier synchrone ME-Bridge-getItem()-Calls (storage.lua's
              read_items()) plus einen Ventil-Peer-Scan -- acht ME-Calls je
              Sekunde fuer eine Zahl, die telemetry_service alle
              status_interval Sekunden verschickt. CC:Tweaked hat nur einen
              Strang, also fehlte genau diese Zeit der Ventil-Logik und der
              Bedienung.

Geprueft wird die Verdrahtung, nicht die Drossel selbst -- die hat ihren
eigenen Test (tests/refresh_gate_test.lua).
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FUEL_MAIN = REPO / "xreactor/nodes/fuel/main.lua"
FUEL_STORAGE = REPO / "xreactor/nodes/fuel/storage.lua"

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def strip_comments(text):
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("--")
    )


body = strip_comments(FUEL_MAIN.read_text(encoding="utf-8"))

init_match = re.search(r"\nlocal function init\(\)\n(.*?)\nend\n", body, re.S)
check(init_match is not None, "init() in nodes/fuel/main.lua nicht gefunden")
init_body = init_match.group(1) if init_match else ""

# 1. Kaltstart: die Peripherie-Erkennung laeuft synchron in init(), nicht
#    erst im discovery_service.
check(
    re.search(r"pcall\(\s*discover\s*\)", init_body) is not None
    or re.search(r"(?<!function )\bdiscover\(\)", init_body) is not None,
    "init() ruft discover() nicht synchron -- der storage_bus (ME Bridge) "
    "waere erst nach der Startverzoegerung des discovery_service gebunden",
)

# 2. Kaltstart: der erste Statuspayload entsteht noch in init(), damit die
#    erste Anzeige und die erste Statusmeldung echte Werte tragen -- und
#    damit der teure Aufbau garantiert nicht in der fast-Coroutine landet.
check(
    re.search(r"refresh_status_payload,\s*true", init_body) is not None
    or re.search(r"refresh_status_payload\(\s*true\s*\)", init_body) is not None,
    "init() baut den ersten Statuspayload nicht erzwungen auf",
)

# 3. Dauerlast: der Payload-Aufbau haengt an einer Haltefrist.
check(
    "core.refresh_gate" in body,
    "nodes/fuel/main.lua benutzt core/refresh_gate.lua nicht -- ohne "
    "Haltefrist baut die slow-Coroutine den Payload zweimal je Sekunde neu",
)
check(
    re.search(r"payload_gate:due\(", body) is not None,
    "refresh_status_payload() fragt keine Haltefrist ab",
)

# 4. Dauerlast: die ME-Bridge-Reservelesung haengt an einer EIGENEN, laengeren
#    Haltefrist und wird nicht mehr direkt in den Payload-Aufbau gereicht.
check(
    re.search(r"reserve_gate:due\(", body) is not None,
    "read_fuel_cached() fragt keine Haltefrist ab",
)
check(
    re.search(r"read_fuel\s*=\s*read_fuel_cached", body) is not None,
    "der Statuspayload bekommt read_fuel nicht ueber read_fuel_cached -- "
    "dann liest jeder Aufbau wieder direkt auf der ME Bridge",
)
check(
    re.search(r"read_fuel\s*=\s*function\(\)\s*return\s*fuel_storage\.read_fuel", body)
    is None,
    "der Statuspayload reicht fuel_storage.read_fuel wieder ungedrosselt durch",
)

# 5. Die Haltefrist der Reserve beruecksichtigt die Bindung: eine frisch
#    gefundene ME Bridge darf nicht bis zum Fristablauf "Reserve 0" zeigen.
check(
    re.search(r"reserve_gate:due\([^)]*devices\.storage_name", body) is not None,
    "die Reserve-Haltefrist kennt den storage_bus nicht als Schluessel -- "
    "nach dem Binden stuende weiter der alte Wert",
)

# 6. Die Annahme hinter alldem: read_fuel macht wirklich mehrere synchrone
#    Peripherie-Calls. Faellt das weg, ist die Drossel nicht mehr begruendet.
storage_body = strip_comments(FUEL_STORAGE.read_text(encoding="utf-8"))
check(
    "getItem" in storage_body,
    "nodes/fuel/storage.lua liest nicht mehr per getItem() -- die Begruendung "
    "der Reserve-Haltefrist in main.lua muss nachgezogen werden",
)

# 7. logistics-Defaults muessen in main.lua stehen: config_normalizer.lua
#    faellt sonst auf eigene Literale zurueck (Versorgungs-Check alle 10 s
#    statt der in nodes/fuel/config.lua dokumentierten 5 s).
default_block = re.search(r"local DEFAULT_CONFIG = \{(.*?)\n\}", body, re.S)
check(default_block is not None, "DEFAULT_CONFIG in nodes/fuel/main.lua nicht gefunden")
if default_block:
    check(
        re.search(r"logistics\s*=\s*\{", default_block.group(1)) is not None,
        "DEFAULT_CONFIG hat keinen logistics-Block -- damit ist "
        "defaults.logistics in config_normalizer.lua nil und jeder dortige "
        "Rueckfall benutzt ein Literal, das von config.lua abweicht",
    )
    check(
        re.search(r"interval\s*=\s*5\b", default_block.group(1)) is not None,
        "DEFAULT_CONFIG.logistics.interval ist nicht 5 s",
    )

if failures:
    print("fuel_startup_latency_guard_test.py: FAIL")
    for message in failures:
        print(" - " + message)
    sys.exit(1)

print("fuel_startup_latency_guard_test.py: ok")
sys.exit(0)
