-- nodes/fuel/logistics_router.lua
--
-- Item logistics router for Fuel and Reprocessor nodes.
-- Handles two peripheral types with different APIs:
--
--   "me_bridge"  Advanced Peripherals ME Bridge (me_bridge / meBridge)
--                  source → dest:  bridge.exportItemToPeripheral(item, destName)
--                  dest ← source:  bridge.importItemFromPeripheral(item, srcName)
--                  list:           bridge.listItems()  → {name, amount, ...}
--
--   "inventory"  Standard CC inventory (chests, injectors, reprocessor I/O)
--                  source → dest:  src.pushItems(destName, slot, count)
--                  list:           src.list()          → {[slot]={name, count}}
--
-- Route rules (config.logistics.routes):
--   { match = "exact:item:name", from = "me_bridge", to = "reactor_injector" }
--   { pattern = "cyanite",       from = "reactor_output", to = "me_bridge" }
--
-- SAFETY: items matching WASTE_PATTERNS are NEVER exported to a destination
-- whose tag is "reactor_injector", regardless of config.
--
-- Usage:
--   local router = require("nodes.fuel.logistics_router")
--   local r = router.new({ config = config, log = fn, warn_once = fn })
--   -- in service loop:
--   r:tick()
--   local summary = r:get_summary()

local M = {}

-- Hard-coded waste patterns — checked case-insensitively against item name.
local WASTE_PATTERNS = { "cyanite", "magentite", "rossinite", "waste" }

-- Tags where waste must never go.
local REACTOR_TAGS = { "reactor_injector", "fuel_input" }

-- Built-in item → destination-tag mapping for ATM10 / ER2.
-- The user can override or extend via config.logistics.routes.
local DEFAULT_ROUTES = {
  -- Fuel ingots: ME → reactor injector
  ["bigreactors:yellorium_ingot"]  = { from = "me", to = "reactor_injector" },
  ["bigreactors:blutonium_ingot"]  = { from = "me", to = "reactor_injector" },
  ["bigreactors:verderium_ingot"]  = { from = "me", to = "reactor_injector" },
  ["mekanism:uranium_ingot"]       = { from = "me", to = "reactor_injector" },
  ["mekanism:plutonium_pellet"]    = { from = "me", to = "reactor_injector" },
  -- Waste: reactor output → ME
  ["bigreactors:cyanite_ingot"]    = { from = "reactor_output", to = "me" },
  ["bigreactors:magentite_ingot"]  = { from = "reactor_output", to = "me" },
  ["bigreactors:rossinite_ingot"]  = { from = "reactor_output", to = "me" },
}

-- ---- helpers ----------------------------------------------------------------

local function is_waste(name)
  local lower = tostring(name or ""):lower()
  for _, p in ipairs(WASTE_PATTERNS) do
    if lower:find(p, 1, true) then return true end
  end
  return false
end

local function tag_is_reactor(tag)
  for _, t in ipairs(REACTOR_TAGS) do
    if tostring(tag or ""):lower():find(t, 1, true) then return true end
  end
  return false
end

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return nil, "no_method:" .. tostring(method)
  end
  local ok, result = pcall(obj[method], ...)
  if not ok then return nil, tostring(result) end
  return result, nil
end

