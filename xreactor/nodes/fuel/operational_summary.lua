-- nodes/fuel/operational_summary.lua
-- Read-only operational projection for the FUEL UI/status payload.
--
-- IMPORTANT: this module does not make delivery decisions and never writes
-- peripherals/config. It derives display/diagnostic state from the existing
-- logistics summary, fuel-status cache and redstone router state.

local M = {}

local function newest_fuel_entry(cache, reactor_id)
  if type(cache) ~= "table" or reactor_id == nil then return nil, nil end
  local best, best_source = nil, nil
  local sources = {
    { name = "MASTER", values = cache.master_relay },
    { name = "DIRECT", values = cache.direct_heard },
  }
  for _, source in ipairs(sources) do
    local entry = type(source.values) == "table" and source.values[reactor_id] or nil
    if type(entry) == "table" and type(entry.ts) == "number" then
      if not best or entry.ts > best.ts then
        best, best_source = entry, source.name
      end
    end
  end
  return best, best_source
end

local function config_for(config, reactor)
  local lg = type(config) == "table" and config.logistics or nil
  for _, entry in ipairs(type(lg) == "table" and lg.reactors or {}) do
    local rid = entry.reactor_id or entry.reactor_port
    local label = entry.name or entry.label
    if (rid ~= nil and reactor.reactor_id ~= nil and tostring(rid) == tostring(reactor.reactor_id))
        or (label ~= nil and reactor.label ~= nil and tostring(label) == tostring(reactor.label)) then
      return entry
    end
  end
  return {}
end

local function route_context(rs_router)
  if type(rs_router) ~= "table" then
    return { state = "ROUTING_NOT_CONFIGURED", routes = {}, valves = {} }
  end

  local state = "ROUTING_NOT_CONFIGURED"
  if type(rs_router.get_routing_state) == "function" then
    local ok, value = pcall(rs_router.get_routing_state, rs_router)
    if ok and type(value) == "string" then state = value end
  end

  local routes = {}
  if type(rs_router.get_tree) == "function" then
    local ok, value = pcall(rs_router.get_tree, rs_router)
    if ok and type(value) == "table" then routes = value end
  end

  local valves = {}
  if type(rs_router.get_valve_status) == "function" then
    local ok, value = pcall(rs_router.get_valve_status, rs_router)
    if ok and type(value) == "table" then
      for _, valve in ipairs(value) do
        if type(valve) == "table" and valve.id ~= nil then valves[tostring(valve.id)] = valve end
      end
    end
  end

  return { state = state, routes = routes, valves = valves }
end

local function find_route(ctx, reactor)
  -- redstone_router:begin_transaction() is called with the logistics label,
  -- so label matching is primary. reactor_id is accepted as a compatibility
  -- fallback for manually authored routes.
  local targets = {}
  if reactor.label ~= nil then targets[tostring(reactor.label)] = true end
  if reactor.reactor_id ~= nil then targets[tostring(reactor.reactor_id)] = true end
  for _, route in ipairs(ctx.routes or {}) do
    if type(route) == "table" then
      if route.reactor ~= nil and targets[tostring(route.reactor)] then return route end
      if route.label ~= nil and targets[tostring(route.label)] then return route end
    end
  end
  return nil
end

local function route_state(ctx, reactor)
  if ctx.state == "ROUTING_NOT_CONFIGURED" then return "DIRECT" end
  if ctx.state == "ROUTING_INVALID" then return "ROUTING_INVALID" end
  if ctx.state == "ROUTING_REQUIRED_BUT_EMPTY" then return "ROUTING_REQUIRED_BUT_EMPTY" end
  if ctx.state ~= "ROUTING_VALID" then return tostring(ctx.state or "ROUTING_UNKNOWN") end

  local route = find_route(ctx, reactor)
  if not route then return "ROUTE_MISSING" end
  for _, step in ipairs(route.path or {}) do
    if type(step) == "table" and step.integrator ~= nil then
      local valve = ctx.valves[tostring(step.integrator)]
      if not valve or valve.online ~= true then return "VALVE_OFFLINE" end
      if valve.stale == true then return "VALVE_STALE" end
    end
  end
  return "ROUTE_READY"
