# Coding-AI-Aufgaben: FUEL-Node Deep Audit

Stand: 2026-07-12  
Geprüfter Repository-Stand: `c64bd60fabf65ba285d5f0c656d6a6a5e634a3fb`  
Ziel-Branch: `beta`

## Zweck

Diese Datei ist eine erneute, ausschließlich auf die FUEL-Node konzentrierte Prüfung. Sie behandelt Funktion, Sicherheit, Zuverlässigkeit, Performance, UI, Konfiguration, Netzwerkdaten und Ventilrouting.

Sie ergänzt:

- `docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md`
- `docs/CODING_AI_INSTALLER_AUTO_UPDATE_AUDIT_2026-07-12.md`

## Wichtigste Ergebnisse

### P0 – vor produktivem Einsatz beheben

1. Die ausgelieferte FUEL-Konfiguration wird nicht als Tabelle zurückgegeben und deshalb nicht geladen.
2. Selbst ein einfaches Ergänzen von `return CONFIG` kann anschließend im Config-Normalizer abstürzen.
3. Alte Reaktor-Füllstandsdaten können unbegrenzt als frisch weitergereicht werden.
4. Derselbe Füllstand kann in mehreren Lieferzyklen wiederverwendet werden; dadurch sind Mehrfachlieferungen möglich.
5. Ein fehlendes `reactor_id` aktiviert einen unbegrenzten Blindliefermodus.
6. Die Funkventil-Node liest beim Standard-CC:Tweaked-Event die falschen Event-Indizes; `SET_VALVE` wird dadurch nicht korrekt empfangen.
7. FUEL behandelt ein lokales `modem.transmit()` als bestätigte Ventilschaltung und exportiert trotzdem.
8. Fehler beim Blockieren eines nicht gewählten Ventils werden ignoriert; dadurch können mehrere Wege gleichzeitig offen sein.
9. Bei ungültigem Routingbaum werden die alten Ventile vor dem angeblichen `block_all()` aus dem State entfernt; der Blockiervorgang wird zum No-op.
10. Die über die Router-UI gespeicherten Routen werden nach einem Neustart nicht in den aktiven Router geladen.
11. Ein Router-Touch wird doppelt verarbeitet und kann Auswahl beziehungsweise Änderungen sofort wieder rückgängig machen.
12. Ein niedriger oder nicht lesbarer Reservewert wird künstlich auf das Minimum angehoben und dadurch im Status verborgen.
13. Liefer- und Ventilwartezeiten blockieren den gesamten FUEL-Hauptloop.
14. `FUEL_STATUS` wird ohne Prüfung eines autorisierten MASTER-Absenders übernommen.

---

# FUEL-P0.1 – FUEL-Konfiguration tatsächlich ladbar und updatefest machen

## Aktueller Pfad

`nodes/fuel/role_descriptor.lua` setzt:

```lua
config_path = "/xreactor/nodes/fuel/config.lua"
```

`main.lua` lädt diesen Pfad mit:

```lua
utils.load_config(CONFIG.CONFIG_PATH, DEFAULT_CONFIG)
```

Der Loader akzeptiert nur eine vom Lua-Chunk zurückgegebene Tabelle.

## Kritischer Fehler

Die ausgelieferte Datei `nodes/fuel/config.lua` definiert:

```lua
local CONFIG = {
  ...
}
```

Sie endet jedoch ohne:

```lua
return CONFIG
```

Damit liefert der Chunk `nil`. `utils.load_config()` verwirft den Inhalt und verwendet die Defaults aus `main.lua`.

## Konkrete Folgen

- Änderungen in `nodes/fuel/config.lua` greifen nicht.
- Die dokumentierte `DEFAULT_LOGISTICS`-Konfiguration greift nicht.
- `main.lua` besitzt in seinem eigenen `DEFAULT_CONFIG` keinen `logistics`-Block.
- Der Normalizer erzeugt deshalb einen anderen Fallback mit `enabled=false` und anderem Intervall.
- Die Lieferlogik bleibt normalerweise deaktiviert.
- `config_meta.reason` ist gesetzt; `support_runtime.init_logging()` aktiviert deshalb Debug-Logging trotz `debug_logging=false`.
- Das erzeugt unnötige Logs und kann Performance-/Speicherprobleme verstärken.
- Die Datei liegt im Programmverzeichnis und wird bei einem Reinstall überschrieben.

