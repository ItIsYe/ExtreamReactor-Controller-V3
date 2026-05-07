# ATM10 / CC:Tweaked konservativer Kompatibilitäts- und Risikoaudit (2026-05-07)

## Scope
- Fokus: Parser-/Größen-/Kompatibilitätsrisiko für ATM10 (MC 1.21.1, NeoForge, CC:Tweaked Lua-5.2/Cobalt).
- Kein Fachlogik-Refactor, keine Laufzeitverhaltensänderung.

## Ergebnis (kurz)
- **Kein akutes Parserdruck-Risiko** in den geprüften Hochrisiko-Dateien auf Basis der bestehenden Guard-Metriken.
- **Haupt-Risiko im Testumfeld**: fehlender Lua/LuaJIT/Luac-Parser verhindert real-parse-Checks im aktuellen Container.
- **Installer-/Manifest-Pfad** ist klar auf konservatives Staging/Storage-Preflight und Hash-/Size-Konsistenz ausgelegt; hier ist der dominantere Betriebsfaktor typischerweise Speicher/Platz, nicht Parserlimit.

## Geprüfte Hochrisiko-Dateien (Ausschnitt)
- `xreactor/nodes/rt/main.lua` (85,079 bytes, chunk_locals=94, max_fn_locals=66)
- `xreactor/master/main.lua` (33,284 bytes, chunk_locals=77, max_fn_locals=25)
- `xreactor/nodes/energy/main.lua` (23,024 bytes, chunk_locals=89, max_fn_locals=7)
- `xreactor/master/ui_controller.lua` (5,511 bytes, chunk_locals=1, max_fn_locals=18)

## Reale Risiken
1. **Real-Parse-Guard ist umgebungsabhängig**: Ohne `lua`/`luajit`/`luac` oder `lupa` kann die verpflichtende Parse-Ausführung nicht stattfinden.
2. **Dateigröße von `rt/main.lua` beobachtungswürdig**, aber gemessener Local-Druck bleibt aktuell klar unter den Guard-Schwellen.

## Unkritische Punkte (im Audit)
- Keine Nutzung von `getfenv`/`setfenv` gefunden.
- Kein `loadstring` gefunden.
- `_ENV`-Verwendung ist punktuell und offensichtlich bewusst für Bootstrap-/Kompatibilitätsrahmen.
- Installer-/Manifest-Tests decken Hash/Size/Update-/Log-Namenskonventionen ab.

## Maßnahmen in diesem Lauf
- Parse-Guard-Abdeckung minimal erweitert: `tests/cc_parse_guard_test.py` prüft jetzt zusätzlich `xreactor/nodes/energy/main.lua`.
- Audit-Dokumentation ergänzt (dieses Dokument).
- Keine Änderungen an Laufzeit-Fachlogik, kein Manifest-Drift.

## Empfehlung
- Für reale ATM10-Freigabe Parse-Guards in einer Umgebung mit installiertem Lua-Parser erneut laufen lassen.
