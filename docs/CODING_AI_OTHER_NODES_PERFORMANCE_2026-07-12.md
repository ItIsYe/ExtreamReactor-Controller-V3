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
| RT | **TEILWEISE BEHOBEN** | 10-Hz-Cadence + Flow-/setActive-Write-Dedup erledigt (RT-P0/P1; Rod- und Coil-Writes waren bereits vorher korrekt dedupliziert); kein separater 20-Hz-Scheduler-Layer, kein koaleszierter Command-Tick; Capability-Cache/Kind-Namen/Attach-Detach-Invalidierung/gemeinsamer UI-Snapshot/Discovery-Default noch offen (RT-P1) |
| ENERGY | **WEITGEHEND ERLEDIGT** | Ingame-Nachweis mit künstlich verlangsamtem Matrixadapter steht aus; Architektur bereits verifiziert isoliert |
| WATER | **WEITGEHEND ERLEDIGT** | Ingame- und Update-Regressionsnachweis |
| FUEL | **WEITGEHEND ERLEDIGT** | Routing ohne blockierende Sleeps erledigt (Abschnitt 8); Ingame-Nachweis mit echter Hardware steht aus |
| REPROCESSOR | **WEITGEHEND ERLEDIGT** | Routing ohne blockierende Sleeps erledigt (Abschnitt 8); Ingame-Nachweis mit echter Hardware steht aus |
| VALVE | **WEITGEHEND ERLEDIGT** | Paketverlust/Reconnect ingame nachweisen |
| LOG Collector | **WEITGEHEND ERLEDIGT** | Renderer ohne Laufzeit-Quelltextpatch |
| Tests / CI | **TEILWEISE BEHOBEN** | Runner + explizite Ausschlussliste läuft in CI (58/135 Lua, 19/28 Python grün); 86 Tests bleiben einzeln zu triagieren |
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

## FUEL / REPROCESSOR gemeinsamer Ventil-Router

- `route_and_act()`s zwei blockierende `os.sleep()`-Aufrufe (~2.05-2.4s pro Lieferung) durch eine tick-getriebene Zustandsmaschine ersetzt (`begin_transaction()`/`tick()`),
- nur eine aktive Transaktion gleichzeitig (Serialisierung), ACK-Timeout bricht sofort ab und blockiert alles,
- FUELs Lieferschleife startet jetzt höchstens eine Ventil-Lieferung pro Zyklus statt mehrere hintereinander zu blockieren,
- bestehender Sicherheitsschutz (ungültiger Baum verweigert Aktion) vollständig erhalten.

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
- last-good Snapshots bleiben erhalten,
- ENERGY-P0-Schedulergruppentrennung durch Codeanalyse verifiziert (keine Codeänderung nötig, siehe Abschnitt 7) — Comms/Heartbeat/Commands liefen bereits in einer von der Matrix-Coroutine unabhängigen eigenen Coroutine.

## Installer

- gesamter `/xreactor/config`-Ordner wird vor jedem Löschen rekursiv gesichert (Denylist statt Allowlist),
- Backup wird sofort zurückgelesen und byte-genau verifiziert, bevor `/xreactor` gelöscht werden darf,
- Minimal-Restore (`role.lua`, `remote_update.lua`, `node_id.txt`) sofort nach Neuanlage des Roots,
- vollständiger Config-Restore nach erfolgreicher Installation, ebenfalls byte-genau verifiziert,
- Recovery-Backup bleibt bei fehlgeschlagener Wiederherstellung erhalten statt gelöscht zu werden,
- Fix identisch in `xreactor/installer/init.lua` und im tatsächlich ausgeführten Live-Pfad in `/installer` angewendet (inkl. der eingebetteten `init_src`-Kopie).

## Tests / CI

