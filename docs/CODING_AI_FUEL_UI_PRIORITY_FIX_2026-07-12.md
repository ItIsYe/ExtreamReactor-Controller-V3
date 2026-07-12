# Coding-AI-Aufgaben: offene FUEL-UI-Restpunkte

Stand der erneuten Prüfung: 2026-07-12  
Geprüfter Branch: `beta`  
Aktueller Branch-Head: `b274660626fdf2dfa99122916b94c3f87dfa6d0c`  
Letzter Programmcodestand der FUEL-UI: `8d3316889ee7c18787a170102e0818ea55ed16df` (`beta-v390`)  

## Ergebnis der erneuten Prüfung

Seit der letzten Dokumentbereinigung wurden keine weiteren Programmänderungen eingecheckt. Der aktuelle Branch-Head enthält nur die zuvor erfolgte Dokumentbereinigung; der ausführbare FUEL-UI-Code entspricht weiterhin `beta-v390`.

Von den verbleibenden Punkten ist aktuell:

| Punkt | Status |
|---|---|
| Router-Persistenz über Neustart | **OFFEN** |
| Schutz verschachtelter Routingbäume | **TEILWEISE UMGESETZT** |
| Sichtbarer VALVE-Online-/Bestätigungsstatus | **TEILWEISE UMGESETZT** |
| Vollständige Renderfehlerdiagnose | **TEILWEISE UMGESETZT** |
| Monitor-Lifecycle einschließlich Textskalierung | **TEILWEISE UMGESETZT** |
| Einheitliche FUEL-View-States | **TEILWEISE UMGESETZT** |
| UI-Diagnosemetriken | **OFFEN** |
| Automatisierte Regressionstests und CI | **OFFEN** |

Keiner dieser acht Restpunkte ist vollständig abgeschlossen.

## Bereits umgesetzt – nicht erneut umbauen

Folgende Kernfixes sind vorhanden und wurden deshalb aus der Aufgabenliste entfernt:

- jeder Touch läuft nur noch über einen zentralen Inputpfad,
- der zusätzliche `router_touch`-Service wurde entfernt,
- konsumierte Navigation wird nicht mehr an die neue Seite weitergereicht,
- `mouse_click` und `monitor_touch` werden bei Navigation gleich behandelt,
- der UI-Service baut pro Zyklus genau ein Model,
- Snapshotvergleich und Rendering verwenden dasselbe Modelobjekt,
- die zweite unabhängige Zeitdrossel im `ui_router` wurde entfernt,
- interaktive Eingaben umgehen die normale Zeitdrossel,
- normale Datenänderungen lösen keinen vollständigen Monitor-Clear mehr aus,
- direkte Router-UI-Selbst-Redraws wurden entfernt,
- Page-Renderfehler erzeugen bereits eine sichtbare Basis-Fallbackseite,
- Monitorobjekt-, Seiten-, Breiten- und Höhenwechsel erzwingen einen neuen Render,
- `LOGISTICS DISABLED` wird im Overview-Banner angezeigt.

Diese Bereiche nur ändern, wenn ein neuer Regressionstest einen konkreten Fehler nachweist.

## Sicherheitsbedingung für alle weiteren Arbeiten

Während Entwicklung und Tests gilt verbindlich:

```lua
config.logistics.enabled = false
```

Zusätzlich:

- keine realen Fuel-Exporte,
- keine realen Ventilöffnungen,
- ME-/Ventilmethoden mocken oder einen Dry-Run-Modus verwenden,
- UI-Tests dürfen niemals echten Brennstoff transportieren.

---

# REST-P0.1 – Router-Konfiguration muss einen Neustart wirklich überleben

**Status: OFFEN**

## Bereits vorhanden

Die Router-UI:

- schreibt nach `/xreactor/config/fuel_routes.lua`,
- validiert den neu aufgebauten flachen Baum vor dem Commit,
- setzt während der laufenden Sitzung:

```lua
lg.redstone_tree = new_tree
self.redstone_router:refresh()
```

- liest danach den Validierungszustand des laufenden Routers zurück,
- zeigt innerhalb derselben Laufzeit `GESPEICHERT=AKTIV`, wenn der Router den Baum akzeptiert.

## Noch nicht umgesetzt

### 1. Gespeicherte Datei wird beim normalen Start nicht geladen

Beim Start erzeugt `main.lua` den operativen Router aus der geladenen FUEL-Konfiguration. Vorher wird `/xreactor/config/fuel_routes.lua` nicht nach `config.logistics.redstone_tree` übernommen.

