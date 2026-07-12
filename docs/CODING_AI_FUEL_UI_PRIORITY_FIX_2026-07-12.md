# Coding-AI-Aufgaben: FUEL-UI hat Vorrang

Stand: 2026-07-12  
Ziel-Branch: `beta`

## Nutzerpriorität

Das aktuell wichtigste Problem der FUEL-Node ist die **nicht zuverlässig funktionierende Benutzeroberfläche**.

Die Coding-KI soll deshalb zuerst die UI reparieren und mit einer vollständig deaktivierten Fuel-Ausgabe testen. Sicherheits- und Logistikpunkte aus `CODING_AI_FUEL_NODE_DEEP_AUDIT_2026-07-12.md` bleiben gültig, dürfen die UI-Reparatur aber nicht unnötig verzögern.

## Sicherheitsbedingung für UI-Tests

Während Entwicklung und Tests der FUEL-UI gilt verbindlich:

```lua
config.logistics.enabled = false
```

Zusätzlich:

- keine realen Exporte,
- keine realen Ventilöffnungen,
- ME-/Ventilmethoden mocken oder in einen Dry-Run-Modus versetzen,
- UI-Tests dürfen niemals unbeabsichtigt Fuel transportieren.

## Betroffener UI-Pfad

```text
nodes/support/runtime.lua
  -> services/ui_service.lua
  -> nodes/fuel/main.lua
  -> nodes/fuel/monitor_ui.lua
  -> core/ui_router.lua
  -> nodes/fuel/ui_pages.lua
  -> nodes/fuel/router_ui.lua
  -> core/mockup_ui.lua
```

---

# 1. Erwarteter End-to-End-Ablauf

Ein einzelner Fingertipp auf einen Monitor soll genau diesen Ablauf erzeugen:

```text
monitor_touch
   ↓
nodes/support/runtime.lua
   ↓
services/ui_service.lua
   ↓
nodes/fuel/monitor_ui.lua
   ↓
core/ui_router.lua
   ↓
genau eine zuständige Seite
   ↓
UI-State genau einmal ändern
   ↓
genau ein frisches UI-Model erzeugen
   ↓
genau einen sichtbaren Frame committen
```

Dabei gelten folgende Regeln:

1. Jeder physische Touch wird exakt einmal verarbeitet.
2. Sobald eine Ebene ein Event konsumiert, endet die Weitergabe.
3. Navigation und Seitenaktion dürfen nicht mit demselben Touch ausgelöst werden.
4. Nach einer Interaktion ist die Änderung im selben Eventzyklus sichtbar.
5. Snapshot und tatsächlich gezeichnetes Model sind identisch.
6. Bei normalen Datenänderungen wird der Monitor nicht vollständig gelöscht.
7. Die Router-Seite zeichnet nicht außerhalb des zentralen Renderpfades.
8. UI-Zustand und operativer Routerzustand besitzen eine gemeinsame kanonische Quelle.
9. Ein UI-Fehler zeigt eine sichtbare Fallbackseite statt eines schwarzen Monitors.

---

# 2. Tatsächlicher problematischer Ablauf

Der derzeitige Ablauf kann vereinfacht so aussehen:

```text
monitor_touch
   ↓
ui_service.handle_input()
   ↓
monitor_router.handle_input()
   ↓
page.handle_touch()
   ↓
router_ui._redraw() zeichnet direkt
   ↓
separater router_touch-Service verarbeitet denselben Touch erneut
   ↓
ui_service baut Snapshot A
   ↓
monitor_ui baut Model/Payload B
   ↓
ui_router kann Render durch zweite Zeitdrossel überspringen
   ↓
bei Render: mux.clear() löscht kompletten Bildschirm
   ↓
Seite wird schrittweise vollständig neu geschrieben
```

Daraus entstehen mehrere Fehler gleichzeitig:

- Aktionen werden doppelt ausgeführt,
- Auswahl wird sofort wieder aufgehoben,
- Navigation löst zusätzlich einen Seitenbutton aus,
- intern geänderter Zustand ist nicht sofort sichtbar,
- Nutzer tippt erneut und verschärft den Zustand,
- direkter Router-Redraw und zentraler Redraw überschreiben sich,
- Snapshot und gezeichnetes Model können auseinanderliegen,
- vollständiges Löschen erzeugt sichtbares Flackern,
- Fehler können als schwarzer oder veralteter Bildschirm erscheinen.

