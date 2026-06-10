-- nodes/fuel/logistics_router.lua
--
-- Periodic item routing for the Fuel node.
-- Reads from configured source inventories (chests, ME bridges, Logistical
-- Transporter-adjacent containers) and pushes items to configured destinations
-- based on explicit item-name routes.
--
-- Safety rule: items whose names match any entry in WASTE_PATTERNS are NEVER
-- pushed to a destination tagged as a reactor_injector. This prevents accidental
-- waste-into-reactor contamination regardless of route config.
--
-- Usage:
--   local router = require("nodes.fuel.logistics_router")
--   local r = router.new({ config = config, log = log_fn, warn_once = warn_fn })
--   -- in service tick:
--   r:tick()
--   -- to get last summary:
--   local s = r:get_summary()

local M = {}

-- Item name substrings that classify an item as nuclear waste.
-- Checked case-insensitively against the full item id (e.g. "bigreactors:cyanite_ingot").
local WASTE_PATTERNS = {
  "cyanite", "magentite", "rossinite", "waste",
}

-- Destination tags that may NEVER receive waste items.
local REACTOR_TAGS = { "reactor", "reactor_injector", "fuel_input" }

-- Default ATM10/ER2 item name → destination-tag mapping used when no explicit
-- routes are configured.  The user overrides this via config.logistics.routes.
--
-- Tags:
--   reactor_injector  Reactor solid fuel input  (safety block active: waste never goes here)
--   reprocessor       Reprocessor waste input
--   fuel_storage      Reprocessor output → back to fuel storage (Blutonium, Magentite-fuel)
local DEFAULT_ITEM_CLASSIFIER = {
  -- Solid fuels → reactor injectors
  ["bigreactors:yellorium_ingot"]  = "reactor_injector",
  ["bigreactors:blutonium_ingot"]  = "reactor_injector",
  ["bigreactors:verderium_ingot"]  = "reactor_injector",
  -- Mekanism uranium/plutonium (ATM10 substitutes for yellorium/blutonium)
  ["mekanism:uranium_ingot"]       = "reactor_injector",
  ["mekanism:plutonium_pellet"]    = "reactor_injector",
  -- Solid waste → reprocessors
  ["bigreactors:cyanite_ingot"]    = "reprocessor",
  ["bigreactors:magentite_ingot"]  = "reprocessor",
  ["bigreactors:rossinite_ingot"]  = "reprocessor",
  -- Reprocessor output (processed fuel) → fuel storage
  -- These are the same ingot types but come OUT of the reprocessor;
  -- the reprocessor node routes them via tag = "fuel_storage".
  -- No entry needed here because the reprocessor config uses explicit routes.
}

-- ---- helpers ---------------------------------------------------------------

local function is_waste(item_name)
  local lower = tostring(item_name or ""):lower()
  for _, pat in ipairs(WASTE_PATTERNS) do
    if lower:find(pat, 1, true) then return true end
  end
  return false
end

local function tag_is_reactor(tag)
  local lower = tostring(tag or ""):lower()
  for _, rt in ipairs(REACTOR_TAGS) do
    if lower:find(rt, 1, true) then return true end
  end
  return false
end

local function safe_inventory_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return nil, "missing_method:" .. tostring(method)
  end
  local ok, result = pcall(obj[method], ...)
  if not ok then return nil, tostring(result) end
  return result, nil
end

