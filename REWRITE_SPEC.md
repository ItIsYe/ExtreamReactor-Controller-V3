# XReactor Controller V3 — Rewrite-Spezifikation
**Für: Coding-KI / Entwickler**
**Repo:** `ItIsYe/ExtreamReactor-Controller-V3` Branch: `beta`
**Ursprünglicher Stand bei Spec-Erstellung:** v192
**Sprache:** Lua 5.1 (CC:Tweaked / CraftOS 1.9, Minecraft 1.21.1)

> **Status (2026-07-07): Alle vier Phasen umgesetzt, aktueller Stand v358.**
> Diese Spezifikation bleibt als Architektur-Referenz gültig und beschreibt weiterhin akkurat den Aufbau der umgesetzten Module (Installer, Energy, Master, Shared Services). Nach der initialen Umsetzung wurden zusätzliche Härtungsfixes nötig, die über die ursprüngliche Spec hinausgehen (siehe README.md und RUNTIME_STATUS_2026-06-03.md für die vollständige, datierte Historie):
> - `shell.run()` durch `dofile()` ersetzt in `installer/auto_update.lua` und `start.lua` (`shell` nicht verfügbar in `parallel`-Coroutinen).
> - SHA-Auflösung via `api.github.com` aus dem Auto-Update-Check-Pfad entfernt (verursachte Hänger auf RT).
> - Reinstall sichert/restauriert `/xreactor/config/role.lua` (und weitere PRESERVE-Dateien) in BEIDEN Installer-Codepfaden, da kein Stage/Backup-Mechanismus mehr existiert (siehe MIGRATION.md).
> - `files_for_role()`-Logik für LOG/LOG_COLLECTOR gefixt.
> - Log-Transport-Kanal-Mismatch (6502 vs. 6503) gefixt.
> - Setpoint-Fluss (Master → RT) und PEAK-Profil-Berechnung gehärtet — beide waren zeitweise fehlerhaft, sind seit 2026-07-07 gefixt.
> - UI-Redesign (zentrales Badge-Layout-System, erweiterte Summary-Seite, Ampel-Statusmonitor) abgeschlossen.
>
> Keine bekannten offenen Blocker zum Zeitpunkt dieses Updates.

---

## 1. Projektkontext

XReactor Controller V3 ist ein SCADA-ähnliches verteiltes Steuerungssystem für das Minecraft-Mod **Extreme Reactors 2** im Modpack ATM10. Es steuert Kernreaktoren und Dampfturbinen über ein Funknetzwerk von CC:Tweaked-Computern.

### Systemarchitektur (Nodes)

| Role | Beschreibung |
|------|-------------|
| `MASTER` | Zentrale Steuerung: berechnet Sollwerte, verteilt an RT-Nodes, überwacht Energiespeicher |
| `RT` (Reactor/Turbine) | Regelt Reaktorstäbe und Turbinen-Dampffluss direkt per Peripheral-API |
| `ENERGY` | Überwacht Mekanism Induction Matrix (Energiespeicher), sendet Füllstand an Master |
| `WATER` | Verwaltet Wasserversorgung für Reaktorkühlkreislauf |
| `FUEL` | Verwaltet Brennstofflogistik |
| `LOG_COLLECTOR` | Empfängt Remote-Logs aller Nodes via Funk, schreibt auf Disk |

### Kommunikation
- Wireless Modems, CC:Tweaked-eigenes Event-System (`os.pullEvent`)
- Modem-Kanäle: Control=6500, Status=6501, Log=6503
- Heartbeat alle 2s, Timeout 30-45s
- Protokoll: eigenes JSON-ähnliches Tabellenformat via `textutils.serialize`