---

# UI-P0.1 – Jeden Touch exakt einmal verarbeiten

## Bestätigtes Problem

Der normale UI-Service verarbeitet Eingaben bereits über:

```lua
handle_input = function(event)
  fuel_monitor_ui.handle_input(event)
end
```

Zusätzlich registriert `nodes/fuel/main.lua` einen zweiten Service:

```lua
services:add({
  name = "router_touch",
  tick = function(_self, dt, event)
    if event and (event[1] == "monitor_touch" or event[1] == "mouse_click") then
      handle_monitor_touch(event[3], event[4])
    end
  end
})
```

Dadurch erreicht derselbe Touch die aktuelle Seite mindestens zweimal.

## Aufgedröselter Fehlerablauf

Beispiel: Nutzer tippt auf den Ausgang `RIGHT`.

Erster Aufruf:

```lua
u.selected_side = "right"
```

Zweiter Aufruf mit denselben Koordinaten:

```lua
if u.selected_side == "right" then
  u.selected_side = nil
end
```

Sichtbares Ergebnis:

- Auswahl blinkt kurz auf,
- Auswahl verschwindet sofort wieder,
- Button wirkt ohne Funktion,
- vorhandene Route kann versehentlich entfernt werden,
- Nutzer tippt wiederholt und erzeugt unvorhersehbare Zustandswechsel.

## Verbindlicher Fix

- Den separaten `router_touch`-Service vollständig entfernen.
- Es gibt nur noch einen zentralen Input-Dispatcher.
- Seitenspezifische Handler werden ausschließlich vom `ui_router` beziehungsweise dessen kontrolliertem Nachfolger aufgerufen.
- Eingabehandler geben immer `true` zurück, wenn das Event konsumiert wurde.

## Instrumentierung

Für Tests temporär zählen:

```lua
ui_diag.pointer_events_received = ui_diag.pointer_events_received + 1
ui_diag.page_handler_calls = ui_diag.page_handler_calls + 1
```

Pro physischem Event muss gelten:

```text
pointer_events_received = 1
page_handler_calls <= 1
```

## Abnahmetest

Ein physisches `monitor_touch`-Event muss genau einen Aufruf von `router_ui:handle_touch()` erzeugen.

---

# UI-P0.2 – Navigation muss Event-Propagation stoppen

## Bestätigtes Problem

`fuel_monitor_ui.handle_input()` führt sinngemäß aus:

```lua
monitor_router:handle_input(event)
M.handle_touch(x, y)
```

Der Rückgabewert von `monitor_router:handle_input()` wird ignoriert.

Wenn ein Footer-Touch eine Seite wechselt, wird derselbe Touch danach noch an den seitenspezifischen Handler der **neu ausgewählten Seite** weitergereicht.

## Aufgedröselter Fehlerablauf

Ausgangszustand:

```text
aktuelle Seite = Overview
```

Der Nutzer tippt unten auf `WEITER`.

Schritt 1:

```text
ui_router erkennt Footerzone
Overview -> Details
```

Schritt 2:

```text
dieselben x/y-Koordinaten werden an die jetzt aktive Details-Seite weitergegeben
```

Schritt 3:

Liegt an denselben Koordinaten ein seitenspezifischer Button, wird er zusätzlich ausgelöst.

Mögliche Auswirkungen:

- Seitenwechsel plus Router-Auswahl,
- Seitenwechsel plus Reset,
- Seitenwechsel plus Diagnoseeinstellung,
- Touch trifft nach dem Wechsel eine Touchzone, die auf dem vorher sichtbaren Bild noch gar nicht sichtbar war.

## Fix

```lua
function M.handle_input(event)
  if monitor_router and monitor_router:handle_input(event) then
    return true
  end

  local page = monitor_router and monitor_router:current()
  if page and type(page.handle_touch) == "function" then
    return page.handle_touch(event[3], event[4]) == true
  end

  return false
end
```

Nach einem konsumierten Event darf keine weitere UI-Schicht denselben Touch verarbeiten.

## Zusätzliche Regel

