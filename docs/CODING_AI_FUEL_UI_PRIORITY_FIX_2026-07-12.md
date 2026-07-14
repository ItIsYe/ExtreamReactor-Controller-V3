# FUEL-UI – stabile Referenz der Aufgabenkennungen

Stand: 2026-07-14  
Geprüfte Release: `beta-v427`  
Status: **Implementierungsreferenz, keine aktuelle Restpunktliste**

## Zweck

Mehrere Codekommentare verweisen auf Kennungen wie `UI-P0.5`, `UI-P0.6` oder `REST-P1.2`. Diese Datei bleibt deshalb als stabile Referenz bestehen.

Die alte, auf `beta-v390` basierende Restpunktliste wurde entfernt. Aktuelle offene Aufgaben stehen ausschließlich in:

[`CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md`](CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md)

## Sicherheitsbedingung für FUEL-UI-Tests

Während UI- und Routingtests:

```lua
config.logistics.enabled = false
```

Zusätzlich:

- keine echten Fuel-Exporte,
- keine unbeabsichtigten Ventilöffnungen,
- ME-/Ventilzugriffe mocken oder Dry-Run verwenden,
- Fehler- und Reconnecttests mit sicheren Ausgangszuständen durchführen.

---

# Historische Aufgabenkennungen

| Kennung | Bedeutung | Stand in `beta-v427` |
|---|---|---|
| `UI-P0.1` | Jeder Touch besitzt genau einen zentralen Inputpfad | umgesetzt |
| `UI-P0.2` | Konsumierte Navigation stoppt Eventweitergabe | umgesetzt |
| `UI-P0.3` | `monitor_touch` und `mouse_click` einheitlich behandeln | umgesetzt |
| `UI-P0.4` | Pro UI-Zyklus genau ein Model erzeugen | umgesetzt |
| `UI-P0.5` | Nur eine zentrale Render-Zeitplanung | umgesetzt |
| `UI-P0.6` | Kein Full-Clear bei normalen Inhaltsänderungen | umgesetzt als Mindest-/Diff-Lösung |
| `UI-P0.7` | Seiten dürfen nicht direkt selbst neu zeichnen | umgesetzt |
| `UI-P0.8` | UI und operativer Router verwenden denselben aktiven Zustand | weitgehend umgesetzt |
| `UI-P1.1` | Renderfehler sichtbar machen und diagnostizieren | weitgehend umgesetzt |
| `UI-P1.2` | Monitor-, Größen- und Textskalierungswechsel erkennen | umgesetzt |
| `UI-P1.3` | FUEL-Zustände eindeutig darstellen | weitgehend umgesetzt |
| `REST-P0.1` | Routen persistieren, validieren und nach Reload aktivieren | umgesetzt/weiter testen |
| `REST-P0.2` | Verschachtelte Bäume vor flachem Überschreiben schützen | umgesetzt/weiter testen |
| `REST-P0.3` | VALVE online, stale, requested und confirmed anzeigen | umgesetzt/weiter testen |
| `REST-P1.1` | Rollenunabhängige Fehlerdarstellung und Diagnostics | umgesetzt/weiter testen |
| `REST-P1.2` | Lifecycle- und Skalierungsdiagnose | umgesetzt |
| `REST-P1.3` | gemeinsamer priorisierter `view_state` | umgesetzt/weiter testen |
| `REST-P1.4` | UI-Diagnosemetriken | umgesetzt/weiter testen |

## Weiterhin relevante Grundregeln

1. Ein physischer Touch darf höchstens eine fachliche Aktion auslösen.
2. Nach konsumierter Navigation wird kein Handler der neu geöffneten Seite im selben Event aufgerufen.
3. Snapshot und gezeichnetes Model stammen aus derselben Generation.
4. Interaktionen werden sofort sichtbar; passive Updates bleiben gedrosselt.
5. Seiten ändern State und invalidieren zentral, zeichnen aber nicht außerhalb des Controllers.
6. Ein Renderfehler zeigt eine lesbare Fallbackseite statt eines schwarzen Monitors.
7. Monitor- oder Geometriewechsel verwerfen alte Touchzonen und Framezustände.
8. `SAVED`, `ACTIVE`, `DIRTY`, `INVALID`, `OFFLINE` und `UNCONFIRMED` dürfen nicht vermischt werden.

## Aktuelle offene FUEL-Themen

Die wesentlichen noch offenen Themen liegen nicht mehr im ursprünglichen Touch-/Renderkern:

- blockierender Routingablauf mit `os.sleep()`,
- vollständiger Ingame-Nachweis unter Paketverlust und Reconnect,
- Testsuite und CI-Ausführung,
- updatesichere Erhaltung aller Benutzerconfigs und Routingdateien.

Details und Prioritäten stehen im aktuellen Gesamt-Audit.