## Zweiter Fehler nach einem naiven Fix

Wird nur `return CONFIG` ergänzt, enthält `CONFIG.logistics` keine Tabelle `destinations`.

`config_normalizer.lua` führt später trotzdem aus:

```lua
for i, dest in ipairs(lg.destinations) do
```

`ipairs(nil)` kann den Start abbrechen.

## Zielarchitektur

1. Ausgelieferte Defaults bleiben unter dem Codepfad, zum Beispiel:

```text
/xreactor/nodes/fuel/default_config.lua
```

2. Veränderbare Benutzerkonfiguration liegt unter:

```text
/xreactor/config/fuel.lua
```

3. `role_descriptor.config_path` verweist auf `/xreactor/config/fuel.lua`.
4. Fehlt die Benutzerdatei, werden die vollständigen Defaults verwendet.
5. Installer/Auto-Update erhalten die Benutzerdatei.
6. Router-Konfiguration kann entweder in dieselbe Datei migriert oder als separate, ebenfalls erhaltene Datei geführt werden.

## Anforderungen an die Default-Tabelle

Sie muss die echten Runtime-Namen enthalten:

```lua
return {
  role = "FUEL-NODE",
  node_id = "FUEL-1",
  storage_bus = "meBridge_0",
  minimum_reserve = 2000,
  logistics = {
    enabled = false,
    interval = 5,
    discovery_interval = 60,
    max_per_cycle = 64,
    me_bridge = "me_bridge",
    reactors = {},
    waste = {},
    redstone_tree = {},
    valve_open_ms = 2000,
  },
}
```

Keine parallelen `DEFAULT_*`-Felder als vermeintliche Benutzerwerte verwenden.

## Abnahmetests

- Ein geändertes `logistics.enabled=true` wird nach Reboot geladen.
- Reaktor- und Waste-Einträge bleiben nach Auto-Update erhalten.
- Fehlt `destinations`, darf der Normalizer nicht abstürzen.
- Ein gültiger Config-Start aktiviert Debug-Logging nicht automatisch.
- Configquelle und Migrationsstatus werden eindeutig im Startlog angezeigt.

---

# FUEL-P0.2 – Veraltete RT-Daten nicht als frisch weiterreichen

## Aktueller Datenweg

```text
RT STATUS
  -> MASTER runtime.state.nodes
  -> master/fuel_relay.lua
  -> FUEL_STATUS Command
  -> fuel_status_network.master_relay
  -> logistics_router
```

Zusätzlich hört FUEL RT-STATUS-Broadcasts direkt mit.

## Fehler im MASTER-Relay

`master/fuel_relay.lua` sammelt Werte aus `runtime.state.nodes`, prüft aber nicht zuverlässig:

- ob der RT-Node down/stale ist
- wann der Reaktorwert ursprünglich gemessen wurde
- ob sich die Messgeneration seit dem letzten Relay geändert hat

Beim Sammeln wird jedes Mal ein neuer Zeitstempel gesetzt.

## Fehler im FUEL-Cache

`ingest_master_relay()` verwirft den vom MASTER gelieferten Ursprungstimestamp und setzt erneut die lokale Empfangszeit:

```lua
ts = now
```

Damit kann ein alter RT-Wert alle zehn Sekunden erneut übertragen werden und für FUEL dauerhaft frisch erscheinen.

## Zusätzlich falsche Quellenauswahl

`logistics_router` wählt die Quelle nach lokaler Empfangszeit. Ein später empfangenes, aber fachlich älteres MASTER-Relay kann dadurch einen frischeren direkt mitgehörten RT-Wert überstimmen.

## Ziel

Jede Reaktormessung benötigt eine eindeutige Messgeneration:

```lua
{
  reactor_id = "...",
  fuel_amount = 1234,
  fuel_capacity = 4000,
  measured_at = 1234567890,
  sample_seq = 4711,
  source_node = "RT-2",
  source_boot_id = "...",
}
```

MASTER darf diese Metadaten weiterreichen, aber nicht durch neue Messzeit ersetzen.

## MASTER-Filter

Nur relayn, wenn:

- RT-Node nicht down ist
- Statusalter unter Grenzwert liegt
- Reaktormessung vollständig und numerisch ist
- Messgeneration zum aktuellen RT-Boot gehört

## FUEL-Auswahl

- Neueste fachliche Messgeneration gewinnt.
- Empfangszeit dient nur als Transportdiagnose.
- Alte Boot-Generation darf eine neue nicht überschreiben.
- Cacheeinträge müssen nach TTL entfernt werden.

## Tests

- RT fällt aus: MASTER darf den letzten Wert nicht unbegrenzt frisch halten.
- altes MASTER-Relay trifft nach neuem Direct-STATUS ein: neuer Direct-Wert bleibt aktiv.
- RT rebootet und Sequenz beginnt neu: Boot-ID trennt die Generationen.

---

# FUEL-P0.3 – Pro Messgeneration höchstens eine Lieferung

## Aktuelles Problem

- Füllstandsdaten gelten bis zu 30 Sekunden als frisch.
- Lieferzyklus läuft standardmäßig alle 5 Sekunden.
- Nach einem Export wartet FUEL nicht auf einen neueren RT-Füllstand.

Dadurch kann derselbe niedrige Messwert theoretisch in mehreren Zyklen erneut eine Lieferung auslösen.

Beispiel:

```text
00s: RT meldet 20 %
01s: FUEL exportiert 64
06s: derselbe Messwert ist noch gültig -> weitere 64
11s: weitere 64
...
```

## Zielzustand pro Reaktor

```lua
{
  last_seen_sample_id = "...",
  last_consumed_sample_id = "...",
  last_export_ts = ...,
  awaiting_confirmation = true,
  exported_amount = 64,
  confirmation_deadline = ...,
}
```

## Regeln

1. Eine Messgeneration darf nur eine normale Lieferentscheidung auslösen.
2. Nach erfolgreichem Export wird `awaiting_confirmation=true` gesetzt.
3. Weitere Lieferung erst nach:
   - neuerer Messgeneration, oder
   - explizitem, streng begrenztem Recovery-Timeout.
4. Der neue Messwert muss plausibel sein.
5. Ein Timeout darf nicht zu unbegrenzten Wiederholungen führen.
6. Globales und per-Reaktor-Limit verwenden.

## Empfohlene Schutzwerte

```lua
supply_cooldown_s = 20
max_unconfirmed_exports = 1
confirmation_timeout_s = 30
max_items_per_reactor_per_minute = 128
```

Werte sind konfigurierbar, aber sichere Defaults sind verpflichtend.

## Tests

- Derselbe Sample-Timestamp über sechs Zyklen -> genau ein Export.
- Neuer Samplewert weiterhin niedrig -> nächster Export erst nach Cooldown/Policy.
- Neuer Samplewert steigt -> Confirmation erfolgreich.
- Keine neue Messung -> kein unbegrenzter Export.

---

# FUEL-P0.4 – Blindliefermodus bei fehlendem `reactor_id` entfernen

## Aktuelles Verhalten

Fehlt `reactor_id`, setzt die Lieferlogik:

```lua
requesting = true
```

Dieser Reaktor wird bei jedem Zyklus als anfordernd behandelt.

## Risiko

Eine unvollständige oder alte Config führt zu regelmäßigen Lieferungen ohne Füllstandskontrolle.

## Ziel

Standardmäßig hart ablehnen:

```text
REACTOR_ID_MISSING
```

Eine bewusste Blindversorgung darf nur über einen ausdrücklich gefährlichen Modus möglich sein:

```lua
allow_blind_supply = false
```

Bei aktivierter Ausnahme zusätzlich:

- langer Cooldown
- sehr kleines Mengenlimit
- sichtbare Warnung/Alarm
- keine automatische Aktivierung durch Legacy-Migration

---

# FUEL-P0.5 – Funkventil-Event korrekt auslesen

## Bestätigter Fehler

Die VALVE-Node verwendet:

```lua
local channel, _, message = event[2], event[3], event[4]
```

Beim Standard-CC:Tweaked-Event gilt:

```text
event[1] = "modem_message"
event[2] = side
event[3] = channel
event[4] = replyChannel
event[5] = message
event[6] = distance
```