Die aktuell sichtbare Seite zu Beginn des Events wird festgehalten. Falls Navigation stattfindet, darf niemals noch ein Handler der neu aktiven Seite im selben Event aufgerufen werden.

## Abnahmetest

Ein Touch auf `WEITER`:

- erhöht oder ändert nur den Seitenindex,
- führt keinen Page-Handler aus,
- erzeugt genau einen sichtbaren Seitenwechsel.

---

# UI-P0.3 – `mouse_click` und `monitor_touch` gleich behandeln

## Aktuelles Problem

`services/ui_service.lua` behandelt als interaktiv nur:

```lua
monitor_touch
key
char
```

`mouse_click` wird zwar an `handle_input()` weitergegeben, umgeht aber nicht die Render-Drosselung.

Zusätzlich verarbeitet `core/ui_router.lua` Footer-Navigation nur für `monitor_touch`, nicht für `mouse_click`.

## Folgen

- Aktionen auf dem Computerterminal können erst verspätet sichtbar werden.
- Seitenspezifische Terminalbuttons können reagieren, Footer-Navigation dagegen nicht.
- Monitor und Terminal verhalten sich unterschiedlich.
- Ein Terminalklick kann intern State ändern, während das Bild unverändert bleibt.

## Fix

Gemeinsame Normalisierung:

```lua
local function normalize_pointer_event(event)
  if event[1] == "monitor_touch" then
    return {
      kind = "pointer",
      source = "monitor",
      x = event[3],
      y = event[4],
      raw = event,
    }
  elseif event[1] == "mouse_click" then
    return {
      kind = "pointer",
      source = "terminal",
      button = event[2],
      x = event[3],
      y = event[4],
      raw = event,
    }
  end
end
```

- `mouse_click` gilt als interaktiv.
- Footer-, Listen- und Seitenbuttons verwenden denselben Pointerpfad.
- Die Quellart darf für Diagnose gespeichert werden, aber nicht zu unterschiedlicher Navigation führen.

## Abnahmetest

Dieselben Koordinaten auf Monitor und Terminal müssen dieselbe UI-Aktion auslösen und im selben Eventzyklus sichtbar werden.

---

# UI-P0.4 – Pro UI-Zyklus genau ein Model erzeugen

## Aktuelles Problem

`ui_service.snapshot()` baut einen Status/Payload auf. Danach ruft `render_monitor()` erneut `build_status_payload()` und baut ein zweites Model.

Der 300-ms-Payload-Cache reduziert einzelne Hardware-Reads, beseitigt aber nicht:

- zwei unabhängige Modelaufbauten,
- zwei Snapshot-Vergleiche,
- mögliche Unterschiede zwischen geprüftem und gezeichnetem Zustand,
- unnötige Registry-/Comms-/Alert-Auswertungen.

## Aufgedröselter Ablauf

Aktuell:

```text
Payload/Model A bauen
   ↓
entscheiden, ob ein Redraw nötig ist
   ↓
Payload/Model B bauen
   ↓
Model B zeichnen
```

Zwischen A und B können sich verändern:

- Zeitstempel,
- `master_seen_s`,
- Queue-/Retrywerte,
- Registrydiagnose,
- aktiver Request,
- Routerzustand,
- Alertzustand.

Damit entscheidet das System anhand von A, zeichnet aber B.

## Ziel-API

```lua
local model = ui_model_builder.build(event)
ui_router:render(mon, model, { force = interactive })
```

Der UI-Service soll das Model einmal erzeugen und genau dieses Objekt an den Renderer übergeben.

Empfohlene neue Signatur:

```lua
ui_service.new({
  build_model = function(event)
    return build_fuel_ui_model(event)
  end,
  snapshot_key = function(model)
    return model.snapshot
  end,
  render = function(model, event, opts)
    render_monitor(model, event, opts)
  end,
})
```

Kein separater kleiner Snapshot und danach ein zweiter vollständiger Renderaufbau.

## Modelinhalt

```lua
model = {
  page = ...,
  payload = ...,
  health = ...,
  master = ...,
  storage = ...,
  logistics = ...,
  router_ui = ...,
  diagnostics = ...,
  snapshot = ...,
}
```

## Abnahmetest

Ein UI-Tick ruft `build_status_payload()` höchstens einmal auf. Das Objekt, dessen Snapshot verglichen wird, ist dasselbe Objekt, das gezeichnet wird.

