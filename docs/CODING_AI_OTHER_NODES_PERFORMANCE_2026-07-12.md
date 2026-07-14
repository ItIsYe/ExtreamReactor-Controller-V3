# Aktueller Gesamt-Audit – XReactor Controller V3

Stand: 2026-07-14  
Branch: `beta`  
Geprüfter ausführbarer Code-Head: `b1b15e292b94a177b98b5e49845bb70a2e4e143d`  
Geprüfte Release: `beta-v427` / `manifest-v427`

Die nachfolgenden Commits bis zu dieser Dateifassung betreffen ausschließlich Dokumentations- und Repository-Bereinigung. Der geprüfte ausführbare Code wurde dabei nicht verändert.

## Zweck

Diese Datei ist die einzige aktuelle, allgemeine Aufgabenquelle. Sie enthält:

- weiterhin offene Punkte,
- nur teilweise umgesetzte Punkte,
- verbindliche Prioritäten,
- Test- und Abnahmeanforderungen,
- den aktuellen Bereinigungsstand.

Erledigte historische Aufgaben wurden entfernt oder in kurze Referenzdateien ausgelagert.

---

# 1. Gesamtstatus

| Bereich | Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Benutzerconfig | **TEILWEISE BEHOBEN** | Config-Persistenz erledigt (GLOBAL-P0); Source-Pinning/CRC-Verify/Quiesce-Koordination laut `CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md` weiterhin offen |
| Shared Runtime | **BEHOBEN** | Events dürfen keine periodischen Vollticks auslösen — erledigt (SHARED-P0); Event-Koaleszierung/ENERGY-Attach-Detach-Kopplung bleibt Teil von Abschnitt 7 |
| MASTER | **WEITGEHEND ERLEDIGT** | mehrere FUEL-/WATER-Zielnodes eindeutig auswählen |
| RT | **TEILWEISE BEHOBEN** | 10-Hz-Cadence + Turbinen-Flow-Write-Dedup erledigt (RT-P0); kein separater 20-Hz-Scheduler-Layer, kein koaleszierter Command-Tick, Coil-Write-Dedup fehlt (RT-P1) |
| ENERGY | **TEILWEISE** | langsame Matrixarbeit vollständig isolieren |
| WATER | **WEITGEHEND ERLEDIGT** | Ingame- und Update-Regressionsnachweis |
| FUEL | **TEILWEISE** | Routing ohne blockierende Sleeps |
| REPROCESSOR | **TEILWEISE** | Routing ohne blockierende Sleeps |
| VALVE | **WEITGEHEND ERLEDIGT** | Paketverlust/Reconnect ingame nachweisen |
| LOG Collector | **WEITGEHEND ERLEDIGT** | Renderer ohne Laufzeit-Quelltextpatch |
| Tests / CI | **KRITISCH OFFEN** | funktionale Lua-/Python-Tests wirklich ausführen |
| Dokumentation | **BEREINIGT** | künftig nur eine aktuelle Aufgabenquelle pflegen |

---

# 2. Seit dem vorherigen Audit wesentlich umgesetzt

## WATER

- gemeinsamer generationsbasierter Tank-Snapshot,
- Tankwerte pro Generation nur einmal lesen,
- sichere `BLOCK_ALL`-Policy bei unbekanntem Tankstand,
- Stateänderung erst nach bestätigtem Redstone-Write,
- persistentes `SET_TARGET`,
- zentralisierte UI-Modell- und Touchpfade.

## REPROCESSOR

- doppeltes `read_buffers()` im Payload entfernt,
- gemeinsamer kurzer Payloadcache,
- Round-Robin-, Budget- und Backoff-Verarbeitung,
- Routing-/Configpfade überarbeitet,
- VALVE-ACK-Verarbeitung integriert.

## VALVE / gemeinsamer Router

