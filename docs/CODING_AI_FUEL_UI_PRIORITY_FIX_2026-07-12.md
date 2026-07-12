# Coding-AI-Aufgaben: offene FUEL-UI-Restpunkte

Stand: 2026-07-12  
Geprüfter Branch: `beta`  
Geprüfter Head: `8d3316889ee7c18787a170102e0818ea55ed16df` (`beta-v390`)  
Ausgangsdokument: `docs/CODING_AI_FUEL_UI_PRIORITY_FIX_2026-07-12.md`

## Zweck dieser bereinigten Datei

Alle im aktuellen Code vollständig umgesetzten FUEL-UI-Aufgaben wurden aus dieser Datei entfernt.

Diese Datei enthält nur noch:

- nicht umgesetzte Punkte,
- nur teilweise umgesetzte Punkte,
- fehlende Regressionstests,
- noch nicht nachgewiesene Abnahmekriterien.

Die vorhandenen Eingabe-, Model-, Render- und Basis-Fallback-Fixes sollen nicht erneut umgebaut werden, außer ein Regressionstest weist einen konkreten Fehler nach.

## Sicherheitsbedingung

Während Entwicklung und Tests gilt verbindlich:

```lua
config.logistics.enabled = false
```

Zusätzlich:

- keine realen Fuel-Exporte,
- keine realen Ventilöffnungen,
- ME-/Ventilmethoden mocken oder Dry-Run verwenden,
- UI-Tests dürfen niemals echten Brennstoff transportieren.

---

# REST-P0.1 – Router-Konfiguration muss einen Neustart wirklich überleben

## Aktueller Zustand

Die Router-UI schreibt weiterhin nach:

```text
/xreactor/config/fuel_routes.lua
```

Beim Speichern wird zusätzlich nur der aktuell laufende In-Memory-Wert geändert:

```lua
lg.redstone_tree = new_tree
self.redstone_router:refresh()
```

Beim nächsten Start erzeugt `main.lua` den operativen Router jedoch aus der geladenen FUEL-Konfiguration. Die gespeicherte Datei `fuel_routes.lua` wird vor dem Erzeugen des Routers nicht in `config.logistics.redstone_tree` geladen.

`router_ui.new()` lädt bei vorhandenem `redstone_router.config` ausdrücklich aus:

```lua
config.logistics.redstone_tree
```

und ignoriert in diesem Normalfall die zuvor geschriebene `fuel_routes.lua`.

## Folge

Der Zustand kann innerhalb derselben Laufzeit als:

```text
GESPEICHERT=AKTIV
```

angezeigt werden, nach einem Neustart aber wieder auf den alten Configwert zurückfallen.

Die bisherige Aussage „gespeichert“ ist deshalb noch kein nachgewiesener persistenter Zustand.

## Verbindlicher Fix

Es muss genau eine dauerhaft kanonische Routequelle geben.

### Bevorzugte Variante

```text
/xreactor/config/fuel_routes.lua
```

wird die kanonische Routequelle.

Ablauf beim Start:

1. `fuel_routes.lua` laden.
2. Struktur und Pfade validieren.
3. Ergebnis vor Erzeugung des operativen Routers nach `config.logistics.redstone_tree` übernehmen.
4. Bei ungültiger Datei keinen Export erlauben.
5. Exakten Fehler auf der Router- und Diagnostics-Seite anzeigen.

Ablauf beim Speichern:

1. neuen Baum im Speicher erstellen,
2. validieren,
3. atomar in temporäre Datei schreiben,
4. temporäre Datei erneut einlesen,
5. erneut validieren,
6. temporäre Datei auf Zielpfad verschieben,
7. endgültige Datei erneut einlesen,
8. in `config.logistics.redstone_tree` übernehmen,
9. operativen Router aktualisieren,
10. aktiven Zustand zurücklesen,
11. erst dann `SAVED/AKTIV` anzeigen.

## Atomare Schreibstrategie

```text
fuel_routes.lua.tmp
  -> schreiben
  -> lesen und validieren
  -> bestehende Datei optional nach .prev verschieben
  -> tmp nach fuel_routes.lua verschieben
  -> finale Datei lesen und validieren
  -> .prev entfernen
```

Ein einfaches direktes `fs.open(path, "w")` reicht nicht.

