-- nodes/fuel/redstone_router.lua
-- Per-reactor valve-path routing for Mekanism pipe networks.
--
-- Fix (2026-07-19): CRITICAL usability finding. Bis hierher war
-- config.logistics.redstone_tree ein VERSCHACHTELTER Baum (side/children),
-- damit mehrere Ventile in Serie (ein gemeinsames Trunk-Ventil vor mehreren
-- Reaktor-Zweigen) und ein per Reaktor eindeutiger Pfad abbildbar waren.
-- Das ist technisch maechtig, aber nur von Hand als Lua-Tabelle editierbar
-- -- die Touch-UI (router_ui.lua) konnte pro Reaktor immer nur GENAU EIN
-- Ventil zuweisen und schaltete sich bei einem bereits verschachtelten Baum
-- sogar komplett auf "nur lesen", um ihn nicht versehentlich platt zu
-- machen.
--
-- Jetzt ist die Config eine FLACHE Liste von Routen, eine pro Reaktor, mit
-- einer geordneten Ventilliste ("path") direkt am Reaktor:
--   { reactor = "<id>", label = "<Anzeigename>",
--     path = { { side = "back" }, { side = "left", integrator = "VALVE-1" } } }
-- Ein gemeinsames Ventil auf dem Weg zu mehreren Reaktoren wird einfach
-- ALS DERSELBE {side=,integrator=}-Kombination in mehreren Routen-Pfaden
-- wiederholt -- keine Tabellen-Verschachtelung mehr noetig, damit ist die
-- Struktur sowohl von Hand als auch (siehe router_ui.lua) durch einen
-- mehrstufigen Touch-Editor (Reaktor waehlen -> Ventil fuer Ventil
-- antippen) direkt konfigurierbar.
--
-- normalize_tree() unten akzeptiert weiterhin (gemischt, auch in derselben
-- Liste) alle drei historischen Formen ohne manuelle Migration:
--   1. NEUES Format (path=...), wie oben.
--   2. Alte FLACHE Form (die bisher einzige, die die Touch-UI erzeugen
--      konnte): { side=, integrator=, reactor=, label= } -- genau ein
--      Ventil pro Reaktor.
--   3. Alte VERSCHACHTELTE Baum-Form (children=...) -- wird rekursiv zu
--      path=<gesamter Ast von der Wurzel bis zum Reaktor-Blatt> aufgeloest.

local constants = require("shared.constants")

local M = {}

local BUILTIN_SIDES = {
  top=true, bottom=true, left=true, right=true, front=true, back=true
}

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return nil, "no_method" end
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

-- Liefert eine flache, deduplizierte Liste JEDES Ventils, das in
-- irgendeiner Route vorkommt (side+integrator identisch => dasselbe
-- physische Ventil, unabhaengig davon, in wie vielen Routen es auftaucht).
local function collect_all_valves(routes)
  local seen, out = {}, {}
  for _, route in ipairs(routes or {}) do
    for _, step in ipairs(route.path or {}) do
      local key = tostring(step.side) .. "|" .. tostring(step.integrator or "")
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { side = step.side, integrator = step.integrator }
      end
    end
  end
  return out
end

local function find_route(routes, target_id)
  for _, route in ipairs(routes or {}) do
    if route.reactor == target_id or route.label == target_id then return route end
  end
  return nil
end

local function find_path(routes, target_id)
  local route = find_route(routes, target_id)
  if not route then return nil end
  local copy = {}
  for i, step in ipairs(route.path or {}) do copy[i] = { side = step.side, integrator = step.integrator } end
  return copy
end

