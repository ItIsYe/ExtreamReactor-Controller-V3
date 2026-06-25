# Node Start Blockers — 2026-06-25

Aktuelle statische Nachprüfung: 2026-06-25, `beta` / `beta-v165`.

Wichtig:

- Kein Ingame-Test wurde gemacht.
- Nichts wurde ingame installiert.
- Diese Datei beschreibt nur den statisch geprüften Repo-Stand.

## Ergebnis

Die vorherige Aussage „Alle Punkte aus dieser Datei wurden behoben (beta-v160)“ war nicht korrekt.

Mehrere frühere Blocker sind sichtbar gefixt, aber `RT` hat weiterhin einen harten Parse-/Syntax-Blocker.

## Aktuell weiterhin offen

### 1. RT Parse-/Syntax-Blocker

Datei:

```text
xreactor/nodes/rt/main.lua
```

Aktueller Bereich:

```lua
last_status_snapshot = monitor_ui.update(mon, {
  ...
  build_health_payload = function() return build_status_payload() end
  read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
  read_turbine_flow = function(t, c) return turbine_control.read_turbine_flow(ctx, t, c) end,
  ...
})
```

Problem:

- Nach `build_health_payload = function() ... end` fehlt weiterhin ein Komma.
- Dadurch ist `xreactor/nodes/rt/main.lua` weiterhin sehr wahrscheinlich nicht parsebar.
- Das blockiert den RT-Node-Start.

Minimaler Fix:

```lua
build_health_payload = function() return build_status_payload() end,
read_turbine_rpm = function(t, c) return turbine_control.read_turbine_rpm(ctx, t, c) end,
read_turbine_flow = function(t, c) return turbine_control.read_turbine_flow(ctx, t, c) end,
reactor_adapter = adapters.reactor,
turbine_adapter = adapters.turbine,
log_prefix = CONFIG.LOG_PREFIX,
get_device_caps = function(k, n) return turbine_control.get_device_caps(ctx, k, n) end,
get_available_steam = function() return reactor_control.get_available_steam(ctx) end,
```

### 2. RT Build-Werte noch hart codiert

Aktueller Stand in `xreactor/nodes/rt/main.lua`:

```lua
manifest_id = "manifest-v158",
release_id  = "beta-v158",
```

Aktueller Release-/Manifest-Stand ist aber `v165`.

Empfehlung:

- Nicht hart codieren.
- Dynamisch aus `xreactor/release.lua` oder `shared.build_info` lesen.
- Alternativ auf `manifest-v165` / `beta-v165` aktualisieren, aber dynamisch ist besser.

### 3. Manifest-Kommentar inkonsistent

Datei:

```text
xreactor/manifest.lua
```

Aktueller Inhalt beginnt sinngemäß mit:

```lua
-- xreactor/manifest.lua -- manifest-v156
return {
  manifest_version = 165,
  manifest_id = "manifest-v165",
  hash_algo = "crc32",
```

Problem:

- Der Kommentar sagt noch `manifest-v156`.
- Die Werte sagen `manifest-v165`.

Das ist kein Runtime-Blocker, aber sollte für saubere Übergabe korrigiert werden.

### 4. CRC32 muss verifiziert bleiben

Manifest/Release stehen aktuell auf:

```lua
hash_algo = "crc32"
```

Das ist nur dann sauber, wenn die `size_bytes` und `hash` Werte wirklich aus einem echten Checkout korrekt regeneriert wurden.

Falls das nicht sicher ist, kann der Installer später wegen falscher CRC/Size-Werte blockieren.

## Sichtbar gefixt

### FUEL

Datei:

```text
xreactor/nodes/fuel/main.lua
```

Status:

- `redstone_router_lib` ist required.
- `is_master_connected` und `master_peer_state` sind vorwärts deklariert.
- Die späteren Funktionen sind per Zuweisung gesetzt.

### WATER

Datei:

```text
xreactor/nodes/water/main.lua
```

Status:

- `is_master_connected` und `master_peer_state` sind vorwärts deklariert.
- Die späteren Funktionen sind per Zuweisung gesetzt.

### REPROCESSING

Datei:

```text
xreactor/nodes/reprocessor/main.lua
```

Status:

- `get_feed_router` und `process_state` stehen vor `build_status_payload()`.
- `get_feed_router` wird später per Zuweisung gesetzt.

### ENERGY

Datei:

```text
xreactor/nodes/energy/main.lua
```

Status:

- `record_error` ist definiert und wird an Runtime-Module übergeben.

Kleiner Hinweis:

- Die Funktion steht vor `local devices = runtime.devices`.
- Dadurch schreibt `if devices then devices.last_error = msg end` vermutlich nicht in das lokale `devices`.
- Logging funktioniert trotzdem; der ursprüngliche fehlende Callback-Blocker ist weg.

### LOG collector

Datei:

```text
xreactor/nodes/log_collector/main.lua
```

Status:

- Header-Segment-Overlap ist sichtbar gefixt.
- Der Header wird als ein einziges volles Segment gerendert.

## Nächste Priorität

1. RT-Komma in `monitor_ui.update(...)` fixen.
2. RT Build-Werte dynamisch oder auf v165 aktualisieren.
3. Manifest-Kommentar von `manifest-v156` auf `manifest-v165` korrigieren.
4. CRC32-Metadaten durch echten Checkout/statischen Check verifizieren.
5. Danach Lua-Parse-/Require-Prüfung über alle Rollen laufen lassen.

Bis Punkt 1 erledigt ist: `beta` weiterhin nicht ingame installieren oder testen.