---

# UI-P0.5 – Nur eine Render-Drossel verwenden

## Aktuelles Problem

Es existieren mindestens zwei voneinander unabhängige Zeitdrosseln:

1. `ui_service.last_draw`
2. `ui_router.last_draw`

Der UI-Service lässt interaktive Events sofort durch. Der innere `ui_router` kann dieselbe Darstellung trotzdem erneut wegen seines eigenen Intervalls überspringen.

Ein Seitenwechsel setzt den inneren Timer zurück, eine normale seitenspezifische Aktion jedoch nicht zwingend.

## Aufgedröselter Fehlerablauf

```text
Touch erkannt
   ↓
State wird geändert
   ↓
ui_service erlaubt sofortiges Rendern
   ↓
ui_router prüft eigenen last_draw
   ↓
inneres Intervall noch nicht abgelaufen
   ↓
kein sichtbares Update
```

Der Nutzer sieht weiterhin den alten Zustand und tippt erneut.

Mögliche Folge:

```text
Tap 1: intern ausgewählt, optisch unverändert
Tap 2: intern wieder abgewählt
Monitor zeigt scheinbar: Button funktioniert nie
```

## Fix

Bevorzugt:

- Zeitplanung ausschließlich im UI-Service.
- `ui_router` entscheidet nur noch anhand von Snapshot/Invalidierung.
- `ui_router.last_draw` und dessen Intervallprüfung entfernen.

Alternativ muss der Renderer einen eindeutigen Force-Parameter erhalten:

```lua
ui_router:render(mon, model, { force = interactive })
```

Bei `force=true` darf weder Intervall noch unveränderter Snapshot die notwendige sichtbare Interaktionsantwort verhindern.

## Regeln

- Passive Datenupdates: Snapshotvergleich und normales Intervall.
- Pointer-/Key-Event: sofortiger sichtbarer Commit.
- Ein sofortiger Commit setzt den normalen Zeitstatus konsistent weiter.
- Kein nachfolgender passiver Tick darf dasselbe alte Model erneut darüberzeichnen.

## Abnahmetest

Eine Router-Auswahl ist noch im selben Touch-Event sichtbar, ohne zweiten Tick und ohne zweiten Touch.

---

# UI-P0.6 – Vollständiges Löschen des Monitors bei jedem Redraw entfernen

## Bestätigtes Problem

Alle FUEL-Seiten rufen über Header beziehungsweise Router-Seite `mux.clear(mon)` auf.

`core/mockup_ui.lua` löscht dabei den kompletten Monitor zeilenweise. Danach werden Header, Karten, Texte und Footer vollständig neu geschrieben.

Der Mockup-Renderer verwendet dabei direkte Monitoraufrufe und umgeht den Dirty-Cache aus `core/ui.lua` weitgehend.

## Aufgedröselter sichtbarer Ablauf

```text
vollständiges Bild sichtbar
   ↓
kompletter Hintergrund wird überschrieben
   ↓
Monitor ist kurz leer/schwarz/einfarbig
   ↓
Header wird geschrieben
   ↓
Karten werden geschrieben
   ↓
Texte und Fortschritt werden geschrieben
   ↓
Footer wird geschrieben
```

Bei einem über Wired Modem angesprochenen Monitor können diese Schritte sichtbar auseinanderliegen.

## Sichtbare Folgen

- hartes Blinken/Flickern,
- kurz leerer oder einfarbiger Monitor,
- hohe Zahl von Monitor-Schreibvorgängen,
- sichtbar unvollständiger Bildaufbau,
- UI wirkt langsam, obwohl die Programmlogik bereits fertig ist.

## Ziel

Vollständiges Framebuffer-/Diff-Rendering.

### Bevorzugte Umsetzung

Neues Modul, zum Beispiel:

```text
core/framebuffer.lua
```

Ablauf:

1. Vollständiges neues Bild ausschließlich im Speicher aufbauen.
2. Für jede Zeile Text, Vordergrund- und Hintergrundfarben speichern.
3. Mit letztem Frame vergleichen.
4. Nur geänderte Zeilen oder Bereiche über `blit()` übertragen.
5. Bei Größen-/Skalenänderung einmal vollständig übertragen.

Mögliches Modell:

