-- nodes/fuel/redstone_router.lua
-- Per-reactor valve-path routing for Mekanism pipe networks.
--
-- config.logistics.redstone_tree ist eine FLACHE Liste von Routen, eine pro
-- Reaktor, mit einer geordneten Ventilliste ("path") direkt am Reaktor:
--   { reactor = "<id>", label = "<Anzeigename>",
--     path = { { side = "back" }, { side = "left", integrator = "VALVE-1" } } }
-- Ein gemeinsames Ventil auf dem Weg zu mehreren Reaktoren wird als dieselbe
-- {side=,integrator=}-Kombination in mehreren Routen-Pfaden wiederholt.
--
-- normalize_tree() akzeptiert gemischt alle drei historischen Formen ohne
-- manuelle Migration: 1. neues Format (path=..., siehe oben). 2. alte
-- FLACHE Form { side=, integrator=, reactor=, label= } (genau ein Ventil
-- pro Reaktor). 3. alte VERSCHACHTELTE Baum-Form (children=...), rekursiv
-- zu path=<Ast von der Wurzel bis zum Reaktor-Blatt> aufgeloest.

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

local function resolve_source_node_id(opts, config)
  local explicit = opts and opts.node_id
  if type(explicit) == "string" and explicit ~= "" then return explicit end
  local configured = config and config.node_id
  if type(configured) == "string" and configured ~= "" then return configured end
  -- Backward-compatible fallback for direct library users/tests.
  -- Production FUEL/REPROCESSOR inject their resolved runtime node_id.
  return "FUEL"
end

local function find_wireless_modem(config)
  local configured = config and type(config.wireless_modem) == "string" and config.wireless_modem or nil
  if configured and configured ~= "" then
    local present_ok, present = pcall(peripheral.isPresent, configured)
    if not present_ok or not present then return nil end
    local wrap_ok, modem = pcall(peripheral.wrap, configured)
    if not wrap_ok or not modem or type(modem.isWireless) ~= "function" then return nil end
    local wireless_ok, wireless = pcall(modem.isWireless)
    if wireless_ok and wireless == true then return modem end
    return nil
  end
  local ok_find, modem = pcall(peripheral.find, "modem", function(_, mm)
    if not mm or type(mm.isWireless) ~= "function" then return false end
    local wireless_ok, wireless = pcall(mm.isWireless)
    return wireless_ok and wireless == true
  end)
  if ok_find then return modem end
  return nil
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

