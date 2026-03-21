# Testplan (Finalisierung)

## Install/Update
1. **Fresh Install**: MASTER/RT/ENERGY mit `installer`.
2. **SAFE UPDATE** aus bestehender Beta-Installation (ohne Config-Reset).
3. **First-Start Setup**: Rollenwahl, Label (`XR-ROLE-ID`) + `node-<ID>` erzeugt, `/xreactor/config/role.lua` plus `/xreactor/config/node_id.txt` geschrieben, Reboot läuft durch.
4. **Low-Space Abort**: Fülle Disk fast voll → SAFE UPDATE starten → erwarteter sauberer Abbruch mit Disk-Übersicht, Log-Eintrag, keine Stage/Backup-Reste.
5. **Rollen-Minimalinstallation**: RT/Energy-Install → prüfen, dass keine `xreactor/master/ui/*` und keine fremden Nodes-Ordner installiert wurden.
6. **Delta-Update**: Nur eine Datei im Repo ändern → Manifest aktualisieren → SAFE UPDATE → es wird nur diese Datei (+ Manifest) geladen/aktualisiert, Backup enthält nur ersetzte Dateien.
7. **Config-Migration**: Alte Config ohne `version` starten → Defaults ergänzt, bestehende Werte bleiben erhalten, Config wird gespeichert.

## Kommunikation
1. **ACK/Retry**: Simuliere Paketverlust (debug drop) und prüfe Retry + ACK (delivered/applied) nur für `COMMAND`, nicht für `STATUS`/`HEARTBEAT`.
2. **Timeouts**: Prüfe, dass nach max retries klare Logmeldung erfolgt.
3. **Proto-Mismatch**: absichtlich proto_ver ändern → Status DEGRADED + keine Command-Ausführung.

## Registry/Discovery
1. Geräte-Registry erzeugt stabile IDs und behält Reihenfolge (kein Flackern).
2. Missing/Found aktualisiert mit last_seen + last_error.
3. Alias-Mapping aus Config sichtbar in UI.
4. RT/FUEL/WATER Fluid-Lesen bevorzugt `tanks()`; Legacy-Methoden nur als Fallback testen.

## UI/Router
1. Master: Node list/Node detail/System summary navigierbar.
2. Nodes: Overview/Details/Diagnostics + Paging.
3. Dirty redraw: keine Full clears pro tick (nur bei Änderungen).
4. UI-Dirty-Redraw: verkürzte Texte überschreiben Restzeichen korrekt; Monitor-Resize invalidiert einmalig und rendert dann stabil.
5. Monitor-Scale: `setTextScale` nur bei echter Scale-Änderung oder neuem Monitor.

## Service-Stabilität
1. Fehlernder Service wird mit Exponential-Backoff erneut versucht und nicht in jedem Tick neu gespammt.
2. Erfolgreicher Tick/Init setzt den Backoff zurück.

## Health/Degraded
1. Energy: fehlende Matrix/Storage führt zu DEGRADED + reason.
2. RT: fehlende Reactor/Turbine führt zu DEGRADED + reason.
3. Master: Node Overview zeigt Status + reasons + last_seen.

## Offline Verhalten
1. Master offline → Nodes gehen DEGRADED/AUTONOM.
2. Master wieder online → Status normalisiert.