### CC:Tweaked Besonderheiten (KRITISCH)
- **Kein echtes Threading** — `parallel.waitForAny()` ist kooperatives Multitasking via Coroutinen
- **Kein `require` ohne Bootstrap** — Dateien werden per `dofile()` oder eigenem `require`-Wrapper geladen
- **Event-Loop blockiert alles** — eine blockierende Peripheral-API-Abfrage (z.B. Mekanism Matrix: 1-3s) verhindert dass Timer-Events verarbeitet werden
- **`os.pullEvent()` ohne Filter** muss genutzt werden wenn parallel Threads laufen — gefiltertes `pullEvent("timer")` verpasst Events wenn andere Threads sie konsumieren
- **Kein `pcall` über `coroutine.yield`** — Fehlerbehandlung muss vor yield-Punkten stattfinden
- **Peripheral-Zugriff per Name** — `peripheral.wrap("BigReactors-Reactor_4")` gibt nil wenn nicht direkt verbunden

---

## 2. Was NICHT neu geschrieben wird

Diese Komponenten laufen stabil und bleiben unverändert:

- **`nodes/rt/`** (komplett) — RT-Node läuft zuverlässig, Setpoints korrekt, Reaktorregler funktioniert
- **`adapters/`** — Peripheral-Adapter für Reaktor, Turbine, Matrix, Monitor
- **`core/comms.lua`** — Kommunikationsschicht, stabil
- **`core/registry.lua`** — Device-Registry, stabil
- **`core/protocol.lua`** — Nachrichtenformat, stabil
- **`core/safety.lua`** — Sicherheitslogik, stabil
- **`core/control_rails.lua`** — PID/Ramp-Logik für Regelung, stabil
- **`shared/`** — Konstanten, Farben, Health-Codes — stabil
- **`services/comms_service.lua`** — Kommunikations-Service, stabil
- **`nodes/log_collector/main.lua`** — Log-Collector läuft gut
- **`nodes/water/`**, **`nodes/fuel/`**, **`nodes/reprocessor/`** — periphere Nodes, nicht kritisch

---

## 3. Was neu geschrieben wird (Phasen)

### Phase 1: Installer + Auto-Update

#### 3.1 Problem-Analyse (aktueller Stand)

**Dateistruktur (chaotisch):**
```
installer           ← Shell-Script, lädt installer_main.lua
installer_main.lua  ← 631 Zeilen Monolith
installer_http.lua  ← HTTP-Download-Logik
installer_manifest.lua ← Manifest-Vergleich
installer_stage.lua ← Install-Schritte
installer_storage.lua ← Datei-Schreiben
installer_startup.lua ← startup.lua schreiben + auto_update Config
```

**Bekannte Probleme:**
1. Auto-Update (`core/remote_update.lua` `auto_check_loop`) wird in `start.lua` gestartet, aber `safe_log` ist nil → alle Logs verworfen, kein Feedback ob Loop läuft
2. `dofile("/xreactor/core/remote_update.lua")` in `start.lua` scheitert manchmal lautlos
3. Hash-Kollisionen (CRC32) führen dazu dass Dateien nicht aktualisiert werden obwohl Inhalt unterschiedlich
4. 4 Retry-Versuche mit exponentiellem Backoff (2/5/10/20s) für Downloads — gut, aber HTML-Antworten (CDN-Fehler) werden nicht immer erkannt
5. SHA-PIN via GitHub API um CDN-Cache zu umgehen — funktioniert aber API-Calls schlagen manchmal fehl
6. `ensure_auto_update_config` legt Config an — aber nur wenn sie nicht existiert (gut), jedoch mit CRC32 Hash-Problem

#### 3.2 Neue Installer-Architektur

**Zielstruktur:**
```
xreactor/
└── installer/
    ├── init.lua         ← Einstiegspunkt (wird von /installer aufgerufen)
    ├── http.lua         ← Download: SHA-PIN + Retries + HTML-Check + Fallback
    ├── manifest.lua     ← Manifest laden, Dateien vergleichen (SHA256 statt CRC32)
    ├── stage.lua        ← Install-Schritte: download → verify → write → rollback
    ├── ui.lua           ← Fortschrittsanzeige im Terminal
    └── auto_update.lua  ← Versions-Check + Update-Trigger (standalone, kein Bootstrap nötig)
```

