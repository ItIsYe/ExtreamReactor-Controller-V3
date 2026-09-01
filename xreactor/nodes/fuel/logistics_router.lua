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
--   4. ME Bridge exports exactly the calculated amount to that reactor's
--      dedicated inlet peripheral (transporter or chest).
--   5. No other reactor is affected.
--
-- Hardware requirements:
--   - Wired Modem on the FUEL computer, connected to:
--       • Each reactor's dedicated inlet transporter/chest (for delivery)
--   - Wireless Modem on the FUEL computer  (for MASTER communication)
--   - ME Bridge accessible (wired or by name)
--
-- Config model (in config.logistics):
--
--   me_bridge = "me_bridge",
--
--   reactors = {
--     { name              = "Reactor A",
--       -- FUEL has no wired access to the reactor itself (only the ME
--       -- system) -- fuel level comes via network (master/fuel_relay.lua,
--       -- with a fallback on overhearing RT's status broadcasts). reactor_id
--       -- must match the ID the owning RT node reports for this reactor.
--       reactor_id        = "node-52-reactor-0",
--       inlet             = "mekanism:ultimate_logistical_transporter_0",
--       item              = "bigreactors:yellorium_ingot",
--       request_below     = 0.25,  -- request when fuel_level < 25% of capacity
--       fill_amount       = 64,    -- how many items to export per request
--       min_in_me         = 32,    -- don't export if ME has fewer than this
--     },
--   },
--
--   -- Waste collection: drain waste output chests/transporters into ME.
--   waste = {
--     { name  = "Reactor A waste",
--       outlet = "mekanism:ultimate_logistical_transporter_1",
--     },
--   },

local M = {}
local redstone_router_lib = require("nodes.fuel.redstone_router")

local WASTE_PATTERNS = { "cyanite", "magentite", "rossinite", "waste" }

local function is_waste(name)
  local lower = tostring(name or ""):lower()
  for _, p in ipairs(WASTE_PATTERNS) do
    if lower:find(p, 1, true) then return true end
  end
  return false
end

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
      reactors      = {},   -- { name, label, reactor, inlet, item, cfg }
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

local function account_async_export(self, request, moved, move_line)
  if moved <= 0 then return end
  self._state.total_exported = self._state.total_exported + moved
  if request.cycle_log then request.cycle_log[#request.cycle_log + 1] = move_line end
  if request.cycle_result then
    request.cycle_result.exported = (request.cycle_result.exported or 0) + moved
  end
end

-- ---- peripheral discovery --------------------------------------------------

-- Sucht per Methodensignatur (getItem + exportItemToPeripheral +
-- importItemFromPeripheral), sobald der konfigurierte/Default-Name nicht
-- direkt gefunden wird -- Advanced Peripherals vergibt generierte Namen
-- wie "meBridge_0", nicht den Konventions-Default "me_bridge".
local function find_me_bridge_by_methods()
  for _, name in ipairs(peripheral.getNames() or {}) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      local set = {}
      for _, m in ipairs(methods) do set[m] = true end
      if set.getItem and set.exportItemToPeripheral and set.importItemFromPeripheral then
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

  -- Per-reactor entries
  local reactors = {}
  for i, entry in ipairs(cfg.reactors or {}) do
    local label = entry.name or ("Reactor " .. i)

    -- Kein Wired-Zugriff auf den Reaktor selbst -- nur die ID merken, unter
    -- der der zustaendige RT-Node ihn im Netzwerk meldet. entry.reactor_port
    -- (alt) wird als Fallback-Alias akzeptiert, aber kein Peripheral gewrapped.
    local reactor_id = entry.reactor_id or entry.reactor_port

    -- Inlet: dedicated transporter or chest for THIS reactor
    local inlet = nil
    if entry.inlet and peripheral.isPresent(entry.inlet) then
      local ok, w = pcall(peripheral.wrap, entry.inlet)
      if ok and w then
        inlet = { name = entry.inlet, wrapped = w,
                  is_transporter = is_transporter_name(entry.inlet)
                                or (entry.transporter == true) }
      else
        self.warn_once("inlet_wrap_" .. i,
          "Logistics: inlet wrap failed: " .. entry.inlet)
      end
    elseif entry.inlet then
      self.warn_once("inlet_absent_" .. i,
        "Logistics: inlet absent: " .. entry.inlet
        .. " (needs Wired Modem connection)")
    end

    reactors[#reactors + 1] = {
      label        = label,
      reactor_id   = reactor_id,
      inlet        = inlet,
      item         = entry.item or "",
      request_below = tonumber(entry.request_below) or 0.25,
      fill_amount  = tonumber(entry.fill_amount)   or 64,
      min_in_me    = tonumber(entry.min_in_me)     or 32,
      cfg          = entry,
    }
  end
  self._state.reactors = reactors

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

  -- Phase 1: ermitteln, WELCHE Reaktoren gerade Fuel anfordern, ohne sie
  -- schon zu beliefern. Alle anfordernden Reaktoren sammeln, dann nach
  -- Prioritaet sortieren (niedrigster Fuellstand zuerst). Reaktoren ohne
  -- reactor_id (Always-Supply-Fallback) werden nach allen bekannten
  -- Fuellstaenden eingeplant, da ihre Dringlichkeit nicht vergleichbar ist.
  local candidates = {}
  for _, r in ipairs(self._state.reactors) do
    if not r.inlet then
      self.warn_once("no_inlet:" .. r.label,
        "Logistics: no inlet configured for " .. r.label)
    elseif is_waste(r.item) then
      self.warn_once("waste_fuel:" .. r.item,
        "SAFETY BLOCK: item '" .. r.item .. "' is waste — cannot use as fuel supply")
    else
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
      if requesting then
        candidates[#candidates + 1] = { r = r, fuel_pct = fuel_pct, order = #candidates + 1 }
      end
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

    -- Check ME availability
    local me_info, _ = safe_call(bridge.wrapped, "getItem", { name = r.item })
    local in_me = type(me_info) == "table" and (me_info.amount or 0) or 0
    if in_me < r.min_in_me then
      self.log("DEBUG", string.format(
        "Logistics: %s: ME has %d %s (need >%d) — skip",
        r.label, in_me, r.item, r.min_in_me))
      goto continue
    end

    local push = math.min(r.fill_amount, in_me - r.min_in_me)
    if push <= 0 then goto continue end

    do
      local valve_ms = tonumber(cfg_l.valve_open_ms) or 2000
      local pct_str = fuel_pct and string.format(" (%.0f%%)", fuel_pct * 100) or ""
      local request = self._state.current_request
      request.transaction_id = request.transaction_id or next_delivery_id(self, r.label)

      if routed then
        local function do_export()
          request.phase = "EXPORTING"
          request.state = "delivering"
          local ok, result = pcall(bridge.wrapped.exportItemToPeripheral,
            { name = r.item, count = push }, r.inlet.name)
          if not ok then
            local err = tostring(result)
            self.warn_once("exp_err:" .. r.inlet.name,
              "exportItemToPeripheral → " .. r.inlet.name .. ": " .. err)
            account_async_error(self, request)
            request.error = err
            return false, err
          end
          local moved = type(result) == "number" and result or 0
          request.moved = moved
          request.exported_at = os.epoch and os.epoch("utc") or 0
          if moved > 0 then
            local move_line = string.format(
              "ME→[%s]%s %s x%d via %s", r.label, pct_str, r.item, moved, r.inlet.name)
            account_async_export(self, request, moved, move_line)
            self.log("INFO", string.format("ME→[%s]%s %s x%d via %s [tx=%s]",
              r.label, pct_str, r.item, moved, r.inlet.name, tostring(request.transaction_id)))
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

        local started, reason, router_tx_id = rs:begin_transaction(r.label, do_export, valve_ms, {
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
      local ok, result = pcall(bridge.wrapped.exportItemToPeripheral,
        { name = r.item, count = push }, r.inlet.name)
      if not ok then
        local err = tostring(result)
        self.warn_once("exp_err:" .. r.inlet.name,
          "exportItemToPeripheral → " .. r.inlet.name .. ": " .. err)
        errors = errors + 1
        request.error_counted = true
        finish_delivery(self, request, "ERROR", "EXPORT_FAILED", err)
      else
        local moved = type(result) == "number" and result or 0
        request.moved = moved
        if moved > 0 then
          exported = exported + moved
          cycle_log[#cycle_log + 1] = string.format(
            "ME→[%s]%s %s x%d via %s", r.label, pct_str, r.item, moved, r.inlet.name)
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
    local ok, result = pcall(bridge.wrapped.importItemFromPeripheral,
      {}, outlet.name)
    if not ok then
      -- Fallback: import item by item
      local items, _ = safe_call(outlet.wrapped, "list")
      if items then
        for _, stack in pairs(items) do
          if type(stack) == "table" and stack.name then
            local ok2, res2 = pcall(bridge.wrapped.importItemFromPeripheral,
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
      inlet         = r.inlet and r.inlet.name or nil,
      reactor_id    = r.reactor_id,
      connected     = r.reactor_id ~= nil and r.inlet ~= nil,
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
    reactors       = reactor_status,
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