```lua
frame:set(x, y, text, fg, bg)
frame:fill(x, y, w, h, bg)
frame:commit(mon)
```

Intern pro Zeile beispielsweise:

```lua
{
  text = "...",
  fg = "...",
  bg = "...",
}
```

## Mindestlösung

Falls ein Framebuffer noch nicht sofort umgesetzt wird:

- `mux.clear()` nur beim ersten Render, Monitorwechsel, Größenwechsel oder Seitenwechsel.
- Bei normalen Datenänderungen nur betroffene Bereiche überschreiben.
- alte längere Texte vollständig mit Leerzeichen entfernen.
- Header/Karten nicht erneut löschen, wenn ihre Geometrie unverändert ist.

## Messwerte

Erfassen:

```lua
ui_diag.full_clears
ui_diag.rows_written
ui_diag.blit_calls
ui_diag.frames_committed
ui_diag.frames_skipped
```

## Abnahmetest

Bei unveränderter Seite und geändertem Reservewert darf der Monitor nicht vollständig geleert werden. Es dürfen nur die betroffenen Zeilen beziehungsweise Bereiche geschrieben werden.

---

# UI-P0.7 – Router-Seite sauber in den normalen Renderzyklus integrieren

## Aktuelles Problem

`router_ui:_redraw()` rendert die Router-Seite direkt und außerhalb des normalen `ui_service -> monitor_ui -> ui_router`-Zyklus.

Dadurch werden umgangen:

- das zentrale Model,
- der äußere Snapshotzustand,
- der reguläre Footerzustand,
- ein einheitlicher Framebuffer,
- zentrale Fehlerdiagnose.

## Aufgedröselter Konflikt

Es existieren zwei Renderpfade:

```text
Pfad A:
ui_service
  -> monitor_ui
  -> ui_router
  -> router_ui.render
```

und:

```text
Pfad B:
router_ui.handle_touch
  -> router_ui._redraw
  -> router_ui.render direkt
```

Möglicher Ablauf:

1. Touch ändert lokalen Router-State.
2. `_redraw()` zeichnet direkt den neuen Zustand.
3. Der zentrale UI-Service tickt danach mit einem älteren oder anders erzeugten Model.
4. Zentraler Render überschreibt den direkten Render teilweise oder vollständig.
5. Snapshotzustand und sichtbarer Frame passen nicht mehr zusammen.

## Fix

Lokale Routerzustände gehören in das UI-Model beziehungsweise den UI-Snapshot:

```lua
model.router_ui = {
  mode = ...,
  selected_side = ...,
  selected_integrator = ...,
  dirty = ...,
  scroll = ...,
  routes = ...,
  save_status = ...,
  validation_error = ...,
}
```

Interaktion:

1. State ändern.
2. zentralen UI-State invalidieren.
3. genau ein neues Model erzeugen.
4. zentralen Renderer einmal ausführen.

Beispiel:

```lua
router_state.selected_side = side
ui_controller:invalidate("router_state")
return true
```

Keine direkte Selbstzeichnung aus dem Page-Objekt.

## Abnahmetest

`router_ui:_redraw()` existiert nicht mehr oder zeichnet nie direkt auf den Monitor. Jeder Router-Frame läuft über denselben zentralen Commitpfad.

---

# UI-P0.8 – Router-UI benötigt einen einzigen kanonischen Zustand

## Aktuelles Problem

Die Oberfläche besitzt lokale `u.routes`, während der operative Router `config.logistics.redstone_tree` verwendet.

Dadurch kann die UI etwas anderes anzeigen als die aktive Konfiguration.

## Aufgedröselter Zustand

```text
UI-Datei / lokaler UI-State:
/xreactor/config/fuel_routes.lua
  -> router_ui._ui.routes
```

Operativer Zustand:

```text
config.logistics.redstone_tree
  -> redstone_router
```

Daraus kann entstehen:

```text
UI zeigt Route A als vorhanden
operativer Router hat keine Route A
```

oder:

```text
UI zeigt gespeicherte Route
aktive Route ist noch die alte In-Memory-Konfiguration
```

## UI-Ziel

Die Router-Seite zeigt klar getrennt:

- `GESPEICHERT`
- `AKTIV`
- `UNGESPEICHERTE ÄNDERUNGEN`
- `VALIDIERUNGSFEHLER`
- `VENTIL OFFLINE`

Der aktive Zustand muss aus derselben kanonischen Routequelle kommen wie die Logik.

## Nach `Speichern`

1. atomar persistieren,
2. Datei wieder einlesen,
3. Struktur validieren,
4. operativen Router aktualisieren,
5. aktiven Zustand zurücklesen,
6. UI-Modell aus dem operativen Zustand neu aufbauen,
7. Erfolg oder exakten Fehler sichtbar anzeigen.

## Save-State

```lua
router_ui.save = {
  state = "IDLE" | "SAVING" | "SAVED" | "FAILED",
  error = nil,
  saved_at = nil,
}
```

## Abnahmetest

Eine Route darf nur als `AKTIV` markiert werden, wenn sie nach Persistierung, Reload und Validierung tatsächlich im operativen Router vorhanden ist.

---

# UI-P1.1 – Fehler nicht stillschweigend verschlucken

## Problem

Mehrere UI-Funktionen sind großflächig mit `pcall()` isoliert. Das schützt den Node, kann aber zu schwarzem oder veraltetem Monitor ohne sichtbare Ursache führen.

## Aufgedröselter Fehlerfall

```text
Page-Renderer wirft Fehler
   ↓
pcall fängt Fehler
   ↓
Steuerprozess läuft weiter
   ↓
kein erfolgreicher Framecommit
   ↓
Monitor bleibt schwarz, halb gezeichnet oder zeigt alten Stand
```

## Ziel

UI darf den Steuerprozess nicht crashen, muss Fehler aber sichtbar machen:

```text
FUEL UI ERROR

Page: Router
Code: RENDER_FAILED
Details: siehe Log
```

- Fehler in dediziertem UI-Diagnose-State speichern.
- Auf Monitor eine minimale Fallbackseite zeichnen.
- Stacktrace nur ins Log.
- Fehlerzähler und letzter Fehlerzeitpunkt im Diagnostics-Tab anzeigen.

## Diagnosezustand

```lua
ui_diag.last_error = {
  page = "Router",
  code = "RENDER_FAILED",
  message = "...",
  ts = os.epoch("utc"),
}
ui_diag.error_count = ui_diag.error_count + 1
```

## Abnahmetest

Ein absichtlich ausgelöster Page-Fehler zeigt innerhalb eines Renderzyklus eine lesbare Fehlerseite. Die FUEL-Node darf dabei nicht crashen.

---

# UI-P1.2 – Monitorwechsel und Größe zuverlässig behandeln

## Anforderungen

Bei:

- `peripheral`
- `peripheral_detach`
- Monitorwechsel
- Größenänderung
- Textskalierungsänderung

muss die UI:

1. alten Framecache verwerfen,
2. Touchzonen verwerfen,
3. neue Größe lesen,
4. genau einmal vollständig zeichnen,
5. danach wieder Diff-Rendering verwenden.

Touchzonen dürfen nie aus einem alten Frame stammen.

## Monitoridentität

Der UI-State muss mindestens unterscheiden:

```lua
{
  peripheral_name = ...,
  width = ...,
  height = ...,
  scale = ...,
  generation = ...,
}
```

Ändert sich eines dieser Felder, steigt die Generation und der nächste Frame wird vollständig übertragen.

## Abnahmetest

Wird der Monitor getrennt und ein anderer Monitor angeschlossen, reagieren Footer und Seitenbuttons sofort auf die neue Geometrie und nicht auf alte Touchzonen.

---

# UI-P1.3 – Datenzustände klar und ehrlich darstellen

Die UI muss unterscheiden:

```text
LOADING
NO CONFIG
LOGISTICS DISABLED
NO STORAGE
NO FRESH RT DATA
ROUTING INVALID
VALVE OFFLINE
READY
DELIVERING
ERROR
```

Ein schwarzer/leerer Monitor ist niemals ein gültiger Zustand.

## Darstellungsregel

Jede Seite erhält einen expliziten View-State:

```lua
model.view_state = {
  code = "NO_FRESH_RT_DATA",
  severity = "WARNING",
  title = "Keine aktuellen Reaktordaten",
  detail = "Warte auf MASTER/RT-Status",
}
```