- korrekte CC:Tweaked-Event-Indizes,
- Stateänderung nur nach erfolgreichem Write,
- ACK, Retry und Dedupe,
- Sender-/Zielprüfung,
- eindeutige `command_id`,
- requested und confirmed getrennt,
- Status pro Integrator und Seite.

## MASTER

- persistente PEAK-/IDLE-Schwellwerte,
- AUTO-UPDATE-Schalter steuert die echte lokale Updaterconfig,
- Terminal-`mouse_click`,
- stale RT-Fuelwerte werden nicht mehr als frisch weitergereicht,
- weniger wiederholte Modelserialisierung,
- kein DEBUG-Log pro erfolgreichem Frame.

## RT

- SAFE-Recovery-Contextfehler behoben,
- Startup-Report-Rollenvergleich korrigiert,
- dynamisches Ziel-RPM im Monitor,
- Buildinfo aus dem Monitor-Hotpath entfernt,
- doppelte manuelle Discovery entfernt,
- Discovery-Wrapper werden im Controlpfad wiederverwendet,
- Capability-/Wrapperarbeit teilweise reduziert.

## ENERGY

- zusätzliche ungeregelte Heartbeats entfernt,
- Storage-Metriken zeitlich gestaffelt,
- Capacity wird seltener gelesen,
- last-good Snapshots bleiben erhalten.

## Installer

- gesamter `/xreactor/config`-Ordner wird vor jedem Löschen rekursiv gesichert (Denylist statt Allowlist),
- Backup wird sofort zurückgelesen und byte-genau verifiziert, bevor `/xreactor` gelöscht werden darf,
- Minimal-Restore (`role.lua`, `remote_update.lua`, `node_id.txt`) sofort nach Neuanlage des Roots,
- vollständiger Config-Restore nach erfolgreicher Installation, ebenfalls byte-genau verifiziert,
- Recovery-Backup bleibt bei fehlgeschlagener Wiederherstellung erhalten statt gelöscht zu werden,
- Fix identisch in `xreactor/installer/init.lua` und im tatsächlich ausgeführten Live-Pfad in `/installer` angewendet (inkl. der eingebetteten `init_src`-Kopie).

## RT

- `RECEIVE_TIMEOUT` von 0.5s auf 0.1s gesenkt — Control-Tick läuft jetzt mit 10 Hz statt 2 Hz,
- `reactor_adjust_interval`/`reactor_adjust_interval_individual` von 5.0s/1.0s auf 0.10s gesenkt,
- Turbinen-Flow-Write dedupliziert (identischer Zielwert wird nicht erneut geschrieben), Overspeed-Bypass bleibt sofort wirksam.

## Shared Runtime

- Service-Manager ruft `tick()` bei Event-getriebenen Aufrufen jetzt nur noch für Services auf, die sich explizit über `wants_events = true` angemeldet haben,
- COMMS und UI melden sich standardmäßig selbst an; rollenspezifische Event-Listener (`valve_channel`, `valve_ack_listener`, `fuel_status_overhear`) melden sich gezielt an,
- Discovery/Telemetry/Alert/Matrix-Sampling und rein periodische Ad-hoc-Services laufen nur noch in ihrem konfigurierten Intervall, nicht mehr zusätzlich bei jedem Modem-/Monitor-/Maus-/Tastenevent,
- periodischer Tick (`event == nil`) bleibt für alle Services unverändert, `inter_service_hook` (ENERGY-Heartbeat-Interleaving) unberührt.

## LOG Collector

- persistente Batch-Writes,
- ACK erst nach bestätigtem Write,
- sofortiger Flush für wichtige Fehlerlevel,
- O(1)-Dedupe-Ringbuffer,
- ein normaler ACK-Sendeweg,
- rate-limitierte UI-Redraws bei Burstverkehr.

---

# 3. GLOBAL-P0 – Benutzerkonfiguration updatesicher erhalten

## Status

**BEHOBEN (2026-07-14)**