**`installer/auto_update.lua` — Anforderungen:**
- Muss **ohne Bootstrap** funktionieren (läuft in `start.lua` vor dem Node-Start)
- Nutzt `print()` direkt für Ausgabe (kein Logger)
- Gibt eine Funktion zurück die in `parallel.waitForAny()` läuft
- Prüft alle 120s ob neue Version verfügbar (konfigurierbar via `/xreactor/config/remote_update.lua`)
- SHA-PIN via GitHub API (3 Versuche, 10s Timeout) um CDN-Cache zu umgehen
- Vergleicht `manifest_version` aus lokalem `/xreactor/release.lua` mit GitHub
- Bei neuer Version: Installer herunterladen und ausführen (nicht `dofile` sondern `shell.run`)
- 3 Update-Versuche mit 5s Pause zwischen Versuchen
- Nach 3 fehlgeschlagenen Versuchen: 60s Extra-Pause, dann weiter mit normalem Zyklus
- HTML-Antwort-Erkennung: `body:sub(1,200):lower():find("<html")` → nicht gültiger Lua-Code
- Arming-Config `/xreactor/config/remote_update.lua` muss `enabled=true` und `auto_update=true` enthalten

**`installer/manifest.lua` — Anforderungen:**
- Hash-Algorithmus: **SHA256** statt CRC32 (CRC32 hat zu viele Kollisionen bei kleinen Dateien)
  - Fallback auf CRC32 wenn keine SHA256-Implementierung verfügbar (Rückwärtskompatibilität)
- Manifest-Format bleibt gleich: `{ path = "...", size_bytes = N, hash = "..." }`
- Vergleich: lokale Datei mit `fs.open` lesen, Hash berechnen, mit Manifest vergleichen
- Fehlende Dateien → immer herunterladen
- Größenabweichung → immer herunterladen (schneller als Hash-Check)
- Hash-Abweichung → herunterladen

**`installer/http.lua` — Anforderungen:**
```lua
-- Öffentliche API:
M.resolve_sha(repo, branch, timeout_s)  -- GitHub API SHA auflösen
M.download(url, opts)                    -- Download mit Retries
  -- opts: { retries=4, delays={2,5,10,20}, timeout=20, check_html=true }
  -- Rückgabe: body, err
M.download_file(repo, sha, path, opts)  -- Datei von GitHub herunterladen
  -- Versucht SHA-URL zuerst, Branch-URL als Fallback
```

**`installer/stage.lua` — Anforderungen:**
- Atomic Write: Datei erst in Temp-Pfad schreiben, dann umbenennen
- Rollback: Liste aller geschriebenen Dateien, bei Fehler wiederherstellen
- Fortschritts-Callback: `on_progress(written, total, current_file)`
- Maximal 5 gleichzeitige Download-Versuche (sequentiell, nicht parallel — CC hat kein echtes Threading)
- Nach erfolgreichem Schreiben: Hash verifizieren (nochmal lesen und vergleichen)

**`start.lua` — Anforderungen (Rewrite):**
- Einfacher, klar strukturiert, < 150 Zeilen
- Liest Rolle aus `/xreactor/config/role.lua`
- Startet `installer/auto_update.lua` als parallelen Loop
- Gibt klare Print-Ausgaben: `[AUTO] Loop gestartet`, `[AUTO] Prüfe Version...`, `[AUTO] Neue Version vX → Update`
- Fehler beim Laden von auto_update → `print("[AUTO] FEHLER: " .. err)` und trotzdem Node starten
- Kein `safe_log`, kein `logger` — nur `print()`

---

### Phase 2: Energy Node Rewrite