Bei fehlenden Daten:

- keine leeren Karten ohne Erklärung,
- Ursache sichtbar nennen,
- nächstmöglichen Prüfschritt anzeigen,
- Diagnosecode im Log und auf der Diagnostics-Seite wiederfinden.

---

# 3. Konkrete Implementierungsarchitektur

## 3.1 Zentraler FUEL-UI-Controller

Empfohlenes neues Modul:

```text
nodes/fuel/ui_controller.lua
```

Verantwortung:

- Input normalisieren,
- Event genau einmal dispatchen,
- konsumierte Events stoppen,
- UI-State halten,
- Model genau einmal bauen,
- Render invalidieren,
- Frame committen,
- Fehlerdiagnose halten.

Beispiel:

```lua
local controller = fuel_ui_controller.new({
  build_model = build_fuel_ui_model,
  renderer = fuel_ui_renderer,
  monitor_provider = function() return devices.monitor end,
})
```

## 3.2 Eventverarbeitung

```lua
function controller:handle_event(event)
  local input = normalize_event(event)
  if not input then return false end

  local consumed = self.router:handle_input(input)
  if not consumed then
    consumed = self:handle_page_input(input)
  end

  if consumed then
    self:invalidate("interaction")
  end

  return consumed
end
```

## 3.3 Renderzyklus

```lua
function controller:tick(now, force)
  if not force and not self:is_due(now) and not self.dirty then
    return
  end

  local model = self.build_model()
  local snapshot = self:snapshot_for(model)

  if force or self.dirty or snapshot ~= self.last_snapshot then
    self.renderer:render(model)
    self.last_snapshot = snapshot
    self.dirty = false
  end
end
```

## 3.4 Keine direkten Page-Redraws

Seiten dürfen nur:

- State lesen,
- State ändern,
- `true/false` für Eventkonsum zurückgeben,
- in einen abstrakten Frame rendern.

Seiten dürfen nicht:

- eigenen Timer führen,
- direkt einen zweiten Renderzyklus starten,
- selbstständig `mux.clear()` auf dem realen Monitor ausführen,
- denselben Event erneut dispatchen.

---

# 4. Verbindliche UI-Testmatrix

## Input

1. Ein `monitor_touch` erzeugt genau eine Aktion.
2. Ein `mouse_click` erzeugt genau eine Aktion.
3. Footer `WEITER` wechselt nur die Seite und löst keinen Button der neuen Seite aus.
4. Footer `ZURÜCK` wechselt nur die Seite.
5. Router-Ausgang auswählen bleibt ausgewählt.
6. Reaktor auswählen erzeugt genau eine Route.
7. Zweiter Tap auf denselben Ausgang besitzt klar definierte Semantik und passiert nur einmal.
8. Schneller Doppeltap erzeugt keine unkontrollierte Mehrfachaktion.
9. Key-Navigation wird genau einmal verarbeitet.
10. Ein konsumiertes Event erreicht keine nachfolgende Seite.

## Render

11. Unverändertes Model erzeugt keine Monitorwrites.
12. Nur Reservewert geändert: kein Full-Clear.
13. Nur Masterstatus geändert: nur betroffene Bereiche werden geschrieben.
14. Seitenwechsel: genau ein vollständiger Framewechsel.
15. Interaktive Aktion ist im selben Eventzyklus sichtbar.
16. Langsamer Monitor erzeugt kein sichtbar halb aufgebautes Bild.
17. Monitorgröße geändert: Touchzonen und Frame werden neu aufgebaut.
18. Monitorwechsel verwirft alten Framecache.
19. Pro UI-Zyklus wird `build_status_payload()` höchstens einmal aufgerufen.
20. Snapshot und gezeichnetes Model besitzen dieselbe Model-ID/Generation.

## Router

21. Gespeicherte und aktive Route stimmen überein.
22. Validierungsfehler wird sichtbar dargestellt.
23. Offline-VALVE wird sichtbar dargestellt.
24. Save-Fehler zeigt Fehler und behält `dirty=true`.
25. Reboot zeigt dieselbe gespeicherte Route.
26. Ein direkter `_redraw()`-Pfad existiert nicht mehr.
27. Ausgewählter Ausgang bleibt nach zentralem Render ausgewählt.
28. Scrollzustand bleibt nach Datenupdate erhalten.
29. `RESET` benötigt klar definierte einmalige Aktion und sichtbare Bestätigung.
30. `SPEICHERN` führt genau einen Schreibversuch aus.

