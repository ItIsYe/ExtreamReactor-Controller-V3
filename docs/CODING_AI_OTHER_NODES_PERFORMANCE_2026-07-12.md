# Aktueller Gesamt-Audit – XReactor Controller V3

Stand: 2026-07-15  
Branch: `beta`  
Geprüfter ausführbarer Code-Head: `954022dba39c296da988254f9e49c6262553eb96`  
Geprüfte Release: `beta-v434` / `manifest-v434`

## Zweck

Diese Datei ist die aktuelle allgemeine Aufgabenquelle für Coding-AI und manuelle Prüfungen. Sie enthält ausschließlich:

- bestätigte offene Fehler,
- teilweise umgesetzte Punkte,
- neu hinzugekommene Regressionen,
- verbindliche Prioritäten,
- notwendige Tests und Abnahmekriterien.

Die Prüfung erfolgte statisch anhand des tatsächlichen Codes auf `beta`. Commitmeldungen wurden nicht als Beweis übernommen. Echte Peripheral-, Netzwerk-, Neustart- und Update-Eigenschaften müssen zusätzlich in CC:Tweaked/Ingame nachgewiesen werden.

---

# 1. Gesamtstatus

| Bereich | Tatsächlicher Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Benutzerconfig | **TEILWEISE BEHOBEN** | Config-Persistenz erledigt (GLOBAL-P0); Source-Pinning/CRC-Verify/Quiesce-Koordination laut `CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md` weiterhin offen |
| Shared Runtime | **BEHOBEN** | Events dürfen keine periodischen Vollticks auslösen — erledigt (SHARED-P0); Event-Koaleszierung/ENERGY-Attach-Detach-Kopplung bleibt Teil von Abschnitt 7 |
| MASTER | **WEITGEHEND ERLEDIGT** | Broadcast an alle FUEL-/WATER-Nodes einer Rolle erledigt (MASTER-P1); kritischer Startup-Sequencer-Aufrufbug behoben (MASTER-P2, Abschnitt 12); konkreten Einzelnode gezielt auswählen + echte ACK-Bestätigung bleibt offen |
| RT | **WEITGEHEND ERLEDIGT** | 10-Hz-Cadence + Flow-/setActive-Write-Dedup + Capability-Cache/Kind-Namen/Attach-Detach-Invalidierung/Discovery-Default-Slowdown erledigt (RT-P0/P1); kein separater 20-Hz-Scheduler-Layer, kein koaleszierter Command-Tick; gemeinsamer UI/Telemetrie-Snapshot bewusst nur dokumentiert (siehe Abschnitt 6) |
| ENERGY | **WEITGEHEND ERLEDIGT** | Ingame-Nachweis mit künstlich verlangsamtem Matrixadapter steht aus; Architektur bereits verifiziert isoliert |
| WATER | **WEITGEHEND ERLEDIGT** | Ingame- und Update-Regressionsnachweis |
| FUEL | **WEITGEHEND ERLEDIGT** | Routing ohne blockierende Sleeps erledigt (Abschnitt 8); Ingame-Nachweis mit echter Hardware steht aus |
| REPROCESSOR | **WEITGEHEND ERLEDIGT** | Routing ohne blockierende Sleeps erledigt (Abschnitt 8); Ingame-Nachweis mit echter Hardware steht aus |
| VALVE | **WEITGEHEND ERLEDIGT** | Paketverlust/Reconnect ingame nachweisen |
| LOG Collector | **WEITGEHEND ERLEDIGT** | Renderer ohne Laufzeit-Quelltextpatch erledigt (LOG-P2, Abschnitt 10); Paketverlust/Reconnect ingame nachweisen |
| Tests / CI | **TEILWEISE BEHOBEN** | Runner + explizite Ausschlussliste läuft in CI (76/142 Lua, 20/28 Python grün); 6 Tests in dieser Runde behoben; 74 Tests bleiben einzeln zu triagieren |
| Dokumentation | **BEREINIGT** | künftig nur eine aktuelle Aufgabenquelle pflegen |
| Installer / Benutzerconfig | **TEILWEISE UMGESETZT** | Manifest und Dateien aus demselben Commit laden; CRC beim Schreiben prüfen |
| Shared Runtime | **WEITGEHEND UMGESETZT** | ENERGY verwendet weiterhin einen Volltick aller Services im Matrix-Thread |
| MASTER | **TEILWEISE OFFEN** | Einzelnode-Auswahl und echte Command-/ACK-Auswertung |
| RT | **TEILWEISE UMGESETZT** | bestehende 1-/5-s-Konfigurationen auf 0,1 s migrieren und echte Deadline-Metriken nachweisen |
| ENERGY | **FEHLERHAFT TEILWEISE** | Matrix-Thread tickt alle Services und sendet Heartbeats zu häufig |
| WATER | **WEITGEHEND UMGESETZT** | Ingame-, Neustart- und Update-Regressionsnachweis |
| FUEL | **KRITISCH FEHLERHAFT** | möglicher Startabsturz, unsichere ACK-State-Machine, fehlerhafte Async-Anbindung |
| REPROCESSOR | **KRITISCH FEHLERHAFT** | fehlende Installationsdatei, unsichere Routing-/Standby-Transaktion |
| VALVE | **TEILWEISE UMGESETZT** | fehlgeschlagene Writes dürfen nicht als dedupliziert abgeschlossen gelten |
| LOG Collector | **TEILWEISE UMGESETZT** | Probe-Fehler darf niemals automatisch alle Logs löschen |
| Tests / CI | **TEILWEISE UMGESETZT** | 77 Lua- und 9 Python-Tests sind weiterhin ausgeschlossen |
| Dokumentation | **AKTUELL** | diese Datei künftig nach jedem Code-Audit aktualisieren |

---

# 2. Bestätigt umgesetzt – nicht ohne konkreten Regressionstest erneut umbauen

## Installer / Configbestand

- `/xreactor/config` wird vor dem Löschen rekursiv gesichert.
- Das Recovery-Backup liegt außerhalb von `/xreactor`.
- Backup und Restore werden bytegenau verifiziert.
- `.xr_tmp` und `.xr_prev` werden als regenerierbare Zwischenstände ausgeschlossen.
- `role.lua`, `remote_update.lua` und `node_id.txt` werden früh wiederhergestellt.
- Das Recovery-Backup bleibt bei einem fehlgeschlagenen Restore erhalten.

## Shared Runtime

- Event-getriebene Aufrufe des Service-Managers ticken nur Services mit `wants_events=true`.
- COMMS und UI melden ihre Eventabhängigkeit explizit an.
- normale Discovery-, Telemetrie- und periodische Services werden durch Modem- oder Touchbursts nicht mehr automatisch vollständig ausgeführt.

## WATER