#### 3.3 Problem-Analyse (aktueller Stand)

**`nodes/energy/main.lua` (674 Zeilen Monolith):**
- Matrix-Polling (`services:tick()` → `MATRIX_SAMPLE`) blockiert Event-Loop für 1-3s
- Heartbeat-Timer kann während Matrix-Polling nicht feuern → Heartbeat verspätet sich
- `Peer down: node-53 (age=57s)` auf allen Energy-Nodes wegen Heartbeat-Verzögerung
- 246 Reconnects in 57s auf dem Master als Folge
- `Heartbeat tick delayed by 4632ms` im Log
- v190 hat versucht Heartbeat/Matrix zu trennen aber Implementierung war unvollständig

**Warum v190 nicht ausreicht:**
- `matrix_loop` nutzt `os.sleep(0.5)` — das gibt Kontrolle ab aber blockiert dann beim nächsten `services:tick()`
- `parallel.waitForAny` koordiniert zwar die Coroutinen aber `services:tick()` selbst blockiert intern die Coroutine

#### 3.4 Neue Energy-Node Architektur

**Zielstruktur:**
```
nodes/energy/
├── main.lua              ← Bootstrap + parallel.waitForAny({heartbeat, matrix, comms, auto_update})
├── heartbeat.lua         ← NEU: nur Heartbeat senden, niemals blockierend
├── matrix.lua            ← NEU: Matrix-Polling in eigener Coroutine mit Shared-State
├── command_handler.lua   ← BEHALTEN (40Z, stabil)
├── config.lua            ← BEHALTEN
├── config_normalizer.lua ← BEHALTEN
├── discovery_runtime.lua ← BEHALTEN
├── matrix_snapshot_runtime.lua ← BEHALTEN
├── status_payload.lua    ← BEHALTEN
└── ui_pages.lua          ← BEHALTEN
```

**`nodes/energy/heartbeat.lua` — Anforderungen:**
```lua
-- Eigene Coroutine, niemals blockierend
-- Nutzt os.startTimer() + os.pullEvent() (ungefiltert!)
-- Sendet Heartbeat via comms:send_heartbeat() alle N Sekunden
-- Verarbeitet modem_message Events und leitet sie weiter
-- Verarbeitet monitor_touch / key Events für UI
-- Kennt Matrix-Daten nur über Shared-State (read-only Referenz)
-- Interface:
function M.run(ctx)  -- blockiert nie länger als nötig
```

**`nodes/energy/matrix.lua` — Anforderungen:**
```lua
-- Eigene Coroutine, darf blockieren (Peripheral-Calls)
-- Pollt Matrix alle poll_interval_s Sekunden
-- Schreibt Ergebnisse in ctx.shared.matrix_data (atomisch: komplette Tabelle ersetzen)
-- Heartbeat-Loop liest ctx.shared.matrix_data (niemals schreiben)
-- Bei Peripheral-Fehler: ctx.shared.matrix_data.error = "reason", alte Daten behalten
-- Interface:
function M.run(ctx)  -- kann blockieren, läuft in eigener Coroutine
```

**`nodes/energy/main.lua` — Anforderungen (Rewrite):**
```lua
-- Maximal 150 Zeilen
-- Bootstrap: modem, comms, config, discovery
-- Shared State initialisieren:
local shared = {
  matrix_data = { energy = 0, capacity = 0, fill_ratio = 0, error = nil, ts = 0 },
  running = true
}
-- Parallel starten:
parallel.waitForAny(
  function() heartbeat.run(ctx) end,   -- Heartbeat + Comms
  function() matrix.run(ctx) end,       -- Matrix-Polling
  function() auto_update.run(ctx) end   -- Auto-Update Check
)
```