- `tests/cc_env_shim.lua` (os.epoch/colors/package.path-Kompatibilitaet fuer Host-Lua),
- `tools/run_lua_tests.sh`/`tools/run_python_tests.sh` in `.github/workflows/offline-tests.yml` eingebunden,
- explizite, kategorisierte Ausschlussliste fuer 77 Lua- und 9 Python-Tests (`tests/known_failing_*_tests.txt`),
- 5 Tests mit fest kodiertem `/workspace/...`-Pfad auf repo-relative Pfade korrigiert (2 laufen dadurch jetzt grün).

## RT

- `RECEIVE_TIMEOUT` von 0.5s auf 0.1s gesenkt — Control-Tick läuft jetzt mit 10 Hz statt 2 Hz,
- `reactor_adjust_interval`/`reactor_adjust_interval_individual` von 5.0s/1.0s auf 0.10s gesenkt,
- Turbinen-Flow-Write dedupliziert (identischer Zielwert wird nicht erneut geschrieben), Overspeed-Bypass bleibt sofort wirksam,
- `setActive`-Write (Reaktor + Turbine) im Control-Hotpath dedupliziert (RT-P1).

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

- identische `setActive`-, Flow-, Coil- und Rod-Writes vollständig unterdrücken:
  - **Flow** (Turbine): BEHOBEN, siehe RT-P0-Abschnitt oben.
  - **Rod**: war bereits vorher korrekt (`ctrl.last_applied == clamped`-Schutz).
  - **Coil/Inductor**: war bereits vorher korrekt (`engaged == ctrl.inductor_engaged`-Schutz).
  - **setActive** (Reaktor + Turbine): **BEHOBEN (2026-07-14)**. `reactor_control.lua`s `M.setReactorActive()` und `turbine_control.lua`s `M.setTurbineActive()` riefen `setActive()` bisher bei jedem Control-Tick unbedingt auf, obwohl der Aufrufer in `turbine_control.lua`s `updateControl()` immer denselben Zielwert (`true`) verlangt — seit der 10-Hz-Cadence (RT-P0) wären das 10 statt vorher 2 redundante Hardware-Writes pro Sekunde und Gerät gewesen. Beide Funktionen akzeptieren jetzt einen optionalen `ctrl`-Parameter (`reactor_ctrl[name]`/`turbine_ctrl_store[name]`) und unterdrücken den Write bei unverändertem Zielwert; die beiden tatsächlichen Hotpath-Aufrufstellen in `updateControl()` übergeben jetzt `ctrl`. Rückwärtskompatibel: andere Aufrufer ohne `ctrl` (z. B. `module_lifecycle.lua`s `M.set_reactors_active`/`M.set_turbines_active`, event-getriebene Zustandswechsel, nicht Teil des 10-Hz-Pfads) verhalten sich unverändert. `module_lifecycle.lua`s `M.process_startup()` (ebenfalls unbedingte `setActive`-Aufrufe) wird aktuell von keiner Stelle im Code aufgerufen (toter Pfad) — nicht angefasst, da nicht erreichbar.

Noch zu prüfen und mit Metriken abzuschließen (nicht Teil dieser Umsetzung):

- Capability-Cache exakt einmal pro Discoverygeneration,
- Singular-/Plural-Kind-Namen normalisieren,
- gezielte Invalidierung bei Attach/Detach,
- gemeinsamer nicht-sicherheitskritischer Snapshot für UI und Telemetrie,
- stabilen Discovery-Default nach erfolgreichem Boot verlangsamen.

Funktional verifiziert (Mock-Test gegen die echten, aus den Quelldateien extrahierten Funktionen): erster Aufruf schreibt, 20 wiederholte Aufrufe mit demselben Zielwert erzeugen 0 weitere Writes, ein echter Wertwechsel schreibt sofort, Aufrufe ohne `ctrl` bleiben unbedingt (Rückwärtskompatibilität), fehlende `setActive`-Capability verhält sich wie zuvor.

---

# 7. ENERGY-P0 – Schedulergruppen isolieren

## Status

