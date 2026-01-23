# Testplan (Finalisierung)

## Install/Update
1. **Fresh Install**: MASTER/RT/ENERGY mit `lua /installer.lua`.
2. **SAFE UPDATE** aus bestehender Beta-Installation (ohne Config-Reset).
3. **FULL REINSTALL** optional mit Restore von Config/Node-ID.

## Kommunikation
1. **ACK/Retry**: Simuliere Paketverlust (debug drop) und prüfe Retry + ACK (delivered/applied).
2. **Timeouts**: Prüfe, dass nach max retries klare Logmeldung erfolgt.
3. **Proto-Mismatch**: absichtlich proto_ver ändern → Status DEGRADED + keine Command-Ausführung.

## Registry/Discovery
1. Geräte-Registry erzeugt stabile IDs und behält Reihenfolge (kein Flackern).
2. Missing/Found aktualisiert mit last_seen + last_error.
3. Alias-Mapping aus Config sichtbar in UI.

## UI/Router
1. Master: Node list/Node detail/System summary navigierbar.
2. Nodes: Overview/Details/Diagnostics + Paging.
3. Dirty redraw: keine Full clears pro tick (nur bei Änderungen).

## Health/Degraded
1. Energy: fehlende Matrix/Storage führt zu DEGRADED + reason.
2. RT: fehlende Reactor/Turbine führt zu DEGRADED + reason.
3. Master: Node Overview zeigt Status + reasons + last_seen.

## Offline Verhalten
1. Master offline → Nodes gehen DEGRADED/AUTONOM.
2. Master wieder online → Status normalisiert.