**Shared-State Protokoll (KRITISCH):**
- Nur `matrix.lua` schreibt in `shared.matrix_data`
- Alle anderen lesen nur
- Update ist atomar: komplette Tabelle wird ersetzt, nicht einzelne Felder
- Kein Mutex nötig da CC:Tweaked single-threaded (Coroutinen wechseln nur bei `os.pullEvent`/`os.sleep`)

---

### Phase 3: Master Rewrite

#### 3.5 Problem-Analyse (aktueller Stand)

**Aktuelle Dateistruktur (verwirrend):**
```
master/runtime_loop.lua     ← 290Z: Event-Loop + Redstone-Check + init()
master/init_runtime.lua     ← 150Z: wird von runtime_loop aufgerufen
master/runtime_context.lua  ← 137Z: Config-Normalisierung
master/rt_sync.lua          ← 415Z: Setpoint-Berechnung + Senden
master/runtime_ops_rt.lua   ← 280Z: RT-Node Operationen
master/runtime_ops_profile.lua ← 221Z: Leistungsprofil-Berechnung
master/message_handlers.lua ← 418Z: Eingehende Nachrichten verarbeiten
master/startup_sequencer.lua ← 299Z: Node-Startup-Sequenz
```

**Bekannte Probleme:**
1. `_G.xreactor_runtime` Global-Hack weil `message_handlers.lua` keinen direkten Zugriff auf `runtime` hat
2. `retry_pending_profile()` ruft `runtime.libs.profile_ops` auf — verschachtelte Referenz die nil sein kann
3. Redstone-Trigger für Remote-Update war nur auf einer Seite, jetzt alle 6 Seiten — aber der Fix ist verstreut
4. `os.sleep(3)` vor Self-Update war ein Blocker (gefixt, aber zeigt das Grundproblem)
5. `runtime_context.lua` normalisiert Config aber das Ergebnis wird an 5 verschiedenen Stellen gepatcht

#### 3.6 Neue Master-Architektur

**Zielstruktur:**
```
master/
├── main.lua              ← REWRITE: Bootstrap + parallel.waitForAny
├── loop.lua              ← NEU: Event-Loop (aus runtime_loop.lua extrahiert)
├── context.lua           ← NEU: Runtime-Context (runtime_loop + init_runtime + runtime_context zusammen)
├── setpoints.lua         ← NEU: RT-Sync + Setpoint-Flow (aus rt_sync.lua + runtime_ops_rt.lua)
├── profile.lua           ← NEU: Leistungsprofil (aus runtime_ops_profile.lua)
├── handlers.lua          ← NEU: Message-Handler (aus message_handlers.lua, kein _G-Hack)
├── sequencer.lua         ← BEHALTEN: startup_sequencer.lua
├── housekeeping.lua      ← BEHALTEN
├── profiles.lua          ← BEHALTEN
├── config.lua            ← BEHALTEN
├── rt_sync_coalescer.lua ← BEHALTEN
└── ui/                   ← BEHALTEN (alle UI-Dateien)
```

**`master/context.lua` — Anforderungen:**
```lua
-- Erstellt und gibt den vollständigen Runtime-Context zurück
-- KEIN _G.xreactor_runtime Global-Hack
-- Context wird als Parameter übergeben an alle Module die ihn brauchen
-- Interface:
function M.create(opts)
  return {
    config   = ...,  -- normalisierte Config
    state    = { power_target = 0, nodes = {}, ... },
    libs     = { profile = ..., setpoints = ..., handlers = ... },
    refs     = { comms = ..., services = ..., ui = ... },
    log      = function(msg, level) ... end,
  }
end
```

**`master/handlers.lua` — Anforderungen:**
- Bekommt `ctx` direkt als Parameter (kein `_G.xreactor_runtime`)
- `on_rt_status(ctx, node_id, payload)` — RT-Status verarbeiten
- `on_energy_status(ctx, node_id, payload)` — Energy-Status verarbeiten
- `retry_pending_profile(ctx)` — direkt im selben Scope, kein verschachteltes `ctx.libs.profile_ops`
- `capacity_max` Update → sofort `retry_pending_profile(ctx)` wenn `ctx.state.power_target == 0`