-- Rein statische Validierung (keine Peripherie-Pruefung -- das bleibt
-- Aufgabe von M:refresh()'s Laufzeit-Warnungen).
-- Rueckgabe: { ok=bool, errors={ {code=..., message=...}, ... } }
function M.validate_tree(raw)
  local _, errors = normalize_with_errors(raw)
  return { ok = #errors == 0, errors = errors }
end

function M.new(opts)
  opts = opts or {}
  -- Eigener Funkkanal fuer SET_VALVE (constants.channels.VALVE), getrennt
  -- von comms_service -- roh per modem.transmit, kein Ack/Retry-Overhead.
  local router_config = opts.config or {}
  local valve_modem = find_wireless_modem(router_config)
  if valve_modem then pcall(valve_modem.open, constants.channels.VALVE) end
  local self = {
    config = router_config,
    source_node_id = resolve_source_node_id(opts, router_config),
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
      refresh_deferred = false,
      transaction_seq = 0,
      last_transaction = nil,
      safety_latch = nil,
      quiesce = nil,
    },
  }
  return setmetatable(self, { __index = M })
end

function M:refresh()
  -- Discovery may fire while a valve transaction is between confirmed OPEN
  -- and the export callback. Rebuilding integrator wrappers or block_all() in
  -- that window races the transaction state machine. Defer the refresh until
  -- the transaction has reached a terminal state instead.
  if self._state.transaction or self._state.quiesce then
    self._state.refresh_deferred = true
    self.log("DEBUG", "RedstoneRouter: refresh deferred while transaction/quiesce is active")
    return false, "busy"
  end
  self._state.refresh_deferred = false

  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}
  -- tree_configured haelt fest, ob ueberhaupt ein Baum in der Config STAND
  -- (unabhaengig davon, ob er gueltig war) -- Grundlage fuer die Unterscheidung
  -- zwischen "Routing war nie gewollt" (sicher, Direkt-Export ok) und
  -- "Routing war konfiguriert, aber kaputt/leer geworden" (GEFAEHRLICH, muss
  -- blockieren, siehe begin_transaction()).
  self._state.tree_configured = #tree > 0

  -- Strukturelle Validierung VOR jeder Aktivierung. Bei einem ungueltigen
  -- Baum: alle Ventile blockieren (Fail-Safe-Grundzustand), all_valves/
  -- integrators NICHT aus dem fehlerhaften Baum laden, Fehler geloggt und
  -- ueber get_validation() fuer UI/Alerts bereitgestellt.
  --
  -- get_routing_state() ist die einzige Autoritaet fuer "war konfiguriert"
  -- vs. "nie konfiguriert" -- basiert auf tree_configured/tree_valid/
  -- all_valves, NICHT auf route_count()/einem strukturellen Baum-Walk (ein
  -- kaputter Baum kann strukturell 0 Ventile ergeben, obwohl er konfiguriert
  -- war -- das darf nicht mit "nie konfiguriert" verwechselt werden).
  --
  -- normalize_with_errors() laeuft hier nur EINMAL pro Zyklus; self._state.
  -- routes ist ab hier die alleinige, gecachte Grundlage fuer begin_
  -- transaction()/get_tree()/get_path_to()/get_routing_table()/get_valve_
  -- status(), bis zum naechsten refresh().
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
      -- Auto-Discovery: der Integrator meldet sich per HELLO/Heartbeat wie
      -- jeder andere Node. "name" ist die node_id des VALVE-Node.
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
  -- Angeforderten Zustand PRO (integrator, side) festhalten (nicht nur
  -- integrator -- sonst ueberschreiben mehrere Seiten am selben Integrator
  -- sich gegenseitig). Ehrlich "requested" benannt, NICHT "confirmed": das
  -- Funkprotokoll bleibt fire-and-forget, ein erfolgreicher modem.transmit()
  -- bestaetigt nicht, dass Redstone tatsaechlich geschaltet wurde.
  if valve.integrator then
    self._state.valve_requested = self._state.valve_requested or {}
    self._state.valve_requested[valve.integrator .. "|" .. tostring(side)] = high and "BLOCKED" or "OPEN"
  end
  if valve.integrator then
    local w = self._state.integrators[valve.integrator]
    if w and w.network then
      -- Jedes Kommando bekommt eine eindeutige command_id, wird als "pending"
      -- verfolgt (siehe check_pending_acks(), periodisch von der aufrufenden
      -- Rolle aufgerufen) und bei fehlender Bestaetigung erneut gesendet
      -- (begrenzte Versuche). handle_valve_ack() traegt den tatsaechlich
      -- bestaetigten Zustand ein. Fail-Safe (VALVE faellt nach 20s ohne
      -- Kommando in BLOCKED) bleibt die letzte Verteidigungslinie.
      if not self.valve_modem then
        self.warn_once("no_valve_modem", "RedstoneRouter: kein Wireless Modem fuer den Ventil-Kanal gefunden")
        return false
      end
      local source_node_id = self.source_node_id
      if type(source_node_id) ~= "string" or source_node_id == "" then
        self.warn_once("missing_valve_source_id", "RedstoneRouter: keine gueltige Runtime-Node-ID fuer SET_VALVE; Netzwerkschaltung verweigert")
        return false
      end
      self._state.command_seq = (self._state.command_seq or 0) + 1
      local command_id = source_node_id .. "-" .. tostring(os.epoch and os.epoch("utc") or 0) .. "-" .. tostring(self._state.command_seq)
      local key = valve.integrator .. "|" .. tostring(side)
      local message = {
        type = "SET_VALVE", src = source_node_id, dst = w.node_id,
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
        command_id = command_id, src = source_node_id, dst = w.node_id, side = side, high = high,
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
    -- Integrator offline/nicht gewrapped: explizite Warnung statt stillem
    -- Nichtstun -- ein nicht schaltbares Ventil ist sicherheitsrelevant.
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
-- confirmed_valve_state[key] wird NIE geloescht und ueberlebt beliebig viele
-- Transaktionen fuer denselben Schluessel -- deshalb wird zusaetzlich
-- verlangt, dass der bestaetigte Zustand zur AKTUELL angeforderten
-- command_id gehoert. Sonst koennte ein alter Bestaetigungszustand als
-- (falscher) Beweis fuer ein neues, tatsaechlich nie bestaetigtes Kommando
-- durchgehen.
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

-- begin_transaction() ist eine asynchrone Zustandsmaschine, die ausschliesslich
-- ueber wiederholte tick(now_ms)-Aufrufe voranschreitet (kein os.sleep() im
-- Routingpfad -- FUEL/REPROCESSOR laufen in nur einer Coroutine, ein
-- blockierender sleep wuerde Heartbeat/Commands/UI/Fail-Safe-Timing komplett
-- einfrieren). Nur eine Transaktion gleichzeitig; ein zweiter begin_
-- transaction()-Aufruf waehrend eine laeuft wird mit "busy" abgelehnt.
--
-- Zweiphasige Zustandsmaschine: Phase 1 (WAIT_BLOCK_ACKS) blockiert und
-- bestaetigt ALLE bekannten Ventile (nicht nur Nebenpfade) als deterministischen
-- Ausgangszustand; erst wenn jedes Ventil nachweislich blockiert ist, oeffnet
-- Phase 2 (WAIT_OPEN_ACKS) den Zielpfad und wartet ebenfalls auf vollstaendige
-- Bestaetigung. WAIT_SETTLE ist danach nur noch eine physische Pufferzeit NACH
-- bestaetigtem Zustand, kein Ersatz fuer die Bestaetigung selbst. Jeder
-- Fehlschlag/Timeout in beiden Phasen bricht sofort mit block_all() ab
-- (_fail_transaction()). Nach dem Export (HOLD_OPEN) wird das finale
-- Blockieren ebenfalls bestaetigt (WAIT_FINAL_ACKS), bevor die Transaktion
-- als abgeschlossen gilt.
local SAFETY_CONFIRM_TIMEOUT_MS = 15000
local SAFETY_RETRY_MS = 1000

local function phase_for_state(state)
  local map = {
    WAIT_BLOCK_ACKS = "BLOCKING",
    WAIT_OPEN_ACKS = "OPENING",
    WAIT_SETTLE = "SETTLING",
    HOLD_OPEN = "HOLDING",
    WAIT_FINAL_ACKS = "FINAL_BLOCK",
  }
  return map[state] or state
end

function M:_next_transaction_id(target_id)
  self._state.transaction_seq = (self._state.transaction_seq or 0) + 1
  local now = os.epoch and os.epoch("utc") or 0
  return table.concat({ tostring(self.source_node_id or "ROUTER"), tostring(now),
    tostring(self._state.transaction_seq), tostring(target_id or "?") }, ":")
end

function M:_all_block_entries()
  local entries = {}
  for _, v in ipairs(self._state.all_valves or {}) do
    entries[#entries + 1] = { integrator = v.integrator, side = v.side, high = true }
  end
  return entries
end

function M:_record_terminal(tx, state_name, reason, notify_complete)
  if not tx then return end
  local now = os.epoch and os.epoch("utc") or 0
  local info = {
    id = tx.id,
    transaction_id = tx.id,
    target_id = tx.target_id,
    state = state_name,
    phase = state_name,
    reason = reason,
    started_ts = tx.started_ts,
    finished_ts = now,
  }
  self._state.last_transaction = info
  if notify_complete and tx.on_complete then
    local ok, err = pcall(tx.on_complete, info)
    if not ok then
      self.warn_once("tx_on_complete_failed:" .. tostring(tx.target_id),
        "RedstoneRouter: on_complete-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
    end
  end
end

function M:_start_final_block(tx, now_ms)
  tx.pending = self:_request_valve_batch(self:_all_block_entries())
  tx.state = "WAIT_FINAL_ACKS"
  tx.phase = "FINAL_BLOCK"
  tx.phase_started_ms = now_ms
end

function M:_set_safety_latch(tx, reason, now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  local latch = {
    state = "FINAL_BLOCK_UNCONFIRMED",
    transaction_id = tx and tx.id or nil,
    target_id = tx and tx.target_id or nil,
    reason = reason,
    since = now_ms,
    phase_started_ms = now_ms,
    attempts = 1,
  }
  if #self._state.all_valves > 0 then
    latch.pending = self:_request_valve_batch(self:_all_block_entries())
  end
  self._state.safety_latch = latch
  self.log("ERROR", "RedstoneRouter: Safety-Latch gesetzt -- neue Lieferungen gesperrt bis BLOCKED erneut bestaetigt ist (" .. tostring(reason) .. ")")
end

function M:_tick_safety_latch(now_ms)
  local latch = self._state.safety_latch
  if not latch then return true end
  if #self._state.all_valves == 0 then return false end
  if not latch.pending then
    latch.pending = self:_request_valve_batch(self:_all_block_entries())
    latch.phase_started_ms = now_ms
    latch.attempts = (latch.attempts or 0) + 1
    return false
  end
  local status = self:_check_valve_batch(latch.pending)
  if status == "ok" then
    self.log("INFO", "RedstoneRouter: Safety-Latch aufgehoben -- alle Ventile erneut BLOCKED bestaetigt")
    self._state.safety_latch = nil
    return true
  end
  if status == "waiting" and now_ms - (latch.phase_started_ms or now_ms) < SAFETY_CONFIRM_TIMEOUT_MS then
    return false
  end
  if now_ms - (latch.phase_started_ms or 0) >= SAFETY_RETRY_MS then
    latch.pending = self:_request_valve_batch(self:_all_block_entries())
    latch.phase_started_ms = now_ms
    latch.attempts = (latch.attempts or 0) + 1
  end
  return false
end

function M:get_safety_latch()
  local latch = self._state.safety_latch
  if not latch then return nil end
  return {
    state = latch.state, transaction_id = latch.transaction_id, target_id = latch.target_id,
    reason = latch.reason, since = latch.since, attempts = latch.attempts,
  }
end

function M:get_last_transaction()
  return self._state.last_transaction
end

-- Update-Quiesce has a stricter contract than shutdown_now(): runtime may only
-- stop after every currently known wireless/local valve is confirmed BLOCKED.
function M:begin_quiesce(reason)
  if self._state.quiesce then return self._state.quiesce.state == "CONFIRMED" end
  if self._state.transaction then
    self:shutdown_now(reason or "UPDATE_QUIESCE", { skip_latch = true })
  end
  local q = {
    reason = reason or "UPDATE_QUIESCE", state = "BLOCKING",
    started_ts = os.epoch and os.epoch("utc") or 0,
    phase_started_ms = os.epoch and os.epoch("utc") or 0,
    attempts = 1,
  }
  self._state.quiesce = q
  if not self._state.tree_configured then
    q.state = "CONFIRMED"
    return true
  end
  if #self._state.all_valves == 0 then
    q.state = "UNCONFIRMED_NO_VALVES"
    self.log("ERROR", "RedstoneRouter: Quiesce kann Routing-Sicherheit nicht bestaetigen -- Baum konfiguriert, aber keine Ventile bekannt")
    return false
  end
  q.pending = self:_request_valve_batch(self:_all_block_entries())
  return false
end

function M:poll_quiesce(now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  if not self._state.quiesce then
    local ready = self:begin_quiesce("UPDATE_QUIESCE")
    if ready then return true end
  end
  local q = self._state.quiesce
  if q.state == "CONFIRMED" then return true end
  if #self._state.all_valves == 0 then return false end
  if not q.pending then
    q.pending = self:_request_valve_batch(self:_all_block_entries())
    q.phase_started_ms = now_ms
    q.attempts = (q.attempts or 0) + 1
    return false
  end
  local status = self:_check_valve_batch(q.pending)
  if status == "ok" then
    q.state = "CONFIRMED"
    self._state.safety_latch = nil
    self.log("INFO", "RedstoneRouter: Update-Quiesce bestaetigt -- alle Ventile BLOCKED")
    return true
  end
  if status == "waiting" and now_ms - (q.phase_started_ms or now_ms) < SAFETY_CONFIRM_TIMEOUT_MS then
    return false
  end
  q.pending = self:_request_valve_batch(self:_all_block_entries())
  q.phase_started_ms = now_ms
  q.attempts = (q.attempts or 0) + 1
  self.log("WARN", "RedstoneRouter: Quiesce-BLOCKED noch nicht bestaetigt -- sichere Anforderung wird erneut gesendet")
  return false
end

function M:begin_transaction(target_id, action_fn, valve_open_ms, opts)
  opts = opts or {}
  if self._state.quiesce then return false, "quiescing" end
  if self._state.safety_latch then return false, "safety_latched" end
  if self._state.transaction then return false, "busy" end

  local tx_id = opts.transaction_id or self:_next_transaction_id(target_id)
  local now_ms = os.epoch and os.epoch("utc") or 0
  if #self._state.all_valves == 0 then
    if not self._state.tree_configured then
      local pseudo = { id = tx_id, target_id = target_id, started_ts = now_ms, on_complete = opts.on_complete }
      local ok, result, detail = true, nil, nil
      if action_fn then ok, result, detail = pcall(action_fn) end
      if not ok or result == false then
        local reason = not ok and tostring(result) or tostring(detail or "action returned false")
        self:_record_terminal(pseudo, "EXPORT_FAILED", reason, true)
        return false, "action_failed", tx_id
      end
      self:_record_terminal(pseudo, "COMPLETE_SAFE", nil, true)
      return true, "direct_export", tx_id
    end
    self.log("ERROR", "RedstoneRouter: begin_transaction() verweigert -- Routing war konfiguriert, aber 0 Ventile bekannt. Kein ungeschuetzter Direkt-Export.")
    self:block_all()
    return false, "invalid_tree", tx_id
  end

  local path = find_path(self._state.routes, target_id)
  if not path then
    self.log("WARN", "RedstoneRouter: no path found for target: " .. tostring(target_id))
    self:block_all()
    self._state.active_target = nil
    self._state.active_path = nil
    return false, "no_path", tx_id
  end

  self._state.transaction = {
    id = tx_id,
    target_id = target_id,
    action_fn = action_fn,
    on_error = opts.on_error,
    on_complete = opts.on_complete,
    valve_open_ms = tonumber(valve_open_ms) or 2000,
    state = "WAIT_BLOCK_ACKS",
    phase = "BLOCKING",
    pending = self:_request_valve_batch(self:_all_block_entries()),
    path = path,
    phase_started_ms = now_ms,
    settle_until = nil,
    hold_until = nil,
    started_ts = now_ms,
  }
  return true, "started", tx_id
end

function M:_fail_transaction(reason)
  local tx = self._state.transaction
  self.log("ERROR", string.format(
    "RedstoneRouter: Transaktion %s zu %s abgebrochen (%s) -- sichere BLOCKED-Bestaetigung wird gelatcht",
    tostring(tx and tx.id), tostring(tx and tx.target_id), tostring(reason)))
  self._state.active_target = nil
  self._state.active_path = nil
  self._state.transaction = nil
  if tx then
    self:_record_terminal(tx, "CANCELLED", reason, false)
    if #self._state.all_valves > 0 then self:_set_safety_latch(tx, "cancelled:" .. tostring(reason)) else self:block_all() end
  else
    self:block_all()
  end
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
function M:_path_runtime_ready(path)
  local peers = self.comms and self.comms:get_peers() or {}
  for _, valve in ipairs(path or {}) do
    if valve.integrator then
      local binding = self._state.integrators[valve.integrator]
      if not binding then
        return false, "integrator_missing:" .. tostring(valve.integrator)
      end
      if binding.network then
        local peer = peers[valve.integrator]
        if not peer then
          return false, "peer_missing:" .. tostring(valve.integrator)
        end
        if peer.down == true or peer.stale == true then
          return false, "peer_stale:" .. tostring(valve.integrator)
        end
      else
        if not peripheral or type(peripheral.isPresent) ~= "function"
            or not peripheral.isPresent(valve.integrator) then
          return false, "peripheral_missing:" .. tostring(valve.integrator)
        end
      end
    end
  end
  return true
end

local VALVE_PHASE_TIMEOUT_MS = 15000

-- Muss regelmaessig (z.B. alle 0.5s aus dem Haupt-Event-Loop der
-- aufrufenden Rolle) aufgerufen werden, unabhaengig davon ob gerade eine
-- neue Lieferung faellig ist -- treibt eine laufende Transaktion voran.
-- Kein Tick-Backlog: verpasste Deadlines werden nicht nachgeholt, nur
-- beim naechsten Aufruf als "faellig" erkannt (kein while-now>=due-Loop).
function M:tick(now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  local tx = self._state.transaction
  if not tx then
    if self._state.safety_latch then self:_tick_safety_latch(now_ms) end
    if self._state.refresh_deferred and not self._state.quiesce and not self._state.safety_latch then
      self._state.refresh_deferred = false
      self:refresh()
    end
    return
  end

  if tx.state == "WAIT_BLOCK_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    if status == "failed" then self:_fail_transaction("block_ack_failed:" .. tostring(failed_key)); return end
    if status == "waiting" then
      if now_ms - tx.phase_started_ms >= VALVE_PHASE_TIMEOUT_MS then self:_fail_transaction("block_ack_timeout") end
      return
    end
    local uses_network, open_entries = false, {}
    for _, v in ipairs(tx.path) do
      open_entries[#open_entries + 1] = { integrator = v.integrator, side = v.side, high = false }
      local w = v.integrator and self._state.integrators[v.integrator]
      if w and w.network then uses_network = true end
    end
    tx.pending = self:_request_valve_batch(open_entries)
    tx.uses_network = uses_network
    tx.state = "WAIT_OPEN_ACKS"
    tx.phase = "OPENING"
    tx.phase_started_ms = now_ms
    return
  end

  if tx.state == "WAIT_OPEN_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    if status == "failed" then self:_fail_transaction("open_ack_failed:" .. tostring(failed_key)); return end
    if status == "waiting" then
      if now_ms - tx.phase_started_ms >= VALVE_PHASE_TIMEOUT_MS then self:_fail_transaction("open_ack_timeout") end
      return
    end
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
    tx.phase = "SETTLING"
    return
  end

  if tx.state == "WAIT_SETTLE" then
    if now_ms < tx.settle_until then return end
    local ready, readiness_error = self:_path_runtime_ready(tx.path)
    if not ready then self:_fail_transaction("path_not_ready:" .. tostring(readiness_error)); return end

    tx.phase = "EXPORTING"
    local action_ok, result, detail = true, nil, nil
    if tx.action_fn then action_ok, result, detail = pcall(tx.action_fn) end
    if not action_ok or result == false then
      local reason = not action_ok and tostring(result) or tostring(detail or "action returned false")
      tx.terminal_after_block = "EXPORT_FAILED"
      tx.terminal_reason = reason
      self.warn_once("transaction_action_error:" .. tostring(tx.target_id),
        "RedstoneRouter: Export/Aktions-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. reason)
      self:_start_final_block(tx, now_ms)
      return
    end

    tx.state = "HOLD_OPEN"
    tx.phase = "HOLDING"
    tx.hold_until = now_ms + tx.valve_open_ms
    return
  end

  if tx.state == "HOLD_OPEN" then
    if now_ms >= tx.hold_until then
      tx.terminal_after_block = tx.terminal_after_block or "COMPLETE_SAFE"
      self:_start_final_block(tx, now_ms)
    end
    return
  end

  if tx.state == "WAIT_FINAL_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    local timed_out = (now_ms - tx.phase_started_ms) >= VALVE_PHASE_TIMEOUT_MS
    if status == "waiting" and not timed_out then return end

    self._state.active_target = nil
    self._state.active_path = nil
    self._state.transaction = nil
    if status == "ok" then
      local terminal = tx.terminal_after_block or "COMPLETE_SAFE"
      self:_record_terminal(tx, terminal, tx.terminal_reason, true)
      return
    end

    local reason = status == "failed"
      and ("final_block_failed:" .. tostring(failed_key)) or "final_block_timeout"
    self:_set_safety_latch(tx, reason, now_ms)
    self:_record_terminal(tx, "FINAL_BLOCK_UNCONFIRMED", reason, true)
    return
  end
end

-- Sofortiger Shutdown-Pfad: blockiert augenblicklich alle Ventile und
-- verwirft eine laufende Transaktion, unabhaengig von deren Zustand.
--
-- Ruft (wie _fail_transaction()) tx.on_error(reason) auf, falls eine
-- Transaktion aktiv war -- sonst bliebe der Abbruch fuer den Aufrufer
-- (logistics_router.lua/feed_router.lua) unsichtbar.
function M:shutdown_now(reason, opts)
  opts = opts or {}
  local tx = self._state.transaction
  self._state.transaction = nil
  self._state.active_target = nil
  self._state.active_path = nil
  if tx then
    self.log("WARN", string.format(
      "RedstoneRouter: Transaktion %s zu %s durch shutdown_now() abgebrochen (%s)",
      tostring(tx.id), tostring(tx.target_id), tostring(reason or "shutdown")))
    self:_record_terminal(tx, "CANCELLED", reason or "shutdown", false)
    if not opts.skip_latch and #self._state.all_valves > 0 then
      self:_set_safety_latch(tx, "shutdown:" .. tostring(reason or "shutdown"))
    else
      self:block_all()
    end
    if tx.on_error then
      local ok, err = pcall(tx.on_error, reason or "shutdown")
      if not ok then
        self.warn_once("tx_on_error_failed:" .. tostring(tx.target_id),
          "RedstoneRouter: on_error-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
      end
    end
  else
    self:block_all()
  end
end

-- Sichtbarkeit fuer UI/Diagnose: aktive Transaktion und ihr Zustand.
function M:get_active_transaction()
  local tx = self._state.transaction
  if not tx then return nil end
  return {
    id = tx.id, transaction_id = tx.id, target_id = tx.target_id,
    state = tx.state, phase = tx.phase or phase_for_state(tx.state), started_ts = tx.started_ts,
  }
end

function M:valve_count()
  return #self._state.all_valves
end

-- Fuehrt fuer jeden Netzwerk-Integrator zusammen: Live-Peer-Status, zuletzt
-- angeforderten Zustand (siehe _set_valve()), und beliefert Reaktoren.
--
-- "confirmed_state"/"state_matches" sind bewusst NICHT vorhanden -- nur
-- "requested_state" (was WIR zuletzt angefordert haben), niemals ein
-- bestaetigter Ist-Zustand.
--
-- Verarbeitet eine eingehende VALVE_ACK-Nachricht -- muss von der aufrufenden
-- Rolle aus ihrem comms-Message-Handler aufgerufen werden. Loescht das
-- zugehoerige pending-Kommando und traegt den tatsaechlich bestaetigten
-- Zustand ein.
function M:handle_valve_ack(message)
  if type(message) ~= "table" or message.type ~= "VALVE_ACK" or not message.command_id then return end
  local pending = self._state.pending_valve_acks
  if not pending then return end
  for key, entry in pairs(pending) do
    if entry.command_id == message.command_id then
      if message.src ~= entry.dst or message.dst ~= entry.src then
        self.warn_once("valve_ack_identity:" .. tostring(key) .. ":" .. tostring(message.command_id),
          "RedstoneRouter: VALVE_ACK mit unpassender src/dst-Identitaet ignoriert")
        return
      end
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

-- Periodisch von der aufrufenden Rolle aufzurufen -- prueft unbestaetigte
-- Kommandos gegen ein Timeout und sendet sie erneut (begrenzte Versuche,
-- danach wird auf das 20s-Fail-Safe der VALVE-Node vertraut).
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
          type = "SET_VALVE", src = entry.src, dst = entry.dst,
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
        label = (peer and peer.label) or v.integrator,
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

-- Einzige Autoritaet fuer "soll ungeroutet direkt exportiert werden, oder
-- muss geroutet (oder hart blockiert) werden?". Basiert ausschliesslich auf
-- dem in refresh() ermittelten Validierungszustand (tree_configured/
-- tree_valid/all_valves), nicht auf einem erneuten rohen Baum-Walk.
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
