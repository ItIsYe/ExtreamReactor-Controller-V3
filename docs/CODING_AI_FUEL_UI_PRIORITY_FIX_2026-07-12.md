# Coding-AI-Aufgaben: FUEL-UI hat Vorrang

Stand: 2026-07-12  
Ziel-Branch: `beta`

## Nutzerpriorität

Das aktuell wichtigste Problem der FUEL-Node ist die **nicht zuverlässig funktionierende Benutzeroberfläche**.

Die Coding-KI soll deshalb zuerst die UI reparieren und mit einer vollständig deaktivierten Fuel-Ausgabe testen. Sicherheits- und Logistikpunkte aus `CODING_AI_FUEL_NODE_DEEP_AUDIT_2026-07-12.md` bleiben gültig, dürfen die UI-Reparatur aber nicht unnötig verzögern.

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

## Konkrete Auswirkung

Auf der Router-Seite kann ein Tap:

1. einen Ausgang auswählen,
2. beim zweiten Aufruf denselben Ausgang sofort wieder abwählen oder eine bestehende Route entfernen.

## Verbindlicher Fix

- Den separaten `router_touch`-Service vollständig entfernen.
- Es gibt nur noch einen zentralen Input-Dispatcher.
- Seitenspezifische Handler werden ausschließlich vom `ui_router` beziehungsweise dessen kontrolliertem Nachfolger aufgerufen.

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

## Risiko

Ein Klick auf `WEITER` kann zusätzlich einen Button auf der neuen Seite auslösen, wenn dessen Touchzone dieselben Koordinaten verwendet.

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

## Fix

Gemeinsame Normalisierung:

```lua
local function normalize_pointer_event(event)
  if event[1] == "monitor_touch" then
    return { kind = "pointer", source = "monitor", x = event[3], y = event[4] }
  elseif event[1] == "mouse_click" then
    return { kind = "pointer", source = "terminal", x = event[3], y = event[4] }
  end
end
```

- `mouse_click` gilt als interaktiv.
- Footer-, Listen- und Seitenbuttons verwenden denselben Pointerpfad.

---

# UI-P0.4 – Pro UI-Zyklus genau ein Model erzeugen

## Aktuelles Problem

`ui_service.snapshot()` baut einen Status/Payload auf. Danach ruft `render_monitor()` erneut `build_status_payload()` und baut ein zweites Model.

Der 300-ms-Payload-Cache reduziert einzelne Hardware-Reads, beseitigt aber nicht:

- zwei unabhängige Modelaufbauten,
- zwei Snapshot-Vergleiche,
- mögliche Unterschiede zwischen geprüftem und gezeichnetem Zustand,
- unnötige Registry-/Comms-/Alert-Auswertungen.

## Ziel-API

```lua
local model = ui_model_builder.build(event)
ui_router:render(mon, model, { force = interactive })
```

Der UI-Service soll das Model einmal erzeugen und genau dieses Objekt an den Renderer übergeben.

Empfohlene neue Signatur:

```lua
ui_service.new({
  build_model = function(event) return build_fuel_ui_model(event) end,
  render = function(model, event) render_monitor(model, event) end,
})
```

Kein separater kleiner Snapshot und danach ein zweiter vollständiger Renderaufbau.

## Abnahmetest

Ein UI-Tick ruft `build_status_payload()` höchstens einmal auf.

---

# UI-P0.5 – Nur eine Render-Drossel verwenden

## Aktuelles Problem

Es existieren mindestens zwei voneinander unabhängige Zeitdrosseln:

1. `ui_service.last_draw`
2. `ui_router.last_draw`

Der UI-Service lässt interaktive Events sofort durch. Der innere `ui_router` kann dieselbe Darstellung trotzdem erneut wegen seines eigenen Intervalls überspringen.

Ein Seitenwechsel setzt den inneren Timer zurück, eine normale seitenspezifische Aktion jedoch nicht zwingend.

## Folgen

- Touch wurde intern verarbeitet, aber sichtbare Reaktion erscheint verspätet.
- Buttons wirken unzuverlässig.
- Nutzer tippt erneut und löst dadurch mehrere Aktionen aus.

## Fix

Bevorzugt:

- Zeitplanung ausschließlich im UI-Service.
- `ui_router` entscheidet nur noch anhand von Snapshot/Invalidierung.

Alternativ muss der Renderer einen eindeutigen Force-Parameter erhalten:

```lua
ui_router:render(mon, model, { force = interactive })
```

Bei `force=true` darf weder Intervall noch unveränderter Snapshot die notwendige sichtbare Interaktionsantwort verhindern.

---

# UI-P0.6 – Vollständiges Löschen des Monitors bei jedem Redraw entfernen

## Bestätigtes Problem

Alle FUEL-Seiten rufen über Header beziehungsweise Router-Seite `mux.clear(mon)` auf.

`core/mockup_ui.lua` löscht dabei den kompletten Monitor zeilenweise. Danach werden Header, Karten, Texte und Footer vollständig neu geschrieben.

Der Mockup-Renderer verwendet dabei direkte Monitoraufrufe und umgeht den Dirty-Cache aus `core/ui.lua` weitgehend.

## Sichtbare Folgen

- hartes Blinken/Flickern,
- kurz leerer oder einfarbiger Monitor,
- hohe Zahl von Monitor-Schreibvorgängen,
- bei langsamen Wired-Modem-Peripherals sichtbar unvollständiger Bildaufbau.

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