`router_ui.new()` lädt bei vorhandenem `redstone_router.config` aus:

```lua
config.logistics.redstone_tree
```

Der Dateifallback `load_routes(self.config_path)` wird im normalen FUEL-Start nicht verwendet.

### 2. Speichern ist nicht atomar

`save_routes()` verwendet direkt:

```lua
fs.open(path, "w")
```

Damit kann ein Schreibabbruch die letzte gültige Datei zerstören.

### 3. Kein Reload der finalen Datei

Die geschriebene Datei wird nach dem Schreiben nicht erneut eingelesen und nicht noch einmal gegen die tatsächliche Dateiversion validiert.

### 4. Kein Reboottest

Es existiert kein eingecheckter Test, der Speichern, Neustart und erneutes Laden des operativen Routers prüft.

## Verbindlicher Fix

Es muss genau eine dauerhaft kanonische Routequelle geben.

Bevorzugt:

```text
/xreactor/config/fuel_routes.lua
```

### Startablauf

1. `fuel_routes.lua` laden.
2. Lua-Struktur sicher einlesen.
3. vollständigen Baum validieren.
4. vor Erzeugung oder Refresh des Routers nach `config.logistics.redstone_tree` übernehmen.
5. bei ungültiger Datei Routing auf `INVALID` setzen.
6. keinen Fuel-Export erlauben.
7. exakten Fehler auf Router- und Diagnostics-Seite anzeigen.

### Atomarer Speichervorgang

```text
fuel_routes.lua.tmp
  -> schreiben
  -> tmp erneut einlesen
  -> tmp validieren
  -> bestehende Zieldatei nach .prev verschieben
  -> tmp nach fuel_routes.lua verschieben
  -> finale Datei erneut einlesen
  -> finale Datei erneut validieren
  -> operativen Router aktualisieren
  -> aktiven Zustand zurücklesen
  -> .prev erst danach entfernen
```

Erst nach vollständigem Erfolg darf die UI anzeigen:

```text
GESPEICHERT=AKTIV
```

## Abnahmetests

- Route speichern.
- Computer vollständig neu starten.
- Route bleibt in der UI sichtbar.
- Route ist im operativen `redstone_router` aktiv.
- beschädigte Datei wird nicht aktiviert.
- Schreibabbruch erhält die letzte gültige Datei.
- Reloadfehler führt zu `FAILED`, nicht zu `SAVED`.

---

# REST-P0.2 – Verschachtelte Routingbäume dürfen nicht zerstört werden

**Status: TEILWEISE UMGESETZT**

## Bereits vorhanden

Die Router-UI:

- erkennt `children` in einem verschachtelten Baum,
- setzt `tree_has_nesting`,
- zeigt einen Hinweis wie:

```text
[VERSCHACHTELT!]
```

- kann den Baum in der Tree-Ansicht grundsätzlich darstellen.

## Noch nicht umgesetzt

- `_do_save()` prüft `tree_has_nesting` nicht.
- `SPEICHERN` bleibt benutzbar.
- `RESET` bleibt benutzbar.
- Zuweisungen bleiben benutzbar.
- Der flache Editor baut beim Speichern weiterhin eine neue flache Liste auf.
- Der verschachtelte Originalbaum kann dadurch strukturell zerstört werden.

## Verbindlicher Mindestfix

Solange kein echter Baumeditor vorhanden ist:

```lua
if u.tree_has_nesting then
  u.save.state = "FAILED"
  u.save.error = "Verschachtelter Baum ist im flachen Editor schreibgeschuetzt"
  return false
end
```

Die UI muss deutlich anzeigen:

```text
NUR LESEN – VERSCHACHTELTER BAUM
```

In diesem Zustand:

- `SPEICHERN` deaktivieren oder hart ablehnen,
- `RESET` deaktivieren oder hart ablehnen,
- Zuweisungen deaktivieren,
- Originaldatei und operativen Baum unverändert lassen.

## Spätere vollständige Lösung

Ein echter Baumeditor muss:

- Eltern-/Kind-Beziehungen erhalten,
- Integrator und Seite pro Knoten bearbeiten,
- Knoten einfügen, verschieben und löschen,
- Zyklen verhindern,
- doppelte Reaktoren verhindern,
- vor dem Commit den vollständigen Baum validieren.

## Abnahmetests