Damit vergleicht der aktuelle Code die Modemseite mit der Kanalnummer und liest den Reply-Channel als Nachricht.

## Richtiger Zugriff

```lua
local side = event[2]
local channel = event[3]
local reply_channel = event[4]
local message = event[5]
```

## Test

Realistisches Event:

```lua
{
  "modem_message",
  "back",
  6504,
  6504,
  { type="SET_VALVE", dst="VALVE-1", high=false },
  12,
}
```

muss das Ventil öffnen.

---

# FUEL-P0.6 – Ventilschaltung bestätigen, bevor Fuel exportiert wird

## Aktuelles Problem

FUEL sendet auf dem Ventilkanal fire-and-forget:

```lua
modem.transmit(...)
```

Ein erfolgreiches `pcall()` bedeutet nur, dass der lokale Methodenaufruf nicht geworfen hat. Es bestätigt nicht:

- Empfang durch die VALVE-Node
- richtige Ziel-Node
- erfolgreiches `redstone.setOutput`
- tatsächlichen Ventilzustand

Danach wartet FUEL lediglich 0,4 Sekunden und startet den Export.

## Weiterer Fehler in VALVE

`apply_valve()` setzt `current_high` vor beziehungsweise unabhängig von einem geprüften Redstone-Erfolg. Der Status kann deshalb den gewünschten statt den tatsächlichen Zustand melden.

## Ziel: leichtgewichtiges bestätigtes Ventilprotokoll

Nachricht:

```lua
{
  type = "SET_VALVE",
  src = "FUEL-1",
  dst = "VALVE-1",
  route_id = "...",
  seq = 123,
  high = false,
  lease_ms = 3000,
  token = "...",
}
```

ACK:

```lua
{
  type = "VALVE_ACK",
  src = "VALVE-1",
  dst = "FUEL-1",
  route_id = "...",
  seq = 123,
  requested_high = false,
  applied = true,
}
```

## Regeln

1. FUEL berechnet den vollständigen gewünschten Zustand aller beteiligten Ventile.
2. Befehl an jedes Ventil senden.
3. Auf ACK aller Ventile warten.
4. Export nur, wenn alle Ziel- und Sperrventile bestätigt sind.
5. Bei Timeout alles blockieren und keinen Export ausführen.
6. Blockierbefehle wiederholen, bis bestätigt oder Fail-safe übernimmt.
7. Duplicate/alte Sequenzen ignorieren.
8. Nur autorisierten FUEL-Absender akzeptieren.

## Lease statt 20-Sekunden-Offenfenster

Ein Öffnen enthält eine kurze Lease. Nach Ablauf blockiert die VALVE-Node selbstständig, auch wenn der Schließbefehl verloren geht.

Die Lease sollte knapp über dem erwarteten Transferfenster liegen, nicht pauschal 20 Sekunden.

---

# FUEL-P0.7 – Jeder nicht gewählte Weg muss sicher blockiert sein

## Aktueller Fehler

`open_path_to()` markiert nur einen Fehler beim Öffnen eines Ventils auf dem Zielpfad als Routingfehler:

```lua
if should_be_open and not ok then
  path_open_failed = true
end
```

Schlägt dagegen das Blockieren eines Ventils außerhalb des Zielpfades fehl, wird weitergemacht.

## Risiko

Ein altes oder zweites Ventil kann offen bleiben. Der anschließende Export kann mehrere Reaktorwege erreichen.

## Ziel

Jeder gewünschte Ventilzustand ist Teil der Freigabebedingung:

```lua
if not ok then routing_failed = true end
```

Bei bestätigtem Zustandsprotokoll gilt:

- genau Zielpfad offen
- alle anderen Ventile blockiert
- erst dann `exportItemToPeripheral`

---

# FUEL-P0.8 – Ungültiger Routingbaum muss alte Ventile wirklich blockieren

## Aktueller Fehler

Bei ungültigem Baum macht `refresh()` sinngemäß:

```lua
self._state.all_valves = {}
self._state.integrators = {}
self:block_all()
```

`block_all()` sieht dadurch keine Ventile mehr und schaltet nichts.

## Risiko

Ventile aus einer vorher gültigen Konfiguration können in ihrem letzten Zustand verbleiben.

## Richtige Reihenfolge

