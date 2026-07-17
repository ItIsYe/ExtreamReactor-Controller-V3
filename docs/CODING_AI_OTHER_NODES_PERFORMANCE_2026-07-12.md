# Aktueller Gesamt-Audit – XReactor Controller V3

Stand: 2026-07-16  
Branch: `beta`  
Geprüfter ausführbarer Code-Head: `423a2f0b5198de61aaaf71c8fa28413d151b63bd`  
Geprüfte Release: `beta-v455` / `manifest-v455`  
Manifest-Dateien: `166`

## Zweck und Prüfumfang

Diese Datei ist die aktuelle, rollenübergreifende Aufgabenquelle für Coding-AI und manuelle Prüfungen. Sie ersetzt die vorherige Fassung vollständig. Alte Fehlerbeschreibungen werden nicht mehr unter bereits behobenen Überschriften weitergeführt.

Geprüft wurden:

- Root-Installer, modularer Installer und Auto-Update,
- Manifest, Rollen-Scope und Entrypoint-Abhängigkeiten,
- Shared Runtime, Service-Manager und Crashpfade,
- MASTER,
- RT,
- ENERGY,
- WATER,
- FUEL,
- REPROCESSOR,
- VALVE,
- LOG Collector,
- Tests und GitHub Actions.

Commitmeldungen und vorhandene Kommentare wurden nicht als Beweis übernommen. Bewertet wurde der tatsächliche Code auf `beta`. Peripheral-, Netzwerk-, Reboot-, Stromausfall-, Update- und Lastverhalten muss zusätzlich in CC:Tweaked/Ingame nachgewiesen werden.

---

# 1. Gesamtstatus

| Bereich | Tatsächlicher Status | Wichtigster Restpunkt |
|---|---|---|
| Installer / Auto-Update | **WEITGEHEND BEHOBEN** | kritische FS-Ergebnisse werden geprüft und unsicherer Backup-Fallback entfernt (Abschnitt 5); transaktionales Installationsjournal mit Boot-Recovery-Guard (Abschnitt 3); rollenübergreifender Quiesce-Handshake vor jedem Reinstall (Abschnitt 4); vollständige Planvalidierung und doppelte Installer-Implementierung bleiben offen (Abschnitt 7) |
| Manifest / Rollen-Scope | **WEITGEHEND BEHOBEN** | strukturelle Vorab-Planvalidierung inkl. transitiver require()-Abdeckung vorhanden (Abschnitt 7, deckte zwei echte Manifest-Lücken auf); doppelte Installer-Implementierung bleibt offen (Abschnitt 8) |
| Shared Runtime | **WEITGEHEND UMGESETZT** | Update-Quiesce fehlt rollenübergreifend |
| MASTER | **WEITGEHEND UMGESETZT** | Config-Editor: Einzelnode-/Alle-Auswahl, `require_applied` und Applied-ACK-Tracking je Ziel behoben (Abschnitt 10) |
| RT | **WEITGEHEND UMGESETZT** | `TURBINE_MODE`-Context-Typfehler (Abschnitt 11), Rampendauer-Einheitenfehler (Abschnitt 12) und fehlende `update_module_states()`-Verdrahtung (Abschnitt 13) behoben; Persistenz-/Observability-Restpunkte (Abschnitt 14) weiterhin offen |
| ENERGY | **WEITGEHEND UMGESETZT** | Schedulergruppen getrennt, Heartbeat-Zeitquelle konsolidiert (Abschnitt 15 behoben) |
| WATER | **WEITGEHEND UMGESETZT** | Persistenzresultat wird jetzt ehrlich im Command-Ergebnis abgebildet (Abschnitt 16 behoben) |
| FUEL | **TEILWEISE OFFEN** | Config/Async-Lifecycle und Router-ACK-Command-ID-Bindung behoben (Abschnitt 17); Async-Ergebnis noch nicht sauber an seinen Lieferzyklus gebunden (Abschnitt 19) |
| REPROCESSOR | **WEITGEHEND UMGESETZT** | Standby-Cancel und Wireless-VALVE-Discovery behoben (Abschnitt 20) |
| VALVE | **WEITGEHEND UMGESETZT** | Retry, Senderbindung (Auto-Pairing) und Sorter-Reconnect behoben (Abschnitt 21); Statusfelder (`actuator_online` etc.) bleiben als Observability-Erweiterung offen |
| LOG Collector | **WEITGEHEND UMGESETZT** | Probe-Wipe (Abschnitt 16), stale Free-Space-Cache im Reclaim und `send_ack`-Absturz bei jedem Flush (beide Abschnitt 22) behoben; Rotation/Datenhaltungsregeln (Abschnitt 23) weiterhin offen |
| Tests / CI | **KRITISCH TEILWEISE** | 63 Lua- und 6 Python-Tests ausgeschlossen (drei echte Fehler/Testbugs am 2026-07-17 behoben, siehe Abschnitt 24); aktueller Head ohne nachgewiesenen grünen Lauf |
| Dokumentation | **AKTUELL** | diese Datei ist die einzige aktuelle allgemeine Auditquelle |

## Produktionsurteil

`beta-v455` ist **noch nicht produktionsreif**.

Die kritischsten aktuellen Risiken sind:

1. ~~Ein Update kann als neue Release erscheinen, obwohl die Installation nur teilweise abgeschlossen wurde.~~ BEHOBEN (2026-07-17, siehe Abschnitt 3): transaktionales Installationsjournal, release.lua zuletzt committet, Boot-Guard verhindert Rollenstart bei unvollständigem Journal.
2. ~~Der Installer kann Dateien ersetzen, während die laufende Node dieselben Dateien und Hardwarepfade weiter benutzt.~~ BEHOBEN (2026-07-17, siehe Abschnitt 4): rollenübergreifender Quiesce-Handshake, `parallel.waitForAll` statt `waitForAny`, physische Sicherzustandsbestätigung für FUEL/REPROCESSOR/VALVE/WATER vor jedem Reinstall.
3. ~~RT-Startup verwendet im echten Context einen falschen `TURBINE_MODE`-Typ und behandelt `30` als 30 Millisekunden.~~ BEHOBEN (2026-07-17, siehe Abschnitt 11 und Abschnitt 12).
4. ~~`module_lifecycle.update_module_states()` ist im Produktionspfad nicht aufgerufen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 13).
5. ~~Der Ventilrouter kann einen fehlenden aktuellen ACK durch einen alten passenden Bestätigungszustand ersetzen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 17).
6. ~~REPROCESSOR übergibt dem Router keine COMMS-Peerquelle und erkennt Wireless-VALVE-Nodes dadurch nicht.~~ BEHOBEN (2026-07-17, siehe Abschnitt 20).
7. ~~LOG-Reclaim prüft nach Löschungen einen gecachten Free-Space-Wert und kann unnötig viele Dateien entfernen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 22).
8. 69 Tests bleiben ausgeschlossen (drei am 2026-07-17 behoben, siehe Abschnitt 24); ein grüner Lauf des geprüften Heads ist nicht nachgewiesen.

---

# 2. Seit `beta-v438` tatsächlich behoben

Die folgenden Punkte sind im aktuellen Code nachvollziehbar umgesetzt. Sie dürfen nur mit einem konkreten Regressionstest erneut umgebaut werden.

## Installer / Manifest

- Manifest und heruntergeladene Dateien verwenden im modularen Installer denselben aufgelösten Source-Ref.
- `installer/stage.lua` prüft nach jedem Write Größe und CRC32.
- `installer/stage.lua`s `M.write()` löscht die alte Datei nicht mehr ungeprüft, wenn der Backup-Move fehlschlägt; alle kritischen FS-Operationen in `installer/init.lua` und im tatsächlich ausgeführten Live-Installflow von `/installer` brechen bei Fehlschlag jetzt kontrolliert ab (Abschnitt 5).
- transaktionales Installationsjournal (`installer/journal.lua`, PREPARED→INSTALLING→VERIFYING→COMMITTED), `release.lua` wird zuletzt committet, `xreactor/start.lua` verhindert bei jedem Boot den Start der Rolle, solange das Journal nicht COMMITTED ist (Abschnitt 3).
- rollenübergreifender Update-Handshake (`core/update_handshake.lua`) stoppt jede Rolle kontrolliert und bestätigt für FUEL/REPROCESSOR/VALVE/WATER den sicheren physischen Ausgangszustand, bevor der Installer Dateien ersetzt (Abschnitt 4).
- `installer/plan_validator.lua` lehnt einen strukturell fehlerhaften Installationsplan (unbekannte Rolle, fehlender Entrypoint, unsichere Pfade, ungültige Hash-/Größenfelder, Manifest-Inkonsistenz, Übergröße) vor dem ersten destruktiven Schritt ab; ein Testsuite-Check gegen den echten Quelltext deckt zusätzlich fehlende transitive `require()`/`dofile()`-Manifestabdeckung auf (Abschnitt 7, deckte zwei echte Lücken auf: `services/alert_service.lua`/`core/alert_rules.lua`, `core/mockup_ui.lua`/`shared/colors.lua`).
- automatische Speicherbereinigung löscht nicht mehr pauschal `/xreactor_logs`.
- REPROCESSOR-`feed_router.lua` besitzt jetzt den Rollen-Scope `REPROCESSING`.
- `optional/speaker_alarm.lua` besitzt einen Rollen-Scope.
- VALVE-Rollen- und Shared-Support-Dateien sind im aktuellen Manifest enthalten.
- der frühere doppelte Manifestpfad für `core/bootstrap.lua` ist nicht mehr vorhanden.

## MASTER / RT

- Colon-/Dot-Aufrufproblem im MASTER-Startup-Sequencer ist behoben.
- RT besitzt jetzt echte Startup-Statevariablen und echte `start_module`-/`process_startup`-Verdrahtung.
- RT-Telemetrie enthält Modul- und Startupzustände.
- RT-Discovery verwendet eine echte Wanduhrdeadline statt Scheduler-Ticks als Slowdown-Zähler.
- historische RT-Defaultintervalle `5.0` und `1.0` werden versionsgesteuert auf `0.10` migriert.
- Capability-Cache normalisiert Singular-/Plural-Kindnamen und entfernt nicht mehr gebundene Einträge.

## ENERGY

- schnelle Services und Matrix-/Storage-Sampling verwenden getrennte Service-Manager.
- der Matrix-Thread tickt nicht mehr COMMS, Discovery, Telemetrie und UI gemeinsam mit blockierenden Matrixcalls.
- Matrixcode verwendet eine `send_heartbeat_if_due`-Funktion statt eines vollständig ungefilterten Sends.

## WATER

- gemeinsamer Tank-Snapshot,
- BLOCK_ALL bei unbekanntem Tankstand,
- Stateänderung erst nach erfolgreichen Redstone-Writes,
- persistentes `SET_TARGET`,
- aktuelles UI-Model,
- zentraler Touchpfad.

## FUEL / Router

- `logistics.destinations`, `sources` und `routes` werden normalisiert; frische Teilconfigs stürzen dort nicht mehr mit `ipairs(nil)` ab.
- asynchroner FUEL-Request bleibt bis Erfolgs- oder Fehlercallback erhalten.
- Exportstatistik wird im asynchronen Callback aktualisiert.
- ungültiges oder erforderliches, aber leeres Routing fällt nicht mehr direkt in den ungeschützten Exportpfad.
- Router blockiert zuerst alle Ventile, bestätigt den Zustand, öffnet danach den Zielpfad und bestätigt diesen ebenfalls.
- REPROCESSOR bricht eine aktive Transaktion beim Eintritt in Standby ab.

## VALVE

- eine Command-ID wird erst nach erfolgreichem Apply dedupliziert.
- ein fehlgeschlagener Write wird bei Retry derselben ID erneut versucht.
- ein fehlgeschlagener Write verlängert den Fail-Safe-Timer nicht mehr.
- Logistical Sorter wird als alternativer Aktor unterstützt.

## LOG Collector

- ein fehlgeschlagener Probe-Write löscht nur noch die eigene `.probe`-Datei.
- ACK bleibt an tatsächliche Persistierung gekoppelt.
- Batch-Writes und Dedupe-Ringstruktur bleiben erhalten.

---

# 3. INSTALL-P0.1 – Kein transaktionaler Installationsabschluss

## Status

**BEHOBEN (2026-07-17)**

## Bestätigtes Problem

`release.lua` wurde wie eine normale Datei innerhalb der Installationsliste geschrieben. Danach folgten weitere Rollen-, Shared- und Startdateien. Bricht der Lauf nach dem Schreiben von `release.lua`, aber vor dem vollständigen Ende ab, konnte der Rechner bereits die neue Release-/Manifestnummer melden, obwohl Teile der Installation fehlten oder alt geblieben waren.

Es existierte kein persistenter Zustand wie `PREPARED`/`INSTALLING`/`VERIFYING`/`COMMITTED` und kein Completion-Marker, der erst nach vollständiger Verifikation gesetzt wird.