- verschachtelten Baum laden,
- Tree-Ansicht zeigt ihn korrekt,
- Editor zeigt Read-only-Zustand,
- Speichern wird abgelehnt,
- Reset wird abgelehnt,
- Originaldatei bleibt byteidentisch,
- operativer Baum bleibt strukturidentisch.

---

# REST-P0.3 – Offline- und unbestätigte Ventile sichtbar anzeigen

**Status: TEILWEISE UMGESETZT**

## Bereits im Backend vorhanden

`redstone_router.refresh()`:

- liest bekannte Kommunikations-Peers,
- erkennt erreichbare VALVE-Nodes als Netzwerk-Integratoren,
- kann lokale Integrator-Peripherien erkennen,
- protokolliert Warnungen bei fehlenden Integratoren,
- gibt bei einem nicht schaltbaren Integrator aus `_set_valve()` `false` zurück.

## Noch nicht in der UI vorhanden

Die Router-Seite zeigt derzeit nur:

- Anzahl Ventile,
- Anzahl Pfade,
- Baumstruktur,
- aktiven oder letzten Pfad,
- gespeicherten/ungespeicherten Zustand.

Es fehlt pro VALVE-Node:

```text
ONLINE
OFFLINE
STALE
UNKNOWN
```

Außerdem fehlen:

- Alter des letzten Kontakts,
- Zuordnung zu den betroffenen Routen,
- angeforderter Ventilzustand,
- bestätigter Ventilzustand,
- sichtbarer Unterschied zwischen konfiguriert und tatsächlich erreichbar.

## Wichtige technische Grenze

Die Funkventilsteuerung arbeitet weiterhin fire-and-forget. Ein erfolgreicher lokaler `modem.transmit()`-Aufruf bestätigt nicht, dass:

- die VALVE-Node das Paket empfangen hat,
- Redstone wirklich geschaltet wurde,
- der gewünschte Zustand erreicht wurde.

Eine Anzeige wie `CONFIRMED BLOCKED` ist deshalb erst nach Einführung eines ACK-/Statusprotokolls fachlich korrekt möglich.

## Zielmodell

```lua
model.router_ui.valves = {
  {
    id = "VALVE-1",
    configured = true,
    online = true,
    stale = false,
    age_s = 1.2,
    requested_state = "BLOCKED",
    confirmed_state = "BLOCKED",
    state_matches = true,
    affected_routes = { "Reactor-A" },
  }
}
```

## Darstellungsanforderung

Mindestens:

```text
VALVE-1  ONLINE   BLOCKED
VALVE-2  OFFLINE  UNKNOWN
```

Eine Route darf nicht als vollständig `AKTIV/OK` gelten, wenn ein benötigtes Ventil:

- offline,
- stale,
- unbestätigt,
- oder im falschen Zustand ist.

## Abnahmetests

- VALVE online → sichtbar `ONLINE`,
- Peer timeout → sichtbar `OFFLINE`,
- Peer kommt zurück → Erholung ohne Reboot,
- Route mit Offline-Ventil ist nicht betriebsbereit,
- verlorenes ACK → Zustand `UNCONFIRMED`,
- falscher bestätigter Zustand → Route `DEGRADED/ERROR`.

---

# REST-P1.1 – Renderfehler vollständig diagnostizierbar machen

**Status: TEILWEISE UMGESETZT**

## Bereits vorhanden

`core/ui_router.lua`:

- kapselt `page.render()` in `pcall`,
- erhöht `error_count`,
- speichert `last_error` mit Seite, Code, Meldung und Zeit,
- zeichnet eine sichtbare Fallbackseite,
- lässt den Node nach einem Page-Fehler weiterlaufen.

## Noch nicht umgesetzt

### 1. Fehler wird nicht garantiert geloggt

Der Catch-Pfad schreibt den konkreten abgefangenen Fehler nicht über einen Logger.

Die Fallbackseite behauptet aktuell:

```text
Details im LOG_COLLECTOR-Export.
```

Das ist durch diesen Fehlerpfad nicht garantiert.

### 2. Diagnostics-Seite erhält die Daten nicht

`monitor_ui.build_model()` übernimmt weder `error_count` noch `last_error` aus dem `ui_router`.

Die FUEL-Diagnostics-Seite zeigt diese Werte nicht an.

### 3. Kein Traceback

Es wird `pcall()` statt `xpcall()` mit Traceback verwendet.

### 4. Shared-Router enthält fest codierten FUEL-Text