-- Detect peripheral type: "me_bridge" or "inventory"
local function detect_ptype(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then return nil end
  local ms = {}
  for _, m in ipairs(methods) do ms[m] = true end
  if ms.exportItemToPeripheral or ms.importItemFromPeripheral or ms.listItems then
    return "me_bridge"
  end
  if ms.list then
    return "inventory"
  end
  return nil
end

-- ---- constructor ------------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    config    = opts.config or {},
    log       = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    _state = {
      sources       = {},
      destinations  = {},
      me_bridges    = {},  -- all known ME bridges (can be source AND dest)
      total_moved   = 0,
      total_errors  = 0,
      last_cycle    = nil,
      last_refresh  = 0,
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- peripheral discovery ---------------------------------------------------

function M:refresh_peripherals()
  local cfg = self.config.logistics or {}
  local sources_cfg = cfg.sources or {}
  local dests_cfg   = cfg.destinations or {}

  local function wrap_entry(entry)
    local name = type(entry) == "string" and entry or (type(entry) == "table" and entry.name)
    local tag  = (type(entry) == "table" and entry.tag) or "generic"
    if not name or not peripheral.isPresent(name) then
      self.warn_once("absent:" .. tostring(name), "Logistics peripheral absent: " .. tostring(name))
      return nil
    end
    local ptype = detect_ptype(name)
    if not ptype then
      self.warn_once("notype:" .. name, "Cannot determine type for peripheral: " .. name)
      return nil
    end
    local ok, wrapped = pcall(peripheral.wrap, name)
    if not ok or not wrapped then
      self.warn_once("wrap:" .. name, "Failed to wrap peripheral: " .. name)
      return nil
    end
    return { name = name, tag = tag, ptype = ptype, wrapped = wrapped }
  end

  local sources, dests, bridges = {}, {}, {}
  for _, e in ipairs(sources_cfg) do
    local p = wrap_entry(e)
    if p then
      sources[#sources + 1] = p
      if p.ptype == "me_bridge" then bridges[p.name] = p end
    end
  end
  for _, e in ipairs(dests_cfg) do
    local p = wrap_entry(e)
    if p then
      dests[#dests + 1] = p
      if p.ptype == "me_bridge" then bridges[p.name] = p end
    end
  end

  self._state.sources      = sources
  self._state.destinations = dests
  self._state.me_bridges   = bridges

  self.log("DEBUG", string.format(
    "Logistics: %d sources, %d destinations (%d ME bridges)",
    #sources, #dests, (function() local n=0 for _ in pairs(bridges) do n=n+1 end return n end)()
  ))
end

-- ---- item classification ----------------------------------------------------

-- Returns matching route config entry or nil.
function M:_match_route(item_name)
  local cfg = self.config.logistics or {}
  local routes = cfg.routes or {}
  local lower = tostring(item_name):lower()

  for _, r in ipairs(routes) do
    if r.match and lower == tostring(r.match):lower() then return r end
    if r.pattern and lower:find(tostring(r.pattern):lower(), 1, true) then return r end
  end

  -- Fall back to built-in table.
  local builtin = DEFAULT_ROUTES[lower]
  if builtin then return builtin end

  return nil
end

-- ---- destination lookup -----------------------------------------------------

-- Find a destination peripheral by tag.
function M:_find_dest(tag)
  for _, d in ipairs(self._state.destinations) do
    if d.tag == tag then return d end
  end
  return nil
end

-- Find a source peripheral by tag.
function M:_find_source(tag)
  for _, s in ipairs(self._state.sources) do
    if s.tag == tag then return s end
  end
  return nil
end

-- ---- move helpers -----------------------------------------------------------

-- ME Bridge → inventory: exportItemToPeripheral
local function me_to_inventory(bridge, item_name, count, dest_name, cycle_log, log_fn, warn_fn)
  local ok_v, result = pcall(bridge.wrapped.exportItemToPeripheral,
    { name = item_name, count = count }, dest_name)
  if not ok_v then
    warn_fn("me_exp:" .. dest_name, "exportItemToPeripheral failed -> " .. dest_name .. ": " .. tostring(result))
    return 0, 1
  end
  local moved = type(result) == "number" and result or 0
  if moved > 0 then
    cycle_log[#cycle_log + 1] = string.format("ME→%s %s x%d", dest_name, item_name, moved)
  end
  return moved, 0
end

-- Inventory → ME Bridge: importItemFromPeripheral
local function inventory_to_me(bridge, item_name, count, src_name, cycle_log, log_fn, warn_fn)
  local ok_v, result = pcall(bridge.wrapped.importItemFromPeripheral,
    { name = item_name, count = count }, src_name)
  if not ok_v then
    warn_fn("me_imp:" .. src_name, "importItemFromPeripheral failed from " .. src_name .. ": " .. tostring(result))
    return 0, 1
  end
  local moved = type(result) == "number" and result or 0
  if moved > 0 then
    cycle_log[#cycle_log + 1] = string.format("%s→ME %s x%d", src_name, item_name, moved)
  end
  return moved, 0
end

-- Inventory → Inventory: pushItems
local function inventory_to_inventory(src, count, slot, dest_name, item_name, cycle_log, warn_fn)
  local ok_v, result = pcall(src.wrapped.pushItems, dest_name, slot, count)
  if not ok_v then
    warn_fn("inv_push:" .. dest_name, "pushItems failed: " .. tostring(result))
    return 0, 1
  end
  local moved = type(result) == "number" and result or 0
  if moved > 0 then
    cycle_log[#cycle_log + 1] = string.format("%s→%s %s x%d", src.name, dest_name, item_name, moved)
  end
  return moved, 0
end

-- ---- routing cycle ----------------------------------------------------------

function M:_process_me_source(src, cycle_log)
  -- Source is an ME Bridge: listItems → match → exportItemToPeripheral to dest
  local cfg = self.config.logistics or {}
  local max = tonumber(cfg.max_per_cycle) or 64
  local items, err = safe_call(src.wrapped, "listItems")
  if not items then
    self.warn_once("me_list:" .. src.name, "listItems failed: " .. tostring(err))
    return 0, 1
  end

  local moved_total, errors_total = 0, 0
  for _, stack in pairs(type(items) == "table" and items or {}) do
    if moved_total >= max then break end
    if type(stack) ~= "table" or not stack.name then goto continue end

    local item_name = stack.name
    local available = stack.amount or 0
    if available <= 0 then goto continue end

    local route = self:_match_route(item_name)
    if not route then goto continue end

    -- Safety: waste never goes to reactor
    if is_waste(item_name) and tag_is_reactor(route.to or "") then
      self.warn_once("waste_block:" .. item_name,
        "SAFETY BLOCK: waste " .. item_name .. " would route to reactor tag '" .. tostring(route.to) .. "'")
      goto continue
    end

    local dest = self:_find_dest(route.to or "")
    if not dest then
      self.warn_once("no_dest:" .. tostring(route.to),
        "No destination for tag '" .. tostring(route.to) .. "' (needed by " .. item_name .. ")")
      goto continue
    end

    local push = math.min(available, max - moved_total)
    if route.max_push then push = math.min(push, tonumber(route.max_push) or push) end

    local m, e = me_to_inventory(src, item_name, push, dest.name, cycle_log,
      self.log, self.warn_once)
    moved_total = moved_total + m
    errors_total = errors_total + e

    ::continue::
  end
  return moved_total, errors_total
end

function M:_process_inventory_source(src, cycle_log)
  -- Source is a standard inventory: list → match → push to dest or ME
  local cfg = self.config.logistics or {}
  local max = tonumber(cfg.max_per_cycle) or 64
  local items, err = safe_call(src.wrapped, "list")
  if not items then
    self.warn_once("inv_list:" .. src.name, "list() failed: " .. tostring(err))
    return 0, 1
  end

  local moved_total, errors_total = 0, 0
  for slot, stack in pairs(type(items) == "table" and items or {}) do
    if moved_total >= max then break end
    if type(stack) ~= "table" or not stack.name then goto continue end

    local item_name = stack.name
    local count = stack.count or 1

    local route = self:_match_route(item_name)
    if not route then goto continue end

    if is_waste(item_name) and tag_is_reactor(route.to or "") then
      self.warn_once("waste_block:" .. item_name,
        "SAFETY BLOCK: waste " .. item_name .. " → reactor tag '" .. tostring(route.to) .. "'")
      goto continue
    end

    local push = math.min(count, max - moved_total)
    if route.max_push then push = math.min(push, tonumber(route.max_push) or push) end

    -- Destination is ME Bridge?
    local dest_tag = route.to or ""
    local dest = self:_find_dest(dest_tag)
    if dest and dest.ptype == "me_bridge" then
      -- inv → ME
      local m, e = inventory_to_me(dest, item_name, push, src.name, cycle_log,
        self.log, self.warn_once)
      moved_total = moved_total + m
      errors_total = errors_total + e
    elseif dest then
      -- inv → inv
      local m, e = inventory_to_inventory(src, push, slot, dest.name, item_name,
        cycle_log, self.warn_once)
      moved_total = moved_total + m
      errors_total = errors_total + e
    else
      self.warn_once("no_dest:" .. dest_tag,
        "No destination for tag '" .. dest_tag .. "' (needed by " .. item_name .. ")")
    end

    ::continue::
  end
  return moved_total, errors_total
end

function M:run_cycle()
  local cycle_log = {}
  local total_moved, total_errors = 0, 0

  for _, src in ipairs(self._state.sources) do
    local m, e
    if src.ptype == "me_bridge" then
      m, e = self:_process_me_source(src, cycle_log)
    else
      m, e = self:_process_inventory_source(src, cycle_log)
    end
    total_moved  = total_moved  + m
    total_errors = total_errors + e
  end

  self._state.total_moved  = self._state.total_moved  + total_moved
  self._state.total_errors = self._state.total_errors + total_errors

  local summary = {
    ts    = os.epoch("utc"),
    moved = total_moved, errors = total_errors,
    sources = #self._state.sources,
    destinations = #self._state.destinations,
    moves = cycle_log,
  }
  self._state.last_cycle = summary

  if total_moved > 0 then
    self.log("INFO", string.format("Logistics: moved=%d errors=%d (%s)",
      total_moved, total_errors, table.concat(cycle_log, "; ")))
  elseif total_errors > 0 then
    self.log("WARN", "Logistics: moved=0 errors=" .. total_errors)
  else
    self.log("DEBUG", "Logistics: nothing to move")
  end
  return summary
end

-- ---- service tick -----------------------------------------------------------

function M:tick()
  local cfg = self.config.logistics or {}
  if cfg.enabled ~= true then return end

  local now = os.epoch("utc")
  local refresh_ms = (tonumber(cfg.discovery_interval) or 60) * 1000
  if now - self._state.last_refresh >= refresh_ms then
    self:refresh_peripherals()
    self._state.last_refresh = now
  end

  local interval_ms = (tonumber(cfg.interval) or 10) * 1000
  if now - (self._state.last_run_ts or 0) < interval_ms then return end
  self._state.last_run_ts = now
  self:run_cycle()
end

-- ---- status -----------------------------------------------------------------

function M:get_summary()
  local s = self._state
  local cfg = self.config.logistics or {}
  return {
    enabled      = cfg.enabled == true,
    sources      = #s.sources,
    destinations = #s.destinations,
    total_moved  = s.total_moved,
    total_errors = s.total_errors,
    last_cycle   = s.last_cycle,
  }
end

return M