## Mindestlösung

Falls ein Framebuffer noch nicht sofort umgesetzt wird:

- `mux.clear()` nur beim ersten Render, Monitorwechsel, Größenwechsel oder Seitenwechsel.
- Bei normalen Datenänderungen nur betroffene Bereiche überschreiben.
- alte längere Texte vollständig mit Leerzeichen entfernen.

## Abnahmetest

Bei unveränderter Seite und geändertem Reservewert darf der Monitor nicht vollständig geleert werden.

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
}
```

Interaktion:

1. State ändern.
2. `ui_service:invalidate("router_state")` aufrufen.
3. zentralen Renderer einmal ausführen.

Keine direkte Selbstzeichnung aus dem Page-Objekt.

---

# UI-P0.8 – Router-UI benötigt einen einzigen kanonischen Zustand

## Aktuelles Problem

Die Oberfläche besitzt lokale `u.routes`, während der operative Router `config.logistics.redstone_tree` verwendet.

Dadurch kann die UI etwas anderes anzeigen als die aktive Konfiguration.

## UI-Ziel

Die Router-Seite zeigt klar getrennt:

- `GESPEICHERT`
- `AKTIV`
- `UNGESPEICHERTE ÄNDERUNGEN`
- `VALIDIERUNGSFEHLER`
- `VENTIL OFFLINE`

Der aktive Zustand muss aus derselben kanonischen Routequelle kommen wie die Logik.

Nach `Speichern`:

1. atomar persistieren,
2. wieder einlesen,
3. validieren,
4. operativen Router aktualisieren,
5. UI-Modell aus operativem Zustand neu aufbauen,
6. Erfolg oder exakten Fehler sichtbar anzeigen.

---

# UI-P1.1 – Fehler nicht stillschweigend verschlucken

## Problem

Mehrere UI-Funktionen sind großflächig mit `pcall()` isoliert. Das schützt den Node, kann aber zu schwarzem oder veraltetem Monitor ohne sichtbare Ursache führen.

## Ziel

UI darf den Steuerprozess nicht crashen, muss Fehler aber sichtbar machen:

```text
UI ERROR
page=Router
code=RENDER_FAILED
short_reason=...
```

- Fehler in dediziertem UI-Diagnose-State speichern.
- Auf Monitor eine minimale Fallbackseite zeichnen.
- Stacktrace nur ins Log.
- Fehlerzähler und letzter Fehlerzeitpunkt im Diagnostics-Tab anzeigen.

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

Für fehlende Daten immer eine sichtbare Seite mit Ursache und nächstem Prüfschritt darstellen.

---

# Verbindliche UI-Testmatrix

## Input

1. Ein `monitor_touch` erzeugt genau eine Aktion.
2. Ein `mouse_click` erzeugt genau eine Aktion.
3. Footer `WEITER` wechselt nur die Seite und löst keinen Button der neuen Seite aus.
4. Router-Ausgang auswählen bleibt ausgewählt.
5. Reaktor auswählen erzeugt genau eine Route.
6. Schneller Doppeltap erzeugt keine unkontrollierte Mehrfachaktion.

## Render

7. Unverändertes Model erzeugt keine Monitorwrites.
8. Nur Reservewert geändert: kein Full-Clear.
9. Seitenwechsel: genau ein vollständiger Framewechsel.
10. Interaktive Aktion ist im selben Eventzyklus sichtbar.
11. Langsamer Monitor erzeugt kein sichtbar halb aufgebautes Bild.
12. Monitorgröße geändert: Touchzonen und Frame werden neu aufgebaut.

## Router

13. Gespeicherte und aktive Route stimmen überein.
14. Validierungsfehler wird sichtbar dargestellt.
15. Offline-VALVE wird sichtbar dargestellt.
16. Save-Fehler zeigt Fehler und behält `dirty=true`.
17. Reboot zeigt dieselbe gespeicherte Route.

## Fehler

18. Absichtlich geworfener Page-Renderfehler zeigt Fallback-UI statt schwarzem Bildschirm.
19. Fehler einer optionalen Ampel beeinflusst Hauptmonitor nicht.
20. fehlender Payload zeigt `LOADING/NO DATA`, nicht leere Karten.

---

# Bearbeitungsreihenfolge

1. `router_touch` entfernen
2. Event-Propagation nach konsumierter Navigation stoppen
3. `mouse_click` normalisieren und als interaktiv behandeln
4. UI-Service auf ein Model pro Zyklus umbauen
5. doppelte Zeitdrossel entfernen
6. Router-State in zentralen Renderzyklus integrieren
7. Full-Clear durch Framebuffer-/Diff-Rendering ersetzen
8. kanonischen aktiven/gespeicherten Routerzustand herstellen
9. sichtbare UI-Fehlerseite und Diagnose
10. Monitor-Lifecycle und komplette Testmatrix

# Definition of Done

- jeder physische Touch wird genau einmal verarbeitet
- Navigation löst keine Aktion auf der neuen Seite aus
- Monitor und Terminal reagieren gleich
- Interaktionen werden sofort sichtbar
- pro UI-Zyklus wird genau ein Model aufgebaut
- kein vollständiges Löschen bei normalen Datenänderungen
- Router-Seite verwendet denselben Zustand wie der operative Router
- UI zeigt bei jedem Fehler einen sichtbaren Zustand statt Schwarzbild
- alle 20 UI-Regressionstests sind vorhanden und grün
