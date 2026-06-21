-- nodes/fuel/logistics_router.lua
--
-- Demand-driven, per-reactor fuel supply management.
--
-- Core principle: ONLY the reactor that has requested fuel receives it.
-- No broadcast, no shared distribution, no accidental cross-supply.
--
-- How it works:
--   1. Each reactor has its own entry in config.logistics.reactors.
--   2. Every cycle: FUEL node reads getFuelAmount()/getFuelStats() directly
--      from the reactor's computer port peripheral (via Wired Modem).
--   3. If fuel_level / capacity < request_below → that reactor requests fuel.
--   4. ME Bridge exports exactly the calculated amount to that reactor's
--      dedicated inlet peripheral (transporter or chest).
--   5. No other reactor is affected.
--
-- Hardware requirements:
--   - Wired Modem on the FUEL computer, connected to:
--       • Each reactor's ER2 Computer Port  (for fuel level polling)
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
--       reactor_port      = "BigReactors-Reactor_0",  -- ER2 computer port peripheral
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

-- ---- reactor fuel level reading --------------------------------------------

-- Read current fuel amount and capacity from an ER2 reactor computer port.
-- Returns: fuel_amount (mB), capacity (mB) or nil, nil on failure.
local function read_reactor_fuel(reactor_wrapped)
  -- Try getFuelStats() first (single call, returns table)
  local stats, _ = safe_call(reactor_wrapped, "getFuelStats")
  if type(stats) == "table" then
    local amount   = type(stats.fuelAmount)   == "number" and stats.fuelAmount   or nil
    local capacity = type(stats.fuelCapacity) == "number" and stats.fuelCapacity or nil
    if amount and capacity then return amount, capacity end
  end
  -- Fallback: individual calls (ER2 Reactor)
  local amount,   _ = safe_call(reactor_wrapped, "getFuelAmount")
  local capacity, _ = safe_call(reactor_wrapped, "getFuelAmountMax")
  if type(amount) == "number" and type(capacity) == "number" then
    return amount, capacity
  end
  -- Generisches Sicherheitsnetz: falls ein reactor_port auf ein Peripheral
  -- mit Waste- statt Fuel-API zeigt. NICHT für den Reprocessor gedacht —
  -- der hat seit nodes/reprocessor/feed_router.lua einen eigenen Versorgungs-
  -- weg ohne reactor_port und ohne Füllstand-Check (random-Intervall-
  -- Befüllung, siehe feed_router.lua). Dieser Router hier wird aktuell
  -- nur von der Fuel-Node genutzt.
  local waste,     _ = safe_call(reactor_wrapped, "getWaste")
  local max_waste, _ = safe_call(reactor_wrapped, "getMaxWaste")
  if type(waste) == "number" and type(max_waste) == "number" then
    return waste, max_waste
  end
  return nil, nil
end

-- ---- constructor -----------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    config    = opts.config or {},
    log       = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    external_rs_router = opts.rs_router or nil,  -- shared rs_router injected from main.lua
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
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- peripheral discovery --------------------------------------------------

