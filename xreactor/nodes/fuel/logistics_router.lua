-- nodes/fuel/logistics_router.lua
--
-- Item logistics router for Fuel and Reprocessor nodes.
--
-- Physical setup (per node):
--
--   ME Bridge ─── exportItemToPeripheral ──► buffer chest ─── Mekanism pipes ──► target
--   ME Bridge ◄── importItemFromPeripheral── buffer chest ◄── Mekanism pipes ─── source
--                (or AE2 Import Bus handles the return trip without CC involvement)
--
-- The CC computer only interacts with:
--   - The ME Bridge  (Advanced Peripherals: me_bridge / meBridge)
--   - The buffer chest  (standard Minecraft inventory)
--
-- Mekanism Logistical Transporters (or other pipes) handle the physical
-- movement between chest and reactor/reprocessor. CC does not interact
-- with those pipes directly.
--
-- ME Bridge API (Advanced Peripherals):
--   exportItemToPeripheral(item, containerName) → number moved
--   importItemFromPeripheral(item, containerName) → number moved
--   listItems() → list of {name, amount, displayName, ...}
--   getItem({name=...}) → {name, amount, ...} or nil
--
-- Route model:
--   from = "me"              source is ME system (uses exportItemToPeripheral)
--   from = "chest"           source is a buffer chest (uses inventory list + importItemFromPeripheral)
--   to   = "chest"           destination is a buffer chest (receives the export)
--   to   = "me"              destination is ME system (receives the import)
--
-- Each route entry: { match=..., from=..., to=..., min_in_me=N, max_in_chest=N, max_push=N }
--
-- Safety: items matching WASTE_PATTERNS are NEVER exported to a chest whose
-- tag is "reactor_injector". Hard-coded, not configurable.

local M = {}

local WASTE_PATTERNS = { "cyanite", "magentite", "rossinite", "waste" }
local REACTOR_TAGS   = { "reactor_injector", "fuel_input" }