```lua
local old_valves = self._state.all_valves
local old_integrators = self._state.integrators
block_using(old_valves, old_integrators)
self._state.all_valves = {}
self._state.integrators = {}
```

Bei fehlender Bestätigung:

- Routingstatus `FAULT`
- keine Fuel-Lieferung
- Alarm an MASTER

## Zweiter Fehler

`logistics_router` prüft nur:

```lua
rs:route_count() > 0
```

Ist der Baum ungültig, ist die Routenzahl 0 und die Logik fällt auf direkten Export zurück.

Es muss unterschieden werden:

```text
DISABLED       kein Routing gewünscht, Direktpfad erlaubt
READY          Routing gültig
INVALID        kein Export
DEGRADED       kein Export
```

---

# FUEL-P0.9 – Router-Konfiguration nach Neustart tatsächlich aktivieren

## Aktuelle Datenpfade

Die UI speichert nach:

```text
/xreactor/config/fuel_routes.lua
```

Beim Erzeugen der UI werden diese Routen in `router_ui._ui.routes` geladen.

Der operative `redstone_router` liest dagegen:

```lua
config.logistics.redstone_tree
```

Die gespeicherte Datei wird beim Boot nicht in `config.logistics.redstone_tree` übernommen. Erst ein erneuter Klick auf „Speichern“ kopiert die UI-Routen in den In-Memory-Router.

## Folge

- UI kann gespeicherte Routen anzeigen.
- Operativer Router kann gleichzeitig ohne diese Routen laufen.
- Nach Reboot sind sie nicht aktiv.

## Zusätzlich inkonsistente Feldnamen

Die ausgelieferte Config dokumentiert/verwendet teilweise:

```lua
redstone_routes
```

Der Router erwartet:

```lua
redstone_tree
```

## Ziel

Eine einzige kanonische Quelle:

```text
/xreactor/config/fuel_routes.lua
```

oder vollständig integriert in `/xreactor/config/fuel.lua`.

Beim Boot:

1. Datei laden.
2. Struktur validieren.
3. In operativen Router übernehmen.
4. alle Ventile blockieren.
5. Routingstatus veröffentlichen.

Legacyfeld `redstone_routes` einmalig nach `redstone_tree` migrieren.

---

# FUEL-P0.10 – Doppelverarbeitung von Router-Touches entfernen

## Aktueller Pfad 1

Der normale `ui_service` ruft bei einem Touch auf:

```lua
fuel_monitor_ui.handle_input(event)
```

Diese Funktion ruft:

```lua
monitor_router:handle_input(event)
M.handle_touch(x, y)
```

## Aktueller Pfad 2

`main.lua` registriert zusätzlich:

```lua
services:add({ name = "router_touch", ... handle_monitor_touch(...) })
```

Damit wird derselbe seitenspezifische Touch ein zweites Mal verarbeitet.

## Konkrete Auswirkung

Bei Auswahl einer Redstone-Seite:

1. erster Aufruf wählt sie aus
2. zweiter Aufruf erkennt dieselbe Auswahl und entfernt/deselektiert sie wieder

Die Router-Konfiguration kann dadurch praktisch unbedienbar sein.

## Ziel

Nur ein Inputpfad. Der separate `router_touch`-Service wird entfernt.

## Test

Ein physischer Touch erzeugt exakt einen Aufruf von `router_ui:handle_touch()`.

---

# FUEL-P0.11 – Reale Reserve nicht künstlich anheben

## Aktuelles Verhalten

`storage.read_fuel()` liefert bei nicht lesbarem Storage `0`.

Danach ruft der Statusaufbau auf:

```lua
amount = safety.with_reserve(amount, minimum)
```

Liegt der tatsächliche Wert unter dem Minimum, wird der gemeldete Wert auf das Minimum angehoben.

## Folgen

- tatsächlicher niedriger Bestand wird verborgen
- ein Lesefehler kann als exakt ausreichende Reserve erscheinen
- UI-Prüfung `reserve < minimum` kann nie auslösen
- MASTER erhält einen geschönten Wert
- Health bleibt OK, solange ein Wrapper vorhanden ist, auch wenn jeder Read fehlschlägt

## Zielmodell