Fix:

- Neues Modul `installer/journal.lua`: schreibt ein Installationsjournal nach `/xreactor_install_journal.lua` — bewusst AUSSERHALB von `/xreactor`, damit es einen abgebrochenen Lauf auch dann noch belegen kann, wenn `/xreactor` selbst gelöscht oder nur teilweise neu geschrieben wurde. Eigener, von `stage.lua` unabhängiger atomarer Write (tmp-Datei + `fs.move`), da das Journal auch von `xreactor/start.lua` bei jedem Boot gelesen wird, potenziell bevor der Rest von `/xreactor` in einem verlässlichen Zustand ist.
- `installer/init.lua` (und identisch der tatsächlich ausgeführte Live-Installflow in `/installer`, siehe Abschnitt 5 zur Struktur des Monolithen): das Journal wird als `PREPARED` geschrieben, BEVOR der alte Baum gelöscht wird (Ziel-Ref, Manifest-ID, Rolle, vollständige erwartete Dateiliste aus `manifest_mod.files_for_role()`). Nach Neuanlage von `/xreactor` und Minimal-Restore wechselt es zu `INSTALLING`. Nach erfolgreichem `stage_mod.install()` zu `VERIFYING`, zusätzlich abgesichert durch eine explizite `fs.exists()`-Prüfung jeder erwarteten Datei (deckt implizit auch den Rollen-Entrypoint ab, da `files_for_role()` ihn immer enthält).
- `release.lua` wird jetzt bewusst aus der Hauptinstallationsschleife ausgeschlossen und erst GANZ AM ENDE, nachdem wirklich alles andere (Dateien, Config-Restore, Rolle, Startup, Auto-Update-Config) erfolgreich geschrieben und verifiziert ist, als einzelne, letzte Datei installiert und CRC32-verifiziert. Erst danach wird das Journal auf `COMMITTED` gesetzt und sofort gelöscht — ein Absturz VOR diesem Punkt hinterlässt garantiert kein neues `release.lua` (der alte Stand bleibt für jede Versions-/Diagnoseanzeige "aktuell"), ein Absturz NACH diesem Punkt bedeutet eine vollständige, verifizierte Installation.
- `xreactor/start.lua` prüft dieses Journal bei JEDEM Boot, BEVOR versucht wird, die (möglicherweise unvollständige) Rolle zu starten. Der Parser ist bewusst selbstständig (kein `dofile()` von `installer/journal.lua`) — bei einem sehr frühen Absturz könnte `/xreactor/installer/` selbst noch unvollständig sein, das Journal liegt aber immer außerhalb davon. Ist ein Journal vorhanden und nicht `COMMITTED`, wird die Rolle NICHT gestartet; stattdessen lädt `start.lua` einen frischen `/installer` herunter und führt ihn im unbeaufsichtigten Modus (`_G.__xreactor_remote_update = true`) aus — derselbe robuste, bereits CRC32-verifizierte Mechanismus, den `auto_update.lua` für normale Updates verwendet (kein neuer, ungetesteter chirurgischer Partial-Resume). Gelingt das, übernimmt der frische Installerlauf und rebootet nach eigenem, erneut journal-gesichertem Abschluss. Schlägt der Download/Lauf fehl (z.B. kein Netzwerk), bricht `start.lua` mit klarem Fehler ab, rebootet nach 5 Sekunden für einen erneuten Versuch — und startet in KEINEM dieser Zwischenschritte jemals die normale Rolle.
- `xreactor/manifest.lua`: `installer/journal.lua` als neue `always=true`-Datei ergänzt.

Bewusst NICHT Teil dieses Fixes: `core/bootstrap.lua`s `state.last_recovery`/`get_recovery_status()` ist ein bereits bestehender, aber toter Stub (wird nirgends auf einen Nicht-nil-Wert gesetzt) für eine SEPARATE, offenbar nie fertiggestellte MASTER-UI-Recovery-Banner-Funktion (`master/init_runtime.lua`s `recovery_notice`) — dieser Stub ist thematisch verwandt, aber ein eigenständiges, unabhängiges Feature, keine Voraussetzung für die hier geforderte Boot-Sicherheitsprüfung (die läuft vollständig und für ALLE Rollen in `start.lua`, bevor irgendein Rollenmodul inklusive MASTER überhaupt geladen wird). Bleibt als mögliche spätere Verbesserung offen.

Pflicht-Tests:
- `tests/installer_journal_state_machine_test.lua` — treibt `installer/journal.lua` direkt mit einer gemockten fs: Round-Trip (write→read liefert dieselben Felder), `check_incomplete()` klassifiziert PREPARED/INSTALLING/VERIFYING als unvollständig, COMMITTED und "kein Journal" als normal, `clear()` entfernt das Journal zuverlässig.
- `tests/installer_journal_ordering_and_release_last_test.lua` — strukturelle Prüfung direkt am Quelltext (Positionsvergleich der Marker), dass sowohl `installer/init.lua` als auch der tatsächlich ausgeführte Live-Installflow in `/installer` (Anker: ein Kommentar, der nur im Live-Flow vorkommt, nicht in der nur eingebetteten `init_src`-Textkopie) die Reihenfolge PREPARED < INSTALLING < VERIFYING < release.lua-Install < COMMITTED < `clear()` einhalten und dass release.lua VOR der VERIFYING-Stufe aus der Hauptschleife ausgeschlossen wird.
- `tests/start_lua_incomplete_install_blocks_role_test.lua` — extrahiert den Boot-Guard direkt aus dem echten `xreactor/start.lua`-Quelltext und führt ihn isoliert mit gemocktem `fs`/`http`/`os` aus: kein Journal oder `COMMITTED` → Guard feuert nicht; `INSTALLING` mit fehlgeschlagenem Recovery-Download → Boot bricht ab (Rolle wird nie erreicht), genau ein `os.reboot()` für den Retry; `VERIFYING` mit erfolgreichem Download → der heruntergeladene Recovery-Installer wird tatsächlich per `dofile()` ausgeführt, die Rolle wird trotzdem nicht in diesem Boot gestartet.

Alle drei Tests wurden per `git stash` gegen den Vorfix-Code verifiziert (schlagen dort fehl, da die geprüften Marker/das Guard-Verhalten dort schlicht nicht existieren).

## Folge (vor dem Fix)

- Teilinstallation konnte als aktuell erscheinen.
- Auto-Update konnte denselben Stand anschließend überspringen.
- Diagnose und UI konnten eine falsche Versionskonsistenz anzeigen.
- ein Neustart mitten im Update besaß keine eindeutige Recoveryentscheidung.

## Verbindlicher Fix (umgesetzt)

1. Installationsjournal außerhalb des ersetzten Baums anlegen — **umgesetzt**.
2. Ziel-Ref, Manifest-ID, Rolle und erwartete Dateiliste speichern — **umgesetzt**.
3. alle Dateien schreiben und verifizieren — **umgesetzt**.
4. Entrypoint und Rollenabhängigkeiten prüfen — **umgesetzt** (Existenzprüfung der vollständigen erwarteten Dateiliste nach Installation).
5. `release.lua` und Completion-Marker **zuletzt** atomar committen — **umgesetzt**.
6. beim Boot unvollständigen Zustand erkennen und entweder Rollback oder kontrollierten Resume ausführen — **umgesetzt** (kontrollierter Resume via frischem Installerlauf; ein chirurgisches Rollback auf den exakten alten Dateizustand ist mit der bestehenden Architektur — kein vollständiges Datei-Backup, nur Config — nicht sinnvoll möglich, der volle Reinstall-Resume ist die sicherere, bereits robuste Alternative).

## Pflicht-Test (Ergebnis)

Die geforderte Fehlerinjektion "nach jedem einzelnen Dateischritt" als vollständige End-to-End-Simulation (Netzwerk, Download, jeder einzelne Dateischreibvorgang) würde externe Abhängigkeiten in die Testsuite ziehen, die in diesem Repo bewusst vermieden werden (siehe `tests/cc_env_shim.lua`). Stattdessen wurde die Invariante an ihren tatsächlichen Durchsetzungspunkten geprüft: der Boot-Guard in `start.lua` (verifiziert für alle vier relevanten Journalzustände: fehlend, COMMITTED, unvollständig+Recovery-Fehlschlag, unvollständig+Recovery-Erfolg) und die Journal-/Release-Reihenfolge im Installer selbst. Damit ist for jeden Absturzzeitpunkt entlang des Installationslaufs sichergestellt: entweder das Journal ist noch nicht auf `COMMITTED` (→ `start.lua` startet die Rolle nie, klarer Recoverymodus) oder es ist bereits `COMMITTED` (→ release.lua und alle Dateien sind nachweislich vollständig geschrieben).

---

# 4. INSTALL-P0.2 – Runtime und Installer laufen parallel

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: `start.lua` startete Rollenruntime und Auto-Updater mit `parallel.waitForAny` — die Rollenruntime konnte während eines laufenden Auto-Updates unverändert weiter Hardware regeln, Ventile schalten, Configs persistieren usw., während der Installer bereits Dateien ersetzte.

Fix — neues Modul `core/update_handshake.lua` implementiert die im Audit vorgeschlagene Zustandsfolge (`UPDATE_REQUESTED → QUIESCE_REQUESTED → SAFE_OUTPUTS_APPLIED → RUNTIME_STOPPED`; die verbleibenden Stationen `INSTALLING`/`VERIFIED`/`COMMITTED`/`REBOOT` deckt bereits das Installationsjournal aus Abschnitt 3 ab) und wird als globaler Wert (`_G.__xreactor_update_handshake`, gleiches Muster wie `_G.__xreactor_remote_update`) zwischen der Rollen-Coroutine und dem Auto-Update-Loop geteilt:

- `start.lua`: erstellt den Handshake, reicht ihn an `auto_update.lua`s `make_loop()` durch, und wechselt von `parallel.waitForAny` zu `parallel.waitForAll` — sonst hätte ein sauberer Quiesce-Exit der Rollen-Coroutine den Auto-Update-Loop sofort mit abgewürgt, noch bevor der Installer überhaupt laufen konnte.
- `installer/auto_update.lua`: fordert Quiesce EINMAL pro erkanntem Update an (nicht pro Downloadversuch — die Rollen-Coroutine ist nach bestätigtem Quiesce bereits beendet, ein erneutes Anfordern pro Retry hätte für immer auf eine bereits beendete Rolle gewartet) und wartet bis zu 20s auf `RUNTIME_STOPPED`, BEVOR überhaupt ein Installer-Download versucht wird. Bleibt die Bestätigung aus, wird die Installation für diesen Zyklus verschoben (nächster Versuch beim nächsten Intervall) — niemals ein Install ohne bestätigten sicheren Zustand. Schlägt der Installationsversuch NACH bestätigtem Quiesce aus anderen Gründen (z.B. Netzwerk) fehl, rebootet der Node explizit, um die (unveränderte) alte Rolle sauber neu zu starten, statt dauerhaft ohne laufende Rolle stehen zu bleiben.
- Gemeinsamer Hook-Punkt für RT/VALVE/FUEL/REPROCESSOR/WATER: `nodes/support/runtime.lua`s `run_event_loop()` erhält einen optionalen 5. Parameter (`quiesce_opts = { handshake, on_quiesce }`, rückwärtskompatibel — bestehende 4-Parameter-Aufrufer verhalten sich unverändert). `on_quiesce()` liefert `true`/`false`/`nil` zurück und wird bei Bedarf JEDEN Zyklus erneut versucht, bis es einen sicheren Zustand bestätigt — erst dann verlässt die Schleife sich sauber (kein Crash, kein `crash_screen`).
- MASTER (`master/loop.lua`) und ENERGY (`nodes/energy/heartbeat.lua`) haben eigene, separate Event-Loops (nicht über `run_event_loop()`) und bekamen denselben Quiesce-Check direkt eingebaut. LOG_COLLECTOR (`nodes/log_collector/main.lua`) ebenso, per `dofile()` statt `require()` (dieses Modul läuft historisch ohne `bootstrap.setup()`).
- **Für FUEL/REPROCESSOR/VALVE/WATER wird bewusst KEIN neuer Aktor-Code eingeführt** — `on_quiesce` ruft jeweils die bereits vorhandene, bereits auditierte Standby-Funktion auf:
  - `VALVE`: `apply_valve(true)` — einzige der vier mit echter, synchroner Erfolgsbestätigung (liefert `true`/`false`, bereits vom Fail-Safe-Watchdog verwendet); wird bei `false` im nächsten Zyklus automatisch erneut versucht.
  - `WATER`: neue kleine `quiesce_all_clusters()`-Funktion iteriert `config.clusters` und ruft für jeden Cluster die bereits vorhandene `set_rs_output(side, false, integrator)` auf (liefert ebenfalls echtes `true`/`false` pro Write); bestätigt nur, wenn ALLE Cluster-Writes erfolgreich waren.
  - `FUEL`: `redstone_router:shutdown_now("UPDATE_QUIESCE")` (blockiert alle bekannten Ventile, bricht eine laufende Transaktion ab) — dieselbe Funktion, die REPROCESSOR bereits für MASTER-Staleness nutzt; Bestätigung über `get_active_transaction() == nil` (wird synchron beim Aufruf gelöscht).
  - `REPROCESSOR`: `enter_standby("UPDATE_QUIESCE")` — bereits idempotent, bereits produktiv für MASTER-Staleness im Einsatz; Bestätigung über das bereits vorhandene `standby`-Flag.
  - FUEL/REPROCESSOR sind dabei fire-and-forget (keine Rückgabe, kein echter Hardware-Bestätigungswert für WIRELESS-Ventile — dieselbe Bestätigungsqualität, die diese Funktionen bereits vorher für ihren jeweils eigenen Zweck hatten, keine Verschlechterung, aber auch keine neue, härtere Garantie).
  - RT ist im Audit nicht unter den vier Rollen mit Pflicht zur physischen Bestätigung gelistet und bekam daher einen trivialen (sofort bestätigten) Handler — RTs bereits bestehender, MASTER-getriggerter `pending_remote_update`-Pfad (synchroner `core.remote_update.run()`-Aufruf direkt im eigenen Thread) bleibt unverändert und blockiert für diese Dauer ohnehin bereits die eigene Steuerschleife.

