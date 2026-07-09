# XReactor Controller V3 — Projektdokumentation

> Letzte Aktualisierung: beta-v358 (2026-07-08)

**Hinweis (Doku-Hygiene, 2026-07-08):** Diese Datei enthielt bisher eine vollständige, parallel gepflegte Kopie der technischen Architektur-Dokumentation, die zeitweise vom echten Code-Stand abwich (z. B. wurde die `power_target`-Prioritätsreihenfolge invertiert dokumentiert — genau der Bug-Zustand vor dem Fix). Um diese Art Inkonsistenz strukturell zu vermeiden, ist die technische Referenz jetzt an einer einzigen Stelle gepflegt:

- **[`../README.md`](../README.md)** — vollständige technische Architektur-Referenz: Systemüberblick, SCADA-Designprinzip, Netzwerk/Kanäle, Rollen, Boot-Sequenz, RT-Node-Details (inkl. Multi-Node-Zuweisungsformel, Setpoint-Feldtabelle, Capacity-Learning, Ampel-Statusmonitor), Master-UI (Layout-System, Overview/Summary, Alerts).
- **[`NODE_OVERVIEW.md`](NODE_OVERVIEW.md)** — detaillierte Pro-Node-Funktionsbeschreibung inkl. konkreter Konfigurationsbeispiele (FUEL/WATER/REPROCESSOR/ENERGY/LOG-Details, die im README nur kurz erwähnt sind).
- **[`../RUNTIME_STATUS_2026-06-03.md`](../RUNTIME_STATUS_2026-06-03.md)** — vollständige, chronologische Session-für-Session-Änderungshistorie.
- **[`../REWRITE_SPEC.md`](../REWRITE_SPEC.md)** — ursprüngliche Rewrite-Spezifikation (Architektur-Referenz für den SCADA-Umbau, historisch aber weiterhin akkurat für die umgesetzten Module).
- **[`SESSION_HANDOFF.md`](SESSION_HANDOFF.md)** — kompakter Einstiegspunkt für neue Chat-Sessions mit aktuellem Stand und offenen/geschlossenen Punkten.

Aktueller Stand kurzgefasst: `beta` / `manifest-v358` / `beta-v358`. Ein offener Punkt: die AUX:ALERTS-Seite wird parallel von einer anderen KI weiter umgebaut (Stand v356) — bei künftigen Änderungen daran Manifest-/Versions-Sync nicht vergessen. Details siehe `docs/SESSION_HANDOFF.md`.
