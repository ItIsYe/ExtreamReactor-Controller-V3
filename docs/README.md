# XReactor-Dokumentationsindex

Stand: 2026-08-12  
Branch: `beta`  
Geprüfte Release: `beta-v548` / `manifest-v548`

> **Hinweis (2026-08-12):** `beta` wurde auf den bereinigten Stand aus `agent/clean-recovery`
> zurückgesetzt (der vorherige `beta`-Stand liegt jetzt unter `beta-funktoniet-nicht`). Die
> Versionsnummerierung (`manifest-v548`) ist daher **kein** nahtloser Fortsatz der früher in
> diesem Index referenzierten `beta-v3xx`/`v4xx`/`v5xx`-Stände — Detaildaten aus den unten
> verlinkten historischen Auditdateien können daher lokal abweichen und sollten vor Nutzung
> gegen den aktuellen Code geprüft werden.

## Zuerst lesen

1. [`CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md`](CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md)  
   Aktueller Gesamt-Audit mit ausschließlich offenen beziehungsweise teilweise umgesetzten Punkten, Prioritäten und Definition of Done.

2. [`SESSION_HANDOFF.md`](SESSION_HANDOFF.md)  
   Kurzer Einstieg für eine neue Entwicklungs- oder Analyse-Sitzung.

3. [`../README.md`](../README.md)  
   Allgemeine Architektur, Rollen und Bedienung.

## Verbindliche Spezialdokumente

- [`CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`](CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md)  
  Verbindliche RT-Scheduler-, Control-, Readback- und Safety-Zeiten. Diese Datei hat für den schnellen RT-Regelkreis Vorrang vor allgemeinen Performanceempfehlungen.

- [`CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md`](CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md)  
  Detaillierter Installer-/Auto-Update-Audit. Der aktuelle Gesamt-Audit entscheidet, welche Punkte noch offen sind.

- [`CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md`](CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md)  
  Stabile Referenz für Aufgabenkennungen, auf die bestehende FUEL-UI-Codekommentare verweisen.

## Kompatibilitäts- und Historien-Einstiege

Diese Dateien bleiben bestehen, weil ältere Links beziehungsweise die historische Änderungschronik darauf verweisen. Sie enthalten keine eigenständige aktuelle Aufgabenliste mehr:

- [`PROJECT_DOCUMENTATION.md`](PROJECT_DOCUMENTATION.md)
- [`CODING_AI_IMPLEMENTATION_TASKS_2026-07-12.md`](CODING_AI_IMPLEMENTATION_TASKS_2026-07-12.md)
- [`CODING_AI_PERFORMANCE_TASKS_2026-07-12.md`](CODING_AI_PERFORMANCE_TASKS_2026-07-12.md)
- [`NODE_START_BLOCKERS_2026-06-25.md`](NODE_START_BLOCKERS_2026-06-25.md)

## Entfernte veraltete Dokumente

- `CODING_AI_FUEL_NODE_DEEP_AUDIT_2026-07-12.md`  
  Vollständig durch den aktuellen Gesamt-Audit und die FUEL-UI-Referenz ersetzt.

- `NODE_OVERVIEW.md`  
  Technische Duplikatdokumentation auf altem Stand; die aktuelle Architektur wird zentral im Root-README und im aktuellen Audit gepflegt.

- `../RUNTIME_STATUS_2026-06-03.md` und `../REWRITE_SPEC.md`  
  Historische Session-/Rewrite-Dokumente, entfernt (siehe Git-Historie: Commits `99ebb717` bzw. `b74a01b6`). Frühere Links auf diese beiden Dateien im Root-README und in `PROJECT_DOCUMENTATION.md`/`NODE_START_BLOCKERS_2026-06-25.md` wurden entsprechend bereinigt.

## Dokumentationsregeln

- Aktuelle Aufgaben werden nur im Gesamt-Audit geführt.
- Spezialdokumente enthalten ausschließlich dauerhaft relevante technische Vorgaben.
- Historische Dateinamen dürfen als kurze Weiterleitung bestehen bleiben, wenn externe oder alte interne Links darauf zeigen.
- Keine parallele vollständige Architekturkopie pflegen.
- Eine Datei erst löschen, wenn Code-, Manifest-, Installer-, Workflow-, Test- und Dokumentreferenzen geprüft wurden.
- Statische Dokumentation ersetzt keinen Ingame-Test.