```lua
{
  reserve_actual = 500,
  reserve_minimum = 2000,
  reserve_deficit = 1500,
  reserve_ok = false,
  measurement_valid = true,
}
```

Bei Lesefehler:

```lua
{
  reserve_actual = nil,
  measurement_valid = false,
  health_reason = "STORAGE_READ_FAILED",
}
```

Messwerte niemals zur Darstellung auf das Minimum klemmen.

## Ampel

- ungültige Messung -> WARNING
- tatsächliche Reserve unter Minimum -> WARNING/EMERGENCY nach Schwelle
- historische `total_errors` dürfen einen aktuellen EMERGENCY-Status nicht überdecken

---

# FUEL-P0.12 – FUEL_STATUS nur von autorisiertem MASTER annehmen

## Aktuelles Problem

Der gemeinsame Parser prüft Ziel und Protokoll, aber keinen autorisierten Absender.

FUEL übernimmt danach jede Tabellen-Payload für `FUEL_STATUS`.

Auch der direkte RT-Mithörpfad vertraut einer Nachricht, wenn sie lediglich behauptet:

```lua
role = "RT-NODE"
```

## Risiko

Ein falscher oder fremder Computer kann niedrige Füllstände melden und Fuel-Exporte auslösen.

## Ziel

- `trusted_master_ids`
- Mapping `reactor_id -> trusted_rt_node_id`
- Sender-ID und Peerrolle prüfen
- Replay-/Sequenzprüfung
- nicht autorisierte Statusdaten protokollieren und verwerfen
- Master-Relay enthält `source_node`; FUEL prüft die Zuordnung

---

# FUEL-P0.13 – Lieferlogik nicht blockierend machen

## Aktuelles Problem

`route_and_act()` verwendet:

```lua
os.sleep(0.4 oder 0.05)
os.sleep(valve_open_ms / 1000)
```

Währenddessen blockiert der FUEL-Hauptloop.

Zusätzlich bearbeitet `_run_supply()` alle Kandidaten nacheinander und `_run_collect()` danach alle Waste-Outlets.

## Folgen

- Heartbeat verspätet
- MASTER-Commands verspätet
- UI friert ein
- Ventil-ACKs könnten in derselben Architektur nicht verarbeitet werden
- `current_request` ist für UI fast unsichtbar, da die UI während des Requests nicht tickt
- mehrere Reaktoren multiplizieren die Blockierzeit

## Ziel

Nicht blockierende Job-State-Machine:

```text
IDLE
SELECT_REQUEST
PREPARE_VALVES
WAIT_VALVE_ACKS
EXPORT
HOLD_LEASE
CLOSE_VALVES
WAIT_CLOSE_ACKS
CONFIRM_SAMPLE
COMPLETE / FAILED
```

Pro Loop nur kleine Arbeit. Netzwerkereignisse bleiben verarbeitbar.

---

# FUEL-P1.1 – Config vollständig validieren

## Pflichtvalidierung pro Reaktor

- `reactor_id`: nichtleer und eindeutig
- `label/name`: eindeutig
- `inlet`: nichtleer, vorhanden oder als erwartetes Binding registriert
- `item`: nichtleer und in erlaubter Fuel-Liste
- `request_below`: `0 < value < 1`
- `fill_amount`: positive Ganzzahl
- `min_in_me`: nichtnegative Ganzzahl
- kein identischer Inlet für mehrere Reaktoren, sofern nicht ausdrücklich erlaubt

## Aktuelle Lücken

- Werte über 1 erzeugen nur Warnung, werden nicht abgelehnt/geklammert.
- negative Werte werden nicht sauber behandelt.
- `fill_amount`/`min_in_me` werden nicht ausreichend validiert.
- fehlendes `reactor_id` führt sogar zum Blindmodus.
- `destinations` wird verwendet, ohne immer initialisiert zu sein.

## Routingvalidierung

Wenn Routing benötigt wird:

- jeder konfigurierte Reaktor besitzt exakt einen Pfad
- kein Pfad zu unbekanntem Reaktor
- keine doppelten Inlets/Pfade
- alle benötigten VALVE-Nodes online oder Routingstatus DEGRADED

---

# FUEL-P1.2 – `max_per_cycle` tatsächlich verwenden

`config_normalizer.lua` normalisiert `logistics.max_per_cycle`, aber `logistics_router.lua` verwendet den Wert nicht.