## Abnahmetests

1. Route speichern.
2. Computer vollständig neu starten.
3. Route muss weiterhin in der UI sichtbar sein.
4. Route muss weiterhin im operativen `redstone_router` aktiv sein.
5. beschädigte Datei darf nicht als aktiv gelten.
6. Schreibabbruch darf die letzte gültige Datei nicht zerstören.

---

# REST-P0.2 – Verschachtelte Routingbäume dürfen beim Speichern nicht zerstört werden

## Aktueller Zustand

Die UI erkennt bereits, ob ein Baum verschachtelte `children` enthält, und zeigt einen Hinweis wie:

```text
[VERSCHACHTELT!]
```

Der Editor bildet den Baum anschließend aber weiterhin als flache Endpunktliste ab.

`_do_save()` prüft `tree_has_nesting` nicht. Ein Speichern kann deshalb den verschachtelten Baum in eine flache Liste umwandeln.

## Risiko

Ein physisch korrekt modellierter mehrstufiger Ventilbaum kann durch einen einzigen UI-Speichervorgang strukturell zerstört werden.

## Mindestfix

Solange der Editor keine echte Baumstruktur bearbeiten kann:

```lua
if u.tree_has_nesting then
  u.save.state = "FAILED"
  u.save.error = "Verschachtelter Baum ist im flachen Editor schreibgeschuetzt"
  return false
end
```

Die UI muss sichtbar anzeigen:

```text
NUR LESEN – VERSCHACHTELTER BAUM
```

`RESET`, Zuweisungen und `SPEICHERN` müssen in diesem Zustand deaktiviert oder hart abgelehnt werden.

## Vollständige spätere Lösung

Ein echter Baumeditor muss:

- Eltern-/Kind-Beziehungen erhalten,
- Integrator und Seite pro Knoten bearbeiten,
- Knoten einfügen, verschieben und löschen,
- Zyklen und doppelte Reaktoren verhindern,
- vor dem Commit den vollständigen Baum validieren.

## Abnahmetests

- verschachtelten Baum laden,
- UI darf ihn anzeigen,
- Speichern im flachen Editor muss abgelehnt werden,
- Originaldatei und operativer Baum bleiben byte-/strukturidentisch.

---

# REST-P0.3 – Offline- und unbestätigte Ventile in der Router-UI anzeigen

## Aktueller Zustand

Die Router-Seite zeigt unter anderem:

- Anzahl Ventile,
- Anzahl Pfade,
- aktiven oder letzten Pfad,
- gespeicherten/ungespeicherten Zustand.

Es fehlt weiterhin die im ursprünglichen Auftrag verlangte eindeutige Anzeige:

```text
VENTIL OFFLINE
```

Die UI prüft nicht sichtbar pro Route, ob ein konfigurierter entfernter VALVE-Node aktuell erreichbar und bestätigt ist.

## Zielmodell

```lua
model.router_ui.valves = {
  {
    id = "VALVE-1",
    online = true,
    age_s = 1.2,
    configured = true,
    confirmed_state = "BLOCKED",
    requested_state = "BLOCKED",
    state_matches = true,
  }
}
```

## Darstellung

Für jeden entfernten Ventilknoten mindestens:

```text
VALVE-1  ONLINE   BLOCKED
VALVE-2  OFFLINE  UNKNOWN
```

Eine Route darf nicht als vollständig `AKTIV/OK` erscheinen, wenn ein benötigtes Ventil:

- offline,
- stale,
- unbestätigt,
- oder im falschen Zustand ist.

## Abnahmetests

- VALVE-Peer online → grün/ONLINE,
- Peer timeout → sichtbar OFFLINE,
- Peer kommt zurück → Anzeige erholt sich ohne Reboot,
- Route mit Offline-Ventil wird nicht als betriebsbereit markiert.

---

# REST-P1.1 – Renderfehler vollständig diagnostizierbar machen

## Bereits vorhandener Teil

Ein Fehler in `page.render()` wird abgefangen und eine sichtbare Fallbackseite angezeigt.

## Noch offen

### 1. Fehler wird nicht zuverlässig ins Log geschrieben

Der Fehler wird im Routerobjekt als `last_error` gespeichert, aber der Catch-Pfad ruft keinen Logger auf.