Das gemeinsam genutzte `core/ui_router.lua` zeichnet fest:

```text
FUEL UI ERROR
```

Bei einer anderen Rolle wäre die Anzeige falsch.

### 5. Model-Build- und Monitor-Write-Fehler sind nicht gleichwertig behandelt

Der vorhandene Fallback deckt primär Fehler innerhalb `page.render()` ab. Ein Fehler vor dem Page-Render oder beim Modelbau benötigt ebenfalls einen sichtbaren und geloggten Fallbackpfad.

## Verbindlicher Fix

`ui_router.new()` erhält konfigurierbare Optionen:

```lua
{
  error_title = "FUEL UI ERROR",
  on_render_error = function(error_info)
    -- loggen und Diagnose übernehmen
  end,
}
```

Öffentliche Diagnose:

```lua
function router:get_diagnostics()
  return {
    error_count = self.error_count or 0,
    last_error = self.last_error,
  }
end
```

FUEL-Model:

```lua
model.ui_diagnostics = monitor_router:get_diagnostics()
```

Diagnostics-Seite zeigt:

- Fehleranzahl,
- betroffene Seite,
- Fehlercode,
- Alter des letzten Fehlers,
- kurze Fehlermeldung.

Der vollständige Traceback muss ins lokale Log und damit in den Log-Collector gelangen.

## Abnahmetests

- Page-Renderfehler zeigt Fallback,
- Fehler steht im lokalen Log,
- Fehler erscheint im Log-Collector,
- Diagnostics zeigt denselben Fehler,
- andere Rollen erhalten keinen Text `FUEL UI ERROR`,
- Model-Build-Fehler zeigt Fallback,
- Monitor-Write-Fehler wird diagnostiziert,
- spätere erfolgreiche Darstellung funktioniert ohne Reboot.

---

# REST-P1.2 – Monitor-Lifecycle einschließlich Textskalierung

**Status: TEILWEISE UMGESETZT**

## Bereits vorhanden

Vor dem Snapshot-Skip prüft der `ui_router`:

```lua
last_render_mon
last_render_page_index
last_render_w
last_render_h
```

Dadurch erzwingen folgende Änderungen einen neuen vollständigen Render:

- anderes Monitorobjekt,
- andere Seite,
- andere Breite,
- andere Höhe.

Ein gleich großer Ersatzmonitor wird aufgrund der geänderten Objektidentität grundsätzlich erkannt.

## Noch nicht umgesetzt

- kein `getTextScale()`,
- kein `last_render_scale`,
- reine Skalierungsänderung wird nicht ausdrücklich erkannt,
- keine eigenen Lifecycle-Diagnosewerte,
- keine eingecheckten Tests für `peripheral`,
- keine eingecheckten Tests für `peripheral_detach`,
- kein eingecheckter Test für Wiederanschluss,
- kein eingecheckter Test für reine Skalierungsänderung.

## Verbindlicher Fix

Falls verfügbar:

```lua
local ok, current_scale = pcall(mon.getTextScale)
```

Routerzustand:

```lua
last_render_scale = nil
```

Transition:

```lua
or self.last_render_scale ~= current_scale
```

Nach jeder Transition:

- Frame-/Dirty-Cache invalidieren,
- Footer-Touchzonen löschen,
- List-Touchzonen löschen,
- genau einmal vollständig zeichnen,
- neue Geometrie speichern.

## Abnahmetests

- Scale ändern, ohne andere Modeldaten zu ändern,
- genau ein vollständiger Redraw,
- neue Touchzonen passen zur neuen Geometrie,
- Monitor trennen,
- gleich großen Ersatzmonitor anschließen,
- neuer Monitor wird trotz identischem Model gezeichnet,
- Wiederanschluss funktioniert ohne Reboot.

---

# REST-P1.3 – Einheitliche FUEL-View-States

**Status: TEILWEISE UMGESETZT**

## Bereits vorhanden

Der Overview-Banner unterscheidet aktuell unter anderem:

```text
LOGISTICS DISABLED
RESERVE LOW
FUEL WARNING
RESERVE NORMAL
```

Weitere einzelne Informationen sind verteilt vorhanden:

- Storage `MISSING`,
- MASTER-Warnstatus,
- aktive Lieferung als `LIMITED` in der Ampellogik,
- einzelne Warnfarben und Diagnosezeilen.

## Noch nicht umgesetzt