- ein gemeinsamer generationsbasierter Tank-Snapshot ist vorhanden,
- Tankwerte werden innerhalb der Snapshot-Altersgrenze wiederverwendet,
- bei unbekanntem Tankstand gilt `BLOCK_ALL`,
- Clusterstate wird erst nach bestätigtem Redstone-Write geändert,
- bei Teilfehlern wird bestmöglich ein sicherer Ausgangszustand hergestellt,
- `SET_TARGET` wird in der kanonischen WATER-Config persistiert,
- das aktuelle UI-Model wird an die Seite übergeben,
- der doppelte `router_touch`-Pfad wurde entfernt.

## RT

- SAFE-Recovery besitzt jetzt einen verdrahteten `setState`-Pfad,
- Capability-Scans werden nicht mehr bei jedem normalen Zugriff neu aufgebaut,
- Ziel-RPM im Monitor stammt aus dem Turbinenregler,
- Release-/Manifestinformationen werden nicht mehr im Render-Hotpath neu geladen,
- Turbinen-Flow und `setActive` werden teilweise dedupliziert,
- neue Defaults für Reactor-Control stehen auf 0,10 Sekunden.

## VALVE

- Standard-CC:Tweaked-Indizes für `modem_message` sind korrigiert,
- Ventilstate wird erst nach erfolgreichem `redstone.setOutput()` geändert,
- ACK, Command-ID und Dedupe-Grundmechanismus existieren,
- Boot-Fail-Safe und 20-s-Stale-Fail-Safe sind vorhanden.

## MASTER

- persistente PEAK-/IDLE-Schwellwerte,
- AUTO-UPDATE-Schalter steuert die echte lokale Updaterconfig,
- Terminal-`mouse_click`,
- stale RT-Fuelwerte werden nicht mehr als frisch weitergereicht,
- weniger wiederholte Modelserialisierung,
- kein DEBUG-Log pro erfolgreichem Frame,
- `set_fuel_reserve`/`set_water_target` senden jetzt an ALLE Nodes der jeweiligen Rolle statt nur an den ersten per `pairs()` gefundenen (MASTER-P1, siehe Abschnitt 9); sichtbare Fehlermeldung im Alarm-Log, falls keine passende Node existiert.
- **KRITISCH**: `startup_sequencer.lua`s `enqueue`/`tick`/`notify_ack`/`notify_stable`/`handle_timeout` waren Punkt-definiert, wurden aber überall (inkl. intern) per Doppelpunkt aufgerufen — das automatisch injizierte Objekt landete dadurch in jedem echten Argument, `enqueue()` fügte nie einen Node zur Warteschlange hinzu. Die gesamte MASTER-gesteuerte Startup-Sequenzierung war dadurch wirkungslos. Behoben durch Umstellung auf Doppelpunkt-Definition (MASTER-P2, siehe Abschnitt 12).
- FUEL-Reserve und WATER-Ziel werden an alle passenden Nodes der Rolle gesendet,
- Terminal-`mouse_click` ist vorhanden,
- stale RT-Fuelwerte werden nicht mehr einfach mit einem frischen Messzeitstempel weitergereicht,
- häufige identische Modelserialisierung und Frame-Debuglogs wurden reduziert.

## LOG Collector

- Batch-Writes existieren,
- ACK erfolgt erst nach bestätigter Persistierung,
- wichtige Fehlerlevel können sofort geflusht werden,
- Dedupe verwendet einen Ring-/Indexansatz,
- der Renderer wird als normales Modul geladen und nicht mehr durch Sourcecode-Textpatching eingebaut.

## Tests / CI

- `.github/workflows/offline-tests.yml` startet Offline-Validator, Lua-Runner und Python-Runner.
- Jeder nicht ausgeschlossene Test muss erfolgreich sein.
- Ausschlüsse sind in `tests/known_failing_lua_tests.txt` und `tests/known_failing_python_tests.txt` sichtbar dokumentiert.

---

# 3. FUEL-P0.1 – Frische FUEL-Installation kann im Config-Normalizer abstürzen

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

- `RECEIVE_TIMEOUT` von 0.5s auf 0.1s gesenkt — Control-Tick läuft jetzt mit 10 Hz statt 2 Hz,
- `reactor_adjust_interval`/`reactor_adjust_interval_individual` von 5.0s/1.0s auf 0.10s gesenkt,
- Turbinen-Flow-Write dedupliziert (identischer Zielwert wird nicht erneut geschrieben), Overspeed-Bypass bleibt sofort wirksam,
- `setActive`-Write (Reaktor + Turbine) im Control-Hotpath dedupliziert (RT-P1),
- Capability-Cache berechnet neue Geräte jetzt gezielt statt bei jeder Bindungsänderung alle gebundenen Geräte neu, entfernt abgehängte Geräte statt sie für immer im Cache zu behalten,
- `get_device_caps()` normalisiert Singular- ("reactor"/"turbine") und Plural-Kind-Namen ("reactors"/"turbines") auf denselben Cache-Schlüssel,
- Discovery-Scan verlangsamt sich nach 3 unveränderten Scans in Folge auf effektiv 60s statt 10s, springt bei echter Attach-/Detach-Änderung sofort zurück auf die normale Kadenz.
`nodes/fuel/config_normalizer.lua` initialisiert:

```lua
lg.reactors
lg.waste
```

aber nicht:

```lua
lg.destinations
```

Anschließend wird ausgeführt:

```lua
for i, dest in ipairs(lg.destinations) do
```

Die aktuelle FUEL-Defaultkonfiguration enthält ebenfalls kein `destinations`-Feld.

## Folge

Bei einer frischen Installation beziehungsweise einer Config ohne `logistics.destinations` kann die Node bereits während der Normalisierung mit `ipairs(nil)` abbrechen.

## Verbindlicher Fix

```lua
if type(lg.destinations) ~= "table" then lg.destinations = {} end
if type(lg.sources)      ~= "table" then lg.sources      = {} end
if type(lg.routes)       ~= "table" then lg.routes       = {} end
```

Danach alle später iterierten Felder vor der Iteration normalisieren.

## Pflicht-Test

- FUEL mit leerer Benutzerconfig starten.
- FUEL mit aktueller Quelldefaultconfig starten.
- FUEL mit `logistics={}` starten.
- Alle drei Varianten müssen ohne Fehler bis `Node ready` gelangen.

---

# 4. INSTALL-P0.1 – REPROCESSOR wird unvollständig installiert

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

`nodes/reprocessor/main.lua` benötigt:

```lua
require("nodes.reprocessor.feed_router")
```

Der Manifest-Eintrag für:

```text
nodes/reprocessor/feed_router.lua
```

besitzt keinen passenden `required_for={"REPROCESSING"}`-Scope.

`installer/manifest.lua` nimmt Rollen-Dateien jedoch nur auf, wenn:

- `always=true`, oder
- `required_for` zur gewählten Rolle passt.

## Folge

Eine vollständige REPROCESSING-Installation beziehungsweise ein Reinstall kann `main.lua` installieren, `feed_router.lua` aber auslassen. Der Start endet dann am fehlenden `require()`.

