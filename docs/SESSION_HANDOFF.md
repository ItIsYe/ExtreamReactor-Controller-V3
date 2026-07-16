# Session Handoff – XReactor Controller V3

Stand: 2026-07-16  
Branch: `beta`  
Geprüfter Code-Stand: `ef37d74419c7e37ab3a099b43e7cf039d8427dca`  
Release: `beta-v454` / `manifest-v454`

## Einstieg für neue Arbeit

1. [`CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md`](CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md) lesen. Dort stehen ausschließlich die aktuellen Restpunkte und Prioritäten.
2. Für RT-Regelzeiten zusätzlich [`CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`](CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md) verwenden.
3. Für Installer-/Auto-Update-Arbeiten zusätzlich [`CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md`](CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md) verwenden.
4. Für historische FUEL-UI-Kennungen die kurze Referenz [`CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md`](CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md) verwenden.

## Wichtigste offene Punkte

1. Der Installer muss den vollständigen Benutzer-Configbestand updatesicher erhalten.
2. Event- und Timerpfade der gemeinsamen Runtime müssen getrennt werden.
3. Der RT-Controlpfad benötigt eine echte deterministische 10-Hz-Cadence.
4. GitHub Actions muss die funktionalen Lua- und Python-Tests wirklich ausführen.
5. ENERGY benötigt echte Schedulergruppen-Isolation.
6. FUEL-/REPROCESSOR-Routing muss ohne blockierende `os.sleep()`-Phasen arbeiten.
7. MASTER benötigt eine eindeutige Zielauswahl für mehrere FUEL-/WATER-Nodes.
8. Der LOG-Renderer soll ohne Quelltext-Patching geladen werden.

## Bereits wesentlich verbessert

- WATER-Snapshot und Cluster-Failsafe,
- REPROCESSOR-Bufferbudget und Payloadcache,
- VALVE ACK/Retry/Dedupe/Auth,
- VALVE unterstützt jetzt wahlweise Redstone ODER einen Mekanism Logistical
  Sorter als Aktor (`config.actuator_type = "redstone" | "sorter"`) — für
  Item-Brennstofftransport ohne klassisches Redstone-Ventil, umgeht dabei
  bewusst Mekanisms Auto-Eject-Verhalten, das Redstone sonst überstimmt,
- FUEL-UI-Eingabe- und Renderpfad,
- MASTER-Persistenz, Terminal-Maus und stale Fuel-Relay,
- LOG-Batching, O(1)-Dedupe und einzelner ACK-Sendeweg,
- ENERGY-Heartbeat und gestaffeltes Storage-Sampling,
- mehrere RT-Hotpath- und Diagnosefehler.

## Arbeitsregeln

- Keine Produktionsänderung ausschließlich anhand alter Auditdateien durchführen.
- Jede manifestierte Datei benötigt passende Manifest-/Release-Metadaten.
- Safety-Pfade nie zugunsten geringerer Last verlangsamen.
- Benutzerconfigs und Routingdateien vor Installeränderungen besonders schützen.
- Erst Referenzen und Tests prüfen, dann Dateien löschen.
- Statische Prüfung ersetzt keinen Ingame-Test.