## Fehler

31. Absichtlich geworfener Page-Renderfehler zeigt Fallback-UI statt schwarzem Bildschirm.
32. Fehler einer optionalen Ampel beeinflusst Hauptmonitor nicht.
33. fehlender Payload zeigt `LOADING/NO DATA`, nicht leere Karten.
34. Monitor-Write-Fehler wird in Diagnostics sichtbar.
35. Model-Build-Fehler zeigt Fallback-UI.
36. Nach vorübergehendem Fehler kann die UI ohne Reboot wieder normal rendern.

## Performance

37. Unveränderte UI über 60 Sekunden erzeugt keine permanenten Full-Clears.
38. `full_clears` steigt nur bei Boot, Seiten-/Monitor-/Größenwechsel.
39. Ein Reserveupdate schreibt deutlich weniger als einen kompletten Bildschirm.
40. 100 Modemevents lösen nicht 100 UI-Modelaufbauten aus.

---

# 5. Bearbeitungsphasen

## Phase 1 – Bedienung reparieren

1. `router_touch` entfernen.
2. Event-Propagation nach konsumierter Navigation stoppen.
3. `mouse_click` und `monitor_touch` vereinheitlichen.
4. zentralen Eventkonsum mit `true/false` erzwingen.
5. Input-Regressionstests 1–10 erstellen.

## Phase 2 – Renderlogik reparieren

6. UI-Service auf genau ein Model pro Zyklus umbauen.
7. doppelte Zeitdrossel entfernen.
8. direkte `_redraw()`-Aufrufe der Router-Seite entfernen.
9. Interaktionen erzwingen einen sofortigen zentralen Commit.
10. Model-/Snapshot-Generation diagnostizierbar machen.

## Phase 3 – Flackern entfernen

11. `mux.clear()` aus normalen Datenupdates entfernen.
12. Framebuffer oder zeilenbasiertes Diff-Rendering einführen.
13. nur bei Boot, Seiten-, Größen- oder Monitorwechsel vollständig zeichnen.
14. Monitorwrite-Metriken ergänzen.
15. Render-/Performance-Tests 11–20 und 37–40 umsetzen.

## Phase 4 – Router zuverlässig machen

16. gespeicherte und aktive Routen zusammenführen.
17. Router-State vollständig ins zentrale UI-Model aufnehmen.
18. Validierungs- und Save-Fehler sichtbar darstellen.
19. Offline-Ventile sichtbar markieren.
20. Route nach Reboot korrekt laden und darstellen.

## Phase 5 – Fehlerdarstellung und Lifecycle

21. sichtbare Fallback-UI implementieren.
22. Monitor-/Größen-/Skalenwechsel korrekt behandeln.
23. Touchzonen an Framegeneration binden.
24. Wiederherstellung nach temporären Renderfehlern testen.
25. vollständige Testmatrix abschließen.

---

# 6. Definition of Done

- jeder physische Touch wird genau einmal verarbeitet
- Navigation löst keine Aktion auf der neuen Seite aus
- Monitor und Terminal reagieren gleich
- Interaktionen werden noch im selben Eventzyklus sichtbar
- pro UI-Zyklus wird genau ein Model aufgebaut
- Snapshot und gezeichnetes Model sind identisch
- nur eine zentrale Render-Drossel existiert
- kein direkter Seiten-Redraw umgeht den UI-Controller
- kein vollständiges Löschen bei normalen Datenänderungen
- vollständige Clears erfolgen nur bei Boot, Seiten-, Monitor- oder Größenwechsel
- Router-Seite verwendet denselben Zustand wie der operative Router
- gespeicherte, aktive und ungespeicherte Zustände sind klar unterscheidbar
- UI zeigt bei jedem Fehler einen sichtbaren Zustand statt Schwarzbild
- Monitorwechsel verwirft alte Touchzonen und Framecaches
- fehlende Daten erzeugen eine verständliche Zustandsseite
- alle 40 UI-Regressionstests sind vorhanden und grün
- während aller UI-Tests bleibt reale Fuel-Ausgabe deaktiviert