## Verbindlicher Fix

- Manifest-Eintrag mit `required_for={"REPROCESSING"}` versehen.
- denselben Fix in der eingebetteten Manifestkopie des monolithischen `/installer` anwenden.
- zusätzlich einen automatischen Entrypoint-Require-Coverage-Test einführen.

## Pflicht-Test

1. leeres Dateisystem,
2. Rolle REPROCESSING wählen,
3. Installationsdateiliste erzeugen,
4. alle statischen `require()`-Abhängigkeiten von `nodes/reprocessor/main.lua` müssen vorhanden sein,
5. Start mit Mock-Peripherals darf nicht an fehlender Datei scheitern.

---

# 5. ROUTER-P0 – Export erst nach vollständig bestätigter Ventilstellung

## Status

**KRITISCH OFFEN**

## Bestätigter Safetyfehler

Die neue tick-getriebene State-Machine startet nach der kurzen Settle-Zeit den Export, obwohl ein Ventil-ACK noch `pending` sein kann. Die Settle-Zeit liegt deutlich unter dem ACK-Timeout.

Damit kann der Export beginnen, bevor bestätigt ist, dass das Zielventil wirklich offen ist.

Zusätzlich werden derzeit primär Ventile des geöffneten Zielpfads als ACK-kritisch betrachtet. Das erfolgreiche Blockieren aller Nebenwege ist jedoch ebenso sicherheitsrelevant.

## Sicherheitsregel

Export ist ausschließlich erlaubt, wenn für **alle betroffenen Ventile** gilt:

```text
ACK empfangen
applied == true
confirmed_state == requested_state
Zielpfad offen
alle Nebenpfade blockiert
ACK nicht stale
```

## Ziel-State-Machine

```text
IDLE
REQUEST_BLOCK_ALL
WAIT_BLOCK_ACKS
REQUEST_OPEN_TARGET
WAIT_OPEN_ACKS
WAIT_SETTLE
EXPORT
HOLD_OPEN
REQUEST_BLOCK_FINAL
WAIT_FINAL_ACKS
COMPLETE / ERROR
```

## Abbruchbedingungen

- irgendein NACK,
- irgendein Timeout,
- VALVE offline/stale,
- Zielventil nicht bestätigt offen,
- irgendein Nebenventil nicht bestätigt blockiert,
- MASTER-/Standby-/Shutdown-Abbruch,
- Exportcallback-Fehler.

Bei jedem Abbruch:

```text
kein Export
bestmöglich block_all
Fehler sichtbar in UI/Telemetrie/Log
Transaktion endet kontrolliert
```

---

# 6. FUEL-P0.2 – Async-Lieferung verliert `current_request`

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

FUEL setzt vor dem Transaktionsstart ein `current_request`-Objekt. Der spätere Exportcallback greift darauf zu. Direkt nach dem erfolgreichen Start der asynchronen Transaktion wird `current_request` jedoch wieder auf `nil` gesetzt.

Wenn der Callback später ausgeführt wird, kann ein Nil-Zugriff entstehen.

Zusätzlich werden Exportmenge, Erfolgsstatus und Zykluslog in lokalen Variablen nach dem Rücksprung aus dem ursprünglichen Tick verändert. Diese Werte werden dadurch nicht zuverlässig in Statistik und Log übernommen.

## Verbindlicher Fix

Die Transaktion bekommt einen dauerhaft lebenden Kontext:

```lua
transaction = {
  request = request,
  reactor = reactor,
  started_ts = now,
  exported = 0,
  state = "ROUTING",
}
```

Callbacks dürfen nur diesen Transaktionskontext ändern. `current_request` wird erst bei `COMPLETE` oder `ERROR` entfernt.

Statistik und Zykluslog werden im Abschlusscallback geschrieben, nicht im Starttick.

## Pflicht-Tests

- erfolgreicher asynchroner Export,
- Exportcallback-Fehler,
- ACK-Timeout vor Export,
- Shutdown während `WAIT_OPEN_ACKS`,
- korrekte Exportmenge in Statistik,
- `current_request` bleibt bis zum Abschluss sichtbar.

---

# 7. FUEL/REPROC-P0.3 – Ungültiges Routing darf nie in direkten Export fallen

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

Der FUEL-Logistikrouter entscheidet vor dem Transaktionsstart anhand von:

```lua
rs:route_count() > 0
```

ob geroutet oder direkt exportiert wird.

Ein ungültiger Baum kann null aktive Routen ergeben. Dadurch wird `begin_transaction()` gar nicht aufgerufen und dessen Invalid-Tree-Schutz umgangen. Stattdessen kann direkter Export erfolgen.

**WEITGEHEND BEHOBEN (2026-07-15)** — von den fünf ursprünglich offenen Folgepunkten sind vier behoben, einer (gemeinsamer UI/Telemetrie-Snapshot) bewusst nur dokumentiert und zurückgestellt (siehe Nachtrag unten).
Beim REPROCESSOR besteht der gleiche Sicherheitsgrundsatz: Eine vorhandene, aber unlesbare oder ungültige persistente Routendatei darf nicht wie „Routing wurde nie konfiguriert“ behandelt werden.

## Verbindliche Zustände

```text
ROUTING_NOT_CONFIGURED
ROUTING_VALID
ROUTING_INVALID
ROUTING_REQUIRED_BUT_EMPTY
```

## Umsetzung (2026-07-15, Nachtrag)

