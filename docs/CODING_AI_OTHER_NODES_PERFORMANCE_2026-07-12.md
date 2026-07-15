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

Beim REPROCESSOR besteht der gleiche Sicherheitsgrundsatz: Eine vorhandene, aber unlesbare oder ungültige persistente Routendatei darf nicht wie „Routing wurde nie konfiguriert“ behandelt werden.

## Verbindliche Zustände

```text
ROUTING_NOT_CONFIGURED
ROUTING_VALID
ROUTING_INVALID
ROUTING_REQUIRED_BUT_EMPTY
```

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

Configschema erhöhen und gezielt migrieren:

```lua
if old_version < TARGET_VERSION then
  if value == nil or value == 5.0 then value = 0.10 end
  if individual == nil or individual == 1.0 then individual = 0.10 end
end
```

Benutzerdefinierte bewusst abweichende Werte dürfen nicht blind überschrieben werden. Dafür entweder:

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