Die Fallbackseite behauptet:

```text
Details im LOG_COLLECTOR-Export.
```

Der abgefangene Fehler wird dort durch diesen Codepfad jedoch nicht garantiert eingetragen.

### 2. Diagnostics-Seite zeigt `last_error` und `error_count` nicht an

Der Zustand liegt nur intern im `ui_router` und wird nicht in das FUEL-UI-Model beziehungsweise die Diagnostics-Zeilen übernommen.

### 3. Kein Stacktrace

Aktuell wird nur `pcall()` verwendet. Für die Logdiagnose soll `xpcall()` mit Traceback verwendet werden, sofern verfügbar.

### 4. Shared-Router enthält hart codierten FUEL-Text

`core/ui_router.lua` ist ein gemeinsam genutztes Modul, zeichnet aber fest:

```text
FUEL UI ERROR
```

Bei einem Fehler einer anderen Rolle wäre diese Anzeige falsch.

## Verbindlicher Fix

`ui_router.new()` erhält rollen-/seitenspezifische Optionen:

```lua
{
  error_title = "FUEL UI ERROR",
  on_render_error = function(err) ... end,
}
```

Zusätzlich öffentliche Diagnose:

```lua
function router:get_diagnostics()
  return {
    error_count = self.error_count or 0,
    last_error = self.last_error,
  }
end
```

Der FUEL-Modelbau übernimmt diese Daten:

```lua
model.ui_diagnostics = monitor_router:get_diagnostics()
```

Die Diagnostics-Seite zeigt:

- Fehleranzahl,
- betroffene Seite,
- Fehlercode,
- Alter des letzten Fehlers,
- kurze Fehlermeldung.

Der vollständige Traceback geht ins Log.

## Abnahmetests

- absichtlicher Renderfehler erzeugt sichtbare Fallbackseite,
- Fehler steht tatsächlich im lokalen/Remote-Log,
- Diagnostics zeigt denselben Fehler,
- andere Rolle erhält keinen Text `FUEL UI ERROR`,
- erfolgreiche spätere Darstellung funktioniert ohne Reboot.

---

# REST-P1.2 – Textskalierung und Monitor-Lifecycle vollständig erkennen

## Bereits vorhandener Teil

Monitorobjekt, Seitenindex, Breite und Höhe werden vor dem Snapshotvergleich geprüft. Ein Monitor- oder Größenwechsel erzwingt dadurch einen neuen vollständigen Render.

## Noch offen

Der Code speichert und vergleicht keinen echten Textskalierungswert.

Die Kommentare sprechen zwar von einer Größen-/Skalenänderung, tatsächlich geprüft werden nur:

```lua
last_render_mon
last_render_page_index
last_render_w
last_render_h
```

Ein explizites Feld wie `last_render_scale` fehlt.

Außerdem fehlen fest eingecheckte Tests für:

- `peripheral`,
- `peripheral_detach`,
- Monitorwechsel gleicher Größe,
- reine Skalierungsänderung,
- Wiederanschluss nach Ausfall.

## Fix

Falls verfügbar:

```lua
local ok, scale = pcall(mon.getTextScale)
```

Routerzustand ergänzen:

```lua
last_render_scale = nil
```

Transition ergänzen:

```lua
or self.last_render_scale ~= current_scale
```

Nach einer Transition:

- Frame-/Dirty-Cache invalidieren,
- Footer- und List-Touchzonen löschen,
- einmal vollständig neu zeichnen,
- neue Geometrie verwenden.

## Abnahmetests

- Scale ändern, ohne andere Daten zu ändern,
- genau ein vollständiger Redraw,
- Touchzonen entsprechen anschließend der neuen Geometrie,
- alter Monitor wird getrennt und gleich großer neuer Monitor angeschlossen,
- neuer Monitor wird trotz identischem Model gezeichnet.

---

# REST-P1.3 – Alle wichtigen FUEL-UI-Zustände explizit darstellen

## Bereits vorhandener Teil

Der Overview-Banner zeigt inzwischen:

```text
LOGISTICS DISABLED
```

## Noch offen

Die übrigen verlangten Zustände sind nicht als einheitlicher `view_state` umgesetzt:

```text
LOADING
NO CONFIG
NO STORAGE
NO FRESH RT DATA
ROUTING INVALID
VALVE OFFLINE
READY
DELIVERING
ERROR
```