end

local function request_matches(request, reactor)
  if type(request) ~= "table" then return false end
  if request.reactor_id ~= nil and reactor.reactor_id ~= nil
      and tostring(request.reactor_id) == tostring(reactor.reactor_id) then return true end
  if request.label ~= nil and reactor.label ~= nil
      and tostring(request.label) == tostring(reactor.label) then return true end
  return false
end

local function blocked_route(state)
  return state ~= "DIRECT" and state ~= "ROUTE_READY"
end

function M.enrich(summary, opts)
  summary = type(summary) == "table" and summary or {}
  opts = opts or {}
  summary.reactors = type(summary.reactors) == "table" and summary.reactors or {}

  local now = tonumber(opts.now_ms) or (os.epoch and os.epoch("utc") or 0)
  local route_ctx = route_context(opts.rs_router)
  local counts = { configured = 0, ready = 0, blocked = 0, stale = 0, missing = 0 }
  local fuel_counts = { fresh = 0, stale = 0, missing = 0 }

  for _, reactor in ipairs(summary.reactors) do
    if type(reactor) == "table" then
      counts.configured = counts.configured + 1
      local cfg = config_for(opts.config, reactor)
      local entry, source = newest_fuel_entry(opts.fuel_status, reactor.reactor_id)
      local valid_entry = entry
        and type(entry.fuel_amount) == "number"
        and type(entry.fuel_capacity) == "number"
        and entry.fuel_capacity > 0

      if type(reactor.fuel_pct) == "number" then
        reactor.fuel_data_state = "FRESH"
      elseif valid_entry then
        -- logistics_router:get_summary() only exposes fuel_pct when its own
        -- canonical freshness check accepts the sample. A numeric cached
        -- sample with fuel_pct=nil is therefore stale, without duplicating
        -- the router's 30s threshold here.
        reactor.fuel_data_state = "STALE"
      else
        reactor.fuel_data_state = "MISSING"
      end

      if reactor.fuel_data_state == "FRESH" then fuel_counts.fresh = fuel_counts.fresh + 1
      elseif reactor.fuel_data_state == "STALE" then fuel_counts.stale = fuel_counts.stale + 1
      else fuel_counts.missing = fuel_counts.missing + 1 end

      reactor.fuel_source = source
      reactor.fuel_age_s = entry and math.max(0, math.floor((now - entry.ts) / 1000)) or nil
      reactor.fuel_amount = valid_entry and entry.fuel_amount or nil
      reactor.fuel_capacity = valid_entry and entry.fuel_capacity or nil

      reactor.configured_inlet = cfg.inlet
      reactor.item = cfg.item
      reactor.request_below = tonumber(cfg.request_below)
      reactor.fill_amount = tonumber(cfg.fill_amount)
      reactor.min_in_me = tonumber(cfg.min_in_me)

      reactor.route_state = route_state(route_ctx, reactor)

      if summary.enabled ~= true or summary.bridge == nil or reactor.connected ~= true or blocked_route(reactor.route_state) then
        reactor.operational_state = "BLOCKED"
        counts.blocked = counts.blocked + 1
      elseif reactor.fuel_data_state == "STALE" then
        reactor.operational_state = "STALE"
        counts.stale = counts.stale + 1
      elseif reactor.fuel_data_state == "MISSING" then
        reactor.operational_state = "MISSING"
        counts.missing = counts.missing + 1
      else
        reactor.operational_state = "READY"
        counts.ready = counts.ready + 1
      end

      if request_matches(summary.current_request, reactor) then
        reactor.delivery_state = "DELIVERING"
      elseif reactor.operational_state == "READY" and reactor.request_below
          and type(reactor.fuel_pct) == "number" and reactor.fuel_pct < reactor.request_below * 100 then
        reactor.delivery_state = "REQUESTING"
      else
        reactor.delivery_state = reactor.operational_state
      end
    end
  end

  summary.routing_state = route_ctx.state
  summary.operational_counts = counts
  summary.fuel_data_summary = fuel_counts
  return summary
end

return M