- **Capability-Cache exakt einmal pro Discoverygeneration** + **gezielte Invalidierung bei Attach/Detach**: **BEHOBEN.** `discovery_runtime.lua`s `M.cache()` (läuft nur bei echter Bindungsänderung, siehe `refresh_bindings()`s `binding_signature`-Vergleich) rief bisher trotzdem für JEDES aktuell gebundene Gerät `build_capabilities()` neu auf, unabhängig davon ob sich dieses konkrete Gerät geändert hatte — bei z. B. 25 Turbinen und dem Attach/Detach einer einzigen liefen alle 25 `peripheral.getMethods()`-Scans erneut. Zusätzlich blieben Cache-Einträge abgehängter Geräte für immer stehen (unbegrenztes Wachstum bei häufig umgesteckter Hardware). Neue Funktion `refresh_capability_cache()` berechnet jetzt nur wirklich neue Namen, lässt bereits gecachte unangetastet und entfernt nicht mehr gebundene Namen aus dem Cache. Funktional verifiziert (`tests/rt_capability_cache_targeted_invalidation_test.lua`): erster Durchlauf berechnet alle Geräte, zweiter (unveränderter) Durchlauf berechnet nichts erneut, dritter Durchlauf (ein Gerät detached, eins neu attached) berechnet nur das neue Gerät und entfernt das abgehängte aus dem Cache.
- **Singular-/Plural-Kind-Namen normalisieren**: **BEHOBEN.** Die Discovery-/Binding-Logik (`binding.lua`, Modul-`type`-Felder) verwendet durchgehend den Singular (`"reactor"`/`"turbine"`), während `capability_cache`/`get_device_caps()` intern den Plural (`"reactors"`/`"turbines"`) als Cache-Schlüssel erwarten. Alle bestehenden Aufrufstellen trafen zufällig die richtige Form, aber ein künftiger Aufruf mit dem im Rest des Codes üblichen Singular hätte still einen separaten, nie befüllten Cache-Namensraum erzeugt (kein Fehler, aber der Cache griffe nie). `turbine_control.lua`s `get_device_caps()` normalisiert jetzt beide Schreibweisen auf denselben Cache-Schlüssel. Funktional verifiziert (`tests/rt_get_device_caps_kind_normalization_test.lua`): singularer und pluraler Aufruf für dasselbe Gerät treffen denselben Cache-Eintrag, kein zusätzlicher Namensraum entsteht.
- **Gemeinsamer nicht-sicherheitskritischer Snapshot für UI und Telemetrie**: **UNTERSUCHT, NICHT UMGESETZT (bewusst zurückgestellt).** Bestätigt: `main.lua`s `build_status_payload()` (Telemetrie/Master-Payload) und `monitor_ui.lua`s `M.update()` → `M.update_status_snapshot()` (Monitor-Anzeige) bauen unabhängig voneinander je einen vollen Geräte-Snapshot pro Tick, jeder mit eigenem vollständigem `reactor_adapter.inspect()`/`turbine_adapter.inspect()`-Durchlauf über ALLE gebundenen Geräte — `status_snapshot.lua`s `build_turbine_snapshots`/`build_reactor_snapshots` einerseits, `monitor_ui.lua`s `collect_reactor_temp_stats`/`build_turbine_status_details`/`build_reactor_status_details` andererseits. `nodes/rt/startup_diagnostics.lua` ruft zusätzlich `ctx.update_status_snapshot()` auf einem dritten Pfad. Das ist eine echte, aber rein durch Performance motivierte Redundanz (keine Fehlfunktion, keine falschen Werte) — ein Merge zu einem gemeinsamen Snapshot wäre ein tieferer Eingriff in UI- und Telemetriecode mit echtem Risiko für die Live-Operator-Anzeige, der nur per Mock-Test (kein CC:Tweaked/Minecraft verfügbar) abgesichert werden könnte. Auf Nutzerentscheidung hin bewusst nicht umgesetzt; präzise dokumentiert für eine spätere Runde mit Ingame-Verifikationsmöglichkeit.
- **Stabilen Discovery-Default nach erfolgreichem Boot verlangsamen**: **BEHOBEN.** `discover()` lief bisher fest alle `config.scan_interval` (10s) für immer, unabhängig davon ob sich die gebundenen Geräte seit Ewigkeiten nicht mehr geändert hatten — jeder Lauf scannt `peripheral.getNames()` plus `getMethods()`/`getType()`/`adapter.inspect()` für jedes sichtbare Gerät. Nutzt den bereits vorhandenen `should_discover`-Erweiterungspunkt von `services/discovery_service.lua` (keine Änderung am geteilten Service nötig, der auch von WATER/FUEL/etc. genutzt wird): nach 3 unveränderten Scans in Folge (`binding_signature` bleibt gleich) wird nur noch jeder 6. fällige Scan tatsächlich ausgeführt (effektiv 60s statt 10s im stabilen Zustand); eine echte Bindungsänderung (Attach/Detach) setzt den Zähler sofort auf die normale Kadenz zurück. Funktional verifiziert (`tests/rt_discovery_stable_slowdown_test.lua`): Boot-Phase scannt bei jedem fälligen Tick, nach Erreichen der Stabilitätsschwelle läuft genau 1 von 6 fälligen Ticks, eine echte Änderung setzt sofort zurück.
Direkter Export ist nur zulässig, wenn ausdrücklich konfiguriert ist:

```lua
routing_required = false
allow_direct_export = true
```

Sobald eine Routendatei vorhanden ist, ein Baum konfiguriert wurde oder Routing als erforderlich gilt, führt jeder ungültige/leere Zustand zu hartem Exportstopp.

---

# 8. VALVE-P0 – Fehlgeschlagener Write darf nicht dedupliziert abgeschlossen werden

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

Die VALVE-Node merkt eine `command_id`, bevor feststeht, ob `apply_valve()` erfolgreich war.

Schlägt der physische Write fehl, sendet der Router dieselbe Command-ID erneut. Die VALVE-Node erkennt das Kommando dann als bereits gesehen und führt keinen erneuten Write aus.

## Folge

Retry ist ausgerechnet beim Writefehler wirkungslos.

## Verbindlicher Fix

Eine Command-ID wird nur als erfolgreich abgeschlossen gespeichert, wenn:

```text
Write erfolgreich
Istzustand entspricht Sollzustand
ACK applied=true wurde erzeugt
```

Fehlgeschlagene Commands benötigen getrennten Zustand:

```lua
seen[id] = {
  requested_high = high,
  applied = false,
  last_error = err,
  attempts = n,
}
```

Ein Retry derselben ID muss den Write erneut ausführen, solange `applied ~= true`.

`last_command_ts` darf den Offen-Fail-Safe nur bei einem erfolgreich angewendeten beziehungsweise bestätigten sicheren Kommando verlängern. Ein fehlgeschlagenes BLOCK-Kommando darf ein offenes Ventil nicht weitere 20 Sekunden offen halten.

---

# 9. REPROC-P0 – Standby muss aktive Transaktion abbrechen

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

REPROCESSOR setzt bei MASTER-Timeout `standby=true`, tickt den gemeinsamen Redstone-Router danach aber weiterhin.

Eine bereits laufende Transaktion kann dadurch nach dem Eintritt in Standby noch aus `WAIT_SETTLE` in den Export wechseln.

## Verbindlicher Fix

Beim Wechsel nach Standby, MASTER_STALE, SAFE oder Shutdown:

```lua
feed_router:cancel("MASTER_STALE")
redstone_router:shutdown_now("MASTER_STALE")
```

Danach:

- keine Exportcallbacks mehr ausführen,
- alle Ventile bestmöglich blockieren,
- aktive Transaktion als abgebrochen protokollieren,
- erst nach bestätigtem MASTER-Reconnect eine neue Transaktion zulassen.

---

# 10. ENERGY-P0 – Matrix-Thread ist nicht vollständig isoliert

## Status

**KRITISCH OFFEN**

## Bestätigter Fehler

`nodes/energy/matrix.lua` ruft weiterhin:

```lua
ctx.services:tick()
```

auf. Damit führt der vermeintliche Matrix-Thread nicht nur Matrix-Sampling aus, sondern potenziell:

- Discovery,
- Storage-Sampling,
- Matrix-Sampling,
- Telemetrie,
- UI,
- COMMS-Maintenance.

Langsame Matrix-Calls können diese Services im Matrix-Thread gemeinsam verzögern.