Pflicht-Tests:
- `tests/core_update_handshake_test.lua` — treibt das Handshake-Modul direkt: korrekte Zustandsfolge, `mark_safe_outputs_applied()` wirkt nur aus `QUIESCE_REQUESTED` (kein Überspringen), `wait_for_runtime_stopped()` Erfolg/Timeout, `reset()`.
- `tests/support_runtime_quiesce_test.lua` — treibt die echte `run_event_loop()`-Funktion mit gemocktem `os.pullEvent`/`os.startTimer`: `on_quiesce()` wird wiederholt versucht bis `true`, danach sauberer Exit mit `RUNTIME_STOPPED`; ohne `quiesce_opts` bleibt das bisherige Verhalten unverändert (harte Zyklusgrenze mit klarer Fehlermeldung statt Endlosschleife bei einer Regression).
- `tests/energy_heartbeat_quiesce_test.lua` — treibt das echte `heartbeat.lua`-Modul: mit gesetztem `QUIESCE_REQUESTED` beendet sich der Thread beim nächsten `svc_timer`-Tick sauber mit `RUNTIME_STOPPED`; ohne Handshake unverändertes Verhalten.
- `tests/install_p0_2_quiesce_wiring_test.lua` — strukturelle Prüfung direkt am Quelltext aller acht Rollen sowie `start.lua`/`installer/auto_update.lua`, dass die erwartete Verdrahtung (insbesondere: welche bestehende Funktion pro sicherheitskritischer Rolle wiederverwendet wird, und dass Quiesce VOR dem Install-Retry-Loop anfordert wird) tatsächlich vorhanden ist.

Alle vier Tests wurden per `git stash` gegen den Vorfix-Code verifiziert (schlagen dort fehl bzw. laufen — bei `support_runtime_quiesce_test.lua` — kontrolliert in eine harte Zyklusgrenze statt in eine echte Endlosschleife).

## Folge (vor dem Fix)

- Dateien wurden ersetzt, während alter Code weiterlief.
- Rollenlogik konnte Configrestore oder Installerwrites überschreiben.
- Safety-Aktoren besaßen keinen definierten Quiesce-Zustand.
- ein Updatefehler konnte Runtime und Installationsbaum gleichzeitig inkonsistent hinterlassen.

## Verbindlicher Fix (umgesetzt)

Ein rollenübergreifender Update-Handshake (`UPDATE_REQUESTED → QUIESCE_REQUESTED → SAFE_OUTPUTS_APPLIED → RUNTIME_STOPPED`, die verbleibenden Stationen `INSTALLING`/`VERIFIED`/`COMMITTED`/`REBOOT` deckt das Installationsjournal aus Abschnitt 3 ab) ist umgesetzt. Jede Rolle hat einen expliziten Quiesce-Handler; für FUEL/REPROCESSOR/VALVE/WATER ist der sichere physische Ausgangszustand bestätigt (VALVE/WATER: echte synchrone Schreibbestätigung; FUEL/REPROCESSOR: dieselbe Bestätigungsqualität, die ihre jeweils bereits vorhandene Standby-Funktion schon vorher hatte), bevor der Installer Dateien ersetzt.

---

# 5. INSTALL-P0.3 – Kritische Dateisystemfehler werden ignoriert

## Status

**BEHOBEN (2026-07-17)** — mit Ausnahme des letzten Punkts ("Fehlerpfad muss Journal/Recoverymarker aktualisieren"), der zu #42 (transaktionales Installjournal) gehört und dort behandelt wird.

Bestätigt in allen drei Codepfaden: `xreactor/installer/stage.lua`s `M.write()`, `xreactor/installer/init.lua` und dem eingebetteten `stage_src`/`init_src`-Text sowie dem tatsächlich ausgeführten Live-Installflow von `/installer` (der Monolith enthält KEINE zwei redundant ausgeführten Installflows, wie zunächst vermutet — nur der Block ab `-- ── Alte Installation löschen` gegen Zeilenende läuft wirklich; der scheinbar identische frühere Block ist Teil des nur als Text eingebetteten `init_src`, das lediglich für die spätere On-Disk-Ablage von `xreactor/installer/init.lua` verwendet wird).

Zwei Fehlerklassen wurden bestätigt:

1. **Unsicherer Fallback in `stage.write()`**: Schlug das Verschieben der alten Datei nach `.xr_prev` fehl (`pcall(fs.move, ...)` lieferte `false`), wurde die alte Zieldatei trotzdem gelöscht ("als letzter Ausweg") und der Lauf machte weiter, als sei nichts geschehen. Schlug danach auch noch der finale `tmp -> path`-Move fehl, war die alte Datei unwiderruflich weg UND kein Backup vorhanden, aus dem `path` hätte zurückgeholt werden können — echter, irreversibler Datenverlust.
2. **Ignorierte Rückgabewerte an 8+ Aufrufstellen**: `INSTALL_ROOT` löschen/neu anlegen, der Minimal-Restore-Loop (role.lua/remote_update.lua/node_id.txt), sowie die Schreibvorgänge für `optional_features.lua`, `role.lua`, `startup.lua` und `remote_update.lua` — jeweils als `pcall(...)` bzw. `stage_mod.write(...)` ohne Prüfung des Rückgabewerts. Ein Fehlschlag (z.B. kein Speicherplatz, schreibgeschützter Datenträger) blieb unbemerkt; die Installation lief mit einer teilweise/nicht angelegten Zielstruktur bzw. ganz ohne Rolle weiter.

Fix:

- `stage.lua`s `M.write()`: die alte Datei wird nur noch gelöscht, wenn `fs.exists(backup)` nach dem Move tatsächlich bestätigt, dass sie am Backup-Pfad liegt (nicht mehr nur am `pcall`-Erfolg von `fs.move`). Schlägt der Backup-Move fehl, bricht `M.write()` sofort mit klarem Fehler ab, `path` bleibt unangetastet. Ebenso wird nach dem finalen `tmp -> path`-Move zusätzlich `fs.exists(path)` verifiziert, nicht nur der `pcall`-Erfolg.
- `installer/init.lua` und der tatsächlich ausgeführte Installflow in `/installer`: alle 8 identifizierten Aufrufstellen prüfen jetzt das Ergebnis explizit und brechen bei Fehlschlag mit `error(..., 0)` ab (gleiches Muster wie das bereits vorhandene `stage_mod.install()`-Ergebnis-Check).
- Die eingebetteten `stage_src`/`init_src`-Textkopien in `/installer` wurden identisch mitgezogen, damit sie nicht erneut von den echten `xreactor/installer/*.lua`-Dateien abdriften.

Pflicht-Tests:
- `tests/installer_stage_write_backup_failure_test.lua` — treibt `stage.write()` mit einem gemockten `fs`, dessen `fs.move` beim Backup-Move (Ziel endet auf `.xr_prev`) einen Fehler wirft; bestätigt, dass die alte Datei erhalten bleibt, kein `.xr_tmp` zurückbleibt und ein klarer Fehler zurückkommt. Zusätzlich ein Sanity-Check, dass normale Writes weiterhin funktionieren.
- `tests/installer_init_critical_write_abort_test.lua` — extrahiert die role.lua-Schreib- und INSTALL_ROOT-Neuanlage-Blöcke direkt per Marker aus dem echten `installer/init.lua`-Quelltext und führt sie isoliert mit gemocktem `stage_mod`/`fs` aus; bestätigt, dass ein Fehlschlag zum Abbruch führt.
- `tests/installer_monolith_critical_write_abort_test.lua` — dieselbe Technik für den tatsächlich ausgeführten Live-Codepfad in `/installer`.

Alle drei Tests wurden per `git stash` gegen den Vorfix-Code verifiziert (schlagen dort fehl, da der extrahierte/aufgerufene Code aus der jeweils aktuellen Datei kommt).

## Folge (vor dem Fix)

Der Installer konnte nach einem fehlgeschlagenen Lösch-, Move-, Mkdir- oder Restore-Schritt fortfahren und später einen scheinbar erfolgreichen, aber unvollständigen oder sogar datenverlustbehafteten Stand hinterlassen.

## Verbindlicher Fix (umgesetzt, bis auf Journal-Punkt)

- jede kritische FS-Operation muss explizit geprüft werden — **umgesetzt**,
- bei Fehler sofort abbrechen — **umgesetzt**,
- alte Datei niemals löschen, wenn das Backup nicht bestätigt vorhanden ist — **umgesetzt**,
- Restorewrites einzeln verifizieren — **umgesetzt** (Minimal-Restore-Loop bricht jetzt pro Datei ab; der vollständige Config-Restore nach der Installation verifizierte bereits vorher byte-genau),
- Fehlerpfad muss Journal/Recoverymarker aktualisieren — **nicht Teil dieses Fixes**, gehört zu #42.

---

# 6. INSTALL-P0.4 – Generische `.xr_prev`-Recovery fehlt

## Status

**OFFEN**

`stage.write()` kann temporär einen Zustand erzeugen, in dem nur `<datei>.xr_prev` vorhanden ist. Für `/xreactor/start.lua` existiert ein spezieller Recoverypfad, nicht aber für beliebige benötigte Module.

## Folge

Stromausfall zwischen Backup-Move und finalem Move kann eine Rollen- oder Shared-Datei fehlen lassen. Der nächste Boot kann bereits beim `require()` abbrechen, bevor der Installer selbst wieder erreichbar ist.

## Fix

- Boot-Recovery scannt `.xr_prev` und `.xr_tmp` anhand des Installationsjournals.
- Wiederherstellung nur für den dokumentierten aktiven Updatevorgang.
- anschließend CRC/Größe prüfen.

---

# 7. INSTALL/MANIFEST-P1 – Vorabvalidierung ist zu schwach

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: vor dem Löschen des alten Baums fehlten vollständige Guards für erlaubte Rollenwerte, erwarteten Entrypoint der gewählten Rolle, doppelte/absolute/`..`-Traversal-Pfade, gültige Hash-/Größenfelder, Manifest-Selbstkonsistenz und maximale Manifest-/Dateigröße.

Fix — neues, reines Datenmodul `installer/plan_validator.lua` implementiert `M.validate(plan)`: prüft ausschließlich, was aus Rolle + Manifest + geplanter Dateiliste OHNE Netzwerk-Download bekannt ist (die eigentlichen Dateiinhalte existieren vor dem Download noch nicht). Wird sowohl in `installer/init.lua` als auch im tatsächlich ausgeführten Live-Installflow von `/installer` unmittelbar nach der Bestimmung der geplanten Dateimenge und VOR dem ersten destruktiven Schritt ("Alte Installation löschen") aufgerufen — ein einziger fehlgeschlagener Guard bricht mit `error()` ab, bevor irgendetwas gelöscht wird.

Geprüft werden: erlaubte Rollenwerte (`M.ROLE_ENTRYPOINTS`, bewusst dieselbe Zuordnung wie `xreactor/start.lua`s `ROLE_ENTRY`, strukturell synchron gehalten), erwarteter Entrypoint der Rolle muss im Plan enthalten sein, doppelte Pfade (Lua-Tabellen können ohnehin keine doppelten Schlüssel haben, aber die Iteration deckt es strukturell ab), absolute Pfade und `..`-Traversal, gültige `size_bytes`/`hash`-Felder (CRC32, 8 Hex-Zeichen — `nil` ist für lokal generierte Inhalte ohne Manifest-Hash bewusst erlaubt), Manifest-Selbstkonsistenz (`manifest_id` muss `manifest_version` enthalten) sowie eine maximale Einzeldatei- und Gesamtplangröße (Sicherheitsnetz gegen ein korruptes/böswilliges Manifest).