local function path_key(path)
  local parts = {}
  for _, v in ipairs(path or {}) do
    parts[#parts + 1] = tostring(v.side) .. ":" .. tostring(v.integrator or "")
  end
  return table.concat(parts, ">")
end

-- Normalisiert die rohe Config (siehe Formen 1-3 oben) in eine flache
-- Routenliste. Sammelt strukturelle Fehler dabei im selben Durchlauf ein
-- (Rueckgabe: routes, errors) -- normalize_tree() (oeffentlich, nur
-- Routen) und M.validate_tree() (oeffentlich, Validierungsergebnis) sind
-- beides duenne Wrapper darum, damit M:refresh() nur EINMAL pro Zyklus
-- laufen muss, statt Normalisierung und Validierung getrennt zu wiederholen.
local function normalize_with_errors(raw)
  local routes, errors = {}, {}
  local function err(code, message) errors[#errors + 1] = { code = code, message = message } end

  if type(raw) ~= "table" then
    err("tree_not_table", "redstone_tree ist keine Tabelle (nil oder falscher Typ)")
    return routes, errors
  end

  local function emit(reactor, label, path, source_desc)
    if not reactor and not label then
      err("missing_target", "Route ohne 'reactor' und ohne 'label' (" .. tostring(source_desc) .. ") -- nicht adressierbar")
      return
    end
    local copy = {}
    for _, step in ipairs(path or {}) do copy[#copy + 1] = { side = step.side, integrator = step.integrator } end
    routes[#routes + 1] = { reactor = reactor, label = label or reactor, path = copy }
  end

  local visiting = setmetatable({}, { __mode = "k" })  -- Zyklen-Schutz fuer verschachtelte Legacy-Baeume

  local function walk(nodes, ancestor_path, depth)
    if visiting[nodes] then
      err("cycle_detected", "Zyklische Struktur erkannt (Tabelle verweist auf sich selbst)")
      return
    end
    visiting[nodes] = true
    if depth > 32 then
      err("depth_exceeded", "Baumtiefe > 32 — vermutlich fehlerhafte/zyklische Struktur")
      visiting[nodes] = nil
      return
    end

    for i, node in ipairs(nodes or {}) do
      if type(node) ~= "table" then
        err("invalid_node", "Eintrag #" .. i .. " auf Tiefe " .. depth .. " ist keine Tabelle")
        goto next_node
      end

      -- Form 1: neues Format, eigenstaendige Route mit 'path'.
      if node.path ~= nil then
        if type(node.path) ~= "table" then
          err("invalid_path", "Route '" .. tostring(node.reactor or node.label or ("#" .. i)) .. "' hat ein 'path'-Feld, das keine Tabelle ist")
          goto next_node
        end
        for step_i, step in ipairs(node.path) do
          if type(step) ~= "table" then
            err("invalid_path_step", "Route '" .. tostring(node.reactor or node.label or ("#" .. i)) .. "', Schritt #" .. step_i .. " ist keine Tabelle")
          elseif step.side and not BUILTIN_SIDES[step.side] then
            err("invalid_side", "Route '" .. tostring(node.reactor or node.label or ("#" .. i)) .. "', Schritt #" .. step_i
              .. ": ungueltige Redstone-Seite '" .. tostring(step.side) .. "' (erlaubt: top/bottom/left/right/front/back)")
          elseif not step.side then
            err("invalid_path_step", "Route '" .. tostring(node.reactor or node.label or ("#" .. i)) .. "', Schritt #" .. step_i .. " hat keine 'side'")
          end
        end
        emit(node.reactor, node.label, node.path, "Index " .. i)
        goto next_node
      end

      -- Formen 2+3: Legacy-Knoten mit eigenem 'side' und/oder 'children'.
      if not node.side and not node.reactor and (type(node.children) ~= "table" or #node.children == 0) then
        err("missing_side", "Knoten ohne 'side', 'reactor', 'children' oder 'path' (Tiefe " .. depth .. ", Index " .. i .. ")")
      end
      if node.side and not BUILTIN_SIDES[node.side] then
        err("invalid_side", "Ungueltige Redstone-Seite '" .. tostring(node.side)
          .. "' (erlaubt: top/bottom/left/right/front/back)")
      end

      local step = node.side and { side = node.side, integrator = node.integrator } or nil
      local next_path = ancestor_path
      if step then
        next_path = {}
        for _, v in ipairs(ancestor_path) do next_path[#next_path + 1] = v end
        next_path[#next_path + 1] = step
      end

      if node.reactor then
        if type(node.children) == "table" and #node.children > 0 then
          err("reactor_with_children", "Reaktor '" .. tostring(node.reactor)
            .. "' hat zusaetzlich 'children' — ein Reaktor-Endpunkt darf keine weiteren Aeste haben")
        end
        emit(node.reactor, node.label, next_path, "Index " .. i)
      elseif not node.side and not (type(node.children) == "table" and #node.children > 0) then
        -- bereits oben als missing_side gemeldet, hier nichts weiter tun
      elseif not (type(node.children) == "table" and #node.children > 0) then
        err("dead_end", "Knoten '" .. tostring(node.side or node.label or ("#" .. i))
          .. "' fuehrt nirgendwohin (kein 'reactor', keine 'children')")
      end

      if type(node.children) == "table" and #node.children > 0 then
        walk(node.children, next_path, depth + 1)
      end

      ::next_node::
    end
    visiting[nodes] = nil
  end

  walk(raw, {}, 1)

  -- Reaktor-Duplikate und identische (nicht unterscheidbare) Pfade ueber
  -- die fertig aufgeloeste Routenliste, nicht ueber die rohe Struktur --
  -- funktioniert dadurch identisch fuer alle drei Eingabeformen.
  local seen_reactors, seen_paths = {}, {}
  for _, route in ipairs(routes) do
    if route.reactor then
      if seen_reactors[route.reactor] then
        err("duplicate_reactor", "Reaktor-Ziel '" .. tostring(route.reactor) .. "' mehrfach konfiguriert")
      end
      seen_reactors[route.reactor] = true
    end
    local pk = path_key(route.path)
    if seen_paths[pk] then
      err("identical_paths", "Routen '" .. tostring(route.reactor or route.label) .. "' und '"
        .. tostring(seen_paths[pk]) .. "' haben identische Ventil-Pfade — nicht unterscheidbar")
    end
    seen_paths[pk] = route.reactor or route.label
  end

  return routes, errors
end

-- Oeffentlich: nur die normalisierten Routen, ohne Validierungsergebnis --
-- fuer router_ui.lua (Editor-Ansicht direkt aus der echten Config bauen,
-- garantiert identisch zu dem, was M:refresh() tatsaechlich verwendet).
function M.normalize_tree(raw)
  local routes = normalize_with_errors(raw)
  return routes
end

-- Feature (2026-07-08): strukturelle Validierung vor Aktivierung. Rein
-- statisch (keine Peripherie-Pruefung -- Integratoren koennen online
-- kommen/gehen, das gehoert nicht in eine Struktur-Validierung, sondern
-- bleibt Aufgabe von M:refresh()'s Laufzeit-Warnungen).
-- Rueckgabe: { ok=bool, errors={ {code=..., message=...}, ... } }
function M.validate_tree(raw)
  local _, errors = normalize_with_errors(raw)
  return { ok = #errors == 0, errors = errors }
end

function M.new(opts)
  opts = opts or {}
  -- Feature (2026-07-09): eigener, dedizierter Funkkanal fuer SET_VALVE
  -- (constants.channels.VALVE = 6504), bewusst getrennt von der normalen
  -- comms_service-Pipeline (kein CONTROL/STATUS-Traffic) -- roh per
  -- modem.transmit, kein Ack/Retry-Overhead.
  local valve_modem = nil
  local ok_find, m = pcall(peripheral.find, "modem", function(_, mm) return mm.isWireless and mm.isWireless() end)
  if ok_find and m then
    valve_modem = m
    pcall(valve_modem.open, constants.channels.VALVE)
  end
  local self = {
    config = opts.config or {},
    log = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    -- Fuer Auto-Discovery erreichbarer VALVE-Nodes (siehe refresh()).
    comms = opts.comms or nil,
    valve_modem = valve_modem,
    _state = {
      all_valves = {},
      integrators = {},
      routes = {},
      active_target = nil,
      active_path = nil,
      last_target = nil,
      last_path = nil,
      last_active_ts = nil,
      tree_valid = nil,
      tree_errors = {},
      tree_configured = false,
    },
  }
  return setmetatable(self, { __index = M })
end

function M:refresh()
  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}
  -- Feature (2026-07-13): CRITICAL Sicherheitsfund (siehe docs/CODING_AI_
  -- OTHER_NODES_PERFORMANCE_2026-07-12.md, Sicherheitsregel zu REPROC-P0.3).
  -- tree_configured haelt fest, ob ueberhaupt ein Baum in der Config
  -- STAND (unabhaengig davon, ob er gueltig war) -- Grundlage fuer die
  -- Unterscheidung in route_and_act() weiter unten zwischen "Routing war
  -- nie gewollt" (sicher, Direkt-Export ok) und "Routing war konfiguriert,
  -- aber kaputt/leer geworden" (GEFAEHRLICH, muss blockieren).
  self._state.tree_configured = #tree > 0

  -- Feature (2026-07-08): strukturelle Validierung VOR jeder Aktivierung.
  -- Bei einem ungueltigen Baum: alle Ventile blockieren (Fail-Safe-
  -- Grundzustand, kein Fuel-Transfer moeglich), all_valves/integrators
  -- NICHT aus dem fehlerhaften Baum laden, und der Fehler wird geloggt
  -- (landet damit auch im Log-Collector-System) sowie ueber get_
  -- validation() fuer UI/zukuenftige Master-Alerts bereitgestellt.
  --
  -- Fix (2026-07-13): CRITICAL. tree_configured (siehe oben) unterscheidet
  -- "Routing war nie gewollt" (sicher, Direkt-Export ok) von "Routing war
  -- konfiguriert, aber kaputt/leer geworden" (GEFAEHRLICH, muss
  -- blockieren) -- ein Baum, der KONFIGURIERT war aber ungueltig ist,
  -- blockiert tatsaechlich (siehe begin_transaction()).
  --
  -- Fix (2026-07-16): CRITICAL (ROUTER-P0.9, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md Abschnitt 9). Die vorherige Fassung
  -- dieses Kommentars empfahl, dass "route_count() bleibt 0, damit
  -- logistics_router.lua sauber auf den ungerouteten Direkt-Export-Pfad
  -- zurueckfaellt" -- das war GENAU der Bug: route_count()/get_routing_
  -- table() liest strukturell aus dem ROHEN cfg.redstone_tree (unabhaengig
  -- von tree_valid/tree_configured hier) und kann bei einem kaputten Baum,
  -- der GAR KEINE 'side'-Ventil-Eintraege mehr strukturell findet, selbst
  -- 0 zurueckgeben, obwohl der Baum tatsaechlich KONFIGURIERT war (nur
  -- kaputt). logistics_router.lua nutzte genau dieses 0 als Signal fuer
  -- "nie konfiguriert" und fiel ungeschuetzt auf Direkt-Export zurueck --
  -- exakt der Bug, den block_all()/begin_transaction()'s eigene "invalid_
  -- tree"-Pruefung eigentlich verhindern sollte, aber NIE erreicht wurde,
  -- weil logistics_router.lua begin_transaction() in diesem Fall gar nicht
  -- erst aufrief. get_routing_state() (siehe unten) ist jetzt die einzige
  -- Autoritaet fuer diese Entscheidung -- basiert auf tree_configured/
  -- tree_valid/all_valves statt auf einem strukturellen Baum-Walk.
  -- Fix (2026-07-19): normalize_with_errors() laeuft hier nur noch EINMAL
  -- pro Zyklus (statt einer separaten M.validate_tree()-Normalisierung und
  -- eines zweiten collect_all_valves()-Baumdurchlaufs) und liefert direkt
  -- die fertigen Routen -- self._state.routes ist ab hier die alleinige,
  -- gecachte Grundlage fuer begin_transaction()/get_tree()/get_path_to()/
  -- get_routing_table()/get_valve_status(), bis zum naechsten refresh().
  local routes, errors = normalize_with_errors(tree)
  self._state.routes = routes
  self._state.tree_valid = #errors == 0
  self._state.tree_errors = errors

  if #errors > 0 then
    for _, e in ipairs(errors) do
      self.warn_once("tree_invalid:" .. e.code, "RedstoneRouter: UNGUELTIGER BAUM [" .. e.code .. "] " .. e.message)
    end
    self._state.all_valves = {}
    self._state.integrators = {}
    self:block_all()
    self.log("ERROR", string.format(
      "RedstoneRouter: redstone_tree ungueltig (%d Fehler) — alle Ventile blockiert, kein Routing aktiv",
      #errors))
    return
  end

  local all = collect_all_valves(routes)
  self._state.all_valves = all

  local int_names = {}
  for _, v in ipairs(all) do if v.integrator then int_names[v.integrator] = true end end
  local integrators = {}
  local known_peers = self.comms and self.comms:get_peers() or {}
  for name in pairs(int_names) do
    if known_peers[name] and not known_peers[name].down then
      -- Feature (2026-07-09): Auto-Discovery -- der Integrator meldet
      -- sich selbststaendig per HELLO/Heartbeat (wie jeder andere Node),
      -- FUEL muss ihn nicht manuell als Peripheral konfigurieren. "name"
      -- ist hier die node_id des VALVE-Node aus dem redstone_tree.
      integrators[name] = { network = true, node_id = name }
      self.log("DEBUG", "RedstoneRouter: integrator " .. name .. " (VALVE-Node, per Funk erreichbar)")
    elseif peripheral.isPresent(name) then
      local ok, w = pcall(peripheral.wrap, name)
      if ok and w then
        integrators[name] = { network = false, wrapped = w }
        self.log("DEBUG", "RedstoneRouter: integrator " .. name .. " (lokales Peripheral)")
      else
        self.warn_once("int:" .. name, "RedstoneRouter: integrator wrap failed: " .. name)
      end
    else
      self.warn_once("int_abs:" .. name,
        "RedstoneRouter: integrator '" .. name .. "' weder als VALVE-Node per Funk erreichbar noch als lokales Peripheral gefunden")
    end
  end
  self._state.integrators = integrators
  self:block_all()
  self.log("DEBUG", string.format("RedstoneRouter: tree loaded, %d total valves", #all))
end

function M:_set_valve(valve, high)
  local side = valve.side
  -- Feature (2026-07-12): REST-P0.3 (siehe docs/CODING_AI_FUEL_UI_
  -- PRIORITY_FIX_2026-07-12.md). Angeforderten Zustand PRO INTEGRATOR
  -- festhalten (unabhaengig davon, ob das Schalten tatsaechlich
  -- erfolgreich war) -- Grundlage fuer die VALVE-Statusanzeige auf der
  -- Router-Seite. Ehrlich benannt "requested", NICHT "confirmed": das
  -- Funkprotokoll ist weiterhin fire-and-forget ohne ACK, ein
  -- erfolgreicher modem.transmit() bestaetigt nicht, dass Redstone
  -- tatsaechlich geschaltet wurde.
  -- Fix (2026-07-13): CRITICAL (VALVE-P1, siehe docs/CODING_AI_OTHER_
  -- NODES_PERFORMANCE_2026-07-12.md). "Der gewuenschte Zustand wird
  -- aktuell nur pro Integrator-ID gespeichert. Fuer Nodes mit mehreren
  -- Seiten muss der Schluessel mindestens (integrator, side) enthalten."
  -- -- vorher konnte bei EINEM VALVE-Node mit MEHREREN angeschlossenen
  -- Seiten der zuletzt gesetzte Zustand einer Seite den einer ANDEREN
  -- Seite am selben Integrator stillschweigend ueberschreiben.
  if valve.integrator then
    self._state.valve_requested = self._state.valve_requested or {}
    self._state.valve_requested[valve.integrator .. "|" .. tostring(side)] = high and "BLOCKED" or "OPEN"
  end
  if valve.integrator then
    local w = self._state.integrators[valve.integrator]
    if w and w.network then
      -- Fix (2026-07-13): CRITICAL (VALVE-P1, siehe docs/CODING_AI_OTHER_
      -- NODES_PERFORMANCE_2026-07-12.md). Der Kanal war bisher komplett
      -- fire-and-forget: kein ACK, kein Retry, keine Sequenznummer, kein
      -- Dedupe. Das bestehende Fail-Safe-Verhalten (VALVE faellt nach 20s
      -- ohne Kommando in BLOCKED) bleibt die LETZTE Verteidigungslinie,
      -- ist aber kein Ersatz fuer eine tatsaechliche Zustellbestaetigung
      -- -- ein verlorenes Kommando konnte bis zu 20s lang unbemerkt
      -- bleiben. Jetzt: jedes Kommando bekommt eine eindeutige command_id,
      -- wird als "pending" verfolgt (siehe check_pending_acks() weiter
      -- unten, periodisch von der aufrufenden Rolle aufgerufen) und bei
      -- fehlender Bestaetigung innerhalb eines Timeouts automatisch erneut
      -- gesendet (begrenzte Anzahl Versuche). handle_valve_ack() verarbeitet
      -- die Antwort und traegt den TATSAECHLICH bestaetigten Zustand ein.
      if not self.valve_modem then
        self.warn_once("no_valve_modem", "RedstoneRouter: kein Wireless Modem fuer den Ventil-Kanal gefunden")
        return false
      end
      self._state.command_seq = (self._state.command_seq or 0) + 1
      local command_id = tostring(self.config.node_id or "FUEL") .. "-" .. tostring(os.epoch and os.epoch("utc") or 0) .. "-" .. tostring(self._state.command_seq)
      local key = valve.integrator .. "|" .. tostring(side)
      local message = {
        type = "SET_VALVE", src = self.config.node_id, dst = w.node_id,
        command_id = command_id, side = side, high = high, ts = os.epoch and os.epoch("utc") or 0,
      }
      local ok = pcall(self.valve_modem.transmit, constants.channels.VALVE, constants.channels.VALVE, message)
      if not ok then
        self.warn_once("valve_net_fail:" .. valve.integrator,
          "RedstoneRouter: SET_VALVE an " .. valve.integrator .. " konnte nicht gesendet werden")
        return false
      end
      self._state.pending_valve_acks = self._state.pending_valve_acks or {}
      self._state.pending_valve_acks[key] = {
        command_id = command_id, dst = w.node_id, side = side, high = high,
        integrator = valve.integrator, sent_ts = message.ts, retries = 0,
      }
      return true, command_id
    end
    if w and w.wrapped then
      local ok = safe_call(w.wrapped, "setOutput", side, high)
      if ok == nil then
        self.warn_once("valve_set_fail:" .. valve.integrator .. ":" .. tostring(side),
          "RedstoneRouter: Ventil-Schaltung fehlgeschlagen (" .. valve.integrator .. "/" .. tostring(side) .. ")")
        return false
      end
      return true
    end
    -- Fix (2026-07-08): Integrator offline/nicht gewrapped — vorher
    -- passierte hier STILLSCHWEIGEND gar nichts (kein Log, kein
    -- Fehlerstatus). Ein Ventil, das nicht geschaltet werden kann, bleibt
    -- in unbekanntem Zustand — sicherheitsrelevant genug fuer eine
    -- explizite Warnung.
    self.warn_once("int_offline:" .. valve.integrator,
      "RedstoneRouter: Integrator '" .. valve.integrator .. "' offline — Ventil (" .. tostring(side) .. ") nicht schaltbar")
    return false
  elseif BUILTIN_SIDES[side] then
    local ok = pcall(redstone.setOutput, side, high)
    if not ok then
      self.warn_once("valve_rs_fail:" .. tostring(side),
        "RedstoneRouter: redstone.setOutput fehlgeschlagen fuer Seite '" .. tostring(side) .. "'")
      return false
    end
    return true
  else
    self.warn_once("bad_side:" .. tostring(side), "RedstoneRouter: unknown side '" .. tostring(side) .. "'")
    return false
  end
end

function M:block_all()
  local all_ok = true
  for _, v in ipairs(self._state.all_valves) do
    if not self:_set_valve(v, true) then all_ok = false end
  end
  return all_ok
end

local function valve_key(integrator, side)
  return tostring(integrator or "") .. "|" .. tostring(side)
end

-- Fix (2026-07-16): CRITICAL (ROUTER-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 8, "Verbindliche Sicherheitsregel").
-- Sendet SET_VALVE fuer eine Liste von {side=, integrator=, high=}-
-- Eintraegen und baut eine Bestaetigungs-Erwartung PRO Ventil auf.
-- Netzwerk-Ventile (VALVE-Node per Funk) brauchen ein asynchrones ACK
-- (siehe _set_valve()/handle_valve_ack() -- pending_valve_acks/confirmed_
-- valve_state); lokale Peripherals und eingebaute Redstone-Seiten werden
-- synchron geschaltet, ihr _set_valve()-Rueckgabewert IST bereits die
-- Bestaetigung (kein Funk-Roundtrip noetig).
function M:_request_valve_batch(entries)
  local pending = {}
  for _, entry in ipairs(entries) do
    local key = valve_key(entry.integrator, entry.side)
    local w = entry.integrator and self._state.integrators[entry.integrator] or nil
    local needs_ack = w and w.network == true
    local ok, command_id = self:_set_valve({ side = entry.side, integrator = entry.integrator }, entry.high)
    pending[key] = {
      integrator = entry.integrator, side = entry.side, high = entry.high,
      needs_ack = needs_ack, sync_ok = ok, command_id = command_id,
    }
  end
  return pending
end

-- Prueft eine per _request_valve_batch() aufgebaute Bestaetigungs-
-- Erwartung. Rueckgabe "ok": JEDES Ventil ist nachweislich im
-- angeforderten Zustand (ACK vorhanden, applied==true, bestaetigtes high
-- entspricht angefordertem high -- fuer synchrone Ventile: Schaltbefehl
-- erfolgreich). "waiting": mindestens ein Netzwerk-ACK ist noch
-- unterwegs (nicht aufgegeben), aber nichts ist bisher fehlgeschlagen.
-- "failed": mindestens ein Ventil ist nachweislich NICHT im gewuenschten
-- Zustand (synchroner Fehlschlag, oder ein Netzwerk-Kommando wurde nach
-- VALVE_ACK_MAX_RETRIES aufgegeben ohne Bestaetigung -- check_pending_
-- acks() loescht es dann aus pending_valve_acks OHNE confirmed_valve_
-- state zu setzen, was hier als "nicht pending UND nicht bestaetigt"
-- erkannt wird).
--
-- Fix (2026-07-17): KRITISCHER SAFETYFEHLER (ROUTER-P0, siehe docs/CODING_
-- AI_OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitt 17). confirmed_valve_
-- state[key] wird NIE geloescht und ueberlebt beliebig viele nachfolgende
-- Transaktionen fuer denselben Ventilschluessel. Vorher pruefte dieser
-- Check nur noch "confirmed.applied==true and confirmed.high==entry.high"
-- OHNE zu wissen, zu WELCHEM Kommando dieser Bestaetigungszustand gehoerte.
-- Szenario: ein Ventil wurde frueher fuer ein AELTERES Kommando bestaetigt
-- BLOCKED; ein NEUES BLOCKED-Kommando (z.B. Phase-1 der naechsten
-- Transaktion) wird gesendet, aber ALLE seine ACKs gehen verloren --
-- check_pending_acks() gibt nach VALVE_ACK_MAX_RETRIES auf und loescht den
-- pending-Eintrag OHNE confirmed_valve_state zu aktualisieren. Der alte,
-- zufaellig passende Bestaetigungszustand blieb dann als (falscher) Beweis
-- fuer das NEUE Kommando stehen -- die Transaktion konnte faelschlich als
-- bestaetigt gelten und exportieren, obwohl das aktuelle Kommando nie
-- bestaetigt wurde. Jetzt wird zusaetzlich verlangt, dass der bestaetigte
-- Zustand zur AKTUELL angeforderten command_id gehoert -- ein alter
-- Bestaetigungszustand (andere/keine command_id) zaehlt nicht mehr als
-- Beweis fuer ein neues Kommando.
function M:_check_valve_batch(pending)
  local waiting = false
  for key, entry in pairs(pending) do
    if entry.needs_ack then
      local still_pending = self._state.pending_valve_acks and self._state.pending_valve_acks[key]
      local confirmed = self._state.confirmed_valve_state and self._state.confirmed_valve_state[key]
      if still_pending then
        waiting = true
      elseif not (confirmed and confirmed.applied == true and confirmed.high == entry.high
          and entry.command_id ~= nil and confirmed.command_id == entry.command_id) then
        return "failed", key
      end
    elseif not entry.sync_ok then
      return "failed", key
    end
  end
  if waiting then return "waiting" end
  return "ok"
end

-- Fix (2026-07-14): CRITICAL. FUEL/REPROCESSOR-P0 (siehe docs/CODING_AI_
-- OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitt 8). route_and_act() war
-- eine synchrone Funktion mit ZWEI eingebetteten os.sleep()-Aufrufen
-- (Settle-Zeit vor dem Export, Offenhaltezeit danach) -- ueblicherweise
-- 2.05-2.4s blockierend PRO Lieferung, und die aufrufende Rolle (siehe
-- logistics_router.lua's Phase-2-Schleife) konnte das fuer MEHRERE
-- Ziel-Reaktoren nacheinander in einem einzigen Zyklus tun. Waehrend
-- dieser Zeit lief in FUEL/REPROCESSOR (kein parallel.waitForAny-Split
-- wie bei ENERGY/RT, nur eine einzige Coroutine) buchstaeblich GAR NICHTS
-- anderes -- Heartbeat, Commands, UI und das VALVE-Fail-Safe-Timing
-- waren fuer die gesamte Dauer eingefroren.
--
-- Jetzt: begin_transaction() startet eine asynchrone Zustandsmaschine, die
-- ausschliesslich ueber wiederholte tick(now_ms)-Aufrufe voranschreitet
-- (von der aufrufenden Rolle regelmaessig aus ihrem normalen Event-Loop-
-- Zyklus aufgerufen, siehe nodes/fuel/main.lua und nodes/reprocessor/
-- main.lua). Kein os.sleep() mehr im Routingpfad. Nur eine Transaktion
-- gleichzeitig -- ein zweiter begin_transaction()-Aufruf waehrend eine
-- laeuft wird mit "busy" abgelehnt, wodurch Lieferungen strukturell
-- serialisiert werden (der Aufrufer versucht es im naechsten Zyklus
-- erneut, statt mehrere Lieferungen zu ueberlappen).
--
-- Fix (2026-07-16): CRITICAL (ROUTER-P0, siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 8). Die alte Zustandsmaschine (IDLE
-- -> WAIT_SETTLE -> EXPORT -> HOLD_OPEN -> COMPLETE/ERROR, ueber open_
-- path_to() aufgebaut) hatte zwei bestaetigte Sicherheitsluecken:
-- (1) WAIT_SETTLE gate'te den Export ueber eine feste Settle-Zeit
--     (settle_until), NICHT ueber eine tatsaechliche Bestaetigung -- ein
--     noch "pending" ACK loeste KEINEN Fehler aus, der Export lief nach
--     Ablauf der Settle-Zeit trotzdem los, selbst wenn die Bestaetigung
--     fuer ein beobachtetes Ventil schlicht noch unterwegs war.
-- (2) watched_keys enthielt nur die Ziel-Pfad-Ventile (die geoeffnet
--     werden sollen) -- ein fehlgeschlagenes Blockieren eines NEBEN-
--     pfads (open_path_to()'s eigener Rueckgabewert wurde dafuer nicht
--     einmal ausgewertet) verhinderte den Export nicht.
-- Neue, zweiphasige Zustandsmaschine (siehe "Ziel-State-Machine" im
-- Audit-Dokument): Phase 1 (WAIT_BLOCK_ACKS) blockiert und bestaetigt
-- ALLE bekannten Ventile (nicht nur Nebenpfade) als deterministischen,
-- sicheren Ausgangszustand; erst wenn JEDES Ventil nachweislich blockiert
-- ist, oeffnet Phase 2 (WAIT_OPEN_ACKS) den Zielpfad und wartet ebenfalls
-- auf dessen vollstaendige Bestaetigung. WAIT_SETTLE ist danach nur noch
-- eine zusaetzliche physische Pufferzeit NACH bestaetigtem Zustand, kein
-- Ersatz mehr fuer die Bestaetigung selbst. Jeder Fehlschlag oder
-- Bestaetigungs-Timeout in beiden Phasen bricht sofort mit block_all() ab
-- (_fail_transaction()). Nach dem Export (HOLD_OPEN) wird ebenfalls
-- versucht, das finale Blockieren zu bestaetigen (WAIT_FINAL_ACKS), bevor
-- die Transaktion als abgeschlossen gilt.
function M:begin_transaction(target_id, action_fn, valve_open_ms, opts)
  if self._state.transaction then
    return false, "busy"
  end
  -- Fix (2026-07-13): CRITICAL (Sicherheitsregel, siehe docs/CODING_AI_
  -- OTHER_NODES_PERFORMANCE_2026-07-12.md). Vorher fiel JEDES "all_valves
  -- == 0" ungeschuetzt in den Direkt-Export-Pfad -- das betraf nicht nur
  -- den beabsichtigten Fall "kein Routing konfiguriert" (harmlos, wie ein
  -- Einzel-Setup ohne Ventile), sondern GENAUSO den Fall "Routing WAR
  -- konfiguriert, ist aber ungueltig/kaputt" (refresh() ruft in diesem
  -- Fall bereits block_all() auf, in der ausdruecklichen Absicht "kein
  -- Fuel-Transfer moeglich" -- diese Absicht wurde hier bisher durch den
  -- Direkt-Export-Fallback wieder aufgehoben). Jetzt: nur wenn der Baum
  -- GENUIN NIE konfiguriert war (tree_configured==false), gilt der
  -- unagierte Direkt-Export als sicher. War ein Baum konfiguriert, aber
  -- resultierte in 0 Ventilen (ungueltig oder anderweitig kaputt), wird
  -- die Aktion jetzt hart verweigert statt ungeschuetzt ausgefuehrt.
  if #self._state.all_valves == 0 then
    if not self._state.tree_configured then
      if action_fn then action_fn() end
      return true, "direct_export"
    end
    self.log("ERROR", "RedstoneRouter: begin_transaction() verweigert -- Routing war konfiguriert, aber 0 Ventile bekannt (ungueltiger/kaputter Baum). Kein ungeschuetzter Direkt-Export.")
    self:block_all()
    return false, "invalid_tree"
  end

  local path = find_path(self._state.routes, target_id)
  if not path then
    self.log("WARN", "RedstoneRouter: no path found for target: " .. tostring(target_id))
    self:block_all()
    self._state.active_target = nil
    self._state.active_path = nil
    return false, "no_path"
  end

  local block_entries = {}
  for _, v in ipairs(self._state.all_valves) do
    block_entries[#block_entries + 1] = { integrator = v.integrator, side = v.side, high = true }
  end

  local now_ms = os.epoch and os.epoch("utc") or 0
  self._state.transaction = {
    target_id = target_id,
    action_fn = action_fn,
    -- Fix (2026-07-16): CRITICAL (FUEL-P0, siehe docs/CODING_AI_OTHER_NODES_
    -- PERFORMANCE_2026-07-12.md Abschnitt 7). Bisher gab es KEINE
    -- Rueckmeldung an den Aufrufer, wenn eine Transaktion abbrach BEVOR sie
    -- jemals action_fn erreichte (z.B. Ventil-ACK-Fehlschlag oder Phasen-
    -- Timeout waehrend WAIT_BLOCK_ACKS/WAIT_OPEN_ACKS) -- ein vom Aufrufer
    -- gehaltener "laufende Lieferung"-Kontext (siehe logistics_router.lua's
    -- current_request) blieb dadurch fuer immer auf "aktiv" haengen, da nur
    -- action_fn ihn je aufraeumen konnte. opts.on_error(reason) wird von
    -- _fail_transaction() IMMER aufgerufen, wenn die Transaktion abbricht
    -- ohne dass action_fn je lief -- damit hat der Aufrufer garantiert
    -- genau einen von zwei Abschluss-Pfaden (action_fn ODER on_error).
    on_error = opts and opts.on_error or nil,
    valve_open_ms = tonumber(valve_open_ms) or 2000,
    state = "WAIT_BLOCK_ACKS",
    pending = self:_request_valve_batch(block_entries),
    path = path,
    phase_started_ms = now_ms,
    settle_until = nil,
    hold_until = nil,
    started_ts = now_ms,
  }
  return true, "started"
end

function M:_fail_transaction(reason)
  local tx = self._state.transaction
  self.log("ERROR", string.format(
    "RedstoneRouter: Transaktion zu %s abgebrochen (%s) -- blockiere sicherheitshalber alles",
    tostring(tx and tx.target_id), tostring(reason)))
  self:block_all()
  self._state.active_target = nil
  self._state.active_path = nil
  self._state.transaction = nil
  if tx and tx.on_error then
    local ok, err = pcall(tx.on_error, reason)
    if not ok then
      self.warn_once("tx_on_error_failed:" .. tostring(tx.target_id),
        "RedstoneRouter: on_error-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
    end
  end
end

-- Maximale Wartezeit auf eine Ventil-Bestaetigungs-Phase (Block oder
-- Open), bevor die Transaktion als fehlgeschlagen abgebrochen wird.
-- Deutlich groesser als das einzelne ACK-Timeout (VALVE_ACK_TIMEOUT_MS,
-- siehe check_pending_acks() weiter unten), da check_pending_acks() erst
-- nach VALVE_ACK_MAX_RETRIES aufgibt -- diese Phasen-Deadline ist nur ein
-- zusaetzliches Sicherheitsnetz, falls ein Ventil dauerhaft "pending"
-- haengen bleibt, ohne dass check_pending_acks() es je aufgibt.
local VALVE_PHASE_TIMEOUT_MS = 15000

-- Muss regelmaessig (z.B. alle 0.5s aus dem Haupt-Event-Loop der
-- aufrufenden Rolle) aufgerufen werden, unabhaengig davon ob gerade eine
-- neue Lieferung faellig ist -- treibt eine laufende Transaktion voran.
-- Kein Tick-Backlog: verpasste Deadlines werden nicht nachgeholt, nur
-- beim naechsten Aufruf als "faellig" erkannt (kein while-now>=due-Loop).
function M:tick(now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  local tx = self._state.transaction
  if not tx then return end

  if tx.state == "WAIT_BLOCK_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    if status == "failed" then
      self:_fail_transaction("block_ack_failed:" .. tostring(failed_key))
      return
    end
    if status == "waiting" then
      if now_ms - tx.phase_started_ms >= VALVE_PHASE_TIMEOUT_MS then
        self:_fail_transaction("block_ack_timeout")
      end
      return
    end
    -- Alle bekannten Ventile nachweislich blockiert -- jetzt den Zielpfad
    -- oeffnen (Phase 2).
    local uses_network = false
    local open_entries = {}
    for _, v in ipairs(tx.path) do
      open_entries[#open_entries + 1] = { integrator = v.integrator, side = v.side, high = false }
      local w = v.integrator and self._state.integrators[v.integrator]
      if w and w.network then uses_network = true end
    end
    tx.pending = self:_request_valve_batch(open_entries)
    tx.uses_network = uses_network
    tx.state = "WAIT_OPEN_ACKS"
    tx.phase_started_ms = now_ms
    return
  end

  if tx.state == "WAIT_OPEN_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    if status == "failed" then
      self:_fail_transaction("open_ack_failed:" .. tostring(failed_key))
      return
    end
    if status == "waiting" then
      if now_ms - tx.phase_started_ms >= VALVE_PHASE_TIMEOUT_MS then
        self:_fail_transaction("open_ack_timeout")
      end
      return
    end
    -- Zielpfad bestaetigt offen UND alle Nebenpfade bestaetigt blockiert
    -- (Phase 1 lief bereits durch) -- ab hier ist die Sicherheitsregel
    -- erfuellt. WAIT_SETTLE ist nur noch eine zusaetzliche physische
    -- Pufferzeit (Mekanism-Rohrnetz-Ausgleich), kein Bestaetigungs-Ersatz.
    local sides = {}
    for _, v in ipairs(tx.path) do sides[#sides + 1] = v.side end
    self._state.active_target = tx.target_id
    self._state.active_path = sides
    self._state.last_target = tx.target_id
    self._state.last_path = sides
    self._state.last_active_ts = now_ms
    local settle_s = tx.uses_network and 0.4 or 0.05
    tx.settle_until = now_ms + math.floor(settle_s * 1000)
    tx.state = "WAIT_SETTLE"
    return
  end

  if tx.state == "WAIT_SETTLE" then
    if now_ms >= tx.settle_until then
      if tx.action_fn then
        local ok, err = pcall(tx.action_fn)
        if not ok then
          self.warn_once("transaction_action_error:" .. tostring(tx.target_id),
            "RedstoneRouter: Aktions-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
        end
      end
      tx.state = "HOLD_OPEN"
      tx.hold_until = now_ms + tx.valve_open_ms
    end
    return
  end

  if tx.state == "HOLD_OPEN" then
    if now_ms >= tx.hold_until then
      local final_entries = {}
      for _, v in ipairs(self._state.all_valves) do
        final_entries[#final_entries + 1] = { integrator = v.integrator, side = v.side, high = true }
      end
      tx.pending = self:_request_valve_batch(final_entries)
      tx.state = "WAIT_FINAL_ACKS"
      tx.phase_started_ms = now_ms
    end
    return
  end

  if tx.state == "WAIT_FINAL_ACKS" then
    -- Export ist bereits gelaufen (EXPORT-Phase oben) -- ein nicht
    -- bestaetigtes finales Blockieren macht die bereits erfolgte
    -- Lieferung nicht rueckgaengig, erzwingt aber trotzdem block_all()
    -- als Fail-Safe statt die Transaktion endlos in WAIT_FINAL_ACKS zu
    -- belassen.
    local status = self:_check_valve_batch(tx.pending)
    local timed_out = (now_ms - tx.phase_started_ms) >= VALVE_PHASE_TIMEOUT_MS
    if status == "failed" then
      self.log("ERROR", "RedstoneRouter: finale Ventil-Blockierung nach Export fehlgeschlagen -- erzwinge block_all()")
    elseif status == "waiting" and not timed_out then
      return
    elseif status == "waiting" then
      self.log("WARN", "RedstoneRouter: finale Ventil-Blockierung nach Export nicht rechtzeitig bestaetigt -- erzwinge block_all()")
    end
    self:block_all()
    self._state.active_target = nil
    self._state.active_path = nil
    self._state.transaction = nil
    return
  end
end

-- Sofortiger Shutdown-Pfad: blockiert augenblicklich alle Ventile und
-- verwirft eine laufende Transaktion, unabhaengig von deren Zustand.
--
-- Fix (2026-07-16): CRITICAL (REPROCESSOR-P0, siehe docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md Abschnitt 11). War bisher toter Code
-- (nirgends aufgerufen) und rief keinerlei Abschluss-Callback auf -- eine
-- per shutdown_now() verworfene Transaktion war fuer den Aufrufer
-- (logistics_router.lua/feed_router.lua) unsichtbar: weder action_fn noch
-- ein Fehlerpfad liefen je, current_request/last_error blieben auf dem
-- letzten Stand haengen statt sichtbar "abgebrochen" zu werden. Ruft jetzt
-- (wie _fail_transaction()) tx.on_error(reason) auf, falls eine
-- Transaktion aktiv war -- nutzt denselben Abschluss-Mechanismus wie beim
-- FUEL-P0-Fix, kein zweiter Signalweg noetig.
function M:shutdown_now(reason)
  local tx = self._state.transaction
  self._state.transaction = nil
  self:block_all()
  self._state.active_target = nil
  self._state.active_path = nil
  if tx then
    self.log("WARN", string.format(
      "RedstoneRouter: Transaktion zu %s durch shutdown_now() abgebrochen (%s)",
      tostring(tx.target_id), tostring(reason or "shutdown")))
    if tx.on_error then
      local ok, err = pcall(tx.on_error, reason or "shutdown")
      if not ok then
        self.warn_once("tx_on_error_failed:" .. tostring(tx.target_id),
          "RedstoneRouter: on_error-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
      end
    end
  end
end

-- Sichtbarkeit fuer UI/Diagnose: aktive Transaktion und ihr Zustand.
function M:get_active_transaction()
  local tx = self._state.transaction
  if not tx then return nil end
  return { target_id = tx.target_id, state = tx.state, started_ts = tx.started_ts }
end

function M:valve_count()
  return #self._state.all_valves
end

-- Feature (2026-07-12): REST-P0.3 (siehe docs/CODING_AI_FUEL_UI_
-- PRIORITY_FIX_2026-07-12.md). Fuehrt fuer jeden konfigurierten
-- Netzwerk-Integrator (VALVE-Node) zusammen: Live-Peer-Status (online/
-- stale/Alter, aus core/comms.lua's ohnehin schon vorhandener Peer-
-- Verfolgung), den zuletzt angeforderten Zustand (siehe _set_valve()),
-- und welche Reaktoren ueber diesen Integrator beliefert werden.
--
-- WICHTIG, ehrlich benannt: "confirmed_state"/"state_matches" sind
-- bewusst NICHT vorhanden -- das Funkprotokoll ist weiterhin fire-and-
-- forget ohne ACK (siehe Dokument), ein erfolgreich gesendetes Kommando
-- bestaetigt nicht, dass Redstone tatsaechlich geschaltet wurde. Diese
-- Funktion behauptet daher nur "requested_state" (was WIR zuletzt
-- angefordert haben), niemals einen bestaetigten Ist-Zustand, den es
-- technisch noch gar nicht geben kann.
-- Feature (2026-07-13): VALVE-P1. Verarbeitet eine eingehende VALVE_ACK-
-- Nachricht -- muss von der aufrufenden Rolle (FUEL/REPROCESSOR) aus
-- ihrem comms-Message-Handler heraus aufgerufen werden, wenn eine
-- Nachricht vom Typ "VALVE_ACK" ankommt. Loescht das zugehoerige pending-
-- Kommando (kein weiterer Retry noetig) und traegt den TATSAECHLICH
-- bestaetigten Zustand ein -- erst ab hier ist "confirmed_state" (im
-- Gegensatz zu "requested_state") ehrlich moeglich.
function M:handle_valve_ack(message)
  if type(message) ~= "table" or message.type ~= "VALVE_ACK" or not message.command_id then return end
  local pending = self._state.pending_valve_acks
  if not pending then return end
  for key, entry in pairs(pending) do
    if entry.command_id == message.command_id then
      pending[key] = nil
      self._state.confirmed_valve_state = self._state.confirmed_valve_state or {}
      self._state.confirmed_valve_state[key] = {
        command_id = message.command_id,
        applied = message.applied == true,
        high = message.high,
        error = message.error,
        confirmed_ts = os.epoch and os.epoch("utc") or 0,
      }
      return
    end
  end
end

-- Feature (2026-07-13): VALVE-P1. Von der aufrufenden Rolle periodisch
-- (z.B. einmal pro Sekunde aus dem Haupt-Event-Loop) aufzurufen -- prueft
-- alle noch unbestaetigten Kommandos gegen ein Timeout und sendet sie
-- erneut (begrenzte Anzahl Versuche, danach wird aufgegeben und auf das
-- bestehende 20s-Fail-Safe der VALVE-Node vertraut).
local VALVE_ACK_TIMEOUT_MS = 3000
local VALVE_ACK_MAX_RETRIES = 3
function M:check_pending_acks()
  if not self.valve_modem or not self._state.pending_valve_acks then return end
  local now = os.epoch and os.epoch("utc") or 0
  for key, entry in pairs(self._state.pending_valve_acks) do
    if (now - (entry.sent_ts or 0)) >= VALVE_ACK_TIMEOUT_MS then
      if entry.retries >= VALVE_ACK_MAX_RETRIES then
        self.warn_once("valve_ack_timeout:" .. key,
          "RedstoneRouter: SET_VALVE an " .. tostring(entry.dst) .. " (" .. key .. ") nach " .. VALVE_ACK_MAX_RETRIES .. " Versuchen unbestaetigt -- verlasse mich auf VALVE-Fail-Safe")
        self._state.pending_valve_acks[key] = nil
      else
        entry.retries = entry.retries + 1
        entry.sent_ts = now
        pcall(self.valve_modem.transmit, constants.channels.VALVE, constants.channels.VALVE, {
          type = "SET_VALVE", src = self.config.node_id, dst = entry.dst,
          command_id = entry.command_id, side = entry.side, high = entry.high, ts = now,
        })
      end
    end
  end
end

function M:get_valve_status()
  local requested = self._state.valve_requested or {}
  local peers = self.comms and self.comms:get_peers() or {}

  -- Reaktor-Zuordnung: jedes Ventil auf dem Pfad einer Route bekommt deren
  -- Reaktor-Label zugeordnet -- ein Ventil, das in MEHREREN Routen
  -- vorkommt (gemeinsames Trunk-Ventil), sammelt entsprechend mehrere
  -- Labels.
  local affected = {}
  for _, route in ipairs(self._state.routes or {}) do
    local label = route.label or route.reactor
    for _, v in ipairs(route.path or {}) do
      if v.integrator then
        affected[v.integrator] = affected[v.integrator] or {}
        local list = affected[v.integrator]
        local already = false
        for _, existing in ipairs(list) do if existing == label then already = true end end
        if not already then list[#list + 1] = label end
      end
    end
  end

  local seen_names, out = {}, {}
  for _, v in ipairs(self._state.all_valves) do
    if v.integrator and not seen_names[v.integrator] then
      seen_names[v.integrator] = true
      local w = self._state.integrators[v.integrator]
      local peer = w and w.network and peers[v.integrator] or nil
      local online, stale, age_s
      if w and w.network then
        online = peer ~= nil and peer.down ~= true
        stale = peer ~= nil and peer.stale == true
        age_s = peer and peer.age or nil
      elseif w and w.wrapped then
        -- lokales Peripheral statt Netzwerk-VALVE -- "online" heisst hier
        -- schlicht "gerade als Peripheral erreichbar".
        online = true
        stale = false
        age_s = 0
      else
        online = false
        stale = false
        age_s = nil
      end
      out[#out + 1] = {
        id = v.integrator,
        configured = true,
        online = online,
        stale = stale,
        age_s = age_s,
        requested_state = requested[v.integrator .. "|" .. tostring(v.side)] or "UNKNOWN",
        affected_routes = affected[v.integrator] or {},
      }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function M:route_count()
  return #self:get_routing_table()
end

-- Fix (2026-07-16): CRITICAL (ROUTER-P0.9, siehe docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md Abschnitt 9). Einzige Autoritaet fuer
-- die Frage "soll FUEL/REPROCESSOR ueberhaupt ungeroutet direkt
-- exportieren, oder muss geroutet (oder hart blockiert) werden?" --
-- ersetzt den vorherigen strukturellen route_count()>0-Check (siehe
-- refresh()-Kommentar oben), der bei einem KONFIGURIERTEN aber kaputten
-- Baum faelschlich 0 zurueckgeben und damit den ungeschuetzten Direkt-
-- Export-Pfad ausloesen konnte. Basiert ausschliesslich auf dem in
-- refresh() ermittelten Validierungszustand (tree_configured/tree_valid/
-- all_valves), nicht auf einem erneuten rohen Baum-Walk.
--   ROUTING_NOT_CONFIGURED    -- kein redstone_tree in der Config: Direkt-
--                                export ist ausdruecklich sicher.
--   ROUTING_INVALID           -- redstone_tree konfiguriert, aber
--                                strukturell ungueltig (validate_tree()).
--   ROUTING_REQUIRED_BUT_EMPTY -- redstone_tree konfiguriert und
--                                strukturell gueltig, aber ohne ein
--                                einziges tatsaechliches Ventil (side) --
--                                Routing ist offensichtlich beabsichtigt,
--                                kann aber nichts absichern.
--   ROUTING_VALID             -- redstone_tree konfiguriert, gueltig, und
--                                enthaelt mindestens ein Ventil.
-- Fuer beide INVALID/EMPTY-Faelle gilt: hart blockieren, NIEMALS
-- ungeschuetzter Direkt-Export.
function M:get_routing_state()
  if not self._state.tree_configured then
    return "ROUTING_NOT_CONFIGURED"
  end
  if not self._state.tree_valid then
    return "ROUTING_INVALID"
  end
  if #self._state.all_valves == 0 then
    return "ROUTING_REQUIRED_BUT_EMPTY"
  end
  return "ROUTING_VALID"
end

-- Liefert die normalisierten Routen (siehe self._state.routes, von
-- M:refresh() gecacht) -- router_ui.lua's TREE-Ansicht und der Pfad-Editor
-- bauen direkt darauf auf, garantiert identisch zu dem, was der Router
-- selbst fuer begin_transaction()/collect_all_valves() verwendet.
function M:get_tree()
  return self._state.routes or {}
end

function M:get_path_to(target_id)
  local path = find_path(self._state.routes, target_id) or {}
  local sides = {}
  for _, v in ipairs(path) do sides[#sides + 1] = v.side end
  return sides
end

function M:get_active_route()
  return {
    target = self._state.active_target,
    path = self._state.active_path,
    last_target = self._state.last_target,
    last_path = self._state.last_path,
    last_active_ts = self._state.last_active_ts,
  }
end

-- Feature (2026-07-08): Validierungsstatus fuer UI/Alerts (siehe
-- validate_tree() / M:refresh() oben).
function M:get_validation()
  return { ok = self._state.tree_valid, errors = self._state.tree_errors or {} }
end

function M:get_routing_table()
  local result = {}
  for _, route in ipairs(self._state.routes or {}) do
    local sides = {}
    for _, v in ipairs(route.path or {}) do sides[#sides + 1] = v.side end
    result[#result + 1] = { reactor = route.reactor, label = route.label or route.reactor, path = sides }
  end
  return result
end

return M