Der Installer sicherte zuvor nur eine kleine feste Dateiliste und löschte danach `/xreactor` vollständig.

Nicht generell geschützt sind unter anderem:

```text
config/master.lua
config/rt.lua
config/energy.lua
config/water.lua
config/fuel.lua
config/reprocessor.lua
config/valve.lua
config/fuel_routes.lua
config/reproc_routes.lua
config/remote_update.lua
weitere Registry-, Layout- und Benutzerdateien
```

## Umsetzung

1. `/xreactor/config` wird rekursiv vollständig eingelesen und als eine Datei nach `/xreactor_recovery/config_backup.lua` geschrieben (außerhalb von `/xreactor`), bevor irgendetwas gelöscht wird.
2. Das Backup wird sofort zurückgelesen und Eintrag für Eintrag byte-genau mit dem Original verglichen; bei jeder Abweichung bricht der Installer mit `error()` ab, **bevor** `fs.delete(INSTALL_ROOT)` erreicht wird.
3. Denylist statt Allowlist: nur `.xr_tmp`/`.xr_prev`-Zwischendateien werden vom Restore ausgeschlossen, alles andere (auch zukünftige, heute unbekannte Configdateien) bleibt erhalten.
4. Sofort nach Neuanlage von `/xreactor` werden `role.lua`, `remote_update.lua` und `node_id.txt` wiederhergestellt (Recovery-Fall bei Abbruch während des Downloads).
5. Nach erfolgreicher Installation wird der gesamte Config-Bestand wiederhergestellt, jede Datei erneut gelesen und mit dem Backup verglichen; das Recovery-Backup wird nur bei vollständigem Erfolg gelöscht.
6. Configschema-Versionierung/Default-Migration existiert bereits pro Node über `core/utils.lua` (`utils.load_config` + `migrate_config`/`merge_defaults`) und wird durch den Restore nicht berührt.
7. Identischer Fix in `xreactor/installer/init.lua` **und** im tatsächlich ausgeführten Live-Pfad in `/installer` (inkl. eingebetteter `init_src`-Kopie) angewendet — beide Installationspfade waren zuvor unabhängig voneinander betroffen.

Betroffene Dateien: `xreactor/installer/init.lua`, `installer`.

## Abnahme (Regressionscheckliste)

Für jede Rolle:

- Benutzerwerte ändern,
- Auto-Update/Reinstall ausführen,
- neu starten,
- Werte und Routen bleiben erhalten,
- neue Defaultfelder werden ergänzt,
- defekte Config erzeugt sichtbare Warnung und sicheren Fallback.

Funktional gegen ein Mock-Dateisystem verifiziert (Backup/Restore/Denylist/Verify-Abort); Ingame-Nachweis mit echter Hardware steht noch aus.

---

# 4. SHARED-P0 – Event- und Timerpfad trennen

## Status

**BEHOBEN (2026-07-14)**

Die gemeinsame Support-Runtime führte bei Modem-, Monitor-, Maus- und Key-Events weiterhin den gesamten Service-Manager aus. Dadurch konnte Eventverkehr zusätzliche Control-, Discovery-, UI-, Telemetrie- oder Maintenance-Zyklen erzeugen.

## Umsetzung

Statt der ursprünglich skizzierten `handle_event(event)`/`tick_due(now_ms)`-Doppel-API wurde eine kleinere, risikoärmere Lösung mit identischer Wirkung gewählt: `services/service_manager.lua`'s `manager:tick(dt, event)` prüft jetzt bei jedem Event-getriebenen Aufruf (`event ~= nil`) pro Service ein explizites `service.wants_events == true`-Opt-in, bevor dessen `tick()` überhaupt aufgerufen wird. Periodische Aufrufe (`event == nil`, aus dem Timer-Zweig jeder Event-Loop) bleiben für alle Services vollständig unverändert.