**WEITGEHEND ERLEDIGT (verifiziert 2026-07-14, kein Codeaenderung noetig)**

Bei genauer Prüfung (nicht nur oberflächlicher Statuscheck) ist diese Anforderung bereits durch bestehenden Code erfüllt — vermutlich aus einer früheren, in diesem Dokument nicht nachgetragenen Iteration. Kein Fix in dieser Runde nötig; unten dokumentiert, WAS bereits welche Gruppe abdeckt, damit der Status nicht erneut als offen missverstanden wird.

Zielgruppen und ihre tatsächliche Umsetzung:

```text
1. Comms + Heartbeat + Commands  -> nodes/energy/heartbeat.lua, eigene Coroutine
2. Matrix-Sampling               -> nodes/energy/matrix.lua, eigene Coroutine
3. Storage-Sampling               -> services:add(matrix_sampling_service "STORAGE_SAMPLE"),
                                      eigener Service mit last-good-Cache
4. UI + Telemetrie                 -> services:add(ui_service "UI") + telemetry_service "TELEMETRY",
                                      eigener Model-Cache mit stale-Kennzeichnung
5. Discovery                       -> services:add(discovery_service "DISCOVERY"),
                                      eigener Due-Check, in Tick-Reihenfolge vor Matrix
```

`nodes/energy/main.lua` startet über `parallel.waitForAny(heartbeat_mod.run, matrix_mod.run)` zwei komplett getrennte Coroutinen. `heartbeat.lua` ruft `ctx.comms:handle_event(event)` und `ctx.comms.tick()` **direkt**, unabhängig vom gemeinsamen Service-Manager — ein blockierender Matrix-Peripheral-Call in der anderen Coroutine (`matrix.lua`, die das explizit darf, siehe deren Kopfkommentar "DARF blockieren — Peripheral-Calls können 1-4s dauern") verzögert Comms/Heartbeat/Commands dadurch strukturell nicht. DISCOVERY und STORAGE_SAMPLE sind im gemeinsamen Service-Manager VOR MATRIX_SAMPLE registriert und damit in jedem Zyklus unabhängig von dessen Laufzeit bereits bedient, bevor Matrix überhaupt an der Reihe ist. `storage_snapshot_runtime.lua` hält pro Storage einen `last_good`-Wert plus Backoff für durchgehend fehlschlagende Geräte (ENERGY-P1, bereits umgesetzt). `ui_model.lua` cached das gebaute UI-Model nach Alter (`max_age_ms`) und gibt bei einer noch nicht fälligen Aktualisierung einfach das letzte Model zurück, statt neu (und ggf. blockierend) zu bauen.

## Bekannte, verbleibende Einschränkung

Ein einzelner, tatsächlich synchron blockierender Peripheral-Call (z.B. 4s) friert für seine gesamte Dauer die komplette Lua-VM des Computers ein — CC:Tweaked/Lua-Coroutinen sind kooperativ, nicht präemptiv, `parallel.waitForAny` kann eine andere Coroutine nicht resumen, solange die aktive nicht an einen `os.pullEvent()`/`os.sleep()`-Yield-Punkt zurückkehrt. Das ist eine Plattformgrenze, keine Codeschwäche, und in reinem Lua nicht auflösbar. Die bestehende Budget-/Zeitlimit-Logik in `matrix_snapshot_runtime.lua` (`matrix_metric_call_budget`, `metric_time_budget_ms`) begrenzt, wie VIELE solcher Calls pro Tick versucht werden, kann aber die Dauer eines einzelnen, bereits laufenden Calls nicht unterbrechen.

Kleinere, nicht sicherheitsrelevante Redundanz: `comms` ist sowohl direkt in `heartbeat.lua` als auch zusätzlich im gemeinsamen Service-Manager registriert (`services:add(comms)`), wodurch `comms:tick()` gelegentlich doppelt läuft. Harmlos, aber nicht bereinigt.

