# Session Handoff – XReactor Controller V3

Stand: 2026-08-10

Branch: `agent/repo-safety-audit-fixes` → `beta`

Geprüfter Runtime-Code-Stand: `0cc0efd575aab082a361a4cf96f600aa6086f46f`

Release: `beta-v521` / `manifest-v521`

## Einstieg für neue Arbeit

1. [`REPO_SAFETY_AUDIT_CLOSURE_2026-08-10.md`](REPO_SAFETY_AUDIT_CLOSURE_2026-08-10.md) lesen. Dort stehen die Audit-Traceability und die noch offenen Ingame-Abnahmen.
2. Für RT-Regelzeiten zusätzlich [`CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`](CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md) verwenden.
3. Für Installer-/Auto-Update-Arbeiten zusätzlich [`CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md`](CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md) verwenden.
4. Für historische FUEL-UI-Kennungen die kurze Referenz [`CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md`](CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md) verwenden.

## Wichtigste offene Punkte

Die codeseitigen Repo-Safety-Audit-Findings sind im Draft umgesetzt und automatisiert abgedeckt. Vor dem Merge fehlen ausschließlich die im Abschlussnachweis aufgeführten Hardware-/Ingame-Abnahmen und ein unabhängiges Review.

## Bereits wesentlich verbessert

- WATER-Snapshot und Cluster-Failsafe,
- REPROCESSOR-Bufferbudget und Payloadcache,
- VALVE ACK/Retry/Dedupe/Auth,
- VALVE steuert ausschließlich einen Mekanism Logistical Sorter als Aktor
  (`sorter_name`, siehe nodes/valve/config.lua) — der ursprüngliche
  Redstone-Aktor wurde am 2026-07-20 entfernt, da nicht mehr im Einsatz,
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