**`master/setpoints.lua` — Anforderungen:**
- Keine Dedup-Logik (wurde entfernt — Setpoints immer senden)
- `compute_setpoint(ctx, node_id)` → `pct, state, reason`
- `send_setpoint(ctx, node_id, pct, state)` → sendet via comms
- `CAPACITY_LEARNING`-Ablehnungen werden als `INFO` geloggt, nicht `WARN`
- Integriert RT-Sync-Coalescer

**`master/loop.lua` — Anforderungen:**
- Klarer Event-Loop ohne eingebettete Business-Logik
- Redstone-Trigger: alle 6 Seiten (`top/bottom/left/right/front/back`)
- Kein `os.sleep()` im Update-Flow
- Interface: `function M.run(ctx)` — blockiert bis Node stoppt

**`master/main.lua` — Anforderungen (Rewrite):**
```lua
-- Maximal 30 Zeilen
local bootstrap = dofile('/xreactor/core/bootstrap.lua')
bootstrap.setup({ role = 'master', log_enabled = false })
local require = bootstrap.require

local ctx  = require('master.context').create()
local loop = require('master.loop')

parallel.waitForAny(
  function() loop.run(ctx) end,
  require('installer.auto_update').make_loop(ctx.log)
)
```

---

### Phase 4: Shared Services

#### 3.7 Neue geteilte Services

**`services/auto_update_service.lua`:**
- Wrapper um `installer/auto_update.lua`
- Wird von Energy, RT-Support-Nodes genutzt
- Interface identisch zu `installer/auto_update.lua`

**`services/heartbeat_service.lua`:**
- Abstraktion des Heartbeat-Mechanismus
- Wird von Energy genutzt (und potenziell anderen Nodes)
- Konfigurierbar: Intervall, Payload-Builder-Callback

---

## 4. Strikte Constraints

### 4.1 Lua 5.1 Kompatibilität
- Kein `string.format("%q")` mit nil
- Kein `table.unpack` (heißt `unpack` in Lua 5.1)
- Kein `goto` (nicht in Lua 5.1)
- Kein `//` Integer-Division (heißt `math.floor(a/b)`)
- Kein `utf8` Library
- Bitwise Ops via `bit` Library: `bit.band()`, `bit.bor()`, etc.

### 4.2 CC:Tweaked Spezifika
- `os.pullEvent()` **ohne Filter** in Parallel-Threads (niemals gefiltert wenn parallel läuft)
- `peripheral.wrap()` kann nil zurückgeben — immer prüfen
- `fs.open()` wirft keinen Fehler bei fehlendem Verzeichnis — vorher `fs.makeDir()` aufrufen
- `http.get()` wirft Exception bei Netzwerkfehler — immer in `pcall()` wrappen
- `textutils.serialize()` für Datenübertragung, `textutils.unserialize()` zum Parsen
- Kein `json` Library — eigene Serialisierung via CC's `textutils`
- `os.epoch("utc")` für Timestamps in Millisekunden
- `os.clock()` für relative Zeitstempel in Sekunden

### 4.3 Fehlerbehandlung
- **Jeder** `http.get()` Call in `pcall()`
- **Jeder** `peripheral.wrap()` + Peripheral-Method-Call in `pcall()`
- **Jeder** `fs.open()` Call geprüft auf nil
- Fehler loggen und graceful degradieren — niemals silent fail
- HTML-Antworten erkennen: `body:sub(1, 200):lower():find("<html", 1, true)`

### 4.4 Modul-Interface
Jedes neue Modul **muss** folgende Struktur haben:
```lua
local M = {}

-- Öffentliche Funktionen
function M.beispiel(...)
  ...
end

return M
```