- `comms_service.lua` und `ui_service.lua` melden sich selbst standardmäßig an (`wants_events = true` im Konstruktor) — beide brauchen sofortige Reaktion auf Netzwerk- bzw. UI-Events.
- Die rollenspezifischen Ad-hoc-Services, die echte Event-Reaktivität benötigen, melden sich gezielt selbst an: `valve_channel` (VALVE), `valve_ack_listener` (FUEL, REPROCESSOR), `fuel_status_overhear` (FUEL).
- Rein periodische Services (Discovery, Telemetry, Alert, Matrix-Sampling sowie die Ad-hoc-Services `valve_failsafe`, `valve_ack_retry`, `ampel_render`, MASTERs `HOUSEKEEPING`) bekommen kein `wants_events` und werden bei Events komplett übersprungen — sie liefen ohnehin schon selbst intervallbasiert (`due`/`last_*`-Prüfung), laufen jetzt aber tatsächlich nur noch in ihrem konfigurierten Intervall statt zusätzlich bei jedem Event erneut.
- `inter_service_hook` (von ENERGY für Heartbeat-Interleaving genutzt) feuert weiterhin unverändert für jeden Service bei jedem `tick()`-Aufruf, unabhängig vom Event-Gating.

Betroffene Dateien: `xreactor/services/service_manager.lua`, `xreactor/services/comms_service.lua`, `xreactor/services/ui_service.lua`, `xreactor/nodes/valve/main.lua`, `xreactor/nodes/fuel/main.lua`, `xreactor/nodes/fuel/fuel_status_network.lua`, `xreactor/nodes/reprocessor/main.lua`. `nodes/support/runtime.lua` selbst musste nicht geändert werden, da das Gating vollständig im Service-Manager und den einzelnen Services lebt.

## Anforderungen (Abnahme)

- Modemempfang und ACK sofort — erhalten (`comms.wants_events = true`).
- periodische Arbeit ausschließlich zeitbasiert — erreicht (Discovery/Telemetry/Alert/Matrix-Sampling laufen nur noch auf dem periodischen Pfad).
- UI-Events nur an UI-relevante Services — erreicht.
- 1.000 Modemevents erzeugen keine 1.000 Controlticks — funktional gegen echte Service-Objekte verifiziert (1000 simulierte Events lösten 0 Discovery-/Telemetry-Ticks aus, nur die angemeldeten Services liefen).
- „Events koaleszieren" / gezielte Attach-Detach-Discovery-Kopplung: nicht Teil dieser Umsetzung, weiterhin offen (ENERGY-spezifisch, siehe Abschnitt 7).

---

# 5. RT-P0 – feste 10-Hz-Control-Cadence

## Status

**TEILWEISE BEHOBEN (2026-07-14)**

Der RT-Control-Service besaß keine eigene monotone Deadline und lief über den gemeinsamen Support-Eventloop, dessen periodischer Zweig durch `RECEIVE_TIMEOUT = 0.5` (2 Hz) gedrosselt war; die Reaktor-Regelung selbst besaß zusätzlich ein eigenes, viel zu langsames inneres Intervall (`reactor_adjust_interval = 5.0s` single-reactor, `1.0s` multi-reactor).

Verbindliche Vorgabe:

```lua
scheduler_interval_s = 0.05
reactor_control_interval_s = 0.10
turbine_control_interval_s = 0.10
```

Details stehen in:

[`CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md`](CODING_AI_RT_CONTROL_CADENCE_2026-07-12.md)

## Umsetzung