Es gibt kein gemeinsames, priorisiertes:

```lua
model.view_state
```

Folgende Zustände sind nicht als einheitlicher Gesamtzustand umgesetzt:

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

Dadurch verwenden Header, Banner, Ampel und Diagnostics nicht dieselbe fachliche Priorisierung.

## Zielmodell

```lua
model.view_state = {
  code = "NO_FRESH_RT_DATA",
  severity = "WARNING",
  title = "Keine aktuellen Reaktordaten",
  detail = "Warte auf MASTER/RT-Status",
  action = "MASTER- und RT-Verbindung pruefen",
}
```

## Empfohlene Priorität

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

Die genaue Reihenfolge muss fachlich geprüft werden. Ein sicherheitsrelevanter Fehler darf nie von einem niedrigeren Zustand verdeckt werden.

## Darstellung

Derselbe `view_state` steuert:

- Headerstatus,
- Hauptbanner,
- Ampelstatus,
- Details-Zustand,
- Diagnostics-Zeile.

Ein schwarzer oder leerer Monitor ist niemals ein gültiger Zustand.

## Abnahmetests

Für jeden Zustand:

- Eingangsdaten erzeugen,
- erwarteten `view_state.code` prüfen,
- Bannertext prüfen,
- Statusfarbe prüfen,
- Ampelstatus prüfen,
- Diagnostics-Zeile prüfen,
- Kombinationen mit höherer Priorität prüfen.

---

# REST-P1.4 – UI-Diagnosemetriken

**Status: OFFEN**

## Aktueller Zustand

Es existieren einzelne interne Werte wie:

- `last_draw`,
- `last_snapshot`,
- `error_count`.

Es gibt aber keinen zusammenhängenden Diagnosezustand für Input-, Model- und Renderverhalten.

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

Die Diagnostics-Seite zeigt mindestens:

- Modelbauten,
- angeforderte Frames,
- committed Frames,
- übersprungene Frames,
- Full-Clears,
- Renderfehler,
- letzte Renderdauer.

## Wichtige Regel

Die Metriken dürfen nicht selbst permanent neue Redraws auslösen. Sie dürfen deshalb nicht ungefiltert Bestandteil des normalen Seitensnapshots sein.

## Abnahmetests

- ein Touch erhöht `pointer_events_received` genau einmal,
- ein Page-Handler erhöht `page_handler_calls` höchstens einmal,
- passives unverändertes Event erhöht keinen committed Frame,
- Seitenwechsel erhöht genau einen Full-Clear,
- normale Reserveänderung erhöht keinen Full-Clear,
- Renderfehler erhöht `render_errors`,
- Diagnoseanzeige erzeugt kein Renderfeedback-Loop.

---

# TEST-P0 – Automatisierte Regressionstests und CI

**Status: OFFEN**

## Befund

Die bisherigen FUEL-UI-Umsetzungscommits änderten Produktionscode und Manifest, aber legten keine dauerhaften FUEL-UI-Testdateien an.

Die Committexte erwähnen einmalige isolierte Prüfungen. Diese sind keine wiederholbaren Repository-Regressionstests.

Für den aktuellen Branch-Head sind keine Commit-Statuschecks registriert.

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

## Inputtests

1. `monitor_touch` erzeugt genau eine Aktion.
2. `mouse_click` erzeugt genau eine Aktion.
3. `WEITER` wechselt nur die Seite.
4. `ZURÜCK` wechselt nur die Seite.
5. Router-Ausgang bleibt ausgewählt.
6. Reaktorzuweisung erzeugt genau eine Route.
7. zweiter Tap besitzt exakt die definierte Semantik.
8. schneller Doppeltap erzeugt keine unkontrollierte Mehrfachaktion.
9. Key-Navigation wird einmal verarbeitet.
10. konsumiertes Event erreicht keine nachfolgende Seite.

## Model- und Rendertests

11. unverändertes Model erzeugt keine Monitorwrites.
12. Reserveänderung erzeugt keinen Full-Clear.
13. Masterstatusänderung schreibt nur notwendige Bereiche.
14. Seitenwechsel erzeugt genau einen vollständigen Framewechsel.
15. Interaktion ist im selben Eventzyklus sichtbar.
16. langsamer Monitor bleibt konsistent.
17. Größenänderung baut Frame und Touchzonen neu.
18. Monitorwechsel verwirft alten Cache.
19. `build_status_payload()` wird höchstens einmal pro UI-Zyklus aufgerufen.
20. Snapshot und gezeichnetes Model sind dieselbe Generation beziehungsweise dasselbe Objekt.