### 4.5 Logging
- Kein direktes `print()` in Business-Logik — nur via `ctx.log(msg, level)`
- Level: `"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`
- In `start.lua` und `installer/`: `print()` direkt (kein Bootstrap verfügbar)
- Remote-Log via `core/utils.lua` `M.log()` — nicht direkt aufrufen

### 4.6 Config-Zugriff
- Config wird einmal beim Start normalisiert
- Danach nur lesend zugegriffen
- Keine globalen Config-Variablen außerhalb von `ctx.config`

### 4.7 Manifest + Hashing
- Neues Format: SHA256 als primären Hash, CRC32 als Fallback
- `size_bytes` bleibt als Schnellcheck
- Manifest-Version inkrementell (Integer)
- `release.lua` wird automatisch vom Manifest-Tool generiert

---

## 5. Bestehende Schnittstellen die erhalten bleiben müssen

### 5.1 Netzwerk-Protokoll (unveränderlich)
```lua
-- Heartbeat
{ type = "HEARTBEAT", state = { ... } }

-- Setpoint
{ type = "SET_SETPOINTS", value = {
    power_target_percent = 57.4,
    assignment_state = "active",
    ...
}}

-- HELLO
{ type = "HELLO", reactors = 1, turbines = 25, ... }

-- Status
{ type = "STATUS", payload = { ... } }
```

### 5.2 Config-Dateien (Node-seitig, dürfen sich nicht ändern)
```
/xreactor/config/role.lua           ← { role = "MASTER" }
/xreactor/config/remote_update.lua  ← { enabled=true, auto_update=true, check_interval_s=120 }
/xreactor/config/rt.lua             ← RT-Node Config (optional)
```

### 5.3 Manifest-Format (rückwärtskompatibel)
```lua
-- release.lua
return {
  release_id = "beta-v192",
  manifest_version = 192,
  manifest_file_count = 132,
  hash_algo = "crc32",  -- oder "sha256" wenn implementiert
  manifest_path = "xreactor/manifest.lua",
}
```

---

## 6. Bekannte Bugs die im Rewrite behoben werden müssen

| # | Bug | Datei | Priorität |
|---|-----|-------|-----------|
| 1 | Auto-Update loggt nichts, läuft möglicherweise gar nicht | `start.lua` | KRITISCH |
| 2 | Heartbeat wird durch Matrix-Polling blockiert (1-3s Verzögerung) | `energy/main.lua` | KRITISCH |
| 3 | `_G.xreactor_runtime` Global-Hack nötig weil context nicht übergeben wird | `master/` | HOCH |
| 4 | `retry_pending_profile` kann nil-Fehler erzeugen wenn `runtime.libs` nicht gesetzt | `master/message_handlers.lua` | HOCH |
| 5 | CRC32 Hash-Kollisionen führen zu ausgelassenen Updates | `installer_manifest.lua` | HOCH |
| 6 | `capacity_learning not locked` Spam wenn node-55 Turbinen noch hochfahren | `master/message_handlers.lua` | MITTEL |
| 7 | `ctx.constants` nil-Crash auf node-55 bei state_handlers | `nodes/rt/state_handlers.lua` | MITTEL |
| 8 | Energy-Nodes verlieren Master alle ~57s wegen Matrix-Blocking | `energy/main.lua` | KRITISCH |
| 9 | `per_matrix_budget=1` zu niedrig — Matrix-Polling throttled | `energy/config.lua` | MITTEL |
| 10 | `safe_log` nutzt `logger` der in start.lua nie initialisiert wird | `start.lua` | HOCH |

---

## 7. Test-Anforderungen

Da Tests in CC:Tweaked nur ingame möglich sind, muss jedes Modul:

1. **Offline-testbar** sein wo möglich (reine Lua-Logik ohne Peripherals)
2. **Klare Fehlerausgaben** bei Fehlkonfiguration
3. **Graceful Degradation** wenn optionale Komponenten fehlen (z.B. kein Monitor)
4. **Startup-Logs** die zeigen welche Version läuft und welche Komponenten initialisiert wurden