## Ziel

- globales Exportbudget pro Zyklus
- optional per Reaktor
- `fill_amount` auf verbleibendes Budget begrenzen
- fairer Scheduler über mehrere Reaktoren
- Waste-Import besitzt separates Budget

Beispiel:

```lua
max_export_items_per_cycle = 64
max_export_calls_per_cycle = 1
max_waste_calls_per_cycle = 4
```

---

# FUEL-P1.3 – Waste-Sammlung budgetieren

## Aktuelles Verhalten

Wenn der „import all“-Aufruf scheitert:

1. gesamtes Outlet mit `list()` lesen
2. jeden Stack durchlaufen
3. pro Stack separaten ME-Import versuchen

Bei großen Inventaren und mehreren Outlets entsteht ein langer synchroner Lauf.

## Ziel

- Slot-/Stack-Cursor speichern
- Call- und Zeitbudget pro Tick
- Round-Robin über Outlets
- leere Outlets mit Backoff
- Fehler nicht jeden Zyklus erneut vollständig scannen

---

# FUEL-P1.4 – Router- und Ventilaktionen crashsicher abschließen

## Aktuelles Problem

Wird `route_and_act()` zwischen Öffnen und `block_all()` durch einen Fehler oder Terminate verlassen, gibt es kein `finally`.

## Ziel

Jeder Routingjob besitzt garantierte Cleanup-Logik.

Bei State-Machine:

- Ablaufdeadline liegt auf der VALVE-Node selbst
- FUEL führt nach jedem Fehler `CLOSE_ALL` aus
- Fehlerstatus bleibt sichtbar
- `current_request` wird in jedem Endpfad gelöscht

---

# FUEL-P1.5 – Common Commands konsistent unterstützen

Der FUEL-spezifische Command-Handler ruft den vorhandenen gemeinsamen Handler für `PING`, `REMOTE_UPDATE`, `TERMINATE`/`SHUTDOWN` nicht sichtbar auf.

Prüfen und vereinheitlichen:

1. Common Command zuerst verarbeiten.
2. Danach FUEL-spezifische Targets.
3. Autorisierung gilt für beide Pfade.
4. Applied-ACK enthält klare Reason-Codes.

---

# FUEL-P2.1 – Ampelzustände nach aktueller Relevanz priorisieren

Aktuell führt jeder jemals aufgetretene Fehler über `total_errors > 0` dauerhaft zu WARNING.

Dadurch kann ein aktueller Reaktorfüllstand unter 10 % anschließend nicht mehr als EMERGENCY dargestellt werden, weil WARNING vorher zurückgegeben wird.

## Zielpriorität

1. aktuelle EMERGENCY
2. aktuelle Routing-/Messfehler
3. MASTER down
4. aktive Lieferung
5. historische Fehler nur als Diagnose, nicht als dauerhafter Betriebsstatus

Verwenden:

- `last_cycle.errors`
- `last_error_ts`
- Fehlerfenster/Quittierung

nicht nur kumulatives `total_errors`.

---

# FUEL-P2.2 – Ampel-Timer echte Zeit verwenden

Der Ampel-Service addiert bei fehlendem `dt` künstlich `0.5`. Modemnachrichten können dadurch zusätzliche Ampel-Render auslösen.

Mit `next_due_at` und `os.epoch("utc")` ersetzen.

---

# FUEL-P2.3 – Integrator-Auswahl in der Router-UI ergänzen

Die UI hält zwar `selected_int`, zeigt aktuell aber hauptsächlich die eingebauten Seiten ohne erkennbare Auswahl eines entfernten VALVE-Nodes.

Für Funkventile benötigt die UI:

- bekannte VALVE-Peers
- Auswahl `lokal` oder `VALVE-<id>`
- Verbindungsstatus
- Testschaltung nur mit ausdrücklicher Bestätigung
- sichtbare ACK-/Lease-Diagnose

---

# FUEL-P2.4 – SET_RESERVE-Semantik klären

`SET_RESERVE` ändert nur die lokale Variable bis zum nächsten Reboot.

Entscheidung dokumentieren:

- Runtime-Setpoint: MASTER sendet ihn nach jedem Reconnect erneut.
- persistenter Setpoint: atomar in `/xreactor/config/fuel.lua` speichern.

