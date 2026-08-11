# Session Handoff — XReactor Controller V3

**Stand: August 2026 | beta-v529**

## System-Überblick
- Repo: `ItIsYe/ExtreamReactor-Controller-V3`, Branch: `beta`
- Stack: CC:Tweaked · Lua 5.2/LuaJ · Extreme Reactors 2 · ATM10 (MC 1.21.1)
- Server: Hetzner VPS, AMP Panel, 39 CC:Tweaked Computer (IDs 52–96)
- MASTER=53, FUEL=64, LOG=62, ENERGY=54/56/57/58

## Aktueller Stand (beta-v529)
- Installer läuft stabil: Journal-Verify-Bug (v523) und SHA-Rate-Limit-Bug (v527) behoben
- http.get Timeout 15s in Installer und http.lua (v528/v529) — kein unbegrenztes Hängen mehr
- Monitor-Flackern FUEL-Node: behoben via setVisible Double-Buffering (v500)
- FUEL-Node Skala: 0.5 (v508)
- registry.lua: Datei beim ersten Start anlegen (v512)
- plan_validator.lua: size_bytes nur prüfen wenn hash vorhanden (v511)

## Offene Punkte
- Edit-Button auf Seite 4 (Router) verschwindet nach ~1s — noch nicht vollständig gefixt
- Installer hängt beim Master bei 1% — Timeout-Fix deployed, noch nicht getestet
- monitor_45 am MASTER zu klein → im Spiel vergrößern oder entfernen

## Wichtige Regeln
- **NIEMALS** Dateien manuell per curl/Server-Konsole anlegen — immer über den Installer
- Manuell angelegte Dateien → root-Ownership → Berechtigungsprobleme
- Installer-Update: `wget https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/beta/installer /installer`
- Branch Protection: nur deletion + non_fast_forward (keine Required Checks — CI hängt sich auf)

## Node-Rollen
| Computer | Rolle | Nodes |
|---|---|---|
| 53 | MASTER | Zentrale Steuerung |
| 54,56,57,58 | ENERGY | Induction Matrix |
| 62 | LOG | Log-Collector |
| 64 | FUEL | Fuel-Node |
| 52+ | RT | Reaktor-Nodes |
| 70,74 | VALVE | Ventil-Nodes (instabil) |

## Doku-Index
- `docs/CI_MAINTENANCE.md` — CI-Bugs und Fixes
- `docs/REPO_SAFETY_AUDIT_CLOSURE_2026-08-10.md` — Safety-Audit August 2026
- `docs/CODING_AI_*.md` — Historische Implementierungs-Vorgaben (Referenz)