1. `nodes/rt/main.lua`: `RECEIVE_TIMEOUT` von `0.5` auf `0.1` gesenkt — der komplette Scheduler-Zyklus (inkl. Control-Tick) läuft jetzt mit 10 Hz statt 2 Hz. Andere periodische Services (Discovery/Telemetry/UI) sind über ihre eigene `interval`-/`due`-Prüfung unverändert von dieser Änderung entkoppelt.
2. `nodes/rt/config.lua`: `reactor_adjust_interval` von `5.0` auf `0.10` gesenkt, `reactor_adjust_interval_individual` explizit auf `0.10` gesetzt (vorher nur impliziter `1.0`-Fallback). Gilt für Erstinstallationen und fehlende/ungültige Werte; bereits bestehende, persistierte `config/rt.lua`-Dateien behalten ihren alten Wert bis zur manuellen Anpassung (kein automatisches Erzwingen, siehe GLOBAL-P0 — Config-Werte sind Nutzerwerte).
3. **Kritischer Begleitfix** (ohne den P3 nicht sicher umsetzbar gewesen wäre): `nodes/rt/turbine_control.lua`s `setTurbineFlow()`-Aufruf war bisher **unbedingt** bei jedem Control-Tick aktiv, unabhängig davon ob sich der Ziel-Flow geändert hatte (im Gegensatz zu den Rod-Writes, die bereits korrekt dedupliziert waren). Bei 10 Hz statt 2 Hz hätte das reale Hardware-Writes verfünffacht. Jetzt wird der Write übersprungen, wenn `requested_flow` exakt dem zuletzt erfolgreich geschriebenen Wert entspricht; Overspeed (erzwingt Flow 0) bleibt unverändert sofort wirksam, da der Zielwert bereits vor der Dedup-Prüfung auf 0 gesetzt wird.

Betroffene Dateien: `xreactor/nodes/rt/main.lua`, `xreactor/nodes/rt/config.lua`, `xreactor/nodes/rt/reactor_control.lua`, `xreactor/nodes/rt/turbine_control.lua`.

## Noch offen

- Kein eigener 20-Hz-Scheduler-Layer, der explizit entscheidet welche Teilregelung fällig ist (Architekturvorgabe Abschnitt 8) — stattdessen wird die gesamte Event-Loop-Periode auf 10 Hz gesenkt. Funktional äquivalent für die geforderte Kernmetrik (10 Hz Control-Tick, kein Event-Sturm-Effekt dank SHARED-P0), aber kein separates 20-Hz-„billiges" Scheduler-Layer.
- Vorgezogener, koaleszierter Tick bei wichtigen Commands (`next_control_due = math.min(next_control_due, now)`) ist nicht implementiert.
- Turbinen-Coil-Writes (`setInductorEngaged`) sind weiterhin nicht auf identische Werte dedupliziert (siehe RT-P1 unten).
- 25-Turbinen-Lasttest mit dokumentierten Vorher-/Nachher-Werten steht aus (Ingame-Messung nötig).

## Anforderungen

- Safety zuerst — unverändert erhalten (SAFE-Tick-Pfad in `updateReactorControl` läuft vor der Intervallprüfung).
- Rod- und Flow-Regler mit eigenen Deadlines — teilweise: gemeinsamer 10-Hz-Scheduler-Zyklus statt vollständig getrennter Deadlines pro Regler.
- keine Nachhol-Bursts — bereits vorher korrekt (`if now - last < interval then return end`, kein `while`-Backlog).
- Commands markieren höchstens einen koaleszierten vorgezogenen Tick — nicht umgesetzt.
- Writes zusätzlich change-/cooldown-basiert — Rod-Writes bereits vorher korrekt; Turbinen-Flow-Writes jetzt ebenfalls korrekt (siehe Umsetzung Punkt 3).
- Overspeed und SCRAM umgehen normale Cooldowns — funktional verifiziert (siehe Testnotiz unten).
- Ticklücke und Laufzeit messbar — nicht Teil dieser Umsetzung.

Funktional verifiziert (Mock-Test gegen den echten Turbinen-Flow-Dedup-Code): 50 aufeinanderfolgende Ticks mit stabilem Zielwert erzeugen 0 Hardware-Writes; ein Overspeed-bedingter Sprung auf Flow 0 schreibt sofort ohne Verzögerung; ein fehlgeschlagener Write hinterlässt keinen falschen "bereits geschrieben"-Zustand und wird beim nächsten Tick erneut versucht.