## Routertests

21. gespeicherte und aktive Route stimmen überein.
22. Validierungsfehler ist sichtbar.
23. Offline-VALVE ist sichtbar.
24. Save-Fehler behält `dirty=true`.
25. Neustart lädt dieselbe Route wieder.
26. kein direkter `_redraw()`-Pfad.
27. Auswahl bleibt nach zentralem Render erhalten.
28. Scrollzustand bleibt nach Datenupdate erhalten.
29. `RESET` wird genau einmal ausgeführt.
30. `SPEICHERN` erzeugt genau einen atomaren Schreibvorgang.
31. verschachtelter Baum ist im flachen Editor schreibgeschützt.
32. Schreibabbruch erhält die letzte gültige Routendatei.

## Fehlertests

33. Page-Renderfehler zeigt Fallback statt Schwarzbild.
34. Ampelfehler beeinflusst Hauptmonitor nicht.
35. fehlender Payload zeigt erklärten Zustand.
36. Monitor-Write-Fehler wird diagnostiziert.
37. Model-Build-Fehler zeigt Fallback.
38. UI erholt sich ohne Reboot.
39. Renderfehler erscheint im Log und in Diagnostics.
40. shared `ui_router` zeigt den richtigen rollenspezifischen Fehlertext.

## Performance- und Lifecycle-Tests

41. unveränderte UI erzeugt über 60 Sekunden keine permanenten Full-Clears.
42. Full-Clears steigen nur bei erlaubten Transitionen.
43. Reserveupdate schreibt deutlich weniger als einen ganzen Bildschirm.
44. 100 Modemevents erzeugen nicht 100 Modelbauten.
45. reine Textskalierungsänderung erzwingt genau einen Full-Redraw.
46. gleich großer Ersatzmonitor wird trotzdem gezeichnet.
47. `peripheral_detach` hinterlässt keine alten Touchzonen.
48. Wiederanschluss funktioniert ohne Reboot.

## CI-Anforderung

- Tests müssen automatisch ausgeführt werden.
- Fehler müssen den Workflow fehlschlagen lassen.
- Der aktuelle Branch-Head muss einen sichtbaren Commitstatus erhalten.
- Ein Committext oder ein einmaliger lokaler Simulationslauf gilt nicht als Regressionstest.

---

# Verbindliche Bearbeitungsreihenfolge

1. **REST-P0.2:** verschachtelte Bäume sofort schreibschützen.
2. **REST-P0.1:** echte persistente Routequelle und atomisches Speichern.
3. **REST-P0.3:** sichtbarer VALVE-Online-/Bestätigungsstatus.
4. **REST-P1.1:** Renderfehler loggen und in Diagnostics anzeigen.
5. **REST-P1.2:** echte Textskalierungs- und Lifecycle-Erkennung.
6. **REST-P1.3:** einheitliche View-States.
7. **REST-P1.4:** UI-Diagnosemetriken.
8. **TEST-P0:** alle Regressionstests einchecken und in CI ausführen.

# Verbleibende Definition of Done

- verschachtelte Routingbäume können durch den flachen Editor nicht verändert oder zerstört werden,
- gespeicherte Routen bleiben nach vollständigem Neustart operativ aktiv,
- Speichern erfolgt atomar und wird durch Reload verifiziert,
- Offline-, stale und unbestätigte Ventile sind sichtbar,
- Route mit problematischem Ventil erscheint nicht als betriebsbereit,
- Renderfehler werden sichtbar, geloggt und in Diagnostics angezeigt,
- der shared `ui_router` besitzt keinen fest codierten falschen Rollentext,
- Model-Build- und Monitor-Write-Fehler besitzen einen sichtbaren Fehlerpfad,
- reine Textskalierungsänderungen werden erkannt,
- Monitortrennung und Wiederanschluss funktionieren ohne Reboot,
- alle wichtigen FUEL-Betriebszustände besitzen einen eindeutigen `view_state`,
- UI-Diagnosemetriken sind verfügbar, ohne Renderrauschen zu erzeugen,
- alle 48 Regressionstests sind als Repository-Dateien vorhanden,
- Tests laufen automatisch und erfolgreich,
- der Branch besitzt sichtbare CI-Statuschecks,
- reale Fuel-Ausgabe bleibt während UI-Tests deaktiviert.