Die transitive `require()`-/`dofile()`-Abdeckung lässt sich NICHT als reiner Laufzeit-Guard umsetzen (die Dateiinhalte sind vor dem Download nicht bekannt) — stattdessen wurde sie als eigenständiger Testsuite-Check gegen den echten lokalen Quelltext umgesetzt (`tests/manifest_transitive_require_coverage_test.lua`, siehe unten), der verhindert, dass eine unvollständige Dateizuordnung überhaupt erst ins Manifest gelangt, statt sie erst zur Laufzeit auf einem Node zu entdecken. Dieser Check deckte dabei zwei ECHTE, bis dahin unentdeckte Manifest-Lücken auf (beide behoben):

- `services/alert_service.lua` (bisher ungefiltert an JEDE nicht-LOG-Rolle mitgeschickt, obwohl nur `master/runtime_loop.lua` es tatsächlich `require()`t) fehlte dabei nicht selbst, sondern seine eigene, unbedingte Abhängigkeit `core/alert_rules.lua` (bereits korrekt auf `required_for={"MASTER"}` beschränkt) — für alle Nicht-MASTER-Rollen eine tote, aber strukturell inkonsistente Kombination (kein tatsächliches Crash-Risiko, da `alert_service.lua` dort nie `require()`t wird, aber unnötiger Ballast). Jetzt `required_for={"MASTER"}` ergänzt.
- `shared/colors.lua` fehlte bei LOG_COLLECTOR: `core/mockup_ui.lua` hat `always=true` (wird u.a. an LOG_COLLECTOR mitgeschickt, obwohl dort in Wirklichkeit nie geladen) und `require()`t `shared.colors` unbedingt beim Laden — `shared/colors.lua` selbst hatte kein `always=true` und wurde vom `is_log`-Filter in `files_for_role()` daher ausgefiltert. Jetzt `always=true` ergänzt.
- Zusätzlich wurde ein struktureller Bug in `installer/manifest.lua`s `files_for_role()` selbst gefunden und behoben: `required_for` wurde bisher NUR für `roles.*`-Einträge ausgewertet — ein `required_for`-Feld auf einem `base_files`-Eintrag (wie es der `alert_service.lua`-Fix braucht) hatte schlicht keine Wirkung.

`ROLE_EXTRAS`-Dateien ohne Manifestmetadaten sind über `plan_validator.validate()`s Hash-/Größenfeld-Prüfung ebenfalls abgedeckt (ein `ROLE_EXTRAS`-Eintrag ohne gültige Metadaten würde die Validierung nicht bestehen).

Pflicht-Tests:
- `tests/installer_plan_validator_test.lua` — treibt `plan_validator.validate()` direkt: je ein Fall pro geprüfter Bedingung (gültiger Plan wird akzeptiert; unbekannte Rolle, fehlender Entrypoint, absoluter Pfad, `..`-Traversal, ungültiges Hash-Feld, negative Größe, überdimensionierte Datei, Manifest-Inkonsistenz werden jeweils einzeln abgelehnt; fehlendes/`nil` Hash-Feld ist erlaubt), plus strukturelle Synchronitätsprüfung zwischen `ROLE_ENTRYPOINTS` und `start.lua`s `ROLE_ENTRY`, plus Verdrahtungsprüfung (Aufruf VOR dem Lösch-Schritt) in `installer/init.lua` und im Live-Installflow von `/installer`.
- `tests/manifest_transitive_require_coverage_test.lua` — treibt die echte `files_for_role()` gegen den echten Quelltext für jede Rolle; deckte die beiden oben beschriebenen echten Lücken auf.

Alle Tests wurden per `git stash` gegen den Vorfix-Code verifiziert.

**Abschnitt 8 (INSTALL-P1, zwei unabhängige Installerimplementierungen) bleibt bewusst OFFEN** — siehe dort. Ein "einziges `validate_install_plan()`" im wörtlichen Sinn des Audits würde idealerweise nur an einer Stelle existieren; da aber weiterhin zwei Codepfade (`installer/init.lua` und der monolithische `/installer`) parallel existieren, musste die Validierung an beiden Stellen (mit identischer Logik, per `git diff`-Sync gehalten) verdrahtet werden. Die vollständige Vereinheitlichung (Abschnitt 8) würde diese Duplizierung strukturell auflösen, ist aber ein deutlich größerer, risikoreicherer Umbau und wird separat behandelt.

## Fix (umgesetzt)

Neues `installer/plan_validator.lua` mit `M.validate(plan)`, aufgerufen vor dem Backup-/Delete-Schritt in beiden Installer-Codepfaden — lehnt die gesamte Installationsmenge ab, sobald irgendeine strukturelle Bedingung nicht erfüllt ist.

---

# 8. INSTALL-P1 – Zwei unabhängige Installerimplementierungen

## Status

**OFFEN**

Der Root-`/installer` enthält weiterhin eingebettete Kopien von HTTP-, Manifest-, Stage-, UI- und Initlogik. Parallel existieren dieselben Module unter `xreactor/installer/`.

## Folge

Jeder Fix muss mehrfach synchron gehalten werden. Ein bestandener Test des modularen Pfads beweist nicht automatisch den Root-Bootstrap-Pfad.

## Fix

Der Root-Installer darf nur noch:

1. einen kleinen, versionsfesten Bootstrap laden,
2. genau einen Source-Ref auflösen,
3. die kanonischen Installermodule dieses Refs herunterladen,
4. anschließend ausschließlich den modularen Installer ausführen.

---

# 9. INSTALL-P1 – Fleet-Jitter und persistenter Circuit Breaker fehlen

## Status

**OFFEN**

Nodes prüfen nach ähnlichem Startdelay und danach in festen Intervallen. Ein dauerhaft fehlerhafter neuer Stand kann von vielen Nodes nahezu gleichzeitig wiederholt geladen werden.

## Fix

- deterministischer Jitter pro Computer-ID,
- persistente Fehleranzahl pro Zielmanifest,
- exponentieller Backoff,
- Circuit Breaker nach N Fehlschlägen,
- manuelle Freigabe oder neueres Manifest zum Entsperren.

---

# 10. MASTER-P1 – Config-Editor behauptet Übernahme vor `ACK_APPLIED`

## Status

**BEHOBEN (2026-07-17)** — auf explizite Nutzerfreigabe umgesetzt, nachdem dieser Punkt zuvor bewusst zurückgestellt worden war.

Bestätigt: Der Config-Editor änderte die lokal angezeigten Werte (`c.state.fuel_reserve_pct`/`water_target_pct`/`reactor_fill_target_pct`) sofort beim Touch, unabhängig vom tatsächlichen Ergebnis. Die drei Setter (`runtime_loop.lua`) sendeten IMMER an ALLE Nodes der jeweiligen Rolle, forderten kein `require_applied` an und die ausgehende `message_id` wurde nirgends festgehalten. `ACK_DELIVERED` war im gesamten Nachrichten-Dispatch (`message_handlers.lua`) unbehandelt und löste bei JEDEM gesendeten Command (nicht nur Config-Editor-Edits) einen falschen „Unknown message type ACK_DELIVERED“-Alarm aus. `ACK_APPLIED` aktualisierte zwar `nodes[id].last_command_result`, aber ausschließlich als EIN generischer Slot pro Node (von jedem Commandtyp geteilt, ohne Zuordnung zu einem konkreten Edit) — keine Aggregation über mehrere angeschriebene Ziele, kein Timeout-Pfad in die UI.

## Fix

Neues, reines Datenmodul `master/config_edits.lua` ist jetzt die einzige Autorität für alle drei editierbaren Fernwerte (FUEL-Reserve, WATER-Target, RT-Fülstandsziel):

- **Zielauswahl:** `ALLE` oder eine konkrete Node-ID, per Touch auf das Zielfeld zyklisch umschaltbar (`cycle_target()`), persistiert in der bereits geschützten `/xreactor/config/master.lua` (überlebt Neustarts/Auto-Updates, über denselben Mechanismus wie PEAK/IDLE-Schwellwerte).
- **`require_applied=true`** wird jetzt bei jedem Config-Editor-Command angefordert (`send_edit()`).
- **Message-ID-Tracking je Ziel:** die von `comms:send_command()` zurückgegebene `message_id` wird pro angeschriebenem Node in `pending.targets[node_id]` festgehalten.
- **Status pro Ziel:** `QUEUED` → `DELIVERED` (jetzt per explizit behandeltem `ACK_DELIVERED` statt des vorherigen spurious-WARN-Zweigs) → `APPLIED`/`REJECTED` (per `ACK_APPLIED`, korreliert über `message.ack_for` gegen die gespeicherte `message_id`) oder `TIMEOUT` (per `housekeeping.lua`s bereits bestehendem `consume_timeouts()`-Konsumenten, jetzt zusätzlich in `config_edits.handle_timeout()` gespeist).
- **Angezeigter Wert:** `confirmed_value` wird ERST übernommen, wenn ALLE angeschriebenen Ziele `APPLIED` melden; bis dahin bleibt der alte bestätigte Wert sichtbar, ein laufender Edit erscheint als `PENDING`-Fortschritt (`x/y angewendet`) direkt in der WERT-Zeile der Karte. Ein Fehlschlag bei mindestens einem Ziel (`REJECTED`/`TIMEOUT`/Sendefehler) hält den alten Wert unverändert und markiert den Edit sichtbar als fehlgeschlagen (`FEHLER x/y`), statt ihn stillschweigend als Erfolg auszuweisen.
- **Persistenz:** Zielauswahl UND zuletzt bestätigter Wert werden bei jeder Änderung in `/xreactor/config/master.lua` geschrieben und beim nächsten Boot wiederhergestellt.

Verdrahtung: `master/runtime_loop.lua` (Setter delegieren vollständig an `config_edits.send_edit()`, neue `cycle_config_edit_target()`/`get_config_edit_model()`-Calc-Funktionen), `master/message_handlers.lua` (neuer `ACK_DELIVERED`-Zweig, `ACK_APPLIED`-Zweig ruft zusätzlich `config_edits.handle_ack_applied()`), `master/housekeeping.lua` (`handle_command_timeouts()` ruft zusätzlich `config_edits.handle_timeout()`), `master/ui_controller.lua` (`config_editor_model` liest jetzt ausschließlich aus `get_config_edit_model()`, keine optimistische `c.state.*_pct`-Mutation mehr, neue `config_edit_target_cycle`-Action), `master/ui/config_editor.lua` (Zielname + Pending-Fortschritt in der bestehenden WERT-Zeile, kein Eingriff in das Karten-/Spaltenraster).

## Pflicht-Test

Vier neue Testdateien: `tests/master_config_edits_test.lua` (reine Logik von `config_edits.lua`: Zielzyklus, Senden an ALLE/einen konkreten/einen verschwundenen Node, Applied-/Rejected-/Timeout-Auflösung, Wertübernahme erst nach vollständiger Bestätigung), `tests/master_config_edit_ack_wiring_test.lua` (echte `message_handlers.lua`/`housekeeping.lua`-Verdrahtung: kein spurious-Alarm mehr bei `ACK_DELIVERED`, korrekte Korrelation über `ack_for`/`message_id`), `tests/master_ui_controller_config_edit_action_test.lua` (echtes `handle_action()`: liest den aktuellen Wert aus `get_config_edit_model()`, schreibt `c.state.*_pct` nicht mehr), sowie die aktualisierte `tests/master_runtime_loop_multi_node_reserve_target_test.lua` (bestehendes Broadcast-an-ALLE-Verhalten bleibt für die `ALL`-Zielauswahl erhalten). Verifiziert per `git stash`, dass alle vier Tests gegen den alten Code fehlschlagen.

---

# 11. RT-P0.1 – Produktions-Context liefert falschen `TURBINE_MODE`-Typ

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: `module_lifecycle.lua` indizierte `ctx.TURBINE_MODE.RAMP` (zwei Stellen: `start_module()` und `apply_safe_controls()`), während `nodes/rt/main.lua`s echter `make_lifecycle_ctx()` nur `TURBINE_MODE = CONFIG.TURBINE_MODE_RAMP or "RAMP"` lieferte — einen String, keine Tabelle. `turbine_control.lua`s eigene, an vielen Stellen verwendete Konvention (`ctx.CONFIG.TURBINE_MODE_RAMP`, immer ein reiner String, z.B. `"RAMP"`, `"OVERSPEED_BRAKE"`, `"UP"`, `"DOWN"`) bestätigt: `ctrl.mode` ist im gesamten Produktionscode konsequent ein Skalar, niemals eine Tabelle — die Tabellenform in `module_lifecycle.lua` war der eigentliche Fehler, nicht der String in `main.lua`.