### Startup-Log Anforderung (alle Nodes):
```
[BOOT] XReactor v192 | Rolle: MASTER | node-53
[BOOT] Comms: OK | Kanal 6500/6501
[BOOT] Services: comms ✓ | ui ✓ | alerts ✓
[AUTO] Auto-Update Loop gestartet (Intervall 120s)
[BOOT] Bereit.
```

---

## 8. Datei-Übergabe

Das vollständige Repository ist unter folgendem Pfad verfügbar:

**GitHub:** `https://github.com/ItIsYe/ExtreamReactor-Controller-V3`  
**Branch:** `beta`  
**Token:** Wird separat übergeben (read/write Zugriff)

### Wichtigste Referenz-Dateien für den Rewrite:

| Datei | Warum wichtig |
|-------|--------------|
| `xreactor/shared/constants.lua` | Alle Kanäle, Rollen, Message-Typen |
| `xreactor/core/comms.lua` | Kommunikations-API die wiederverwendet wird |
| `xreactor/nodes/rt/main.lua` | Referenz-Implementierung für gute Struktur |
| `xreactor/master/rt_sync.lua` | Setpoint-Flow (vereinfacht werden soll) |
| `xreactor/nodes/energy/main.lua` | Monolith der aufgeteilt werden soll |
| `xreactor/master/runtime_loop.lua` | Aktueller Event-Loop |
| `xreactor/installer_main.lua` | Aktueller Installer (Referenz) |

---

## 9. Lieferobjekte

### Phase 1 (Installer):
- [ ] `xreactor/installer/init.lua`
- [ ] `xreactor/installer/http.lua`
- [ ] `xreactor/installer/manifest.lua`
- [ ] `xreactor/installer/stage.lua`
- [ ] `xreactor/installer/ui.lua`
- [ ] `xreactor/installer/auto_update.lua`
- [ ] `xreactor/start.lua` (Rewrite, < 150 Zeilen)
- [ ] Aktualisiertes `xreactor/manifest.lua`

### Phase 2 (Energy):
- [ ] `xreactor/nodes/energy/main.lua` (Rewrite, < 150 Zeilen)
- [ ] `xreactor/nodes/energy/heartbeat.lua` (NEU)
- [ ] `xreactor/nodes/energy/matrix.lua` (NEU)

### Phase 3 (Master):
- [ ] `xreactor/master/main.lua` (Rewrite, < 30 Zeilen)
- [ ] `xreactor/master/loop.lua` (NEU)
- [ ] `xreactor/master/context.lua` (NEU)
- [ ] `xreactor/master/setpoints.lua` (NEU)
- [ ] `xreactor/master/profile.lua` (NEU)
- [ ] `xreactor/master/handlers.lua` (NEU)

### Phase 4 (Shared Services):
- [ ] `xreactor/services/auto_update_service.lua` (NEU)
- [ ] `xreactor/services/heartbeat_service.lua` (NEU)

---

## 10. Qualitäts-Kriterien

- Kein Modul darf länger als **300 Zeilen** sein (Ausnahme: komplexe Algorithmen wie Turbinen-Regler)
- Jede Funktion hat einen **klaren Rückgabewert** (`value` oder `nil, error_string`)
- Keine **zirkulären Abhängigkeiten** zwischen Modulen
- Kein **_G Global State** außer dem Bootstrap-internen `require`
- Jeder `pcall` hat eine **Fehlerbehandlung** die loggt
- **Einheitliche Logging-API**: `ctx.log(message, level)` überall gleich
- **Startup dauert < 5s** auf einem normalen CC:Tweaked Computer
- **Auto-Update Check dauert < 30s** (inklusive GitHub API + Download)
- **Heartbeat-Verzögerung < 500ms** auch wenn Matrix-Polling läuft