## Heartbeatfehler

Nach jedem Matrixdurchlauf wird direkt:

```lua
ctx.send_heartbeat(ctx.now_ms())
```

aufgerufen. Die zentrale `send_heartbeat()`-Funktion prüft das konfigurierte Intervall nicht selbst.

Bei `receive_timeout_s=0.5` können dadurch ungefähr alle 0,5 Sekunden Heartbeats gesendet werden, obwohl standardmäßig 2 Sekunden konfiguriert sind. Der separate Heartbeat-Thread existiert zusätzlich.

## Verbindlicher Fix

Der Matrix-Thread ruft ausschließlich einen dedizierten Matrixscheduler auf:

```lua
matrix_service:tick_due(now)
```

Keine vollständige `services:tick()`-Ausführung.

Heartbeat nur über:

```lua
heartbeat:send_if_due(now)
```

mit einer einzigen zentralen `last_sent_ts`-Quelle.

## Pflicht-Test

Ein künstlicher 4-Sekunden-Matrixcall darf:

- COMMS-Empfang nicht blockieren,
- Heartbeatabstand nicht vervielfachen,
- UI-Touch nicht blockieren,
- Storage-/Discovery-Deadlines nicht unkontrolliert verschieben,
- keine zusätzlichen Heartbeats erzeugen.

---

# 11. RT-P0 – Bestehende alte Taktwerte migrationssicher ersetzen

## Status

**KRITISCH OFFEN FÜR BESTEHENDE INSTALLATIONEN**

## Bestätigtes Problem

Neue Defaults stehen auf 0,10 Sekunden. Bereits persistierte Werte wie:

```lua
reactor_adjust_interval = 5.0
reactor_adjust_interval_individual = 1.0
```

bleiben aber gültige Zahlen und werden vom Normalizer nicht ersetzt.

Die allgemeine Default-Migration ergänzt nur fehlende Felder; sie ändert keine vorhandenen Altwerte.

## Folge

Neue Installationen können ungefähr mit dem gewünschten Grundtakt arbeiten, aktualisierte Bestandsnodes jedoch weiterhin nur alle 1 beziehungsweise 5 Sekunden.

## Verbindlicher Fix

## Noch offen (2026-07-15, vertieft untersucht)
Configschema erhöhen und gezielt migrieren:

```lua
if old_version < TARGET_VERSION then
  if value == nil or value == 5.0 then value = 0.10 end
  if individual == nil or individual == 1.0 then individual = 0.10 end
end
```

Benutzerdefinierte bewusst abweichende Werte dürfen nicht blind überschrieben werden. Dafür entweder:

- Auswahl eines KONKRETEN Zielnodes (statt nur "alle Nodes der Rolle" oder "erster Node"), falls mehrere FUEL/WATER-Nodes tatsächlich unterschiedliche Reserven/Ziele haben sollen — würde eine neue Auswahl-UI-Komponente in `master/ui/config_editor.lua` (Live-Operator-Touchscreen) benötigen,
- gespeicherte beziehungsweise eindeutig nachvollziehbare Auswahl, falls ein konkreter Zielnode eingeführt wird.

**Echte ACK-/Applied-Bestätigung — genauer untersucht, bewusst nicht umgesetzt.** `core/comms.lua` verfolgt ausstehende Commands zwar bereits intern (`state.inflight[message_id]`, `handle_ack()` löscht den Eintrag bei `ACK_APPLIED` und loggt das Ergebnis), aber es gibt **keine** Callback- oder Abfrage-Schnittstelle, über die ein Aufrufer wie `set_fuel_reserve`/`set_water_target` (synchron in `runtime_loop.lua`) das Ergebnis eines konkreten, vorher gesendeten Commands später erfährt — die Bestätigung landet aktuell ausschließlich als Log-Zeile, nirgendwo abfragbar. Eine echte Lösung bräuchte eine neue Callback-/Ergebnis-Tracking-Schnittstelle in `core/comms.lua` — einem von JEDER Rolle (RT/ENERGY/WATER/FUEL/REPROCESSOR/MASTER/LOG) gemeinsam genutzten Kernmodul. Das ist ein tiefer Eingriff in die gemeinsame Comms-Schicht mit echtem Risiko für alle Rollen, nur per Mock-Test absicherbar (kein CC:Tweaked/Minecraft verfügbar) — dasselbe Risikoprofil wie der zurückgestellte gemeinsame UI/Telemetrie-Snapshot (Abschnitt 6). Auf Basis derselben Entscheidung (siehe dort) bewusst nicht umgesetzt, präzise dokumentiert für eine spätere Runde mit Ingame-Verifikationsmöglichkeit.

Für die typische Konfiguration (genau eine FUEL- und eine WATER-Node) sind alle drei Punkte nicht sicherheitskritisch.
- bekannte historische Defaultwerte erkennen, oder
- ein `control_cadence_mode`/explizites Migrationsflag verwenden.

## Pflicht-Metriken

- Control-Ticks/s,
- Reactor-Regler-Ticks/s,
- Turbinen-Regler-Ticks/s,
- maximale Ticklücke,
- Write-Skips,
- Deadlineüberschreitungen.

---

# 12. INSTALL-P0.2 – Manifest und Dateien müssen aus demselben Commit stammen

## Status

**OFFEN**

## Bestätigtes Problem

Der Installer kann:

- das Manifest vom aktuellen `beta`-Branch laden,
- einen separat ermittelten SHA für Dateien verwenden.

Sind Branchmanifest und Datei-SHA nicht identisch, kann ein gültiger älterer Dateiinhalt gegen Metadaten des neueren Manifests geprüft werden.

## Verbindlicher Fix

1. Branch-SHA einmal auflösen.
2. Manifest ausschließlich von genau diesem SHA laden.
3. alle Dateien ausschließlich von demselben SHA laden.
4. Release-/Manifest-SHA im Installationsreport anzeigen.
5. Branch-Fallback nur als vollständiger neuer Installationsversuch, niemals gemischt innerhalb eines Laufs.

---

# 13. INSTALL-P0.3 – CRC32 beim tatsächlichen Schreiben verifizieren

## Status

**OFFEN**

## Bestätigtes Problem

`installer/manifest.lua` besitzt CRC32-Prüfung. `installer/stage.lua` prüft nach dem Download jedoch nur:

- Dateigröße,
- Lua-Syntax.

Der im Manifest vorhandene Hash wird dort nicht ausgewertet.

- Lua: 76 von 142 laufen grün, 66 explizit ausgeschlossen und begründet.
- Python: 20 von 28 laufen grün, 8 explizit ausgeschlossen und begründet.
- Offline-Validator: vollständig grün unter `lua5.2` (die zuvor unter Host-`lua5.1` beobachteten Parse-Fehler waren ein reines Lua-5.1-vs-5.2-goto/label-Artefakt, nicht in der echten CI-Umgebung reproduzierbar).