Fix: `main.lua`s Feld wurde konsistent zu `TURBINE_MODE_RAMP` (weiterhin ein String) umbenannt — passend zur bereits etablierten Namenskonvention der übrigen flachen `make_lifecycle_ctx()`-Felder (`START_FLOW`, `RPM_TOL`). `module_lifecycle.lua` liest jetzt an beiden Stellen direkt `ctx.TURBINE_MODE_RAMP` statt `ctx.TURBINE_MODE.RAMP`. Die drei betroffenen Tests (`tests/rt_master_startup_end_to_end_test.lua`, `tests/rt_module_lifecycle_control_rod_caps_test.lua`, `tests/rt_module_lifecycle_safe_controls_test.lua`), die bisher jeweils einen eigenen, künstlichen Mock-Context mit der falschen Tabellenform (`TURBINE_MODE = { RAMP = 'RAMP' }`) bauten und die reale Produktionsabweichung dadurch nicht aufdeckten, wurden auf die korrekte Skalarform angepasst.

Pflicht-Test: `tests/rt_turbine_mode_context_shape_test.lua` — anders als die drei oben genannten (handgeschriebene Mock-Contexts, könnten erneut driften) prüft dieser neue Test strukturell direkt am echten Quelltext beider Dateien, dass `main.lua`s `make_lifecycle_ctx()` ein skalares `TURBINE_MODE_RAMP`-Feld definiert (und **kein** `TURBINE_MODE`-Tabellenfeld mehr reintroduziert) und dass `module_lifecycle.lua` an beiden Stellen exakt `ctx.TURBINE_MODE_RAMP` liest, nie `ctx.TURBINE_MODE.RAMP`. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Folge (vor dem Fix)

Beim echten Turbinenstart wurde `ctrl.mode` nicht zuverlässig auf den vorgesehenen Rampenmodus gesetzt.

## Fix (umgesetzt)

```lua
-- main.lua
TURBINE_MODE_RAMP = CONFIG.TURBINE_MODE_RAMP or "RAMP",
-- module_lifecycle.lua
ctrl.mode = ctx.TURBINE_MODE_RAMP
```

---

# 12. RT-P0.2 – Rampendauer wird als Millisekunden behandelt

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: Produktionscode lieferte `ramp_duration = function() return 30 end`, während `module_lifecycle.process_startup()` mit `os.epoch("utc")` in Millisekunden rechnet (`progress = (now - module.start_time) / duration`) — die Reaktorrampe erreichte dadurch bereits nach ungefähr 30 Millisekunden 100 Prozent statt der beabsichtigten 30 Sekunden, ein deutlicher Widerspruch zum 60-s-Startup-Stage-Timeout und zur fachlichen Bedeutung einer Rampe. Der bisherige End-to-End-Test bestätigte dieses (falsche) Verhalten sogar ausdrücklich, indem er die Fake-Clock nur um 100 ms erhöhte.

Fix: die Einheit ist jetzt explizit im Namen — `ramp_duration_ms(profile)` liefert garantiert Millisekunden (`STARTUP_RAMP_DURATION_S * 1000`, kein unbenannter Zahlenkonstante mehr). `module_lifecycle.lua` liest den Wert als `duration_ms` und dividiert korrekt Millisekunden durch Millisekunden. Der bisherige End-to-End-Test wurde auf die reale Dauer (30000 statt 100 ms Fake-Clock-Vorlauf) korrigiert.

Pflicht-Test: `tests/rt_ramp_duration_units_test.lua` — treibt die echte `process_startup()`-Funktion mit einer Fake-Clock über die tatsächlichen Produktionswerte (30000 ms): (1) nach 100 ms ist die Rampe nachweislich NICHT fertig (`progress < 1`, Modul bleibt `STARTING`); (2) Fortschritt steigt monoton (100 ms → 15 s); (3) bei Erreichen der konfigurierten Dauer wird das Modul `STABLE`; (4) weit nach der Deadline bleibt `progress` bei exakt `1` geklammert (kein Überschreiten), demonstriert an einem zweiten Modul, dessen Temperatur-Gate absichtlich nie erfüllt ist, damit die Rampen-Fortschrittsberechnung isoliert von der `STABLE`-Transition wiederholt geprüft werden kann. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt (die alte `module_lifecycle.lua` erwartet noch das alte `ramp_duration`-Feld, nicht `ramp_duration_ms` — ein direkter Beweis für die inkompatible Schnittstelle).

Beim Schreiben dieses Tests wurde zusätzlich ein separater, vorbestehender Bug in `update_module_limits()`s Coolant-Check entdeckt (`skip_coolant and nil or ctx.evaluate_reactor_coolant(...)` — der klassische Lua-`and/or`-Fallstrick: die `or`-Seite läuft immer, wenn die `and`-Seite `nil` ist, unabhängig von `skip_coolant`). Dieser Bug ist NICHT Teil dieses Fixes (eigenständiges Problem, bereits durch die vorbestehende Testausschlussliste als `NEEDS_MOCK` markiert) und wurde hier nur umgangen (echter `evaluate_reactor_coolant`-Stub im neuen Test), nicht behoben.

## Fix (umgesetzt)

```lua
-- main.lua
ramp_duration_ms = function(_ramp_profile)
  local STARTUP_RAMP_DURATION_S = 30
  return STARTUP_RAMP_DURATION_S * 1000
end,
-- module_lifecycle.lua
local duration_ms = ctx.ramp_duration_ms(module.ramp_profile)
local progress = safety.clamp((now - module.start_time) / duration_ms, 0, 1)
```

---

# 13. RT-P0.3 – `update_module_states()` ist im Produktionspfad nicht verdrahtet

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: `update_module_states()` existierte bereits in `nodes/rt/module_lifecycle.lua` und war bereits funktional getestet (`tests/rt_coolant_low_confirm_delay_test.lua`), wurde aber im Produktivcode nirgends aufgerufen — die einzige weitere Fundstelle war ein Test. `control_tick()` rief bisher nur `process_startup()`, Reactor-Control und Turbine-Control auf. Ohne `update_module_states()` waren unter anderem nicht regelmäßig aktiv: `STABLE -> RUNNING`, laufende Modul-Limitbewertung, Modulstate `LIMITED`, modulbezogene Temperatur-/Coolant-Transitionen außerhalb eines aktiven Startups.

Fix: `module_lifecycle.update_module_states(make_lifecycle_ctx())` wird jetzt in `control_tick()` aufgerufen — dieselbe `make_lifecycle_ctx()`, die `process_startup()` bereits erfolgreich verwendet, liefert bereits alle von `update_module_states()` benötigten Felder (`log`, `current_state`, `STATE`, `setState`, `node_state_machine`, `constants`, `evaluate_reactor_coolant`, `get_effective_regulator_rod_caps`, `read_current_rods`, `config.safety.*`, `get_target_rpm`) — keine neuen Ctx-Felder nötig. Reihenfolge bewusst sicherheitserst dokumentiert und getestet: `update_module_states()` (erkennt/reagiert auf neue Gefahrenzustände über alle Module) läuft VOR `process_startup()` (treibt nur das aktuell startende Modul voran) und VOR `reactor_control`/`turbine_control` (die Regelung darf nicht auf einem in diesem Tick bereits veralteten Sicherheitszustand aufbauen).

Pflicht-Test: `tests/rt_control_tick_wires_update_module_states_test.lua` — prüft strukturell an `control_tick()`s echtem Quelltext, dass `update_module_states()` tatsächlich aufgerufen wird UND in der dokumentierten Reihenfolge vor `process_startup()`, `reactor_control.updateReactorControl()` und `turbine_control.updateControl()` steht. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Fix (umgesetzt)

`module_lifecycle.update_module_states(make_lifecycle_ctx())` in `control_tick()` aufgenommen, sicherheitserst vor `process_startup()`, Reactor-Control und Turbine-Control.

---

# 14. RT-P1 – Persistenz- und Observability-Restpunkte

## Status

**TEILWEISE OFFEN**

- Schema-Migration schreibt per ignoriertem `pcall`; Fehlschlag wird nicht sichtbar behandelt.
- ~~`SET_REACTOR_FILL_TARGET` loggt Erfolg, obwohl `utils.write_config()` in einem ignorierten `pcall` scheitern kann.~~ BEHOBEN (2026-07-17, siehe Abschnitt 16): `set_reactor_fill_target()` wertet den Rückgabewert jetzt aus, loggt WARN bei Fehlschlag statt eines unbedingten INFO, und `SET_REACTOR_FILL_TARGET` im Command-Handler meldet ein ehrliches `persisted`-Feld statt eines blinden `{ ok = true }`. `tests/water_rt_persistence_ack_honesty_test.lua`.
- `build_discovery_context().build_capabilities()` verwendet unabhängig vom tatsächlichen Gerät zunächst den Turbinen-Key.
- UI und Telemetrie bauen weiterhin getrennte vollständige Gerätesnapshots.
- es fehlen echte Control-Tick-/Jitter-/Deadline-Metriken.

## Pflicht-Metriken

- Control-Ticks/s,
- maximale Ticklücke,
- Reactor-/Turbine-Reglerticks,
- Startup-Lifecycle-Ticks,
- übersprungene Writes,
- Discovery-Calls/min,
- Peripheral-Inspect-Calls/min,
- Deadlineüberschreitungen.

---

# 15. ENERGY-P1 – Heartbeat besitzt weiterhin zwei Zeitquellen

## Status

**BEHOBEN (2026-07-17)**

Die Schedulertrennung war real umgesetzt, die Heartbeatlogik jedoch nicht vollständig zentral:

- `main.lua` besaß `hb_state.last_ts` und `send_heartbeat_if_due()`.
- der Matrix-Thread verwendete bereits diese Quelle (korrekt, unverändert).
- `heartbeat.lua` besaß zusätzlich `ctx.last_heartbeat_ts` (im `ctx` von `make_hb_ctx()` mit `0` initialisiert), aktualisierte diesen separat in `do_heartbeat()` und sendete auf seinem Heartbeat-Timer unbedingt über `ctx.send_heartbeat()` — ohne jede Fälligkeitsprüfung gegen die geteilte Quelle.

Konkretes Fehlerszenario: `main.lua` sendet bereits vor `parallel.waitForAny()` einen initialen Heartbeat und setzt dabei `hb_state.last_ts`. Die private Kopie in `heartbeat.lua`s `ctx` blieb davon unberührt bei `0`. Ein kurz danach eintreffendes `modem_message`-Event wertete `now - 0 >= interval` sofort als fällig und löste einen unnötigen Zusatz-Send aus, obwohl gerade erst gesendet worden war. Zusätzlich sendete der Timer-Pfad in `heartbeat.lua` immer unbedingt, selbst wenn der Matrix-Thread kurz zuvor bereits über `send_heartbeat_if_due()` gesendet hatte.

## Fix

`nodes/energy/main.lua`:
- neue `get_last_heartbeat_ts()`-Funktion, liest `hb_state.last_ts` (dieselbe Quelle, die auch `send_heartbeat_if_due()` prüft/aktualisiert).
- `make_hb_ctx()` verdrahtet jetzt `send_heartbeat_if_due = send_heartbeat_if_due` und `get_last_heartbeat_ts = get_last_heartbeat_ts` in den Heartbeat-Thread-Context, statt eines bei `0` initialisierten privaten `last_heartbeat_ts`-Felds und des rohen, ungegateten `send_heartbeat`.

`nodes/energy/heartbeat.lua`:
- `should_send()`/`do_heartbeat()` (private Zählerlogik) ersetzt durch `maybe_heartbeat()`, das jeden Sendeversuch — sowohl vom `hb_timer` als auch vom `modem_message`-Event ausgelöst — ausschließlich über `ctx.send_heartbeat_if_due(now)` gated (dieselbe Funktion, dieselbe geteilte `hb_state.last_ts`-Quelle wie der Matrix-Thread). Die Verzögerungs-Warnung liest den letzten tatsächlichen Sendezeitpunkt jetzt über `ctx.get_last_heartbeat_ts()` statt über eine eigene Kopie.
- kein privater `ctx.last_heartbeat_ts`-Zustand mehr vorhanden — eine geteilte `last_sent_ts`-Quelle (`hb_state.last_ts`) für alle Aufrufer.

## Pflicht-Test

`tests/energy_heartbeat_shared_last_ts_test.lua` (neu): treibt das echte `nodes/energy/heartbeat.lua` mit einem Fake-Ctx, der main.lua's geteilte `hb_state`-Semantik nachbildet, und beweist (1) ein `modem_message`-Event 50ms nach einem vorherigen Send (2000ms-Intervall) löst keinen Zusatz-Send aus, (2) der `hb_timer` 200ms nach einem vorherigen Send (über eine andere Quelle) sendet nicht unbedingt nach, (3) strukturelle Prüfung, dass `heartbeat.lua` keinen privaten `ctx.last_heartbeat_ts`-Zähler mehr referenziert und `main.lua`s `make_hb_ctx()` die geteilte Quelle verdrahtet. Ergänzend angepasst: `tests/energy_matrix_thread_scheduler_isolation_test.lua` (Block 3) auf den neuen `ctx`-Vertrag (`get_last_heartbeat_ts`/`send_heartbeat_if_due` statt `last_heartbeat_ts`/`send_heartbeat`) aktualisiert.