## Pflicht-Test (Ergebnis der Codeanalyse, keine Ingame-Messung)

Einen Matrixadapter mehrere Sekunden blockieren lassen:

- Heartbeat bleibt im erlaubten Intervall — erfüllt (eigene Coroutine, direkter `comms.tick()`-Aufruf).
- Commands werden verarbeitet — erfüllt (direkter `comms:handle_event()`-Aufruf in derselben Coroutine).
- last-good Storage bleibt sichtbar — erfüllt (`storage_snapshot_runtime.lua`).
- UI zeigt stale statt einzufrieren — erfüllt (`ui_model.lua`-Cache + `stale`-Flag).
- Discovery kann später weiterlaufen — erfüllt (eigenständiger Service, eigener Due-Check, unabhängig vom Matrix-Zustand).

Ingame-Nachweis mit einem künstlich verlangsamten Matrix-Adapter steht weiterhin aus (nur Codeanalyse, kein Laufzeittest in dieser Runde).

---

# 8. FUEL / REPROCESSOR – Routing nicht blockierend machen

## Status

**BEHOBEN (2026-07-14)**

Der gemeinsame Router (`nodes/fuel/redstone_router.lua`, von FUEL und REPROCESSOR geteilt) verwendete blockierende Wartephasen: `route_and_act()` rief zwei `os.sleep()`-Aufrufe auf (Settle-Zeit vor dem Export, Offenhaltezeit danach), zusammen üblicherweise 2.05–2.4s **pro Lieferung**. Da FUEL/REPROCESSOR als einzelne Coroutine laufen (kein `parallel.waitForAny`-Split wie bei ENERGY/RT), fror das den gesamten Node für diese Zeit ein — Heartbeat, Commands, UI und Failsafe eingeschlossen. FUELs Lieferschleife konnte das zusätzlich für mehrere Reaktoren pro Zyklus hintereinander tun (mehrere Sekunden bis weit über zehn Sekunden Blockade in einem einzigen Aufruf).

## Umsetzung

`route_and_act()` wurde durch eine tick-getriebene Zustandsmaschine ersetzt:

```text
IDLE          -- kein aktiver Transfer (transaction == nil)
WAIT_SETTLE   -- Pfad geöffnet, wartet auf Settle-Zeit (0.05s lokal / 0.4s Netzwerk-Ventil);
                 bricht sofort ab (-> block_all), wenn ein beobachtetes SET_VALVE-Kommando
                 endgültig unbestätigt aufgegeben wird (ACK-Timeout)
EXPORT        -- Aktions-Callback läuft, sobald Settle-Zeit erreicht ist (Teil des WAIT_SETTLE-Ticks)
HOLD_OPEN     -- Ventil bleibt für valve_open_ms offen
COMPLETE/IDLE -- block_all(), Transaktion wird gelöscht, Router wieder frei
ERROR         -- sofortiger Abbruch (ungültiger Baum, kein Pfad, ACK-Timeout) -> block_all()
```