Teilweise werden einzelne Werte oder Warnfarben angezeigt, aber nicht als eindeutiger, priorisierter Gesamtzustand mit Ursache und Handlungshinweis.

## Zielmodell

```lua
model.view_state = {
  code = "NO_FRESH_RT_DATA",
  severity = "WARNING",
  title = "Keine aktuellen Reaktordaten",
  detail = "Warte auf MASTER/RT-Status",
  action = "MASTER- und RT-Verbindung prüfen",
}
```

## Priorität

Empfohlen:

1. `ERROR`
2. `NO CONFIG`
3. `ROUTING INVALID`
4. `VALVE OFFLINE`
5. `NO STORAGE`
6. `NO FRESH RT DATA`
7. `LOGISTICS DISABLED`
8. `DELIVERING`
9. `READY`
10. `LOADING`

Die konkrete Reihenfolge muss fachlich geprüft werden; ein sicherheitsrelevanter Fehler darf nicht von einem niedrigeren Zustand verdeckt werden.

## Darstellung

Jede Hauptseite verwendet denselben `view_state` für:

- Headerstatus,
- Hauptbanner,
- Ampelstatus,
- Diagnostics-Zeile.

Ein schwarzer oder leerer Monitor ist niemals ein gültiger Zustand.

## Abnahmetests

Für jeden Zustand:

- Eingangsdaten erzeugen,
- erwarteten `view_state.code` prüfen,
- Bannertext prüfen,
- Statusfarbe prüfen,
- prioritäre Kombinationen prüfen.

---

# REST-P1.4 – UI-Diagnosemetriken ergänzen

Die ursprüngliche Aufgabenbeschreibung verlangte nachvollziehbare Render- und Inputmetriken. Diese sind im aktuellen Code nicht als zusammenhängende Diagnose verfügbar.

## Ziel

```lua
ui_diag = {
  pointer_events_received = 0,
  page_handler_calls = 0,
  model_builds = 0,
  frames_requested = 0,
  frames_committed = 0,
  frames_skipped = 0,
  full_clears = 0,
  rows_written = 0,
  render_errors = 0,
  last_render_ms = 0,
}
```

Die Diagnostics-Seite soll mindestens anzeigen:

- Modelbauten,
- committed/skipped Frames,
- Full-Clears,
- Renderfehler,
- letzten Rendertime-Wert.

Die Zähler dürfen selbst keinen permanenten Redraw verursachen. Sie gehören deshalb nicht ungefiltert in den normalen Seitensnapshot.

---

# TEST-P0 – Geforderte Regressionstests fehlen als Repository-Dateien

## Befund

Die fünf Umsetzungscommits enthalten Änderungen an Produktionscode und Manifest, aber keine hinzugefügten oder geänderten Testdateien.

Die Committexte beschreiben „in isolation“ ausgeführte Prüfungen. Diese sind nicht als wiederholbare Regressionstests im Repository vorhanden.

Für den geprüften Head sind außerdem keine Commit-Statuschecks registriert.

## Verbindliche Testdateien

Empfohlene Aufteilung:

```text
tests/fuel_ui_input_regression_test.lua
tests/fuel_ui_model_render_regression_test.lua
tests/fuel_ui_router_persistence_test.lua
tests/fuel_ui_error_fallback_test.lua
tests/fuel_ui_monitor_lifecycle_test.lua
tests/fuel_ui_view_state_test.lua
tests/fuel_ui_performance_test.lua
```

## Noch fehlende Inputtests

1. `monitor_touch` erzeugt genau eine Aktion.
2. `mouse_click` erzeugt genau eine Aktion.
3. `WEITER` wechselt nur die Seite.
4. `ZURÜCK` wechselt nur die Seite.
5. Router-Ausgang bleibt ausgewählt.
6. Reaktorzuweisung erzeugt genau eine Route.
7. zweiter Tap besitzt genau die definierte Semantik.
8. schneller Doppeltap erzeugt keine unkontrollierte Mehrfachaktion.
9. Key-Navigation wird einmal verarbeitet.
10. konsumiertes Event erreicht keine folgende Seite.

## Noch fehlende Rendertests