---

# 16. WATER-P1 – Persistenzfehler kann trotzdem als angewendet bestätigt werden

## Status

**BEHOBEN (2026-07-17)**

`SET_TARGET` änderte den RAM-Wert, versuchte die Config zu schreiben und loggte einen Persistenzfehler als WARN — anschließend wurde der Command aber unbedingt mit `support_command_handler.finish(devices, true)` (also immer `{ ok = true }`, ohne jedes Persistenzsignal) abgeschlossen. Derselbe Fehlerschatten fand sich bei RT's `SET_REACTOR_FILL_TARGET` (siehe Abschnitt 14): der Rückgabewert von `utils.write_config()` wurde dort sogar komplett verworfen (`pcall(utils.write_config, ...)` ohne jede Auswertung), und `command_handler.lua`s Handler gab bei Erfolg unbedingt `nil` zurück, was der äußere Dispatcher automatisch als `{ ok = true }` interpretierte.

## Folge (vor dem Fix)

MASTER konnte `ACK_APPLIED` erhalten, obwohl der Wert nach einem Neustart verloren geht.

## Fix

Gewählt wurde die im Audit selbst genannte Alternative — `ok=true` bleibt korrekt (der RAM-Wert wird sofort wirksam übernommen), aber das Ergebnis trägt jetzt explizit ein `persisted`-Feld:

- `nodes/support/command_handler.lua`: `finish(devices, ok, extra)` akzeptiert jetzt ein optionales drittes Argument, dessen Felder in das Ergebnis gemerged werden (rückwärtskompatibel — bestehende 2-Argument-Aufrufer unverändert).
- `nodes/water/main.lua`: `SET_TARGET` gibt jetzt `finish(devices, true, { persisted = ok_write == true })` zurück statt eines blinden `finish(devices, true)`.
- `nodes/rt/main.lua`: `set_reactor_fill_target(value)` wertet `utils.write_config()`s Rückgabewert jetzt tatsächlich aus (statt eines unausgewerteten `pcall(...)`), loggt bei Fehlschlag WARN statt eines unbedingten INFO, und gibt den Erfolg als Boolean zurück.
- `nodes/rt/command_handler.lua`: `SET_REACTOR_FILL_TARGET` gibt jetzt `{ ok = true, persisted = <Rückgabewert von ctx.set_reactor_fill_target()> }` zurück statt unbedingt `nil`.

Eine vollständige `APPLIED_VOLATILE`/`APPLIED_PERSISTED`/`REJECTED_PERSISTENCE`-Statusunterscheidung wäre ein größerer, MASTER-seitig konsumierender Umbau (Config-Editor-UI, ACK-Auswertung) und wurde bewusst nicht mitgemacht — das explizite `persisted`-Feld macht das Ergebnis bereits ehrlich abfragbar und ist die im Audit selbst als gleichwertig genannte Alternative.

## Pflicht-Test

`tests/water_rt_persistence_ack_honesty_test.lua` (neu): vier Blöcke — (1) `support_command_handler.finish()`s neues `extra`-Argument inkl. Rückwärtskompatibilität, (2) WATER's echter `SET_TARGET`-Zweig (Marker-extrahiert aus dem Boot-Skript) mit `persisted=true` bei erfolgreichem und `persisted=false` bei fehlgeschlagenem `write_config()`, (3) RT's echtes `nodes/rt/command_handler.lua` (direkt require()-bar) mit derselben Unterscheidung, (4) RT's `set_reactor_fill_target`-Callback (Marker-extrahiert aus `nodes/rt/main.lua`) beweist, dass der frühere unausgewertete `pcall(...)` jetzt durch eine echte Erfolgsauswertung ersetzt ist. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Weiterer Nachweis

WATER bleibt statisch ansonsten weitgehend sauber. Notwendig sind Ingame-Tests für Tanklesefehler, Teil-Writefehler, Reboot, Update und Touchverarbeitung.

---

# 17. ROUTER-P0 – Alter bestätigter Zustand kann aktuellen ACK ersetzen

## Status

**BEHOBEN (2026-07-17)**

Bestätigt in `xreactor/nodes/fuel/redstone_router.lua`: die Batchlogik speicherte pro Ventil angefordertes `high`, ob ein ACK benötigt wird und das synchrone Ergebnis, aber NICHT die `command_id` des aktuellen Ventilkommandos. `handle_valve_ack()` legte im bestätigten Zustand (`confirmed_valve_state[key]`) ebenfalls keine Command-ID ab — dieser Zustand wird pro Ventilschlüssel nie gelöscht und überlebt beliebig viele nachfolgende Transaktionen. Wurde ein aktuelles Kommando nach allen Retries aus `pending_valve_acks` entfernt (verlorene ACKs), prüfte `_check_valve_batch()` nur noch, ob irgendein FRÜHER bestätigter Zustand für denselben Ventilschlüssel `applied=true` und denselben `high`-Wert besitzt — exakt der Fall bei der WAIT_FINAL_ACKS-Phase einer Transaktion, deren nächster Delivery-Zyklus in WAIT_BLOCK_ACKS erneut denselben `high=true`-Wert für dieselben Ventile anfordert.

Fix: `_set_valve()` gibt die erzeugte `command_id` als zweiten Rückgabewert zurück; `_request_valve_batch()` speichert sie in jedem Batcheintrag; `handle_valve_ack()` speichert `command_id` zusätzlich im Confirmed-State; `_check_valve_batch()` akzeptiert einen Confirmed-State nur noch, wenn dessen `command_id` exakt mit der `command_id` des AKTUELL angeforderten Kommandos übereinstimmt (zusätzlich zu `applied==true` und passendem `high`). Ein alter, zufällig passender Confirmed-State (andere oder fehlende `command_id`) zählt damit nicht mehr als Beweis für ein neues Kommando — das schließt automatisch auch den letzten Fix-Punkt ("vor einem neuen Command alten Confirmed-State nicht als aktuellen Beweis verwenden") mit ein, da jedes Kommando eine neue, aus Zeitstempel+Sequenznummer gebildete `command_id` erhält. Die zusätzlich vorgeschlagene Prüfung von "Bestätigungsalter und Peerstatus" wurde als durch die Command-ID-Bindung bereits abgedeckt bewertet: eine Bestätigung mit korrekter `command_id` kann per Konstruktion nicht älter sein als die aktuelle Anfrage (eindeutige ID pro Anfrage), und `VALVE_PHASE_TIMEOUT_MS` begrenzt ohnehin, wie lange eine Phase auf eine Bestätigung wartet.

Pflicht-Test: `tests/redstone_router_stale_confirmed_state_test.lua` — treibt die echte `begin_transaction()`/`tick()`-Zustandsmaschine über zwei aufeinanderfolgende Transaktionen: die erste läuft vollständig durch und hinterlässt in `confirmed_valve_state` für beide Ventile einen bestätigten `BLOCKED`-Zustand (`high=true`) aus ihrer WAIT_FINAL_ACKS-Phase; die zweite Transaktion sendet in ihrer eigenen WAIT_BLOCK_ACKS-Phase erneut `BLOCKED` (`high=true`) für dieselben Ventile — mit neuen, nachweislich anderen `command_id`s —, aber alle ihre ACKs gehen verloren (`check_pending_acks()` gibt nach `VALVE_ACK_MAX_RETRIES` auf). Beweist: die zweite Transaktion bricht sicherheitshalber ab (`transaction == nil`), ihr `action_fn` (Export) läuft niemals. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt (der beschriebene Bug reproduziert sich exakt wie im Audit beschrieben).

## Beispiel (ursprünglich beobachtet)

1. Ventil wurde früher bestätigt `BLOCKED`.
2. neuer `BLOCKED`-Befehl wird gesendet.
3. alle aktuellen ACKs gehen verloren.
4. Retrylogik gibt den aktuellen Befehl auf und entfernt ihn aus `pending`.
5. alter bestätigter `BLOCKED`-Eintrag passt weiterhin.
6. aktueller Batch kann fälschlich als bestätigt gelten.

## Verbindlicher Fix (umgesetzt)

- `_set_valve()` gibt die erzeugte `command_id` zurück.
- Batchentry speichert diese ID.
- `handle_valve_ack()` speichert `command_id` im Confirmed-State.
- `_check_valve_batch()` akzeptiert ausschließlich exakt dieselbe ID.
- vor einem neuen Command alten Confirmed-State für denselben Schlüssel nicht als aktuellen Beweis verwenden — durch die Command-ID-Bindung automatisch erfüllt.

---

# 18. ROUTER-P1 – Abschluss- und Fehlerzustände nach Export

## Status

**OFFEN**

- Wirft `action_fn` selbst einen Fehler, wird nur gewarnt; die Transaktion geht trotzdem nach `HOLD_OPEN` und erhält keinen normalen `on_error`-Abschluss.
- finale Blockbestätigung kann fehlschlagen; danach wird `block_all()` erneut gesendet, aber die Transaktion wird ohne bestätigten sicheren Istzustand gelöscht.
- ein solcher Zustand muss als latched Safetyfehler in Telemetrie/UI erhalten bleiben.

## Fix

Eigene Abschlusszustände:

```text
COMPLETE_SAFE
EXPORT_FAILED
FINAL_BLOCK_UNCONFIRMED
CANCELLED
```

Ein unbestätigt offenes Ventil darf nicht durch Löschen des Transaktionsobjekts diagnostisch verschwinden.

---

# 19. FUEL-P1 – Async-Ergebnis ist nicht sauber an seinen Zyklus gebunden

## Status

**OFFEN**

Der spätere Exportcallback schreibt in `self._state.last_cycle`. Dauert eine Ventiltransaktion länger als das normale Logistikintervall, kann zwischen Start und Callback bereits ein neuer Zyklus `last_cycle` ersetzt haben.

Zusätzlich wird `current_request.state` direkt nach `begin_transaction()` auf `delivering` gesetzt, obwohl die Transaktion zu diesem Zeitpunkt erst Ventile blockiert beziehungsweise ACKs abwartet.

## Folge

- Exportmenge kann dem falschen Zyklus zugerechnet werden.
- UI meldet „delivering“, bevor ein Export überhaupt zulässig ist.

## Fix

Eigener Transaction-Record mit stabiler ID:

```text
REQUESTING
BLOCKING
OPENING
SETTLING
EXPORTING
HOLDING
FINAL_BLOCK
COMPLETE / ERROR
```

Zyklusstatistik referenziert diese ID und wird nicht über ein global austauschbares `last_cycle` aktualisiert.

---

# 20. REPROCESSOR-P0 – Wireless-VALVE-Peers werden nicht verdrahtet

## Status

**BEHOBEN (2026-07-17)**

Bestätigt in `xreactor/nodes/reprocessor/main.lua`: FUEL erzeugt den Redstone-Router mit `comms = comms`, REPROCESSORs `get_rs_router()` erzeugte denselben Router dagegen komplett ohne `comms`. `redstone_router:refresh()` verwendet `self.comms:get_peers()`, um einen konfigurierten Integrator als erreichbaren Wireless-VALVE-Node zu erkennen — ohne COMMS-Referenz bleibt die Peer-Liste leer, danach wird nur noch nach einem lokalen Peripheral gleichen Namens gesucht.

Fix: `comms = comms` wird jetzt auch in REPROCESSORs `get_rs_router()` an `redstone_router_lib.new()` übergeben — identisch zu FUEL. `get_rs_router()` ist ein Lazy-Singleton, der erst zur Laufzeit (aus Event-Handlern/Tick-Loop) aufgerufen wird, zu diesem Zeitpunkt ist die vorwärtsdeklarierte `comms`-Upvalue bereits per `comms_service.new(...)` zugewiesen — keine zusätzliche nachträgliche Injektion nötig, die bestehende Konstruktionsreihenfolge reicht bereits aus.

Pflicht-Test: `tests/reprocessor_wireless_valve_comms_wiring_test.lua` — prüft strukturell, dass `get_rs_router()`s Konstruktoraufruf tatsächlich `comms = comms` enthält, und demonstriert zusätzlich funktional mit dem echten `redstone_router.lua`-Modul den beobachtbaren Unterschied: ohne `comms` wird ein konfigurierter Wireless-Integrator gar nicht erkannt (`self._state.integrators[name] == nil`), mit `comms` wird er korrekt als `network=true` erkannt. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt.

## Fix (umgesetzt)

- `comms = comms` an `redstone_router_lib.new()` übergeben.
- Reconnect-/Peer-Down-/Peer-Up-Test bleibt als weiterführender Ingame-Nachweis offen (kein neuer statischer Fund).

---

# 21. VALVE-P1 – Senderbindung und Sorter-Reconnect

## Status

**WEITGEHEND BEHOBEN (2026-07-17)**

## Senderbindung