---

# 6. RT-P1 – verbleibende Hotpath-Arbeit

## Status

**TEILWEISE OFFEN**

Noch zu prüfen und mit Metriken abzuschließen:

- identische `setActive`-, Flow-, Coil- und Rod-Writes vollständig unterdrücken,
- Capability-Cache exakt einmal pro Discoverygeneration,
- Singular-/Plural-Kind-Namen normalisieren,
- gezielte Invalidierung bei Attach/Detach,
- gemeinsamer nicht-sicherheitskritischer Snapshot für UI und Telemetrie,
- stabilen Discovery-Default nach erfolgreichem Boot verlangsamen.

---

# 7. ENERGY-P0 – Schedulergruppen isolieren

## Status

**TEILWEISE OFFEN**

Zielgruppen:

```text
1. Comms + Heartbeat + Commands
2. Matrix-Sampling
3. Storage-Sampling
4. UI + Telemetrie
5. Discovery
```

Ein langsamer Matrixadapter darf keine andere Gruppe blockieren oder über einen UI-/Eventpfad in den Comms-Thread gelangen.

## Pflicht-Test

Einen Matrixadapter mehrere Sekunden blockieren lassen:

- Heartbeat bleibt im erlaubten Intervall,
- Commands werden verarbeitet,
- last-good Storage bleibt sichtbar,
- UI zeigt stale statt einzufrieren,
- Discovery kann später weiterlaufen.

---

# 8. FUEL / REPROCESSOR – Routing nicht blockierend machen

## Status

**OFFEN**

Der gemeinsame Router verwendet weiterhin blockierende Wartephasen für Settle- und Valve-open-Zeiten.

## Ziel-State-Machine

```text
IDLE
OPEN_PATH
WAIT_ACK
WAIT_SETTLE
EXPORT
HOLD_OPEN
BLOCK_ALL
COMPLETE
ERROR
```

## Anforderungen

- kein `os.sleep()` im normalen Routingpfad,
- Heartbeat, Commands, UI und Failsafe bleiben aktiv,
- ACK-Timeout führt zu `BLOCK_ALL`,
- Shutdown blockiert sofort alle Ventile,
- Lieferungen werden serialisiert oder klar budgetiert,
- aktive Transaktion und Fehler sind sichtbar.

---

# 9. MASTER-P1 – mehrere Zielnodes

## Status

**OFFEN**

FUEL-Reserve und WATER-Ziel dürfen nicht von der zufälligen Tabellenreihenfolge des ersten gefundenen Nodes abhängen.

Die UI benötigt:

- konkreten Zielnode,
- Option „alle Nodes der Rolle“,
- sichtbare ACK-/Fehlerauswertung,
- gespeicherte beziehungsweise eindeutig nachvollziehbare Auswahl.

---

# 10. LOG-P2 – Renderer ohne Sourcecode-Patch

## Status

**OFFEN, Wartbarkeit**

`nodes/log_collector/mockup_main.lua` liest `main.lua` als Text und ersetzt die lokale `draw()`-Funktion anhand fester Marker.

Ziel:

- normale Renderer-Schnittstelle,
- keine Quelltextmanipulation zur Laufzeit,
- Runtime ruft Renderer-Modul auf,
- sichtbarer Fallback bei Rendererfehler.

Bis dahin werden `main.lua` und `mockup_main.lua` beide benötigt.

---

# 11. TEST-P0 – funktionale Tests in CI

## Status

**KRITISCH OFFEN**

`.github/workflows/offline-tests.yml` führt weiterhin nur den Offline-Validator aus. Die funktionalen Dateien unter `tests/` werden nicht automatisch ausgeführt.

## Verbindlicher Umbau