## Seit dem letzten Stand behoben (2026-07-15)

- **`core/bootstrap.lua` doppelt in `xreactor/manifest.lua`**: war einmal in `base_files` (ohne `always=true`) und einmal explizit unter `roles.log` gelistet — Letzteres war ein Workaround, weil `installer/manifest.lua`s `build_expected()` für die LOG-Rolle alle nicht-`always`-`base_files`-Einträge überspringt (LOG installiert bewusst nicht den vollen Basis-Dateisatz). Fix: `core/bootstrap.lua`s `base_files`-Eintrag bekommt jetzt `always=true` (wie andere Kernabhängigkeiten, z. B. `release.lua`, `start.lua`), der redundante `roles.log`-Eintrag wurde entfernt. `manifest_integrity_consistency_test.lua`/`manifest_hash_size_guard_test.py` laufen jetzt grün, ohne Verhaltensänderung für andere Rollen.
- **Die vier `is_master_connected`-Tests**: bei genauer Prüfung stellte sich heraus, dass `is_master_connected` in der echten Runtime bereits korrekt verdrahtet war — die Tests bauten lediglich unvollständige Mock-Kontexte (fehlendes `is_master_connected`/`set_current_state` in der ctx-Tabelle), die an `state_handlers.lua`s eigenem, bereits vorher vorhandenem `assert_fn`-Guard scheiterten. Die Mocks wurden ergänzt; zusätzlich bekam `nodes/rt/main.lua` einen expliziten Guard + Diagnose-Log (`"State context ready (is_master_connected=true)"`) beim Aufbau des State-Context, bevor `state_handlers.build()` aufgerufen wird — redundant zum generischen Guard in `state_handlers.lua`, aber mit klarerem, RT-spezifischem Fehlertext für Operator-Logs.
- **KRITISCHER Fund während dieser Prüfung, unabhängig vom `is_master_connected`-Muster**: `rt_master_startup_off_state_regression_test.lua`s dritter Testblock deckte einen echten, weitreichenden Bug in `xreactor/master/startup_sequencer.lua` auf — siehe eigener Abschnitt 12 (MASTER-P2). Das ist der bei weitem wichtigste Fund dieser Runde.
- **Sechs weitere Tests einzeln triagiert und behoben** (von den ursprünglich 86 explizit ausgeschlossenen): `registry_dirty_test.lua`/`registry_io_test.lua` (`SYNTAX_ERROR`) enthielten einen Lua-5.3-only-Bitoperator-Fallback (`&`/`~`/`<<`), der die gesamte Testdatei unter dem CI-Interpreter `lua5.2` gar nicht erst parsen ließ — entfernt, da `lua5.2` `bit32` bereits nativ bereitstellt (von `core/registry.lua`s Hash-Funktion ohnehin genutzt). `master_message_handler_node_id_canonicalization_test.lua`/`master_shutdown_degraded_semantics_test.lua`/`master_status_recovery_semantics_test.lua` (`STALE_API`, "mark_rt_sync_dirty required") bauten `message_handlers.new({...})`-Mocks ohne das inzwischen per `assert()` geforderte `mark_rt_sync_dirty`-Feld — echte, aber unvollständige Mocks, kein Produktivbug; ergänzt. `master_energy_aggregation_test.lua` (`NEEDS_MOCK`) erwartete ein `captured.nodes`-Feld im Energy-View-Model, das echte Feld heißt `support_nodes` (`ui_controller.lua` Zeile 326) — Test korrigiert.
- Rollenweise Jobgruppen (separate CI-Jobs pro Rolle) weiterhin nicht umgesetzt — alle Tests laufen aktuell in einem Job.
- Keine Tests wurden gelöscht; die im Original geforderte "Löschregel"-Prüfung (Abschnitt 13) wurde für keinen der ausgeschlossenen Tests einzeln durchgeführt.
- Die verbleibenden 66 (Lua) + 8 (Python) ausgeschlossenen Tests sind weiterhin **nicht** einzeln triagiert — größtenteils `CONTENT_DRIFT` (echtes aktuelles Verhalten, Ursache noch nicht verifiziert) und `NEEDS_MOCK` (echtes CC:Tweaked-Peripheral/Monitor-Global nötig, kein pauschaler Shim möglich). Das ist weiterhin ein offener, potenziell mehrstündiger Folgeaufwand.
## Fix

`stage.verify()` muss zusätzlich den Manifest-Hash gegen den geschriebenen Inhalt prüfen. Dieselbe Implementierung muss im modularen Installer und in der eingebetteten `/installer`-Kopie gelten.

## Pflicht-Test

Eine Datei mit korrekter Größe, gültiger Lua-Syntax, aber verändertem Inhalt muss die Installation zuverlässig abbrechen.

---

# 14. LOG-P0 – Probe-Fehler darf kein Logarchiv löschen

## Status

**KRITISCH OFFEN**

## Bestätigtes Problem

Wenn `probe_disk()` beim Schreibtest fehlschlägt, wird aktuell der gesamte Ordner:

```text
<xreactor_logs>
```

rekursiv geleert und danach erneut getestet.

Ein Probe-Fehler kann aber auch durch temporäre Ursachen entstehen:

- Disk kurzzeitig nicht verfügbar,
- Mountproblem,
- volles Medium,
- I/O-Fehler,
- Race beim Ein-/Ausstecken.

## Folge

Ein transienter Fehler kann das gesamte bestehende Logarchiv löschen.

## Verbindlicher Fix

- niemals vorhandene Logs automatisch löschen,
- nur die eigene `.probe`-Datei entfernen,
- Disk als `UNAVAILABLE`, `READ_ONLY`, `FULL` oder `IO_ERROR` markieren,
- neue Logs puffern oder auf andere Disk ausweichen,
- Löschen alter Logs nur durch explizite Retentionpolicy mit Mindestalter/Maximalgröße.

---

# 12. MASTER-P2 – Startup-Sequencer Punkt-/Doppelpunkt-Aufrufbug (KRITISCH)

## Status

**BEHOBEN (2026-07-15)**

`xreactor/master/startup_sequencer.lua`s `sequencer.new()` definierte `enqueue`, `tick`, `notify_ack`, `notify_stable` und `handle_timeout` per **Punkt-Syntax** (`function self.enqueue(node_id, reason)` usw.), wurde aber **ausnahmslos** per **Doppelpunkt-Syntax** aufgerufen:

- `xreactor/master/housekeeping.lua:62`: `runtime.refs.sequencer:tick(runtime.state.nodes)`
- `xreactor/master/message_handlers.lua:404,474,479,509`: `sequencer:enqueue(id)`, `sequencer:notify_stable(...)`, `sequencer:notify_ack(...)`
- `xreactor/master/runtime_ops_rt.lua:116`: `runtime.refs.sequencer:enqueue(node.id, "DEMAND_STARTUP")`
- intern in `startup_sequencer.lua` selbst: `self:handle_timeout(nodes, "WAITING_ACK", elapsed)` / `self:handle_timeout(nodes, "WAITING_STABLE", elapsed)`