- `M:begin_transaction(target_id, action_fn, valve_open_ms)` startet die Transaktion nicht-blockierend und gibt sofort zurück (`true`/`false, reason`).
- `M:tick(now_ms)` treibt eine laufende Transaktion voran — muss regelmäßig aus dem normalen Event-Loop aufgerufen werden (`nodes/fuel/main.lua`, `nodes/reprocessor/main.lua`, jetzt beide alle ~0.5s), **kein** `os.sleep()` mehr irgendwo im Pfad.
- Nur eine Transaktion gleichzeitig: ein zweiter `begin_transaction()`-Aufruf während eine läuft wird mit `"busy"` abgelehnt — serialisiert Lieferungen strukturell, ohne separate Warteschlange.
- `logistics_router.lua`s Lieferschleife (FUEL, mehrere Reaktoren) kaskadiert weiterhin durch Kandidaten mit unzureichendem ME-Bestand, startet aber pro Zyklus höchstens **eine** tatsächliche Ventil-Lieferung (bricht bei `"busy"` sofort ab, da ohnehin kein weiterer Kandidat gleichzeitig über denselben Ventilbaum beliefert werden könnte).
- `feed_router.lua`s Zyklus (REPROCESSOR) war bereits Ein-Ziel-pro-Tick; nutzt jetzt `begin_transaction()` statt der blockierenden Funktion, überspringt sauber bei `"busy"`.
- Alter Sicherheitsschutz vollständig erhalten: ungültiger/kaputter Baum verweigert die Aktion weiterhin hart (`invalid_tree`), nur ein genuin nie konfigurierter Baum erlaubt Direkt-Export (`direct_export`).
- `M:shutdown_now()` als sofortiger Not-Aus-Pfad ergänzt (verwirft eine laufende Transaktion, blockiert augenblicklich alles) — aktuell nicht an einen bestehenden Shutdown-Befehl gebunden, da FUEL/REPROCESSOR keinen solchen Befehl von MASTER kennen; REPROCESSORs bestehender `standby`-Zustand lässt eine laufende Transaktion stattdessen sauber zu Ende laufen (kein neuer Export startet, offene Ventile werden trotzdem fristgerecht wieder blockiert).
- `M:get_active_transaction()` für Sichtbarkeit ergänzt (Ziel + Zustand); Fehler werden weiterhin per `log("ERROR", ...)`/`warn_once` sichtbar gemacht.

Betroffene Dateien: `xreactor/nodes/fuel/redstone_router.lua`, `xreactor/nodes/fuel/logistics_router.lua`, `xreactor/nodes/fuel/main.lua`, `xreactor/nodes/reprocessor/feed_router.lua`, `xreactor/nodes/reprocessor/main.lua`.

## Anforderungen

- kein `os.sleep()` im normalen Routingpfad — erfüllt.
- Heartbeat, Commands, UI und Failsafe bleiben aktiv — erfüllt (kein blockierender Aufruf mehr im gesamten Pfad).
- ACK-Timeout führt zu `BLOCK_ALL` — erfüllt (siehe `_fail_transaction()`).
- Shutdown blockiert sofort alle Ventile — teilweise: `shutdown_now()` existiert, ist aber an keinen bestehenden Shutdown-Befehl angebunden (keiner existiert für FUEL/REPROCESSOR); `standby` lässt laufende Transaktionen kontrolliert auslaufen statt abrupt abzubrechen.
- Lieferungen werden serialisiert oder klar budgetiert — erfüllt (max. eine aktive Transaktion).
- aktive Transaktion und Fehler sind sichtbar — erfüllt (`get_active_transaction()`, Fehler-Logging).

Funktional verifiziert (Mock-Test gegen den echten State-Machine-Code, siehe `xreactor/nodes/fuel/redstone_router.lua`): kein `os.sleep()`-Aufruf über den gesamten Lebenszyklus; Happy Path (WAIT_SETTLE → Aktion → HOLD_OPEN → block_all/IDLE); zweiter Transaktionsversuch während einer laufenden wird abgelehnt; ACK-Timeout bricht sofort ab statt bis zum Settle-Ende zu warten; nie konfigurierter Baum exportiert direkt; konfigurierter aber ungültiger Baum verweigert die Aktion hart. Ingame-Nachweis mit echter Hardware (Paketverlust, echte Ventil-Latenz) steht weiterhin aus.

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

**TEILWEISE BEHOBEN (2026-07-14)**

`.github/workflows/offline-tests.yml` führte bisher nur den Offline-Validator aus. Die funktionalen Dateien unter `tests/` wurden nicht automatisch ausgeführt.

## Umsetzung

