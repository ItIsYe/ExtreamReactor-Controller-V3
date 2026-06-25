# Node Start Blockers — 2026-06-25

Dieses Dokument ist die aktuelle Übergabe für den `beta`-Stand.

Letzte Nachprüfung: 2026-06-25, nach den v158-Änderungen.

Wichtig:

- Kein Ingame-Test wurde für diese Analyse gemacht.
- Nichts wurde ingame installiert.
- Diese Datei beschreibt nur die statische Repo-Prüfung.

## Verification update — 2026-06-25 / v158

Aktuelle Nachprüfung gegen `beta`:

- `xreactor/nodes/fuel/main.lua`: **gefixt sichtbar** — `redstone_router_lib` ist jetzt required; `is_master_connected` und `master_peer_state` sind vorwärts deklariert und später per Zuweisung gesetzt.
- `xreactor/nodes/water/main.lua`: **gefixt sichtbar** — `is_master_connected` und `master_peer_state` sind vorwärts deklariert und später per Zuweisung gesetzt.
- `xreactor/nodes/reprocessor/main.lua`: **gefixt sichtbar** — `process_state` und `get_feed_router` stehen vor `build_status_payload()`; `get_feed_router` wird später per Zuweisung gesetzt.
- `xreactor/nodes/energy/main.lua`: **teilweise/gefixt genug für Callback** — `record_error` ist jetzt definiert und wird an Runtime-Module übergeben. Kleiner Hinweis: Die Funktion steht vor `local devices = runtime.devices`; dadurch schreibt `if devices then devices.last_error = msg end` wahrscheinlich nicht in das lokale `devices`, aber Logging funktioniert und der fehlende Callback-Blocker ist weg.
- `xreactor/nodes/log_collector/main.lua`: **gefixt sichtbar** — Header wird jetzt als ein einziges volles Segment gerendert; das vorherige `fill_line(1, ...)` + `line_ui(2, 1, ...)` Overlap ist weg.
- `xreactor/nodes/rt/main.lua`: **weiterhin offen** — fehlendes Komma in `monitor_ui.update(...)` ist weiterhin vorhanden. Zusätzlich ist die Master-connected-Logik weiterhin falsch. Die UI-Werte wurden zwar auf `manifest-v157` / `beta-v157` geändert, aber Manifest/Release stehen aktuell bereits auf `v158`.
- `xreactor/manifest.lua` / `xreactor/release.lua`: **geändert, prüfen** — aktueller Stand ist `manifest-v158` / `beta-v158` mit `hash_algo = "crc32"`. Das weicht von der früheren Übergabe ab, in der `hash_algo = "none"` absichtlich gesetzt war. Das ist nur dann okay, wenn die CRC/Size-Metadaten wirklich aus einem echten Checkout sauber regeneriert wurden.

## Aktueller Kurzstatus

Vor einem späteren Ingame-Test bleiben mindestens diese Punkte offen:

1. `xreactor/nodes/rt/main.lua` — Syntax-/Parse-Blocker in `update_monitor()` fixen.
2. `xreactor/nodes/rt/main.lua` — Master-connected-Logik fixen.
3. `xreactor/nodes/rt/main.lua` — UI-Buildwerte nicht hart/falsch auf `v157` lassen, sondern passend zu Release/Manifest `v158` machen oder dynamisch aus Build/Release lesen.
4. `xreactor/manifest.lua` / `xreactor/release.lua` — verifizieren, ob `hash_algo = "crc32"` wirklich sauber regeneriert wurde. Falls nicht, wieder bewusste Beta-Strategie festlegen.
5. Statische Lua-Parse-/Require-Prüfung über alle Rollen laufen lassen.

---

## 1. RT node: weiterhin Parse-/Syntax-Blocker

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
- Dadurch ist `nodes/rt/main.lua` weiterhin sehr wahrscheinlich nicht parsebar.

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

Zusatzproblem:

```lua
manifest_id = "manifest-v157",
release_id  = "beta-v157",
```

Aktuell stehen Manifest/Release aber auf `v158`. Diese Werte sollten nicht hart codiert bleiben.

Empfohlener Fix:

- Entweder aus `xreactor/release.lua` / `shared.build_info` lesen.
- Oder die Felder entfernen, falls `monitor_ui` sie nur optional anzeigt.

Weiteres RT-Logikproblem:

```lua
if message.role == constants.roles.MASTER then
  master_seen_ts = os.epoch("utc")
  ...
  if not master_seen_ts then
    log("INFO", "Master connected: " .. tostring(message.role or "?"))
  end
end
```

Problem:

- `master_seen_ts` wird gesetzt und direkt danach geprüft.
- `if not master_seen_ts` wird dadurch nie wahr.

Empfohlener Fix:

```lua
if message.role == constants.roles.MASTER then
  local was_connected = master_seen_ts ~= nil
  master_seen_ts = os.epoch("utc")
  ...
  if not was_connected then
    log("INFO", "Master connected: " .. tostring(message.role or "?"))
  end
end
```

---

## 2. Bereits sichtbar gefixte Punkte

### FUEL

Datei:

```text
xreactor/nodes/fuel/main.lua
```

Aktueller Status:

- `local redstone_router_lib = require("nodes.fuel.redstone_router")` ist vorhanden.
- `local is_master_connected` und `local master_peer_state` stehen vor `build_status_payload()`.
- Spätere Funktionsdefinitionen wurden zu Zuweisungen geändert.

### WATER

Datei:

```text
xreactor/nodes/water/main.lua
```

Aktueller Status:

- `local is_master_connected` und `local master_peer_state` stehen vor `build_status_payload()`.
- Spätere Funktionsdefinitionen wurden zu Zuweisungen geändert.

### REPROCESSING

Datei:

```text
xreactor/nodes/reprocessor/main.lua
```

Aktueller Status:

- `local get_feed_router` und `local process_state = {}` stehen vor `build_status_payload()`.
- `get_feed_router = function() ... end` steht später und ist dadurch für frühere Funktionskörper sichtbar.

### ENERGY

Datei:

```text
xreactor/nodes/energy/main.lua
```

Aktueller Status:

- `record_error` ist jetzt definiert und wird an Runtime-Module übergeben.
- Kleiner Follow-up: Die Funktion steht vor der lokalen `devices`-Deklaration. Dadurch loggt sie zwar, schreibt aber vermutlich nicht nach `devices.last_error`. Bei Bedarf Funktion hinter `local devices = runtime.devices` verschieben.

### LOG collector

Datei:

```text
xreactor/nodes/log_collector/main.lua
```

Aktueller Status:

- Header-Segment-Overlap ist sichtbar gefixt.
- Der Header wird nun als ein einziges volles Segment geschrieben.

---

## 3. Manifest / Release Prüfpunkt

Aktueller Stand:

```lua
manifest_version = 158
manifest_id = "manifest-v158"
hash_algo = "crc32"
```

und:

```lua
release_id = "beta-v158"
manifest_id = "manifest-v158"
hash_algo = "crc32"
```

Hinweis:

- Frühere Übergabe sagte: `hash_algo = "none"` war absichtlich.
- Jetzt wurde wieder auf `crc32` umgestellt.
- Das ist nur dann sauber, wenn alle `size_bytes` und `hash` Werte aus einem echten Checkout korrekt regeneriert wurden.
- Ohne diese Prüfung kann der Installer später wegen falscher CRC/Size blockieren.

---

## 4. Danach statisch prüfen

Nach dem RT-Fix und Manifest/CRC-Check sollte zuerst **ohne Ingame-Test** geprüft werden:

```text
1. Lua-Parse über alle xreactor/**/*.lua
2. Require-Ketten prüfen
3. Rollen-Entrypoints prüfen:
   - xreactor/master/main.lua
   - xreactor/nodes/rt/main.lua
   - xreactor/nodes/energy/main.lua
   - xreactor/nodes/water/main.lua
   - xreactor/nodes/fuel/main.lua
   - xreactor/nodes/reprocessor/main.lua
   - xreactor/nodes/log_collector/main.lua
4. Manifest/Release v158 + crc32-Metadaten prüfen.
5. Erst danach entscheiden, ob später ein Ingame-Test sinnvoll ist.
```

## Priorität

1. RT Syntax fixen.
2. RT Master-connected-Logik fixen.
3. RT Build/Release-Anzeige auf v158/dynamisch korrigieren.
4. Manifest/Release CRC32-Metadaten verifizieren.
5. Statische Checks laufen lassen.

Bis diese Punkte erledigt sind: weiterhin nicht ingame installieren oder testen.