1. Offline-Validator.
2. Alle kompatiblen `tests/*.lua`.
3. Alle `tests/*.py`.
4. Ausschlüsse nur explizit und begründet.
5. Rollenweise Jobgruppen.
6. Pflichtstatuscheck für `beta` und Pull Requests.
7. Veraltete Tests aktualisieren oder löschen, wenn ihr Schutz vollständig ersetzt wurde.

Wichtige Testgruppen:

```text
config_persistence_all_roles
shared_event_timer_separation
rt_fixed_cadence
rt_control_event_storm
energy_scheduler_isolation
fuel_reprocessor_nonblocking_routing
valve_packet_loss_retry
master_multi_target_selection
log_renderer_entrypoint
```

---

# 12. Dokumentations- und Repository-Bereinigung

## Gelöscht

- `.github/workflows/publish-beta-v360.yml` — fest auf v360 verdrahteter, gefährlicher Alt-Workflow.
- `docs/CODING_AI_FUEL_NODE_DEEP_AUDIT_2026-07-12.md` — vollständig durch diesen Audit ersetzt.
- `docs/NODE_OVERVIEW.md` — veraltete technische Duplikatdokumentation.

## Verdichtet und als kompatible Referenz behalten

- `docs/CODING_AI_IMPLEMENTATION_TASKS_2026-07-12.md`
- `docs/CODING_AI_PERFORMANCE_TASKS_2026-07-12.md`
- `docs/CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md`
- `docs/SESSION_HANDOFF.md`
- `docs/PROJECT_DOCUMENTATION.md`
- `docs/NODE_START_BLOCKERS_2026-06-25.md`

Diese Dateien enthalten nun nur noch aktuelle Verweise, stabile Aufgabenkennungen oder notwendige historische Hinweise.

## Aktiv gepflegte Dokumente

- dieser Gesamt-Audit,
- RT-Control-Cadence,
- Installer-/Auto-Update-Audit,
- `docs/README.md`,
- kompakter Session-Handoff.

## Löschregel

Eine Datei wird erst entfernt, wenn sie:

1. nicht in Manifest, Startup, Installer oder Workflow benötigt wird,
2. nicht von `require`, `dofile`, `shell.run`, Tests oder Tools verwendet wird,
3. keinen notwendigen manuellen Entry-Point darstellt,
4. keinen Recovery-/Migrationszweck besitzt,
5. nicht von weiterhin gültigen Links abhängig ist oder diese Links vorher aktualisiert wurden,
6. durch Ersatzfunktion und Regressionstest abgesichert ist.

---

# 13. Priorität

1. vollständige Config-Persistenz des Installers,
2. Event- und Timerpfad trennen,
3. echte RT-10-Hz-Cadence,
4. funktionale Testsuite in CI,
5. ENERGY-Schedulergruppen isolieren,
6. nicht blockierendes FUEL-/REPROCESSOR-Routing,
7. restliche RT-Hotpath-Arbeit,
8. MASTER-Multi-Node-Auswahl,
9. LOG-Renderer-Schnittstelle.

---

# 14. Definition of Done

- Updates erhalten alle Benutzerconfigs und Routen.
- Events erzeugen keine periodischen Vollticks.
- RT läuft gemessen und deterministisch mit 10 Hz.
- langsame ENERGY-Peripherals blockieren Comms und Heartbeat nicht.
- Routing enthält keine blockierenden Sleeps.
- VALVE-Kommandos enden bestätigt oder mit sichtbarem Fehler.
- MASTER arbeitet bei mehreren Supportnodes zielgenau.
- LOG benötigt keine Quelltextmanipulation.
- relevante Lua-/Python-Tests laufen verpflichtend in GitHub Actions.
- jede gelöschte Datei ist durch Referenzscan und Tests als unbenötigt nachgewiesen.
- der aktuelle ausführbare Code besitzt einen nachweislich grünen CI- und Ingame-Teststand.