1. `tests/cc_env_shim.lua`: minimaler CC:Tweaked-Kompatibilitäts-Shim (`os.epoch`, `colors`, `package.path` für `xreactor/`), da Host-Lua kein CC:Tweaked ist. Enthält bewusst keine Testlogik, nur Umgebung.
2. `tools/run_lua_tests.sh` / `tools/run_python_tests.sh`: führen jede `tests/*.lua` bzw. `tests/*.py` einzeln in einem eigenen Prozess aus (kein gemeinsamer globaler State zwischen Tests), mit dem Shim vorgeladen. Explizit ausgeschlossene Tests werden übersprungen, alles andere **muss** grün sein, sonst schlägt der Schritt fehl.
3. `tests/known_failing_lua_tests.txt` / `tests/known_failing_python_tests.txt`: **explizite, begründete Ausschlussliste** (kein stiller Skip) — jeder Eintrag hat eine Kategorie (`STALE_API`, `STALE_STRUCTURE`, `NEEDS_MOCK`, `CONTENT_DRIFT`, `SYNTAX_ERROR`, `DUPLICATE_MANIFEST_PATH`) und wurde durch tatsächliches Ausführen aller Tests unter `lua5.2`/`python3` (identisch zur CI-Umgebung) ermittelt.
4. `.github/workflows/offline-tests.yml`: zwei neue Schritte nach dem Offline-Validator, die beide Runner ausführen. Der Workflow triggert bereits auf `push`/`pull_request` für `main`/`beta` — als **Pflichtstatuscheck** muss das zusätzlich in den Branch-Protection-Regeln des Repos aktiviert werden (Repo-Einstellung, nicht per Workflow-Datei änderbar).
5. Fünf Tests hatten eine fest kodierte, umgebungsfremde absolute Pfadangabe (`/workspace/ExtreamReactor-Controller-V3/...`) statt eines repo-relativen Pfads — korrigiert; zwei davon liefen danach direkt grün, drei zeigten echte, unabhängige Content-Abweichungen (jetzt in der Ausschlussliste als `CONTENT_DRIFT`/`STALE_API` dokumentiert).

## Ergebnis

- Lua: 58 von 135 laufen grün, 77 explizit ausgeschlossen und begründet.
- Python: 19 von 28 laufen grün, 9 explizit ausgeschlossen und begründet.
- Offline-Validator: vollständig grün unter `lua5.2` (die zuvor unter Host-`lua5.1` beobachteten Parse-Fehler waren ein reines Lua-5.1-vs-5.2-goto/label-Artefakt, nicht in der echten CI-Umgebung reproduzierbar).

## Noch offen

- Die 86 explizit ausgeschlossenen Tests sind **nicht repariert**, nur ehrlich dokumentiert und aus dem Pflicht-Grün-Pfad herausgenommen — jede einzelne Datei braucht eine gezielte Einzelfallprüfung (echte Regression vs. veraltete Erwartung vs. fehlendes Mock), das würde den Rahmen dieser Umsetzung sprengen. Priorität für Folgearbeit: die vier `is_master_connected`-Tests (`rt_control_service_tick_stability_test.lua`, `rt_main_state_context_guard_test.lua`, `rt_master_startup_off_state_regression_test.lua`, `rt_state_handler_context_wiring_test.lua`) zeigen ein wiederkehrendes, konsistentes Muster und sind der wahrscheinlichste Kandidat für einen echten (nicht nur veralteten) Fix.
- `core/bootstrap.lua` ist doppelt in `xreactor/manifest.lua` gelistet (eigenständiger Bug, verursacht 2 der Ausschlüsse) — noch nicht behoben.
- Rollenweise Jobgruppen (separate CI-Jobs pro Rolle) nicht umgesetzt — alle Tests laufen aktuell in einem Job.
- Keine Tests wurden gelöscht; die im Original geforderte "Löschregel"-Prüfung (Abschnitt 12) wurde für keinen der ausgeschlossenen Tests einzeln durchgeführt.

Wichtige Testgruppen (aus der ursprünglichen Vorgabe, ob sie tatsächlich existieren wurde nicht einzeln geprüft):

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