function M:refresh_peripherals()
  local cfg = self.config.logistics or self.config or {}

  -- ME Bridge
  local bridge_name = cfg.me_bridge or "me_bridge"
  self._state.bridge = nil
  if peripheral.isPresent(bridge_name) then
    local ok, w = pcall(peripheral.wrap, bridge_name)
    if ok and w then
      self._state.bridge = { name = bridge_name, wrapped = w }
      self.log("DEBUG", "Logistics: ME Bridge: " .. bridge_name)
    else
      self.warn_once("bridge_wrap", "Logistics: ME Bridge wrap failed: " .. bridge_name)
    end
  else
    self.warn_once("bridge_absent", "Logistics: ME Bridge absent: " .. bridge_name)
  end

  -- Per-reactor entries
  local reactors = {}
  for i, entry in ipairs(cfg.reactors or {}) do
    local label = entry.name or ("Reactor " .. i)

    -- Reactor computer port (for fuel level polling)
    local reactor_port = nil
    if entry.reactor_port and peripheral.isPresent(entry.reactor_port) then
      local ok, w = pcall(peripheral.wrap, entry.reactor_port)
      if ok and w then
        reactor_port = { name = entry.reactor_port, wrapped = w }
      else
        self.warn_once("reactor_wrap_" .. i,
          "Logistics: reactor port wrap failed: " .. entry.reactor_port)
      end
    elseif entry.reactor_port then
      self.warn_once("reactor_absent_" .. i,
        "Logistics: reactor port absent: " .. entry.reactor_port
        .. " (needs Wired Modem connection)")
    end

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
      reactor      = reactor_port,
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
  local exported, errors = 0, 0

  for _, r in ipairs(self._state.reactors) do
    if not r.inlet then
      self.warn_once("no_inlet:" .. r.label,
        "Logistics: no inlet configured for " .. r.label)
      goto continue
    end

    -- Safety: fuel item must not be waste
    if is_waste(r.item) then
      self.warn_once("waste_fuel:" .. r.item,
        "SAFETY BLOCK: item '" .. r.item .. "' is waste — cannot use as fuel supply")
      goto continue
    end

    -- Determine if this reactor is requesting fuel
    local requesting = false
    local fuel_pct = nil

    if r.reactor then
      -- Direct reading via Wired Modem: most accurate
      local fuel_amt, capacity = read_reactor_fuel(r.reactor.wrapped)
      if fuel_amt and capacity and capacity > 0 then
        fuel_pct = fuel_amt / capacity
        requesting = fuel_pct < r.request_below
        self.log("DEBUG", string.format(
          "Logistics: %s fuel=%.1f%% (%.0f/%.0f mB) request=%s",
          r.label, fuel_pct * 100, fuel_amt, capacity,
          requesting and "YES" or "no"))
      else
        -- Reactor port present but can't read level → be conservative, skip
        self.warn_once("fuel_read_fail:" .. r.label,
          "Logistics: cannot read fuel level for " .. r.label .. " — skipping")
        goto continue
      end
    else
      -- No reactor_port configured: fall back to always-supply mode (fill inlet)
      -- This is less precise but works without direct peripheral access.
      requesting = true
      self.log("DEBUG", "Logistics: " .. r.label
        .. " has no reactor_port — using always-supply mode")
    end

    if not requesting then goto continue end

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

    local cfg_l = self.config.logistics or self.config or {}
    local rs    = self._state.rs_router
    local valve_ms = tonumber(cfg_l.valve_open_ms) or 2000

    local moved = 0
    local exp_ok = false

    local function do_export()
      local ok, result = pcall(bridge.wrapped.exportItemToPeripheral,
        { name = r.item, count = push }, r.inlet.name)
      if not ok then
        self.warn_once("exp_err:" .. r.inlet.name,
          "exportItemToPeripheral → " .. r.inlet.name .. ": " .. tostring(result))
        errors = errors + 1
      else
        moved   = type(result) == "number" and result or 0
        exp_ok  = true
      end
    end

    if rs and rs:route_count() > 0 then
      -- Redstone routing: open valve for THIS reactor, block all others
      rs:route_and_act(r.label, do_export, valve_ms)
    else
      -- No redstone routing configured: export directly
      do_export()
    end

    if exp_ok and moved > 0 then
      exported = exported + moved
      local pct_str = fuel_pct and string.format(" (%.0f%%)", fuel_pct * 100) or ""
      cycle_log[#cycle_log + 1] = string.format(
        "ME→[%s]%s %s x%d via %s",
        r.label, pct_str, r.item, moved, r.inlet.name)
    end

    ::continue::
  end
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
    if r.reactor then
      local amt, cap = read_reactor_fuel(r.reactor.wrapped)
      if amt and cap and cap > 0 then fuel_pct = math.floor(amt / cap * 100) end
    end
    reactor_status[#reactor_status + 1] = {
      label         = r.label,
      fuel_pct      = fuel_pct,
      inlet         = r.inlet and r.inlet.name or nil,
      reactor_port  = r.reactor and r.reactor.name or nil,
      connected     = r.reactor ~= nil and r.inlet ~= nil,
    }
  end
  return {
    enabled        = cfg.enabled == true,
    bridge         = s.bridge and s.bridge.name or nil,
    reactors       = reactor_status,
    waste_outlets  = #s.waste_outlets,
    total_exported = s.total_exported,
    total_imported = s.total_imported,
    total_errors   = s.total_errors,
    last_cycle     = s.last_cycle,
  }
end

return M