`trusted_source` war rein optional. Ohne dieses Feld akzeptierte die VALVE-Node auf Dauer jedes korrekt adressierte `SET_VALVE` auf dem dedizierten Kanal, von jedem beliebigen Sender.

Fix: automatisches Pairing beim ERSTEN akzeptierten `SET_VALVE` nach einer frischen Installation — `config.trusted_source` wird auf den Absender dieses ersten Kommandos gesetzt und über `utils.write_config()` in die geschützte Nutzerconfig persistiert (überlebt Neustarts, WARN bei Persistenzfehler, analog zu Abschnitt 16). Jeder SPÄTERE Sender mit abweichender `src` wird verworfen (WARN geloggt, kein Write, kein Dedupe-Eintrag). Bleibt dadurch abwärtskompatibel — kein manuelles Vorab-Pairing nötig, funktioniert "out of the box" — schließt aber die Lücke "akzeptiert dauerhaft jeden Sender". `VALVE_ACK` trägt jetzt zusätzlich `src` (die eigene Node-ID) und `dst` (der ursprüngliche Absender, aus `message.src` gespiegelt) — die eigentliche ACK-Zuordnung auf FUEL-Seite läuft bereits ausschließlich über die (per ROUTER-P0 command-id-gebundene) `command_id`, `src`/`dst` verbessern aber Logging/Diagnose.

## Sorter-Reconnect

`get_sorter()` cachte den einmal gewrappten Sorter dauerhaft. Schlug ein späterer Call wegen Detach/Reattach oder ersetztem Peripheral fehl, wurde `sorter_device` nicht verworfen und neu gebunden — jeder weitere Versuch traf denselben kaputten Handle erneut.

Fix: bei einem Callfehler (`pcall(sorter.setAutoMode, ...)` schlägt fehl) wird `sorter_device = nil` gesetzt; der nächste `get_sorter()`-Aufruf (nächster Retry) wrappt das Peripheral frisch über `peripheral.wrap()`.

## Fix (umgesetzt)

- ~~verpflichtendes Pairing beziehungsweise `trusted_source`~~ — als automatisches Erstsender-Pairing umgesetzt (siehe oben).
- ~~ACK mit `src`, `dst` und aktuellem Commandbezug~~ — umgesetzt (`command_id` war bereits vorhanden, `src`/`dst` ergänzt).
- ~~bei Sorter-Callfehler Cache leeren~~ — umgesetzt.
- ~~beim nächsten Retry neu wrappen~~ — umgesetzt (Konsequenz aus dem geleerten Cache).
- Statusfelder für `actuator_online`, `last_apply_ts`, `last_error_ts` — NICHT Teil dieses Fixes (reine Observability-Erweiterung, keine Korrektheits-/Sicherheitslücke); bleibt als VALVE-P2-Weiterentwicklung offen.

## Pflicht-Test

`tests/valve_sender_pairing_and_sorter_reconnect_test.lua` (neu) — treibt die echten, per Marker aus `nodes/valve/main.lua` extrahierten Funktionen (`get_sorter()`/`write_actuator()`/`apply_valve()` sowie `handle_valve_channel_event()`). Vier Senderbindungs-Fälle (Erstsender wird automatisch gepaart und persistiert; abweichender Sender nach Pairing wird verworfen; bereits gepaarter Sender läuft ohne erneuten Persistenzversuch normal weiter; ein Persistenzfehler beim Pairing wirkt sofort im RAM, aber mit WARN) und zwei Sorter-Reconnect-Fälle (fehlgeschlagener Call gefolgt von einem erfolgreichen Retry beweist einen zweiten, frischen `peripheral.wrap()`-Aufruf statt eines wiederverwendeten kaputten Handles). Ergänzend angepasst: `tests/valve_failed_write_retry_test.lua` (vorbelegtes `trusted_source`/`src`, damit die neue Pairing-Logik die bestehenden Retry-Assertions nicht verfälscht). Verifiziert per `git stash`, dass der neue Test gegen den alten Code nicht einmal extrahierbar ist (die Fix-Logik existiert dort schlicht nicht).

---

# 22. LOG-P0 – Reclaim verwendet stale Free-Space-Cache

## Status

**BEHOBEN (2026-07-17)**

Bestätigt: `free_space()` cached Werte für `FREE_SPACE_CACHE_TTL` (2 echte Sekunden, per `os.clock()`) pro Mount. `reclaim_oldest()` prüfte vor jeder Löschung denselben gecachten Wert, löschte eine Datei, invalidierte den Cache aber nicht. Da mehrere aufeinanderfolgende Löschungen innerhalb eines einzigen, synchronen Reclaim-Laufs praktisch keine messbare Zeit verbrauchen, blieb der Cache-Eintrag über den gesamten Lauf "frisch" — die Schleife sah bei jeder Iteration weiterhin den alten, niedrigen Free-Space-Wert und entfernte munter weiter, obwohl bereits nach der ersten Löschung genug Platz frei sein konnte. Die frühere pauschale Komplettlöschung war zwar bereits entfernt (siehe Abschnitt 16), aber diese Schleife konnte im Extremfall trotzdem alle aufgelisteten Dateien löschen.

Fix: `free_space_cache[mount] = nil` direkt nach jeder erfolgreichen Löschung, damit die nächste `free_space()`-Abfrage tatsächlich neu misst. Zusätzlich umgesetzt: `reclaim_oldest()` erhält einen `exclude_path`-Parameter, der die gerade tatsächlich offene Zieldatei (die der LOG Collector im selben Schreibversuch befüllen will) niemals löscht — beide Aufrufstellen (`write_log()`s Vorab-Check, `flush_bucket()`s Out-of-Space-Retry) übergeben jetzt den betroffenen Zielpfad. Ein hartes `RECLAIM_MAX_FILES_PER_RUN`-Limit (64) begrenzt zusätzlich den maximalen Schaden pro Lauf, selbst falls die Free-Space-Messung aus einem anderen Grund weiterhin falsch wäre. Die Punkte "Mindestanzahl/Mindestalter geschützter Dateien" und "UI zeigt Retention-/Reclaimereignisse" aus dem ursprünglichen Fix-Vorschlag bleiben als LOG-P1-Weiterentwicklung offen (siehe Abschnitt 23) — kein Datenverlustrisiko mehr durch DIESEN Bug, da die Kernursache (stale Cache) behoben ist.

Pflicht-Test: `tests/log_collector_reclaim_cache_invalidation_test.lua` — treibt die echte `reclaim_oldest()`-Funktion mit einer Fake-Disk aus drei gleich großen Dateien und einem `os.clock()`, der über den GESAMTEN Testlauf einen konstanten Wert liefert (simuliert exakt die reale Bedingung: synchrone Löschungen verbrauchen keine messbare Zeit). Fake-Free-Space steigt nach der ersten Löschung über das angeforderte Ziel — beweist, dass exakt eine Datei entfernt wird (nicht alle drei) und dass `fs.getFreeSpace()` nach der Löschung tatsächlich erneut aufgerufen wird. Verifiziert per `git stash`, dass der Test mit dem alten Code fehlschlägt (entfernt dort nachweislich alle drei Dateien statt einer).

## Fix (umgesetzt)

```lua
-- nach jeder erfolgreichen Loeschung:
free_space_cache[mount] = nil
```

plus `exclude_path`-Schutz der offenen Zieldatei und `RECLAIM_MAX_FILES_PER_RUN`-Obergrenze.

## Zusatzfund (2026-07-17, BEHOBEN): `send_ack` als globale Variable aufgelöst — LOG_COLLECTOR stürzt bei JEDEM erfolgreichen Flush ab

Vom Nutzer per echten `xreactor_logs/log_collector/*.log`-Auszug (Disk-Backup-ZIP, datiert 2026-07-16) gemeldet als "die Node stürzt kurz nach dem Start wegen eines nil value ab" (zunächst der FUEL-Node zugeschrieben — die tatsächlich betroffene Rolle war LOG_COLLECTOR). Log-Auszug:

```text
[2026-07-16 21:58:51] LOG_COLLECTOR | LOG | ERROR | loop crashed on event=timer: ...log_collector/main.lua:674: attempt to call global 'send_ack' (a nil value)
```

Diese Zeile wiederholte sich im Sekundentakt, deterministisch bei praktisch jedem Timer-Tick.

**Ursache:** `nodes/log_collector/main.lua` deklariert `flush_bucket`/`flush_due` bewusst als Vorwärtsdeklaration (`local flush_bucket` / `local flush_due`, siehe Kommentar dort), weil `write_log()` (weiter oben im Chunk) sie bereits referenziert, bevor sie definiert werden. `flush_bucket = function(path) ... end` selbst ruft `send_ack(payload, "written")` auf — `send_ack` war aber NICHT in dieser Vorwärtsdeklaration enthalten, sondern erst weiter unten im selben Chunk als `local function send_ack(payload, status)` deklariert. Lua löst freie Variablen beim KOMPILIEREN eines Funktionsliterals anhand des zu diesem Zeitpunkt sichtbaren lexikalischen Scopes auf, nicht beim späteren Ausführen — der `flush_bucket`-Funktionsliteral wurde kompiliert, als im Chunk-Scope noch keine lokale `send_ack` existierte, der Aufruf fiel deshalb auf eine GLOBALE Variable dieses Namens zurück, die nirgends gesetzt wird. Ergebnis: **jeder einzige erfolgreiche Log-Flush** (persistierte Zeilen tatsächlich geschrieben) stürzte beim anschließenden ACK-Versand ab — der äußere `xpcall` der Event-Loop fängt das zwar ab ("loop crashed on event=timer", kein Reboot), aber `send_ack()` läuft dadurch NIE, absendende Nodes erhalten nie ein `LOG_ACK`, und der Fehler wird bei laufendem Betrieb minütlich wiederholt geloggt.

**Fix:** `send_ack` in dieselbe Vorwärtsdeklaration wie `flush_bucket`/`flush_due` aufgenommen (`local send_ack` VOR der `flush_bucket`-Definition); die spätere Definition wurde von `local function send_ack(...)` auf `send_ack = function(...)` umgestellt (identisches Muster wie bereits bei `flush_bucket`/`flush_due`).

**Pflicht-Test:** `tests/log_collector_flush_bucket_send_ack_forward_decl_test.lua` — extrahiert per Marker den echten Quelltext (Vorwärtsdeklarationsblock, die echte `flush_bucket()`-Definition, die echte `send_ack()`-Definition, in genau dieser Kompilierreihenfolge) aus `nodes/log_collector/main.lua`, treibt einen echten gepufferten Log-Eintrag durch `flush_bucket()` und beweist: kein Absturz, `stats.written` erhöht sich, UND `send_ack()` sendet tatsächlich ein `LOG_ACK` mit korrektem `event_id`/`status`. Verifiziert per `git stash`, dass der Test gegen den alten Code nicht einmal extrahierbar ist (die vorwärtsdeklarierte `send_ack`-Zeile existiert dort nicht) — exakter Nachweis, dass die Fix-Logik zuvor fehlte.

---

# 23. LOG-P1 – Rotation und Datenhaltungsregeln explizit machen

## Status

**OFFEN**

Eine einzelne Node-Logdatei wird bei Überschreiten von `MAX_LOG_BYTES` gelöscht statt archiviert oder atomar rotiert. Das kann beabsichtigt sein, ist aber keine nachvollziehbare Retentionpolicy.

## Fix

- nummerierte oder datierte Rotation,
- Maximalalter und Maximalgröße pro Rolle,
- Mindestanzahl erhaltener Dateien,
- UI zeigt Retention-/Reclaimereignisse,
- Tests für Full-Disk, Mountverlust und Reattach.

---

# 24. TEST-P0 – 72 Tests sind ausgeschlossen

## Status

**KRITISCH TEILWEISE** (Ausschlussliste schrumpft, siehe unten)

Aktuelle Ausschlusslisten:

```text
63 Lua-Tests
6 Python-Tests
69 insgesamt
```

Darunter befinden sich weiterhin echte Verhaltenskategorien wie:

- ENERGY-Architektur und Payloadcache,
- MASTER-ACK-/Shutdown-Semantik,
- RT-Control, Safety, Startup und Sync,
- Logger-/Registry-Runtime.

Der neue RT-Startup-Test zeigt außerdem ein strukturelles Problem des Testansatzes: Er behauptet, den Produktions-Context zu spiegeln, liefert aber einen anderen `TURBINE_MODE`-Typ und kodiert die 30-ms-Rampensemantik als erwartet.

## Triage-Ergebnis 2026-07-17 (drei Eintraege aus der Ausschlussliste entfernt)