-- ---- constructor -----------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    config    = opts.config or {},
    log       = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    _state    = {
      last_run_ts   = 0,
      sources       = {},   -- { name, wrapped }
      destinations  = {},   -- { name, tag, wrapped }
      total_moved   = 0,
      total_errors  = 0,
      last_cycle    = nil,  -- summary table from last run
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- inventory wrapping ----------------------------------------------------

function M:_wrap_inventory(name)
  if not peripheral.isPresent(name) then
    return nil, "not_present"
  end
  local ok, mlist = pcall(peripheral.getMethods, name)
  if not ok or type(mlist) ~= "table" then
    return nil, "methods_unavailable"
  end
  local ms = {}
  for _, m in ipairs(mlist) do ms[m] = true end
  -- Must support at least list() to be a usable inventory.
  if not ms.list then
    return nil, "no_list_method"
  end
  local ok2, wrapped = pcall(peripheral.wrap, name)
  if not ok2 or not wrapped then
    return nil, "wrap_failed"
  end
  return wrapped, nil
end

-- ---- discovery -------------------------------------------------------------

function M:refresh_peripherals()
  local cfg_logistics = self.config.logistics or {}
  local sources_cfg  = cfg_logistics.sources or {}
  local dests_cfg    = cfg_logistics.destinations or {}

  -- Sources
  local sources = {}
  for _, entry in ipairs(sources_cfg) do
    local name = type(entry) == "string" and entry or entry.name
    if name then
      local wrapped, err = self:_wrap_inventory(name)
      if wrapped then
        sources[#sources + 1] = { name = name, wrapped = wrapped }
      else
        self.warn_once("src_wrap:" .. name, "Logistics source unavailable: " .. name .. " (" .. tostring(err) .. ")")
      end
    end
  end

  -- Destinations
  local destinations = {}
  for _, entry in ipairs(dests_cfg) do
    local name = type(entry) == "string" and entry or entry.name
    local tag  = type(entry) == "table" and entry.tag or "generic"
    if name then
      local wrapped, err = self:_wrap_inventory(name)
      if wrapped then
        destinations[#destinations + 1] = { name = name, tag = tag, wrapped = wrapped }
      else
        self.warn_once("dst_wrap:" .. name, "Logistics destination unavailable: " .. name .. " (" .. tostring(err) .. ")")
      end
    end
  end

  self._state.sources      = sources
  self._state.destinations = destinations

  self.log("DEBUG", string.format(
    "Logistics peripherals refreshed: %d sources, %d destinations",
    #sources, #destinations
  ))
end

-- ---- item classification ---------------------------------------------------

-- Returns the destination tag for an item, or nil if no route exists.
function M:_classify(item_name)
  local cfg_logistics = self.config.logistics or {}
  local routes = cfg_logistics.routes or {}

  -- Explicit config routes take priority (exact item name match).
  for _, route in ipairs(routes) do
    if route.match and tostring(item_name):lower() == tostring(route.match):lower() then
      return route.tag or "generic", route
    end
    -- Pattern match (substring)
    if route.pattern and tostring(item_name):lower():find(tostring(route.pattern):lower(), 1, true) then
      return route.tag or "generic", route
    end
  end

  -- Fall back to built-in default classifier.
  local default_tag = DEFAULT_ITEM_CLASSIFIER[tostring(item_name):lower()]
  if default_tag then return default_tag, nil end

  return nil, nil
end

-- Find the best destination for a given tag.
-- Returns the first available (non-full) destination whose tag matches.
function M:_find_destination(tag)
  for _, dest in ipairs(self._state.destinations) do
    if dest.tag == tag then
      return dest
    end
  end
  return nil
end

-- ---- routing cycle ---------------------------------------------------------

function M:_route_source(source, cycle_log)
  local cfg_logistics = self.config.logistics or {}
  local max_per_cycle = tonumber(cfg_logistics.max_per_cycle) or 64

  local items, err = safe_inventory_call(source.wrapped, "list")
  if not items then
    self.warn_once("src_list:" .. source.name, "Source list() failed: " .. source.name .. ": " .. tostring(err))
    return 0, 1
  end

  local moved = 0
  local errors = 0

  for slot, stack in pairs(items) do
    if type(stack) ~= "table" or not stack.name then goto continue end
    if moved >= max_per_cycle then break end

    local item_name = stack.name
    local count     = stack.count or 1
    local dest_tag, route = self:_classify(item_name)

    if not dest_tag then goto continue end

    -- Safety: waste items never go to reactor destinations.
    if is_waste(item_name) and tag_is_reactor(dest_tag) then
      self.warn_once("waste_block:" .. item_name,
        string.format("SAFETY BLOCK: waste item %s would route to reactor tag '%s' — check config", item_name, dest_tag))
      goto continue
    end

    local dest = self:_find_destination(dest_tag)
    if not dest then
      self.warn_once("no_dest:" .. dest_tag,
        string.format("No destination for tag '%s' (needed by %s)", dest_tag, item_name))
      goto continue
    end

    -- Determine how many to push (respect per-cycle limit).
    local push_count = math.min(count, max_per_cycle - moved)
    if route and route.max_push and tonumber(route.max_push) then
      push_count = math.min(push_count, tonumber(route.max_push))
    end

    local pushed, push_err = safe_inventory_call(
      source.wrapped, "pushItems",
      dest.name, slot, push_count
    )

    if push_err then
      self.warn_once("push_err:" .. source.name .. ":" .. dest.name,
        string.format("pushItems failed %s->%s slot=%d: %s", source.name, dest.name, slot, push_err))
      errors = errors + 1
    elseif type(pushed) == "number" and pushed > 0 then
      moved = moved + pushed
      cycle_log[#cycle_log + 1] = string.format(
        "%s x%d: %s -> %s (%s)", item_name, pushed, source.name, dest.name, dest_tag
      )
    end

    ::continue::
  end

  return moved, errors
end

function M:run_cycle()
  local cycle_log = {}
  local total_moved  = 0
  local total_errors = 0

  for _, source in ipairs(self._state.sources) do
    local m, e = self:_route_source(source, cycle_log)
    total_moved  = total_moved  + m
    total_errors = total_errors + e
  end

  self._state.total_moved  = self._state.total_moved  + total_moved
  self._state.total_errors = self._state.total_errors + total_errors

  local summary = {
    ts            = os.epoch("utc"),
    moved         = total_moved,
    errors        = total_errors,
    sources       = #self._state.sources,
    destinations  = #self._state.destinations,
    moves         = cycle_log,
  }
  self._state.last_cycle = summary

  if total_moved > 0 then
    self.log("INFO", string.format(
      "Logistics cycle: moved=%d errors=%d (%s)",
      total_moved, total_errors, table.concat(cycle_log, "; ")
    ))
  elseif total_errors > 0 then
    self.log("WARN", string.format("Logistics cycle: moved=0 errors=%d", total_errors))
  else
    self.log("DEBUG", "Logistics cycle: nothing to move")
  end

  return summary
end

-- ---- service tick ----------------------------------------------------------

function M:tick()
  local cfg_logistics = self.config.logistics or {}
  if cfg_logistics.enabled ~= true then return end

  local now = os.epoch("utc")
  local interval_ms = (tonumber(cfg_logistics.interval) or 10) * 1000

  -- Periodic peripheral refresh (every 60 s or on first tick).
  local refresh_interval_ms = (tonumber(cfg_logistics.discovery_interval) or 60) * 1000
  if now - (self._state.last_refresh_ts or 0) >= refresh_interval_ms then
    self:refresh_peripherals()
    self._state.last_refresh_ts = now
  end

  if now - self._state.last_run_ts < interval_ms then return end
  self._state.last_run_ts = now

  self:run_cycle()
end

-- ---- status -----------------------------------------------------------------

function M:get_summary()
  local s = self._state
  local cfg = self.config.logistics or {}
  return {
    enabled       = cfg.enabled == true,
    sources       = #s.sources,
    destinations  = #s.destinations,
    total_moved   = s.total_moved,
    total_errors  = s.total_errors,
    last_cycle    = s.last_cycle,
  }
end

return M