Ein Doppelpunkt-Aufruf (`obj:f(a, b)`) übergibt in Lua das Objekt selbst automatisch als **erstes** Argument (äquivalent zu `obj.f(obj, a, b)`). Da die Funktionen aber KEINEN `self`-Parameter deklarierten, landete das Sequencer-Objekt selbst in `node_id` (bei `enqueue`), in `nodes` (bei `tick`) bzw. in `nodes`/`stage`/`elapsed_ms` (bei `handle_timeout`) — jedes echte Argument rutschte um eine Position weiter.

**Praktische Auswirkung**: `enqueue()`s eigene Typprüfung (`type(node_id) ~= "string" and type(node_id) ~= "number"`) griff bei jedem echten Aufruf, weil `node_id` jetzt eine Tabelle (das Sequencer-Objekt) statt eines Node-Namens war — die Funktion loggte höchstens eine WARN-Zeile und **fügte nie etwas zur Warteschlange hinzu**. `tick()` erhielt statt der echten Node-Registry das Sequencer-Objekt selbst als `nodes`, wodurch Node-Lookups intern ins Leere liefen. `handle_timeout()` (Eskalation bei Startup-Timeout auf `LIMITED`/`EMERGENCY`) erhielt bei jeder Auslösung vertauschte, falsche Argumente. Insgesamt: die MASTER-gesteuerte, sicherheitsrelevante Startup-Sequenzierung (Turbinen vor Reaktoren, ein Modul nach dem anderen, ACK- und Stabilitäts-gated) war **komplett wirkungslos**, solange sie über den normalen Aufrufpfad angestoßen wurde — unabhängig davon, seit wann dieser Zustand bestand.

Entdeckt als Nebenbefund beim Beheben des dritten `is_master_connected`-Testblocks in `rt_master_startup_off_state_regression_test.lua` (Abschnitt 11): der Test scheiterte nach den ersten beiden Fixes weiterhin, mit einem Ergebnis, das erst nach genauer Analyse des tatsächlichen Aufrufmusters erklärbar war (nicht durch einen einfachen Backoff-Timing-Effekt, wie zunächst vermutet).

## Umsetzung

1. `xreactor/master/startup_sequencer.lua`: `enqueue`, `tick`, `notify_ack`, `notify_stable`, `handle_timeout` von Punkt- auf Doppelpunkt-Definition umgestellt (`function self:enqueue(...)` usw.) — passt jetzt zum tatsächlichen Aufrufmuster überall im Code, ohne dass ein einziger Aufrufer geändert werden musste. `build_steps` blieb Punkt-definiert, da es ausschließlich intern per Punkt-Syntax aufgerufen wird (`self.build_steps(nodes)`).
2. Funktionaler Regressionstest `tests/master_startup_sequencer_colon_call_test.lua` (neu): ruft ausschließlich per Doppelpunkt auf (wie die echten Aufrufer) und deckt den kompletten Lebenszyklus ab — `enqueue` → `tick` (sendet `STARTUP_STAGE`) → `notify_ack` → `notify_stable`, sowie separat den `handle_timeout`-Pfad (Timeout während `WAITING_ACK` löst eine `MODE`-Eskalation aus und setzt den Sequencer zurück).
3. `tests/rt_master_startup_off_state_regression_test.lua`s dritter Testblock (ursprünglich ein brüchiger Text-Grep gegen `xreactor/nodes/rt/main.lua` nach einem Transitions-Aufruf, der dort nie existierte, weil diese Logik tatsächlich in `state_handlers.lua`s `apply_mode()` lebt) wurde durch einen echten Funktionstest gegen `state_handlers.apply_mode()` ersetzt.

Betroffene Dateien: `xreactor/master/startup_sequencer.lua`, `tests/rt_master_startup_off_state_regression_test.lua` (plus die drei anderen `is_master_connected`-Mock-Fixes, siehe Abschnitt 11).

## Anforderungen (Abnahme)

- `enqueue()` fügt bei jedem echten (Doppelpunkt-)Aufruf tatsächlich einen Eintrag zur Warteschlange hinzu — funktional verifiziert.
- `tick()` erhält die echte Node-Registry und sendet `STARTUP_STAGE` sobald ein Modul bereit ist (MASTER-Modus, Modul `OFF`) — funktional verifiziert.
- `notify_ack()`/`notify_stable()` treiben den Zustand `WAITING_ACK` → `WAITING_STABLE` → `IDLE` korrekt voran — funktional verifiziert.
- `handle_timeout()` eskaliert bei Ablauf von `timeout_s` korrekt auf eine `MODE`-Eskalation und setzt den Sequencer zurück — funktional verifiziert.
- Ingame-Nachweis mit echter RT-Node-Flotte (mehrere Nodes, mehrere Module, echte ACK-/Stable-Meldungen über das Netzwerk) steht weiterhin aus.

---

# 13. Dokumentations- und Repository-Bereinigung
# 15. MANIFEST-P1 – Rollen- und optionale Dateien vollständig scopen

## Status

**OFFEN**

Zusätzlich zum fehlenden REPROCESSOR-`feed_router` müssen alle Manifestdateien überprüft werden:

- statische Entrypoint-Abhängigkeiten,
- `required_for`,
- `always`,
- optionale Features,
- doppelte Pfade.

Bestätigt beziehungsweise bereits in der Testausschlussliste sichtbar:

- `core/bootstrap.lua` ist doppelt im Manifest enthalten,
- `optional/speaker_alarm.lua` besitzt keinen klaren Rollen-Scope und kann trotz Auswahl nicht in der Installationsmenge landen,
- mehrere Manifest-Rollenscope-Tests sind wegen Content-Drift ausgeschlossen.

## Pflicht-Test

Für jede installierbare Rolle:

1. erwartete Dateiliste erzeugen,
2. alle Entrypoint-`require()`- und `dofile()`-Abhängigkeiten transitiv prüfen,
3. keine fehlende Datei,
4. keine doppelten Manifestpfade,
5. optionale Auswahl ändert die Dateiliste tatsächlich,
6. nicht ausgewählte optionale Dateien fehlen tatsächlich.

---

# 16. MASTER-P1 – Zielnode und echte Bestätigung

## Status

**TEILWEISE OFFEN**

Das Senden an alle Nodes einer Rolle ist umgesetzt. Weiter offen:

- konkreten einzelnen FUEL-/WATER-Node auswählen,
- „alle Nodes“ explizit anzeigen,
- Command-ID und ACK je Zielnode sichtbar auswerten,
- Teilfehler darstellen,
- persistente UI-Auswahl für den Zielnode.

Eine Meldung „gesendet“ darf nicht mit „vom Ziel angewendet“ gleichgesetzt werden.

---

# 14. Priorität