Keine unklare Mischform.

---

# Verbindliche Tests

## Config

1. FUEL-Config wird als Lua-Tabelle geladen.
2. `logistics.enabled=true` bleibt nach Reboot aktiv.
3. fehlende optionale Legacytabellen verursachen keinen Crash.
4. Auto-Update erhält `fuel.lua` und `fuel_routes.lua`.

## Netzwerkfüllstand

5. MASTER relayed keine stale RT-Messung als frisch.
6. Direct- und Relayquelle werden nach Messgeneration statt Empfangszeit gewählt.
7. gefälschter MASTER/RT-Absender wird abgelehnt.

## Lieferung

8. gleicher Sample erzeugt höchstens einen Export.
9. fehlendes `reactor_id` erzeugt keinen Export.
10. `max_per_cycle` wird eingehalten.
11. zwei Reaktoren werden fair bedient.
12. ME-Mindestbestand wird nie unterschritten.

## Ventile

13. Standard-`modem_message`-Event wird korrekt gelesen.
14. verlorener Open-Befehl -> kein Export.
15. verlorener Close-Befehl -> Lease blockiert Ventil automatisch.
16. Fehler beim Schließen eines fremden Pfads -> kein Export.
17. ungültiger Baum blockiert alte Ventile wirklich.
18. Routen bleiben nach Reboot aktiv.
19. nur autorisierter FUEL-Absender darf Ventile steuern.

## UI

20. ein Touch erzeugt genau eine Aktion.
21. Seite auswählen -> Reaktor auswählen -> speichern funktioniert.
22. aktuelle EMERGENCY überstimmt historische Fehler.

## Reserve

23. tatsächlicher Wert unter Minimum wird unverändert gemeldet.
24. Storage-Readfehler erzeugt DEGRADED statt künstlicher Mindestreserve.

## Performance/Verfügbarkeit

25. während eines Ventilfensters bleiben Heartbeat, Commands und UI aktiv.
26. zehn gleichzeitige Requests blockieren nicht den Eventloop.
27. Waste-Import hält Call-/Zeitbudget ein.

---

# Empfohlene Bearbeitungsreihenfolge

1. FUEL-P0.1 Configpfad/Configformat/Normalizer
2. FUEL-P0.5 VALVE-Event-Indizes
3. FUEL-P0.8 ungültiger Baum und kein Direktfallback bei Fault
4. FUEL-P0.7 alle Sperrventile als Pflichtbedingung
5. FUEL-P0.6 ACK-/Lease-Ventilprotokoll
6. FUEL-P0.2 echte Messgeneration und stale MASTER-Filterung
7. FUEL-P0.3 Transaktions-/Confirmation-State
8. FUEL-P0.4 Blindmodus entfernen
9. FUEL-P0.12 Absenderauthentifizierung
10. FUEL-P0.11 echte Reserve-/Readfehler-Semantik
11. FUEL-P0.9 Route-Persistenz
12. FUEL-P0.10 Doppel-Touch entfernen
13. FUEL-P0.13 nicht blockierende Job-State-Machine
14. FUEL-P1.1/P1.2 Configvalidierung und Budgets
15. FUEL-P1.3 Waste-Budget
16. P2 UI/Ampel/Setpoint-Bereinigung
17. vollständige FUEL-Testmatrix

# Definition of Done

- FUEL-Konfiguration wird nachweislich geladen und überlebt Updates.
- Keine Lieferung ohne gültige, frische und autorisierte Messgeneration.
- Pro Messgeneration höchstens eine normale Lieferung.
- Kein Blindexport wegen fehlender ID.
- Fuel wird erst nach bestätigtem, exklusivem Ventilpfad exportiert.
- Ventile besitzen kurze Lease und sichere Blockierung bei Kommunikationsverlust.
- Ungültige Route oder fehlendes ACK verhindert Export.
- Router-Routen sind nach Reboot aktiv.
- Ein Touch wird einmal verarbeitet.
- tatsächliche Reserve und Messfehler werden ehrlich gemeldet.
- Liefer-, Waste- und Ventilabläufe blockieren nicht den Eventloop.
- sämtliche Punkte besitzen Regressionstests und Lasttests.