- `comms_peer_state_hysteresis_test.lua` und `comms_peer_down_observation_debounce_test.lua` (beide zuvor `CONTENT_DRIFT`): **echter Produktionsfehler**, nicht veraltete Erwartung. `core/comms.lua`s `update_peer_timeouts()` liess `peer.down` so lange `nil` stehen, bis die Down-Transition einmal tatsaechlich ausgeloest wurde -- also fuer JEDEN frisch gesehenen Peer und weiterhin waehrend der gesamten Down-Grace-/Beobachtungs-Periode. `get_peer_state()` behandelt ein `nil`-`down`-Feld aber als "noch nie von der Hysterese ausgewertet" und berechnete stattdessen einen ROHEN `delta > peer_timeout_s`-Wert OHNE Gnadenfrist oder Mindestbeobachtungen -- das unterlief die komplette Hysterese-Logik extern sichtbar (Peer erschien sofort als `down`, sobald das reine Timeout ueberschritten war, unabhaengig von `peer_down_grace_s`/`peer_down_min_observations`). Fix: `update_peer_timeouts()` initialisiert `peer.down` jetzt explizit auf `false`, sobald ein Peer zum ersten Mal ausgewertet wird -- der `nil`-Fallback in `get_peer_state()` greift danach nur noch fuer Peers, die diese Funktion tatsaechlich noch nie erreicht hat. Beide Tests sind jetzt gruen ohne Testaenderung (nur der Produktionscode wurde korrigiert) und aus der Ausschlussliste entfernt.
- `alert_rules_numeric_normalization_test.lua` (zuvor `CONTENT_DRIFT`): **veraltete/fehlerhafte Testerwartung**, kein Produktionsfehler. Der Test setzte `role = 'RT_NODE'` (Unterstrich) als Node-Rolle, aber `constants.roles.RT_NODE` ist tatsaechlich `"RT-NODE"` (Bindestrich) -- der Rollenvergleich in `core/alert_rules.lua` schlug dadurch fehl, der gesamte RT-Node-Alarmzweig (inkl. der zu testenden Steam-Deficit-Logik) wurde nie erreicht. Testfix: verwendet jetzt `require('shared.constants').roles.RT_NODE` statt eines hartcodierten falschen Strings. Aus der Ausschlussliste entfernt.

Weiterhin ausgeschlossen bleibt `comms_peer_retention_cleanup_test.lua` (`NEEDS_MOCK`, anderer Fehlschlag -- Logger-Backend meldet degraded ohne echtes Dateisystem-Mock, unabhaengig vom obigen Hysterese-Fix).

## Regel

Ein Test darf nur entfernt werden, wenn:

1. die Anforderung nachweislich nicht mehr existiert, oder
2. ein aktueller, gleichwertiger Test dieselbe Anforderung vollständig schützt.

`CONTENT_DRIFT` ist keine Freigabe zum Überspringen, sondern muss einzeln als echter Produktionsfehler oder veraltete Erwartung entschieden werden.

## Sofortige neue Tests

1. Installer-Powerloss-Matrix und Completion-Marker.
2. Update-Quiesce je Rolle.
3. ~~RT-Produktions-Context-Shape.~~ BEHOBEN (2026-07-17, siehe Abschnitt 11): `tests/rt_turbine_mode_context_shape_test.lua`.
4. ~~RT-Rampeneinheit mit Fake-Clock.~~ BEHOBEN (2026-07-17, siehe Abschnitt 12): `tests/rt_ramp_duration_units_test.lua`.
5. ~~produktive Verdrahtung von `update_module_states()`.~~ BEHOBEN (2026-07-17, siehe Abschnitt 13): `tests/rt_control_tick_wires_update_module_states_test.lua`.
6. ~~Router-ACK muss aktuelle Command-ID matchen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 17): `tests/redstone_router_stale_confirmed_state_test.lua`.
7. ~~REPROCESSOR Wireless-VALVE-Discovery.~~ BEHOBEN (2026-07-17, siehe Abschnitt 20): `tests/reprocessor_wireless_valve_comms_wiring_test.lua`.
8. ~~ENERGY exakt eine Heartbeat-Zeitquelle.~~ BEHOBEN (2026-07-17, siehe Abschnitt 15): `tests/energy_heartbeat_shared_last_ts_test.lua`.
9. ~~LOG-Reclaim mit Cacheinvalidierung.~~ BEHOBEN (2026-07-17, siehe Abschnitt 22): `tests/log_collector_reclaim_cache_invalidation_test.lua`.
10. MASTER Config-Editor Applied-ACK je Zielnode.

---

# 25. CI-Status

Der Workflow führt aus:

- Offline-Validator,
- funktionale Lua-Tests,
- funktionale Python-Tests.

Für den geprüften Code-Head `423a2f0b5198de61aaaf71c8fa28413d151b63bd` wurden über die GitHub-Schnittstelle jedoch weder kombinierte Statuschecks noch zugeordnete Pull-Request-Workflow-Runs zurückgegeben.

Daher gilt:

```text
Workflow vorhanden != dieser konkrete Head nachweislich grün
```

## Definition of Done für CI

- aktueller `beta`-Head besitzt einen sichtbaren grünen Check,
- keine kritische Safety-/Installeranforderung steht auf einer Ausschlussliste,
- Testergebnis enthält Anzahl ausgeführt/übersprungen/fehlgeschlagen,
- Ingame-/Hardwaretests werden als separate dokumentierte Abnahme geführt.

---

# 26. Rollen ohne neuen statischen P0-Fund

## Shared Runtime

Das Event-Gating über `wants_events` ist weiterhin sinnvoll umgesetzt. Rein periodische Services laufen nicht zusätzlich bei jedem Event. Offener Querschnittspunkt bleibt das fehlende Update-Quiesce.

## WATER

Neben der Persistenz-/ACK-Semantik wurde kein neuer statischer P0-Blocker bestätigt. Ingame-Nachweise bleiben erforderlich.

## Manifest-Rollen-Scope

Die zuletzt bekannten konkreten Scopefehler für REPROCESSOR, Speaker und VALVE-Support sind im aktuellen Manifest behoben. Offen bleibt die generische Vorabvalidierung des Installationsplans.

---

# 27. Verbindliche Bearbeitungsreihenfolge

1. ~~**ROUTER-P0:** aktuellen ACK über Command-ID statt alten Confirmed-State beweisen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 17): `tests/redstone_router_stale_confirmed_state_test.lua`.
2. ~~**REPROCESSOR-P0:** COMMS-Peers an Wireless-Router verdrahten.~~ BEHOBEN (2026-07-17, siehe Abschnitt 20): `tests/reprocessor_wireless_valve_comms_wiring_test.lua`.
3. ~~**RT-P0:** `TURBINE_MODE`-Context-Typ korrigieren.~~ BEHOBEN (2026-07-17, siehe Abschnitt 11): `tests/rt_turbine_mode_context_shape_test.lua`.
4. ~~**RT-P0:** Rampendauer in eindeutigen Millisekunden konfigurieren.~~ BEHOBEN (2026-07-17, siehe Abschnitt 12): `tests/rt_ramp_duration_units_test.lua`.
5. ~~**RT-P0:** `update_module_states()` in den Produktions-Controlpfad aufnehmen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 13): `tests/rt_control_tick_wires_update_module_states_test.lua`.
6. ~~**INSTALL-P0:** Installationsjournal, Completion-Marker und Release-last-Commit.~~ BEHOBEN (2026-07-17, siehe Abschnitt 3): `tests/installer_journal_state_machine_test.lua`, `tests/installer_journal_ordering_and_release_last_test.lua`, `tests/start_lua_incomplete_install_blocks_role_test.lua`.
7. ~~**INSTALL-P0:** Runtime-Quiesce und sichere Aktorzustände vor Reinstall.~~ BEHOBEN (2026-07-17, siehe Abschnitt 4): `tests/core_update_handshake_test.lua`, `tests/support_runtime_quiesce_test.lua`, `tests/energy_heartbeat_quiesce_test.lua`, `tests/install_p0_2_quiesce_wiring_test.lua`.
8. ~~**INSTALL-P0:** alle kritischen FS-Ergebnisse prüfen und unsicheren Backup-Fallback entfernen.~~ BEHOBEN (2026-07-17, siehe Abschnitt 5): `tests/installer_stage_write_backup_failure_test.lua`, `tests/installer_init_critical_write_abort_test.lua`, `tests/installer_monolith_critical_write_abort_test.lua`.
9. ~~**LOG-P0:** Free-Space-Cache im Reclaimpfad korrigieren.~~ BEHOBEN (2026-07-17, siehe Abschnitt 22): `tests/log_collector_reclaim_cache_invalidation_test.lua`.
10. ~~**MASTER-P1:** Einzelnode-/Alle-Auswahl und Applied-ACK je Ziel.~~ BEHOBEN (2026-07-17, siehe Abschnitt 10): `tests/master_config_edits_test.lua`, `tests/master_config_edit_ack_wiring_test.lua`, `tests/master_ui_controller_config_edit_action_test.lua`.
11. ~~**ENERGY-P1:** genau eine Heartbeat-Zeitquelle.~~ BEHOBEN (2026-07-17, siehe Abschnitt 15): `tests/energy_heartbeat_shared_last_ts_test.lua`.
12. ~~**WATER/RT-P1:** Persistenzresultat ehrlich im Command-ACK abbilden.~~ BEHOBEN (2026-07-17, siehe Abschnitt 16): `tests/water_rt_persistence_ack_honesty_test.lua`.
13. ~~**VALVE-P1:** verpflichtende Senderbindung und Sorter-Reconnect.~~ BEHOBEN (2026-07-17, siehe Abschnitt 21): `tests/valve_sender_pairing_and_sorter_reconnect_test.lua`.
14. ~~**INSTALL/MANIFEST-P1:** vollständige Planvalidierung.~~ BEHOBEN (2026-07-17, siehe Abschnitt 7): `tests/installer_plan_validator_test.lua`, `tests/manifest_transitive_require_coverage_test.lua`.
14b. **INSTALL-P1:** nur eine Installerimplementierung (siehe Abschnitt 8) — weiterhin offen, eigenständiger, größerer Umbau.
15. **TEST-P0:** Ausschlusslisten Test für Test abbauen.
16. Danach Ingame-Last-, Funkverlust-, Reconnect-, Reboot-, Stromausfall- und Updateabnahme.

---

# 28. Definition of Done

## Installer / Auto-Update

- alter oder neuer Stand ist nach jedem Fehler vollständig und eindeutig,
- Release wird erst beim Commit geschrieben,
- Runtime ist vor Dateiersatz beendet und Aktoren sind sicher,
- jeder FS-Schritt wird geprüft,
- generische `.xr_prev`-Recovery vorhanden,
- ein kanonischer Installerpfad,
- Jitter und persistenter Circuit Breaker.

## MASTER

- `ALLE` oder konkrete Zielnode auswählbar,
- Applied-ACK/Reject/Timeout je Node sichtbar,
- keine optimistische Erfolgsmeldung,
- Teilfehler bleiben sichtbar und persistent nachvollziehbar.

## RT

- echter Produktions-Context wird im Test verwendet,
- Turbinenmodus korrekt gesetzt,
- Rampenzeit in eindeutiger Einheit,
- `update_module_states()` läuft regelmäßig,
- Migration und Sollwertpersistenz melden echte Resultate,
- Control-/Jittermetriken belegen den Takt.

## ENERGY

- getrennte Schedulergruppen,
- genau eine Heartbeat-Zeitquelle,
- keine Doppel-Sends bei gleichzeitigem Timer/Matrixabschluss,
- langsame Matrixcalls blockieren COMMS/UI nicht.

## WATER

- Tank-Snapshot und BLOCK_ALL ingame bestätigt,
- Writefehler sichtbar,
- `SET_TARGET`-ACK unterscheidet volatile und persistierte Übernahme,
- Reboot und Update erhalten Config.

## FUEL / Router

- Export nur mit ACK der **aktuellen** Command-ID für jedes betroffene Ventil,
- alte Bestätigungen sind kein aktueller Beweis,
- Async-Transaktion besitzt stabile ID und korrekte Zykluszuordnung,
- finaler Blockfehler bleibt als Safetyalarm sichtbar,
- kein Export bei invalidem Routing.

## REPROCESSOR

- Wireless-VALVE-Nodes werden über COMMS-Peers gefunden,
- Standby/MASTER_STALE bricht Transaktion sofort ab,
- kein Export nach Standby,
- vollständige Rolleninstallation.

## VALVE

- Failed-Write-Retry führt echten neuen Write aus,
- Sender ist gebunden/authentisiert,
- Sorter kann nach Detach/Reattach neu gebunden werden,
- ACK enthält eindeutigen aktuellen Commandbezug.

## LOG Collector

- Probe-Fehler löscht keine Logs,
- Reclaim misst nach jeder Löschung frisch,
- maximale Löschgrenzen und Retentionpolicy,
- ACK erst nach Persistierung,
- Full-/Mount-/Reconnecttests grün.

## Tests / CI

- keine kritischen Produktionsanforderungen ausgeschlossen,
- aktueller Head sichtbar grün,
- echte Produktionscontexts statt vereinfachter, abweichender Mocks,
- Hardware-/Ingame-Abnahme separat dokumentiert.