1. vollständige Config-Persistenz des Installers,
2. Event- und Timerpfad trennen,
3. echte RT-10-Hz-Cadence,
4. funktionale Testsuite in CI,
5. ENERGY-Schedulergruppen isolieren,
6. nicht blockierendes FUEL-/REPROCESSOR-Routing,
7. restliche RT-Hotpath-Arbeit,
8. MASTER-Multi-Node-Auswahl,
9. LOG-Renderer-Schnittstelle,
10. Startup-Sequencer Punkt-/Doppelpunkt-Aufrufbug (MASTER-P2, kritisch — erledigt).

---

# 15. Definition of Done

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
# 17. TEST-P0 – Ausschlusslisten abbauen

## Status

**KRITISCH TEILWEISE**

Der Workflow führt funktionale Tests aus, überspringt aber weiterhin:

```text
77 Lua-Tests
9 Python-Tests
```

Die Ausschlussliste enthält nicht nur sicher veraltete Tests, sondern auch Kategorien wie:

- `CONTENT_DRIFT`,
- `DUPLICATE_MANIFEST_PATH`,
- mögliche echte RT-Contextfehler,
- Manifest-Rollenscope-Abweichungen,
- ENERGY-Architekturabweichungen.

## Regel

Ein Test darf nur gelöscht werden, wenn:

1. die geschützte Anforderung nicht mehr existiert, oder
2. dieselbe Anforderung vollständig durch einen aktuellen gleichwertigen Test geschützt wird.

Andernfalls:

- Test auf aktuelle API migrieren,
- notwendige CC:Tweaked-Mocks ergänzen,
- echten Produktionsfehler beheben,
- aus Ausschlussliste entfernen.

## Sofortige Priorität

1. FUEL-Config-Starttest,
2. REPROCESSOR-Installations-/Require-Coverage,
3. Router-ACK-Safety,
4. FUEL-Async-Lifecycle,
5. VALVE-Failed-Write-Retry,
6. REPROCESSOR-Standby-Cancel,
7. ENERGY-Heartbeat-/Schedulerisolation,
8. RT-Configmigration,
9. Manifest-Duplikate/Rollenscope,
10. Installer-SHA-/CRC-Konsistenz,
11. LOG-Datenerhalt.

Für den geprüften Merge-Commit wurden über die GitHub-Schnittstelle keine zugeordneten Statuschecks beziehungsweise Pull-Request-Workflow-Runs zurückgegeben. Ein vorhandener Workflow ist deshalb kein Nachweis, dass dieser konkrete Head erfolgreich geprüft wurde.

---

# 18. Verbindliche Bearbeitungsreihenfolge

1. **FUEL Config-Normalizer** – Startabsturz verhindern.
2. **REPROCESSOR Manifest-Scope** – `feed_router.lua` sicher installieren.
3. **Router-ACK-Safety** – alle Ziel- und Nebenventile vor Export bestätigen.
4. **FUEL Async-Lifecycle** – `current_request`, Statistik und Abschlusscallback korrigieren.
5. **Invalid-Routing-Hardblock** für FUEL und REPROCESSOR.
6. **VALVE Failed-Write-Retry** und sichere Fail-Safe-Zeitstempel.
7. **REPROCESSOR Standby-Cancel** laufender Transaktionen.
8. **ENERGY Scheduler-/Heartbeat-Trennung**.
9. **RT Altconfig-Migration auf 0,10 s**.
10. **Installer ein SHA + CRC-Verifikation**.
11. **LOG-Probe ohne Datenlöschung**.
12. **Manifest-Duplikate, optionale Dateien und Rollen-Scope**.
13. **MASTER Einzelnode-/ACK-UI**.
14. **Ausschlusslisten Test für Test abbauen**.
15. Danach Ingame-Last-, Reconnect-, Reboot- und Update-Tests.

---

# 19. Definition of Done

## Installer

- Manifest und alle Dateien stammen aus exakt demselben Commit.
- Größe und CRC32 werden nach jedem Write geprüft.
- jede Rolle erhält alle transitiven Entrypoint-Abhängigkeiten.
- Benutzerconfigs und Routen überleben Update, Reinstall und Neustart.
- optionale Auswahl verändert die installierte Dateimenge korrekt.

## FUEL

- frische Defaultconfig startet fehlerfrei.
- kein Export bei ungültigem oder erforderlichem, aber leerem Routing.
- Export erst nach vollständiger Bestätigung aller Ziel- und Nebenventile.
- asynchroner Request bleibt bis COMPLETE/ERROR erhalten.
- Statistik und Logs entsprechen der tatsächlich exportierten Menge.
- Shutdown/Standby/Timeout führen zu block_all und keinem Export.

## REPROCESSOR

- `feed_router.lua` wird immer installiert.
- persistentes Routing wird beim Start korrekt geladen.
- ungültiges Routing blockiert Feed.
- Standby/MASTER_STALE bricht laufende Transaktion ab.
- keine Exportaktion nach Eintritt in Standby.

## VALVE

- fehlgeschlagene Writes werden bei Retry tatsächlich erneut ausgeführt.
- Command-ID gilt erst nach erfolgreichem Apply als abgeschlossen.
- NACK/Fehler bleibt sichtbar.
- ein fehlgeschlagenes BLOCK-Kommando verlängert keinen unsicheren Offen-Zustand.

## RT

- bestehende historische Defaultintervalle werden migrationssicher auf 0,10 s aktualisiert.
- echte Metriken belegen Controlfrequenz und maximale Ticklücke.
- Eventbursts erzeugen keine zusätzlichen vollständigen Controlticks.
- Write-Dedupe und Safety-Bypass bleiben korrekt.

## ENERGY

- Matrix-Thread tickt ausschließlich Matrixarbeit.
- Comms/Heartbeat/UI bleiben bei langsamen Matrixcalls reaktionsfähig.
- genau eine zentrale Heartbeat-Zeitquelle.
- Heartbeatfrequenz entspricht der Config.

## WATER

- Snapshot, Block-All, Writes und persistentes Ziel funktionieren ingame.
- Reboot und Update erhalten Config und Target.
- UI zeigt aktuelle Werte und jeder Touch erzeugt genau eine Aktion.

## MASTER

- alle oder ein konkreter Zielnode auswählbar.
- ACK je Zielnode sichtbar.
- Teilfehler werden nicht als Gesamterfolg dargestellt.

## LOG Collector

- Probe-/Mount-/Full-Fehler löschen keine vorhandenen Logs.
- Retention ist explizit, alters-/größenbasiert und nachvollziehbar.
- ACK erfolgt weiterhin erst nach echter Persistierung.

## Tests / CI

- keine kritischen Produktionsfehler stehen auf einer Ausschlussliste.
- Manifest-/Installations-, Routing-, Safety-, Config- und Reboottests laufen verpflichtend.
- aktueller `beta`-Head besitzt einen nachweislich grünen Statuscheck.
- gelöschte Tests erfüllen die dokumentierte Löschregel.