-- Built-in ATM10/ER2 routes.
-- from/to tags match the tag field on source/destination config entries.
local DEFAULT_ROUTES = {
  -- Fuel ingots: ME → reactor injector chest
  ["bigreactors:yellorium_ingot"]  = { from = "me", to = "reactor_injector" },
  ["bigreactors:blutonium_ingot"]  = { from = "me", to = "reactor_injector" },
  ["bigreactors:verderium_ingot"]  = { from = "me", to = "reactor_injector" },
  ["mekanism:uranium_ingot"]       = { from = "me", to = "reactor_injector" },
  ["mekanism:plutonium_pellet"]    = { from = "me", to = "reactor_injector" },
  -- Waste: reactor output chest → ME
  ["bigreactors:cyanite_ingot"]    = { from = "reactor_output", to = "me" },
  ["bigreactors:magentite_ingot"]  = { from = "reactor_output", to = "me" },
  ["bigreactors:rossinite_ingot"]  = { from = "reactor_output", to = "me" },
  -- Reprocessor output (used by REPROC node): processed fuel → ME
  ["bigreactors:blutonium_ingot_processed"] = { from = "reprocessor_output", to = "me" },
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
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

local function detect_ptype(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  if not ok or type(methods) ~= "table" then return nil end
  local ms = {}
  for _, m in ipairs(methods) do ms[m] = true end
  if ms.exportItemToPeripheral or ms.listItems then return "me_bridge" end
  if ms.list then return "inventory" end
  return nil
end

local function inventory_free_slots(wrapped)
  -- Returns number of empty slots; nil if size() unavailable.
  local size, err = safe_call(wrapped, "size")
  if not size then return nil end
  local items, _ = safe_call(wrapped, "list")
  if not items then return nil end
  local used = 0
  for _ in pairs(items) do used = used + 1 end
  return math.max(0, size - used)
end

local function inventory_count(wrapped, item_name)
  -- Count how many of a specific item are in a standard inventory.
  local items, _ = safe_call(wrapped, "list")
  if not items then return 0 end
  local total = 0
  for _, stack in pairs(items) do
    if type(stack) == "table" and stack.name == item_name then
      total = total + (stack.count or 0)
    end
  end
  return total
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
      me_bridge     = nil,   -- the single ME Bridge entry (used for both export and import)
      total_moved   = 0,
      total_errors  = 0,
      last_cycle    = nil,
      last_refresh  = 0,
      last_run_ts   = 0,
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- peripheral discovery ---------------------------------------------------

function M:refresh_peripherals()
  local cfg = self.config.logistics or {}

  local function wrap(entry)
    local name = type(entry) == "string" and entry or (type(entry) == "table" and entry.name)
    local tag  = (type(entry) == "table" and entry.tag) or "generic"
    if not name or not peripheral.isPresent(name) then
      self.warn_once("absent:" .. tostring(name), "Logistics: peripheral absent: " .. tostring(name))
      return nil
    end
    local ptype = detect_ptype(name)
    if not ptype then
      self.warn_once("notype:" .. name, "Logistics: unknown type for: " .. name)
      return nil
    end
    local ok, wrapped = pcall(peripheral.wrap, name)
    if not ok or not wrapped then
      self.warn_once("wrap:" .. name, "Logistics: wrap failed: " .. name)
      return nil
    end
    return { name = name, tag = tag, ptype = ptype, wrapped = wrapped }
  end

  local sources, dests, me_bridge = {}, {}, nil
  for _, e in ipairs(cfg.sources or {}) do
    local p = wrap(e)
    if p then
      if p.ptype == "me_bridge" then me_bridge = p end
      sources[#sources + 1] = p
    end
  end
  for _, e in ipairs(cfg.destinations or {}) do
    local p = wrap(e)
    if p then
      if p.ptype == "me_bridge" and not me_bridge then me_bridge = p end
      dests[#dests + 1] = p
    end
  end

  self._state.sources      = sources
  self._state.destinations = dests
  self._state.me_bridge    = me_bridge

  self.log("DEBUG", string.format(
    "Logistics: %d sources, %d destinations, ME Bridge: %s",
    #sources, #dests, me_bridge and me_bridge.name or "none"
  ))
end

-- ---- route matching ---------------------------------------------------------

function M:_match_route(item_name)
  local cfg = self.config.logistics or {}
  local lower = tostring(item_name):lower()
  for _, r in ipairs(cfg.routes or {}) do
    if r.match   and lower == tostring(r.match):lower()              then return r end
    if r.pattern and lower:find(tostring(r.pattern):lower(), 1, true) then return r end
  end
  return DEFAULT_ROUTES[lower]
end

function M:_find_dest(tag)
  for _, d in ipairs(self._state.destinations) do
    if d.tag == tag then return d end
  end
  return nil
end

-- ---- ME → chest (export) ----------------------------------------------------

function M:_export_me_to_chest(item_name, route, cycle_log)
  local bridge = self._state.me_bridge
  if not bridge then
    self.warn_once("no_bridge", "Logistics: no ME Bridge configured")
    return 0, 1
  end

  local dest = self:_find_dest(route.to or "")
  if not dest then
    self.warn_once("no_dest:" .. tostring(route.to),
      "Logistics: no destination for tag '" .. tostring(route.to) .. "'")
    return 0, 1
  end

  -- Safety block: waste must not go to reactor injector chest
  if is_waste(item_name) and tag_is_reactor(dest.tag) then
    self.warn_once("waste_block:" .. item_name,
      "SAFETY BLOCK: waste '" .. item_name .. "' blocked from reactor tag '" .. dest.tag .. "'")
    return 0, 0
  end

  -- How much is in ME?
  local me_info, _ = safe_call(bridge.wrapped, "getItem", { name = item_name })
  local in_me = type(me_info) == "table" and (me_info.amount or 0) or 0
  local min_in_me = tonumber(route.min_in_me) or 0
  if in_me <= min_in_me then
    self.log("DEBUG", string.format("Logistics: skip export %s (in_me=%d <= min=%d)",
      item_name, in_me, min_in_me))
    return 0, 0
  end

  -- How full is the destination chest?
  if dest.ptype == "inventory" then
    local free = inventory_free_slots(dest.wrapped)
    if free ~= nil and free == 0 then
      self.warn_once("chest_full:" .. dest.name,
        "Logistics: destination chest full: " .. dest.name)
      return 0, 0
    end
    local max_in_chest = tonumber(route.max_in_chest)
    if max_in_chest then
      local already = inventory_count(dest.wrapped, item_name)
      if already >= max_in_chest then
        self.log("DEBUG", string.format(
          "Logistics: skip export %s chest=%s already=%d max=%d",
          item_name, dest.name, already, max_in_chest))
        return 0, 0
      end
    end
  end

  local cfg = self.config.logistics or {}
  local push = math.min(in_me - min_in_me, tonumber(cfg.max_per_cycle) or 64)
  if route.max_push then push = math.min(push, tonumber(route.max_push)) end
  if push <= 0 then return 0, 0 end

  local ok, result = pcall(bridge.wrapped.exportItemToPeripheral,
    { name = item_name, count = push }, dest.name)
  if not ok then
    self.warn_once("exp_err:" .. dest.name,
      "exportItemToPeripheral -> " .. dest.name .. ": " .. tostring(result))
    return 0, 1
  end
  local moved = type(result) == "number" and result or 0
  if moved > 0 then
    cycle_log[#cycle_log + 1] = string.format("ME→%s %s x%d", dest.name, item_name, moved)
  end
  return moved, 0
end

-- ---- chest → ME (import) ----------------------------------------------------

function M:_import_chest_to_me(src, item_name, route, cycle_log)
  local bridge = self._state.me_bridge
  if not bridge then
    self.warn_once("no_bridge", "Logistics: no ME Bridge configured")
    return 0, 1
  end

  local cfg = self.config.logistics or {}
  local push = tonumber(cfg.max_per_cycle) or 64
  if route.max_push then push = math.min(push, tonumber(route.max_push)) end

  local ok, result = pcall(bridge.wrapped.importItemFromPeripheral,
    { name = item_name, count = push }, src.name)
  if not ok then
    self.warn_once("imp_err:" .. src.name,
      "importItemFromPeripheral from " .. src.name .. ": " .. tostring(result))
    return 0, 1
  end
  local moved = type(result) == "number" and result or 0
  if moved > 0 then
    cycle_log[#cycle_log + 1] = string.format("%s→ME %s x%d", src.name, item_name, moved)
  end
  return moved, 0
end

-- ---- routing cycle ----------------------------------------------------------

function M:run_cycle()
  local cycle_log = {}
  local total_moved, total_errors = 0, 0

  -- Pass 1: ME → chests  (sources tagged "me")
  for _, src in ipairs(self._state.sources) do
    if src.ptype ~= "me_bridge" then goto continue end

    -- listItems to find what's available for export
    local items, err = safe_call(src.wrapped, "listItems")
    if not items then
      self.warn_once("list_err:" .. src.name, "listItems failed: " .. tostring(err))
      goto continue
    end

    for _, stack in pairs(type(items) == "table" and items or {}) do
      if type(stack) ~= "table" or not stack.name then goto skip end
      local route = self:_match_route(stack.name)
      if not route then goto skip end
      if tostring(route.from or ""):lower() ~= "me" then goto skip end

      local m, e = self:_export_me_to_chest(stack.name, route, cycle_log)
      total_moved  = total_moved  + m
      total_errors = total_errors + e
      ::skip::
    end
    ::continue::
  end

  -- Pass 2: chests → ME  (sources tagged anything except "me")
  for _, src in ipairs(self._state.sources) do
    if src.ptype ~= "inventory" then goto continue end

    local items, err = safe_call(src.wrapped, "list")
    if not items then
      self.warn_once("list_err:" .. src.name, "list() failed: " .. tostring(err))
      goto continue
    end

    for _, stack in pairs(type(items) == "table" and items or {}) do
      if type(stack) ~= "table" or not stack.name then goto skip end
      local route = self:_match_route(stack.name)
      if not route then goto skip end
      if tostring(route.to or ""):lower() ~= "me" then goto skip end

      local m, e = self:_import_chest_to_me(src, stack.name, route, cycle_log)
      total_moved  = total_moved  + m
      total_errors = total_errors + e
      ::skip::
    end
    ::continue::
  end

  self._state.total_moved  = self._state.total_moved  + total_moved
  self._state.total_errors = self._state.total_errors + total_errors
  self._state.last_cycle   = {
    ts = os.epoch("utc"), moved = total_moved, errors = total_errors,
    sources = #self._state.sources, destinations = #self._state.destinations,
    moves = cycle_log,
  }

  if total_moved > 0 then
    self.log("INFO", string.format("Logistics: moved=%d errors=%d (%s)",
      total_moved, total_errors, table.concat(cycle_log, "; ")))
  elseif total_errors > 0 then
    self.log("WARN", "Logistics: moved=0 errors=" .. total_errors)
  else
    self.log("DEBUG", "Logistics: nothing to move")
  end
  return self._state.last_cycle
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
  if now - self._state.last_run_ts < interval_ms then return end
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
    me_bridge    = s.me_bridge and s.me_bridge.name or nil,
    total_moved  = s.total_moved,
    total_errors = s.total_errors,
    last_cycle   = s.last_cycle,
  }
end

return M
