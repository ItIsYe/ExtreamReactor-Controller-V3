-- nodes/fuel/logistics_router.lua
--
-- Demand-driven, per-reactor fuel supply management.
--
-- Core principle: ONLY the reactor that has requested fuel receives it.
-- No broadcast, no shared distribution, no accidental cross-supply.
--
-- How it works:
--   1. Each reactor has its own entry in config.logistics.reactors.
--   2. Every cycle: FUEL node reads the reactor's fuel level from the
--      network-relayed status cache (see read_reactor_fuel_from_network())
--      -- NOT from a local peripheral. FUEL has no Wired Modem link to the
--      reactors themselves, only to the ME system. The RT node controlling
--      each reactor already reads fuel level locally (it has the wired
--      link) and reports it as part of its regular status update; Master
--      relays this to FUEL nodes (master/fuel_relay.lua), with a fallback
--      to directly overhearing RT's status broadcasts if Master hasn't
--      relayed recently.
--   3. If fuel_level / capacity < request_below → that reactor requests fuel.
--   4. ME Bridge exports exactly the calculated amount into the ONE shared
--      export chest (config.logistics.export_chest) -- there is no
--      per-reactor delivery target. A Mekanism logistics network (sorters +
--      VALVE-Nodes) carries everything downstream from that single chest;
--      which physical reactor actually receives it is decided purely by
--      which valves are open at export time (see redstone_router.lua's
--      begin_transaction(), which blocks every other route before opening
--      this reactor's path and only then runs the export).
--   5. No other reactor is affected.
--
-- Hardware requirements:
--   - Wired Modem on the FUEL computer, connected to the shared export
--     chest/transporter (config.logistics.export_chest)
--   - Wireless Modem on the FUEL computer  (for MASTER communication)
--   - ME Bridge accessible (wired or by name)
--
-- Config model (in config.logistics):
--
--   me_bridge = "me_bridge",
--
--   -- The ONE physical hand-off point for every reactor: FUEL always
--   -- exports here, never to a per-reactor target. Which reactor the item
--   -- actually reaches is entirely a function of the valve path opened for
--   -- that delivery (see redstone_tree synthesis below).
--   export_chest = "mekanism:ultimate_logistical_transporter_0",
--
--   reactors = {
--     { -- FUEL has no wired access to the reactor itself (only the ME
--       -- system) -- fuel level comes via network (master/fuel_relay.lua,
--       -- with a fallback on overhearing RT's status broadcasts). reactor_id
--       -- and label are learned from the owning RT node's own broadcasts
--       -- (see router_ui.lua's reactor-teach flow), never typed by hand.
--       reactor_id        = "node-52-reactor-0",
--       label             = "Reactor A",
--       path              = { "VALVE-1", "VALVE-3" },  -- see redstone_tree note below
--       request_below     = 0.25,  -- request when fuel_level < 25% of capacity
--       fill_amount       = 64,    -- how many ingot-equivalent items to export per request
--       min_in_me         = 32,    -- don't export if ME has fewer than this (ingot-equivalent)
--     },
--   },
--
--   -- Waste collection: drain waste output chests/transporters into ME.
--   waste = {
--     { name  = "Reactor A waste",
--       outlet = "mekanism:ultimate_logistical_transporter_1",
--     },
--   },
--
-- No `item` field: which fuel (Uranium vs Blutonium) and which form (ingot
-- vs block) to deliver is decided automatically, fresh on every delivery --
-- see pick_fuel_delivery() below. The interchangeable fuel families come
-- from config.reserve_items (shared with nodes/fuel/storage.lua's reserve
-- tally), grouped by their `element` field.
--
-- redstone_tree (the VALVE routing topology redstone_router.lua actually
-- consumes) is never hand-maintained here: refresh_peripherals() builds it
-- transparently from each reactor's own `path`, keyed by `reactor_id`, on
-- every refresh. See build_redstone_tree_from_reactors() below.

local M = {}
local redstone_router_lib = require("nodes.fuel.redstone_router")
local me_bridge_compat = require("core.me_bridge_compat")

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return nil, "no_method:" .. tostring(method)
  end
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

local function is_transporter_name(name)
  return tostring(name or ""):lower():find("logistical_transporter", 1, true) ~= nil
end

-- ---- reactor fuel level reading (network-based) ----------------------------

-- Fuellstand kommt aus dem netzwerkbasierten Cache (fuel_status_cache in
-- nodes/fuel/main.lua), befuellt per Master-Relay (primaer) oder direktem
-- Mithoeren der RT-Status-Broadcasts (Fallback). Die juengere der beiden
-- Quellen gewinnt; ist keine von beiden innerhalb von MAX_AGE_MS aktuell,
-- gilt der Fuellstand als nicht lesbar (Reaktor wird diesen Zyklus
-- uebersprungen statt zu raten) -- FUEL hat keinen Wired-Zugriff auf die
-- Reaktoren selbst, nur aufs ME-System.
local MAX_FUEL_DATA_AGE_MS = 30000

local function read_reactor_fuel_from_network(fuel_status, reactor_id)
  if not fuel_status or not reactor_id then return nil, nil end
  local now = os.epoch("utc")
  local best = nil
  for _, source in ipairs({ fuel_status.master_relay, fuel_status.direct_heard }) do
    local entry = source and source[reactor_id]
    if entry and entry.ts and (now - entry.ts) <= MAX_FUEL_DATA_AGE_MS then
      if not best or entry.ts > best.ts then best = entry end
    end
  end
  if not best then return nil, nil end
  if type(best.fuel_amount) ~= "number" or type(best.fuel_capacity) ~= "number" then
    return nil, nil
  end
  return best.fuel_amount, best.fuel_capacity
end

-- ---- automatic fuel family/form selection ----------------------------------

-- Groups config.reserve_items (the same list nodes/fuel/storage.lua sums for
-- the reserve display) by their `element` field into ingot/block pairs.
-- Entries without a usable `element`/`item` are skipped -- they still count
-- toward the plain reserve total in storage.lua, but can't participate in
-- delivery family selection without an element to group by.
local function build_fuel_families(reserve_items)
  local by_element, order = {}, {}
  for _, entry in ipairs(reserve_items or {}) do
    if type(entry) == "table" and type(entry.element) == "string" and entry.element ~= ""
        and type(entry.item) == "string" and entry.item ~= "" then
      local family = by_element[entry.element]
      if not family then
        family = { element = entry.element, ingot = nil, block = nil, block_multiplier = 9 }
        by_element[entry.element] = family
        order[#order + 1] = family
      end
      local multiplier = tonumber(entry.unit_multiplier) or 1
      if multiplier > 1 then
        family.block = entry.item
        family.block_multiplier = multiplier
      else
        family.ingot = entry.item
      end
    end
  end
  return order
end

-- Reads the live ME stock (in ingot-equivalent units) for every fuel family,
-- then picks whichever family currently has the larger stock -- decided
-- fresh on every delivery, never fixed per reactor. Returns nil if no
-- family has any stock at all (nothing sensible to deliver).
local function pick_fuel_family(bridge, families)
  local best = nil
  for _, family in ipairs(families) do
    local ingot_amt = 0
    if family.ingot then
      local info = safe_call(bridge.wrapped, "getItem", { name = family.ingot })
      ingot_amt = me_bridge_compat.item_amount(info)
    end
    local block_amt = 0
    if family.block then
      local info = safe_call(bridge.wrapped, "getItem", { name = family.block })
      block_amt = me_bridge_compat.item_amount(info)
    end
    local total = ingot_amt + block_amt * family.block_multiplier
    if total > 0 and (not best or total > best.total) then
      best = {
        element = family.element,
        ingot = family.ingot, ingot_amt = ingot_amt,
        block = family.block, block_amt = block_amt,
        block_multiplier = family.block_multiplier,
        total = total,
      }
    end
  end
  return best
end

-- Chooses ingot vs block form for a single delivery of `push` ingot-
-- equivalent units of the already-picked family: whole blocks first (fewer
-- item transfers for bulk amounts), otherwise ingots for small/remaining
-- amounts. Never splits one delivery across both forms -- redstone-routed
-- deliveries move exactly one item stack through one valve-open window.
-- ---- redstone_tree synthesis ------------------------------------------------

-- redstone_router.lua (shared with nodes/reprocessor/feed_router.lua) is the
-- one piece of shared valve-routing machinery and is left untouched -- it
-- still consumes a flat { {reactor=, label=, path=}, ... } tree. FUEL no
-- longer hand-maintains that tree as a second config object: it is rebuilt
-- here, every refresh, directly from each reactor's own `path`. A reactor
-- without a reactor_id or a non-empty path contributes no route (nothing to
-- route to yet -- e.g. freshly learned but not wired up).
local function build_redstone_tree_from_reactors(reactor_entries)
  local tree = {}
  for _, r in ipairs(reactor_entries) do
    if r.reactor_id and type(r.path) == "table" and #r.path > 0 then
      tree[#tree + 1] = { reactor = r.reactor_id, label = r.label, path = r.path }
    end
  end
  return tree
end

local function pick_fuel_form(family, push)
  local whole_blocks = family.block and math.floor(push / family.block_multiplier) or 0
  if whole_blocks >= 1 and family.block_amt >= 1 then
    local count = math.min(whole_blocks, family.block_amt)
    return family.block, count, count * family.block_multiplier
  end
  if family.ingot and family.ingot_amt >= 1 then
    local count = math.min(push, family.ingot_amt)
    return family.ingot, count, count
  end
  return nil, 0, 0
end

-- ---- constructor -----------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    config    = opts.config or {},
    log       = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    external_rs_router = opts.rs_router or nil,  -- shared rs_router injected from main.lua
    -- Netzwerkbasierter Fuellstand-Cache (siehe read_reactor_fuel_from_network()).
    fuel_status = opts.fuel_status or { master_relay = {}, direct_heard = {} },
    _state = {
      bridge        = nil,
      reactors      = {},   -- { label, reactor_id, path, cfg }
      export_chest  = nil,  -- { name, wrapped, is_transporter } -- shared by all reactors
      waste_outlets = {},   -- { name, label, outlet }
      rs_router     = nil,  -- redstone_router instance (if configured)
      total_exported= 0,
      total_imported= 0,
      total_errors  = 0,
      last_cycle    = nil,
      last_refresh  = 0,
      last_run_ts   = 0,
      -- current_request umfasst (anders als redstone_router.lua's kurzes
      -- Ventil-Fenster) den gesamten Entscheidungs- bis Lieferzyklus fuer
      -- den aktiv belieferten Reaktor -- Grundlage fuer get_current_request().
      current_request = nil,  -- { transaction_id, reactor_id, label, state, phase }
      last_delivery = nil,
      delivery_seq = 0,
      -- Ueberlebt refresh_peripherals() (das self._state.reactors komplett
      -- neu aufbaut) -- Grundlage fuer die Abklingzeit unten: wann eine
      -- Lieferung an diesen Reaktor zuletzt tatsaechlich exportiert wurde.
      last_export_ts = {},  -- [reactor_id] = os.epoch("utc")
    },
  }
  return setmetatable(self, { __index = M })
end

local function next_delivery_id(self, label)
  self._state.delivery_seq = (self._state.delivery_seq or 0) + 1
  local now = os.epoch and os.epoch("utc") or 0
  return table.concat({ "FUEL", tostring(now), tostring(self._state.delivery_seq), tostring(label or "?") }, ":")
end

local function finish_delivery(self, request, phase, terminal_state, err)
  if not request then return end
  request.phase = phase
  request.terminal_state = terminal_state
  request.error = err or request.error
  request.finished_ts = os.epoch and os.epoch("utc") or 0
  self._state.last_delivery = {
    transaction_id = request.transaction_id,
    reactor_id = request.reactor_id,
    label = request.label,
    phase = request.phase,
    terminal_state = request.terminal_state,
    item = request.item,
    element = request.element,
    moved = request.moved or 0,
    error = request.error,
    started_ts = request.started_ts,
    finished_ts = request.finished_ts,
  }
  if self._state.current_request == request then self._state.current_request = nil end
end

local function account_async_error(self, request)
  if request.error_counted then return end
  request.error_counted = true
  self._state.total_errors = self._state.total_errors + 1
  if request.cycle_result then
    request.cycle_result.errors = (request.cycle_result.errors or 0) + 1
  end
end

-- Merkt sich, WANN zuletzt tatsaechlich etwas an diesen Reaktor exportiert
-- wurde -- Grundlage fuer resupply_cooldown_s in _run_supply()'s Phase 1
-- (siehe dortiger Kommentar): FUEL hat kein Wired-Modem-Sichtfeld auf die
-- letzte Kiste vor dem Reaktor, kann also physisch nicht pruefen, ob eine
-- vorige Lieferung schon angekommen/verbraucht wurde. Der vom Reaktor
-- gemeldete Fuellstand (fuel_pct) aktualisiert sich erst NACH Verbrauch --
-- ohne diese Abklingzeit wuerde FUEL bei jedem ~5s-Zyklus erneut nachlegen,
-- solange fuel_pct unter der Schwelle bleibt, und Fuel staut sich in der
-- Kiste vor dem Reaktor an (Feldbericht 2026-09-06).
local function record_export(self, reactor_id, moved)
  if not reactor_id or (tonumber(moved) or 0) <= 0 then return end
  self._state.last_export_ts[reactor_id] = os.epoch and os.epoch("utc") or 0
end

local function account_async_export(self, request, moved, move_line)
  if moved <= 0 then return end
  self._state.total_exported = self._state.total_exported + moved
  if request.cycle_log then request.cycle_log[#request.cycle_log + 1] = move_line end
  if request.cycle_result then
    request.cycle_result.exported = (request.cycle_result.exported or 0) + moved
  end
end

-- ---- peripheral discovery --------------------------------------------------

-- Sucht per Methodensignatur (core/me_bridge_compat.lua, deckt beide
-- Advanced-Peripherals-API-Generationen ab), sobald der konfigurierte/
-- Default-Name nicht direkt gefunden wird -- Advanced Peripherals vergibt
-- generierte Namen wie "meBridge_0"/"me_bridge_3", nicht den Konventions-
-- Default "me_bridge".
local function find_me_bridge_by_methods()
  for _, name in ipairs(peripheral.getNames() or {}) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      local set = {}
      for _, m in ipairs(methods) do set[m] = true end
      if me_bridge_compat.is_bridge(set) then
        return name
      end
    end
  end
  return nil
end

function M:refresh_peripherals()
  local cfg = self.config.logistics or self.config or {}

  -- ME Bridge
  local bridge_name = cfg.me_bridge or "me_bridge"
  self._state.bridge = nil
  local bridge_found_name = nil
  if peripheral.isPresent(bridge_name) then
    bridge_found_name = bridge_name
  elseif cfg.me_bridge == nil or cfg.me_bridge == ""
      or cfg.me_bridge == "me_bridge" or cfg.me_bridge == "meBridge" then
    -- "me_bridge"/"meBridge" are shipped convention defaults, not proof of
    -- an intentional strict peripheral binding. Advanced Peripherals normally
    -- exposes generated names such as meBridge_0, so fall back to the method
    -- signature for those default values. A genuinely custom configured name
    -- remains strict and is never silently replaced by another bridge.
    bridge_found_name = find_me_bridge_by_methods()
  end
  if bridge_found_name then
    local ok, w = pcall(peripheral.wrap, bridge_found_name)
    if ok and w then
      self._state.bridge = { name = bridge_found_name, wrapped = w }
      self.log("DEBUG", "Logistics: ME Bridge: " .. bridge_found_name)
    else
      self.warn_once("bridge_wrap", "Logistics: ME Bridge wrap failed: " .. bridge_found_name)
    end
  else
    self.warn_once("bridge_absent", "Logistics: ME Bridge absent: " .. bridge_name)
  end

  -- Shared export chest: the ONE physical hand-off point every delivery
  -- exports into, regardless of which reactor it's destined for. Which
  -- reactor actually receives it is decided by the valve path opened for
  -- that delivery (see redstone_router.lua's begin_transaction()), not by
  -- picking a different peripheral here.
  self._state.export_chest = nil
  if cfg.export_chest and peripheral.isPresent(cfg.export_chest) then
    local ok, w = pcall(peripheral.wrap, cfg.export_chest)
    if ok and w then
      self._state.export_chest = { name = cfg.export_chest, wrapped = w,
        is_transporter = is_transporter_name(cfg.export_chest) }
    else
      self.warn_once("export_chest_wrap", "Logistics: export_chest wrap failed: " .. cfg.export_chest)
    end
  elseif cfg.export_chest then
    self.warn_once("export_chest_absent", "Logistics: export_chest absent: " .. cfg.export_chest
      .. " (needs Wired Modem connection)")
  end

  -- Per-reactor entries
  local reactors = {}
  for i, entry in ipairs(cfg.reactors or {}) do
    -- reactor_id/label are learned from the owning RT node's broadcasts
    -- (router_ui.lua's teach flow) and never typed by hand; reactor_port is
    -- accepted as a legacy alias for reactor_id only.
    local reactor_id = entry.reactor_id or entry.reactor_port
    local label = entry.label or reactor_id or ("Reactor " .. i)

    local path = {}
    if type(entry.path) == "table" then
      for _, step in ipairs(entry.path) do
        if type(step) == "string" and step ~= "" then path[#path + 1] = step end
      end
    end

    reactors[#reactors + 1] = {
      label        = label,
      reactor_id   = reactor_id,
      path         = path,
      request_below = tonumber(entry.request_below) or 0.25,
      fill_amount  = tonumber(entry.fill_amount)   or 64,
      min_in_me    = tonumber(entry.min_in_me)     or 32,
      -- Mindestwartezeit nach einer Lieferung an diesen Reaktor, bevor
      -- erneut nachgelegt wird -- siehe record_export()-Kommentar oben.
      -- Je nach physischer Entfernung des Reaktors vom Transportnetz
      -- unterschiedlich lang, daher pro Reaktor einstellbar (Router-UI).
      resupply_cooldown_s = math.max(0, tonumber(entry.resupply_cooldown_s) or 30),
      cfg          = entry,
    }
  end
  self._state.reactors = reactors
  cfg.redstone_tree = build_redstone_tree_from_reactors(reactors)

  -- Waste outlets
  local waste_outlets = {}
  for i, entry in ipairs(cfg.waste or {}) do
    local label = entry.name or ("Waste " .. i)
    if entry.outlet and peripheral.isPresent(entry.outlet) then
      local ok, w = pcall(peripheral.wrap, entry.outlet)
      if ok and w then
        waste_outlets[#waste_outlets + 1] = {
          label   = label,
          name    = entry.outlet,
          wrapped = w,
        }
      else
        self.warn_once("outlet_wrap_" .. i,
          "Logistics: waste outlet wrap failed: " .. entry.outlet)
      end
    elseif entry.outlet then
      self.warn_once("outlet_absent_" .. i,
        "Logistics: waste outlet absent: " .. entry.outlet)
    end
  end
  self._state.waste_outlets = waste_outlets

  -- Redstone router: prefer external (shared with router_ui); fall back to own.
  -- Config key is redstone_tree (tree topology, set by router_ui on save).
  local cfg_rs = self.config.logistics or self.config or {}
  local has_tree = type(cfg_rs.redstone_tree) == "table" and #cfg_rs.redstone_tree > 0
  if self.external_rs_router then
    self._state.rs_router = self.external_rs_router
    if has_tree then self._state.rs_router:refresh() end
  elseif has_tree then
    if not self._state.rs_router then
      self._state.rs_router = redstone_router_lib.new({
        config    = self.config,
        log       = self.log,
        warn_once = self.warn_once,
      })
    end
    self._state.rs_router:refresh()
  else
    self._state.rs_router = nil
  end

  self.log("DEBUG", string.format(
    "Logistics: bridge=%s reactors=%d waste_outlets=%d",
    self._state.bridge and self._state.bridge.name or "NONE",
    #reactors, #waste_outlets
  ))
end

-- ---- supply cycle (demand-driven, per reactor) -----------------------------

function M:_run_supply(cycle_log)
  local bridge = self._state.bridge
  if not bridge then return 0, 0 end
  -- Never overwrite the operator-visible lifecycle of an in-flight routed
  -- delivery. The router serializes transactions; supply is retried after its
  -- final BLOCKED confirmation, while waste collection may continue.
  if self._state.current_request then return 0, 0 end
  local exported, errors = 0, 0

  -- The shared export chest is a global precondition, not a per-reactor one
  -- -- without it, nothing can be delivered to ANY reactor regardless of
  -- routing/ME stock, so this is checked once up front.
  local export_chest = self._state.export_chest
  if not export_chest then
    self.warn_once("no_export_chest", "Logistics: no export_chest configured — cannot supply any reactor")
    return 0, 0
  end

  -- Phase 1: ermitteln, WELCHE Reaktoren gerade Fuel anfordern, ohne sie
  -- schon zu beliefern. Alle anfordernden Reaktoren sammeln, dann nach
  -- Prioritaet sortieren (niedrigster Fuellstand zuerst). Reaktoren ohne
  -- reactor_id (Always-Supply-Fallback) werden nach allen bekannten
  -- Fuellstaenden eingeplant, da ihre Dringlichkeit nicht vergleichbar ist.
  local now_ts = os.epoch and os.epoch("utc") or 0
  local candidates = {}
  for _, r in ipairs(self._state.reactors) do
    local requesting, fuel_pct = false, nil
    if r.reactor_id then
      local fuel_amt, capacity = read_reactor_fuel_from_network(self.fuel_status, r.reactor_id)
      if fuel_amt and capacity and capacity > 0 then
        fuel_pct = fuel_amt / capacity
        requesting = fuel_pct < r.request_below
        self.log("DEBUG", string.format(
          "Logistics: %s fuel=%.1f%% (%.0f/%.0f mB) request=%s",
          r.label, fuel_pct * 100, fuel_amt, capacity,
          requesting and "YES" or "no"))
      else
        self.warn_once("fuel_read_fail:" .. r.label,
          "Logistics: no fresh network fuel data for " .. r.label
          .. " (reactor_id=" .. tostring(r.reactor_id) .. ") — skipping")
      end
    else
      requesting = true
      self.log("DEBUG", "Logistics: " .. r.label
        .. " has no reactor_id — using always-supply mode")
    end
    -- Abklingzeit seit der letzten tatsaechlichen Lieferung: fuel_pct
    -- aktualisiert sich erst, NACHDEM der Reaktor eine vorige Lieferung
    -- verbraucht hat -- ohne diese Sperre wuerde hier jeden Zyklus erneut
    -- nachgelegt, solange fuel_pct noch unter der Schwelle liegt, obwohl
    -- die letzte Ladung physisch noch unterwegs/nicht verbraucht ist (siehe
    -- record_export()-Kommentar oben).
    if requesting and r.reactor_id then
      local last_ts = self._state.last_export_ts[r.reactor_id]
      local cooldown_ms = (r.resupply_cooldown_s or 0) * 1000
      if last_ts and (now_ts - last_ts) < cooldown_ms then
        requesting = false
        self.log("DEBUG", string.format(
          "Logistics: %s: resupply_cooldown aktiv (%.0fs verbleibend) — kein Nachlegen diesen Zyklus",
          r.label, (cooldown_ms - (now_ts - last_ts)) / 1000))
      end
    end
    if requesting then
      candidates[#candidates + 1] = { r = r, fuel_pct = fuel_pct, order = #candidates + 1 }
    end
  end

  table.sort(candidates, function(a, b)
    -- Bekannter Fuellstand geht immer vor unbekanntem (Always-Supply).
    if (a.fuel_pct ~= nil) ~= (b.fuel_pct ~= nil) then
      return a.fuel_pct ~= nil
    end
    if a.fuel_pct and b.fuel_pct and a.fuel_pct ~= b.fuel_pct then
      return a.fuel_pct < b.fuel_pct  -- niedrigster Fuellstand zuerst
    end
    return a.order < b.order  -- stabile Reihenfolge bei Gleichstand/beide unbekannt
  end)

  -- redstone_router.lua's route_and_act() ist eine asynchrone Zustandsmaschine
  -- (begin_transaction() + tick()) mit immer nur EINER aktiven Transaktion pro
  -- Router. Ist Routing konfiguriert, wird deshalb pro Zyklus hoechstens EINE
  -- Lieferung tatsaechlich gestartet: Kandidaten mit unzureichendem ME-Bestand
  -- werden weiter der Reihe nach uebersprungen, aber sobald der Router "busy"
  -- meldet, lohnt kein weiterer Versuch in diesem Zyklus. Ohne konfiguriertes
  -- Routing bleibt Direkt-Export synchron und schnell.
  local cfg_l = self.config.logistics or self.config or {}
  local rs = self._state.rs_router

  -- get_routing_state() ist die einzige Autoritaet fuer "war konfiguriert"
  -- (nicht ein struktureller Walk ueber das rohe cfg.redstone_tree, der bei
  -- einem kaputten Baum faelschlich "nie konfiguriert" ergeben koennte).
  -- ROUTING_INVALID/ROUTING_REQUIRED_BUT_EMPTY blockieren die Belieferung
  -- komplett (kein Routing-Versuch, aber auch kein Direkt-Export-Fallback).
  local routing_state = rs and rs:get_routing_state() or "ROUTING_NOT_CONFIGURED"
  if routing_state == "ROUTING_INVALID" or routing_state == "ROUTING_REQUIRED_BUT_EMPTY" then
    self.warn_once("routing_blocked:" .. routing_state,
      "Logistics: Routing " .. routing_state .. " -- Belieferung diesen Zyklus komplett blockiert, kein ungeschuetzter Direktexport")
    return exported, errors
  end
  local routed = routing_state == "ROUTING_VALID"

  -- Which fuel family to deliver is decided once per cycle (freshest ME
  -- read available), not per reactor -- see pick_fuel_family() above. At
  -- most one delivery happens per cycle anyway (see comment above), so a
  -- per-reactor re-read would only waste getItem() calls.
  local families = build_fuel_families(self.config.reserve_items)
  local family = #candidates > 0 and pick_fuel_family(bridge, families) or nil
  if #candidates > 0 and not family then
    self.warn_once("no_fuel_family", "Logistics: no fuel (Uranium/Blutonium) available in the ME system — cannot supply any reactor")
  end

  for _, cand in ipairs(candidates) do
    local r, fuel_pct = cand.r, cand.fuel_pct

    -- current_request VOR dem Export setzen (nicht erst waehrend des kurzen
    -- Ventil-Fensters) -- deckt den gesamten Entscheidungs- bis
    -- Lieferzyklus ab, Grundlage fuer die UI-Hervorhebung (get_summary()).
    self._state.current_request = {
      reactor_id = r.reactor_id, label = r.label, state = "requesting", phase = "REQUESTING",
      started_ts = os.epoch and os.epoch("utc") or 0,
      cycle_log = cycle_log,
    }

    if not family then goto continue end

    -- ME availability, in ingot-equivalent units of the chosen family.
    if family.total < r.min_in_me then
      self.log("DEBUG", string.format(
        "Logistics: %s: ME has %d %s-equivalent (need >%d) — skip",
        r.label, family.total, family.element, r.min_in_me))
      goto continue
    end

    local push = math.min(r.fill_amount, family.total - r.min_in_me)
    if push <= 0 then goto continue end

    local deliver_item, deliver_count = pick_fuel_form(family, push)
    if not deliver_item or deliver_count <= 0 then goto continue end

    do
      local valve_ms = tonumber(cfg_l.valve_open_ms) or 2000
      local pct_str = fuel_pct and string.format(" (%.0f%%)", fuel_pct * 100) or ""
      local request = self._state.current_request
      request.transaction_id = request.transaction_id or next_delivery_id(self, r.label)
      request.item = deliver_item
      request.element = family.element

      if routed then
        local function do_export()
          request.phase = "EXPORTING"
          request.state = "delivering"
          local ok, result = me_bridge_compat.export_to(bridge.wrapped,
            { name = deliver_item, count = deliver_count }, export_chest.name)
          if not ok then
            local err = tostring(result)
            self.warn_once("exp_err:" .. export_chest.name,
              "exportItemToPeripheral → " .. export_chest.name .. ": " .. err)
            account_async_error(self, request)
            request.error = err
            return false, err
          end
          local moved = type(result) == "number" and result or 0
          request.moved = moved
          request.exported_at = os.epoch and os.epoch("utc") or 0
          if moved > 0 then
            record_export(self, request.reactor_id, moved)
            local move_line = string.format(
              "ME→[%s]%s %s x%d via %s", r.label, pct_str, deliver_item, moved, export_chest.name)
            account_async_export(self, request, moved, move_line)
            self.log("INFO", string.format("ME→[%s]%s %s x%d via %s [tx=%s]",
              r.label, pct_str, deliver_item, moved, export_chest.name, tostring(request.transaction_id)))
          end
          return true, moved
        end

        local function on_transaction_error(reason)
          self.warn_once("routing_failed:" .. tostring(r.label),
            "Logistics: Routing-Transaktion fuer " .. r.label .. " abgebrochen (" .. tostring(reason) .. ")")
          account_async_error(self, request)
          finish_delivery(self, request, "ERROR", "CANCELLED", tostring(reason))
        end

        local function on_transaction_complete(info)
          local terminal = type(info) == "table" and info.state or "ERROR"
          if terminal == "COMPLETE_SAFE" then
            finish_delivery(self, request, "COMPLETE", terminal, nil)
          else
            account_async_error(self, request)
            finish_delivery(self, request, "ERROR", terminal,
              type(info) == "table" and info.reason or "transaction failed")
          end
        end

        local started, reason, router_tx_id = rs:begin_transaction(r.reactor_id, do_export, valve_ms, {
          on_error = on_transaction_error,
          on_complete = on_transaction_complete,
          transaction_id = request.transaction_id,
        })
        if not started then
          self._state.current_request = nil
          if reason == "busy" then
            self.log("DEBUG", "Logistics: Router beschaeftigt (aktive Transaktion) — restliche Kandidaten diesen Zyklus uebersprungen")
            return exported, errors
          end
          if reason == "safety_latched" or reason == "quiescing" then
            self.log("WARN", "Logistics: Router sicherheitsgesperrt (" .. tostring(reason) .. ") — keine weitere Lieferung")
            return exported, errors
          end
          self.log("DEBUG", "Logistics: " .. r.label .. ": Routing nicht moeglich (" .. tostring(reason) .. ") — naechster Kandidat")
          goto continue
        end
        request.transaction_id = router_tx_id or request.transaction_id
        request.state = "delivering"
        local active = type(rs.get_active_transaction) == "function" and rs:get_active_transaction() or nil
        request.phase = active and active.phase or "BLOCKING"
        return exported, errors
      end

      -- No redstone routing configured: synchronous export with the same
      -- stable transaction identity/terminal semantics.
      request.state = "delivering"
      request.phase = "EXPORTING"
      local ok, result = me_bridge_compat.export_to(bridge.wrapped,
        { name = deliver_item, count = deliver_count }, export_chest.name)
      if not ok then
        local err = tostring(result)
        self.warn_once("exp_err:" .. export_chest.name,
          "exportItemToPeripheral → " .. export_chest.name .. ": " .. err)
        errors = errors + 1
        request.error_counted = true
        finish_delivery(self, request, "ERROR", "EXPORT_FAILED", err)
      else
        local moved = type(result) == "number" and result or 0
        request.moved = moved
        if moved > 0 then
          record_export(self, request.reactor_id, moved)
          exported = exported + moved
          cycle_log[#cycle_log + 1] = string.format(
            "ME→[%s]%s %s x%d via %s", r.label, pct_str, deliver_item, moved, export_chest.name)
        end
        finish_delivery(self, request, "COMPLETE", "COMPLETE_SAFE", nil)
      end
    end

    ::continue::
  end
  self._state.current_request = nil
  return exported, errors
end

-- ---- collect cycle (waste → ME) --------------------------------------------

function M:_run_collect(cycle_log)
  local bridge = self._state.bridge
  if not bridge then return 0, 0 end
  local imported, errors = 0, 0

  for _, outlet in ipairs(self._state.waste_outlets) do
    local ok, result = me_bridge_compat.import_from(bridge.wrapped, {}, outlet.name)
    if not ok then
      -- Fallback: import item by item
      local items, _ = safe_call(outlet.wrapped, "list")
      if items then
        for _, stack in pairs(items) do
          if type(stack) == "table" and stack.name then
            local ok2, res2 = me_bridge_compat.import_from(bridge.wrapped,
              { name = stack.name, count = stack.count or 64 }, outlet.name)
            if ok2 then
              local n = type(res2) == "number" and res2 or 0
              imported = imported + n
              if n > 0 then
                cycle_log[#cycle_log + 1] = string.format(
                  "[%s]→ME %s x%d", outlet.label, stack.name, n)
              end
            else
              errors = errors + 1
              self.warn_once("imp_err:" .. outlet.name,
                "importItemFromPeripheral from " .. outlet.name .. ": " .. tostring(res2))
            end
          end
        end
      else
        errors = errors + 1
        self.warn_once("imp_err_all:" .. outlet.name,
          "importItemFromPeripheral (all) from " .. outlet.name .. ": " .. tostring(result))
      end
    else
      local moved = type(result) == "number" and result or 0
      imported = imported + moved
      if moved > 0 then
        cycle_log[#cycle_log + 1] = string.format(
          "[%s]→ME all x%d", outlet.label, moved)
      end
    end
  end
  return imported, errors
end

-- ---- main cycle ------------------------------------------------------------

function M:run_cycle()
  local cycle_log = {}
  local exp, err1 = self:_run_supply(cycle_log)
  local imp, err2 = self:_run_collect(cycle_log)
  local errs = err1 + err2

  self._state.total_exported = self._state.total_exported + exp
  self._state.total_imported = self._state.total_imported + imp
  self._state.total_errors   = self._state.total_errors   + errs
  self._state.last_cycle = {
    ts = os.epoch("utc"), exported = exp, imported = imp, errors = errs,
    moves = cycle_log,
  }
  if self._state.current_request and self._state.current_request.cycle_log == cycle_log then
    self._state.current_request.cycle_result = self._state.last_cycle
  end

  if exp > 0 or imp > 0 then
    self.log("INFO", string.format(
      "Logistics: exported=%d imported=%d errors=%d | %s",
      exp, imp, errs, table.concat(cycle_log, " | ")))
  elseif errs > 0 then
    self.log("WARN", "Logistics: exported=0 imported=0 errors=" .. errs)
  else
    self.log("DEBUG", "Logistics: nothing to do")
  end
  return self._state.last_cycle
end

-- ---- service tick ----------------------------------------------------------

function M:tick()
  local cfg = self.config.logistics or self.config or {}
  if cfg.enabled ~= true then return end

  local now = os.epoch("utc")
  local refresh_ms = (tonumber(cfg.discovery_interval) or 60) * 1000
  if now - self._state.last_refresh >= refresh_ms then
    self:refresh_peripherals()
    self._state.last_refresh = now
  end

  local interval_ms = (tonumber(cfg.interval) or 5) * 1000
  if now - self._state.last_run_ts < interval_ms then return end
  self._state.last_run_ts = now
  self:run_cycle()
end

-- ---- status ----------------------------------------------------------------

function M:get_summary()
  local s = self._state
  local cfg = self.config.logistics or self.config or {}
  local reactor_status = {}
  for _, r in ipairs(s.reactors) do
    local fuel_pct = nil
    if r.reactor_id then
      local amt, cap = read_reactor_fuel_from_network(self.fuel_status, r.reactor_id)
      if amt and cap and cap > 0 then fuel_pct = math.floor(amt / cap * 100) end
    end
    reactor_status[#reactor_status + 1] = {
      label         = r.label,
      fuel_pct      = fuel_pct,
      reactor_id    = r.reactor_id,
      path          = r.path,
      -- Delivery to a reactor no longer depends on a peripheral dedicated
      -- to it (see export_chest below) -- only on having learned its
      -- identity from the owning RT node.
      connected     = r.reactor_id ~= nil,
    }
  end
  local active_tx = s.rs_router and type(s.rs_router.get_active_transaction) == "function"
    and s.rs_router:get_active_transaction() or nil
  if s.current_request and active_tx
      and (not s.current_request.transaction_id or s.current_request.transaction_id == active_tx.transaction_id) then
    s.current_request.transaction_id = active_tx.transaction_id or s.current_request.transaction_id
    s.current_request.phase = active_tx.phase or s.current_request.phase
  end
  local safety_latch = s.rs_router and type(s.rs_router.get_safety_latch) == "function"
    and s.rs_router:get_safety_latch() or nil

  -- Live ME-Bestand je Fuel-Familie fuer die Diagnose-Seite (ui_pages.lua)
  -- -- unabhaengig davon, ob gerade ein Reaktor anfordert, damit der
  -- Bestand jederzeit einsehbar ist, nicht nur waehrend einer Lieferung.
  local fuel_families = nil
  if s.bridge then
    fuel_families = {}
    for _, fam in ipairs(build_fuel_families(self.config.reserve_items)) do
      local ingot_amt = 0
      if fam.ingot then
        ingot_amt = me_bridge_compat.item_amount(safe_call(s.bridge.wrapped, "getItem", { name = fam.ingot }))
      end
      local block_amt = 0
      if fam.block then
        block_amt = me_bridge_compat.item_amount(safe_call(s.bridge.wrapped, "getItem", { name = fam.block }))
      end
      fuel_families[#fuel_families + 1] = {
        element = fam.element, ingot_amt = ingot_amt, block_amt = block_amt,
        total = ingot_amt + block_amt * fam.block_multiplier,
      }
    end
    table.sort(fuel_families, function(a, b) return a.total > b.total end)
  end

  local current_request = nil
  if s.current_request then
    current_request = {
      transaction_id = s.current_request.transaction_id,
      reactor_id = s.current_request.reactor_id,
      label = s.current_request.label,
      state = s.current_request.state,
      phase = s.current_request.phase,
      started_ts = s.current_request.started_ts,
      moved = s.current_request.moved,
      error = s.current_request.error,
    }
  end
  return {
    enabled        = cfg.enabled == true,
    bridge         = s.bridge and s.bridge.name or nil,
    export_chest   = s.export_chest and s.export_chest.name or nil,
    reactors       = reactor_status,
    fuel_families  = fuel_families,
    waste_outlets  = #s.waste_outlets,
    -- Deckt den ganzen Entscheidungs-/Lieferzyklus ab (das kurze Ventil-
    -- Fenster bleibt separat ueber rs_router:get_active_route() verfuegbar).
    current_request = current_request,
    last_delivery  = s.last_delivery,
    router_safety_latch = safety_latch,
    total_exported = s.total_exported,
    total_imported = s.total_imported,
    total_errors   = s.total_errors,
    last_cycle     = s.last_cycle,
  }
end

return M