11. unverändertes Model erzeugt keine Monitorwrites.
12. Reserveänderung erzeugt keinen Full-Clear.
13. Masterstatusänderung schreibt nur erforderliche Bereiche.
14. Seitenwechsel erzeugt genau einen vollständigen Framewechsel.
15. Interaktion ist im selben Eventzyklus sichtbar.
16. langsamer Monitor bleibt konsistent.
17. Größenänderung baut Frame und Touchzonen neu.
18. Monitorwechsel verwirft alten Cache.
19. `build_status_payload()` höchstens einmal pro UI-Zyklus.
20. Snapshot und gezeichnetes Model sind dieselbe Generation beziehungsweise dasselbe Objekt.

## Noch fehlende Routertests

21. gespeicherte und aktive Route stimmen überein.
22. Validierungsfehler ist sichtbar.
23. Offline-VALVE ist sichtbar.
24. Save-Fehler behält `dirty=true`.
25. Reboot lädt dieselbe Route wieder.
26. kein direkter `_redraw()`-Pfad.
27. Auswahl bleibt nach zentralem Render erhalten.
28. Scrollzustand bleibt nach Datenupdate erhalten.
29. `RESET` wird genau einmal ausgeführt.
30. `SPEICHERN` erzeugt genau einen atomaren Schreibversuch.
31. verschachtelter Baum ist im flachen Editor schreibgeschützt.

## Noch fehlende Fehlertests

32. Page-Renderfehler zeigt Fallback statt Schwarzbild.
33. Ampelfehler beeinflusst Hauptmonitor nicht.
34. fehlender Payload zeigt erklärten Zustand.
35. Monitor-Write-Fehler wird diagnostiziert.
36. Model-Build-Fehler zeigt Fallback.
37. UI erholt sich ohne Reboot.
38. Renderfehler erscheint im Log und in Diagnostics.

## Noch fehlende Performance-/Lifecycle-Tests

39. unveränderte UI erzeugt über 60 Sekunden keine permanenten Full-Clears.
40. Full-Clears steigen nur bei erlaubten Transitionen.
41. Reserveupdate schreibt deutlich weniger als einen ganzen Bildschirm.
42. 100 Modemevents erzeugen nicht 100 Modelbauten.
43. reine Textskalierungsänderung erzwingt einen Full-Redraw.
44. gleich großer Ersatzmonitor wird trotzdem gezeichnet.

## CI-Anforderung

Diese Tests müssen in der vorhandenen Testausführung beziehungsweise einem GitHub-Actions-Workflow automatisch laufen.

Ein Committext oder ein einmaliger lokaler Simulationslauf ist kein dauerhafter Regressionstest.

---

# Bearbeitungsreihenfolge der verbleibenden Punkte

1. REST-P0.2 – verschachtelte Bäume sofort schreibschützen
2. REST-P0.1 – echte persistente kanonische Routequelle und atomisches Speichern
3. REST-P0.3 – VALVE-Online-/Bestätigungsstatus in Router-UI
4. REST-P1.1 – Fehler loggen und in Diagnostics anzeigen
5. REST-P1.2 – echte Skalierungs-/Lifecycle-Erkennung
6. REST-P1.3 – einheitliche View-States
7. REST-P1.4 – UI-Diagnosemetriken
8. TEST-P0 – alle Regressionstests fest einchecken und in CI ausführen

---

# Verbleibende Definition of Done

- verschachtelte Routingbäume können durch die flache UI nicht zerstört werden
- gespeicherte Routen bleiben nach vollständigem Neustart operativ aktiv
- Speichern erfolgt atomar und wird durch Reload verifiziert
- Offline-/stale/unbestätigte Ventile sind sichtbar
- Renderfehler werden sichtbar, geloggt und in Diagnostics angezeigt
- shared `ui_router` zeigt keine fest codierte falsche Rolle
- reine Textskalierungsänderungen werden erkannt
- alle wichtigen FUEL-Betriebszustände besitzen einen eindeutigen `view_state`
- UI-Diagnosemetriken sind verfügbar, ohne selbst Renderrauschen zu erzeugen
- alle 44 verbleibenden Regressionstests sind als Repository-Dateien vorhanden
- Tests laufen automatisch und erfolgreich
- reale Fuel-Ausgabe bleibt während UI-Tests deaktiviert
