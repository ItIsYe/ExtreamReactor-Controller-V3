-- nodes/fuel/logistics_router.lua
--
-- Demand-driven supply management for Fuel and Reprocessor nodes.
--
-- Each reactor and reprocessor gets its OWN dedicated buffer chest.
-- CC monitors each chest independently and tops it up from ME only when
-- the chest falls below a configured minimum level.
-- This ensures each reactor/reprocessor receives its own allocation —
-- items are never routed to the wrong destination.
--
-- Physical setup (one per reactor or reprocessor):
--
--   [ME Bridge]──exportItemToPeripheral──►[Dedicated chest]──Mekanism pipe──►[Reactor/Reprocessor]
--   [ME Bridge]◄──importItemFromPeripheral──[Dedicated chest]◄─Mekanism pipe──[Output]
--
-- Each chest is a short, direct pipe run to ONE specific reactor/reprocessor.
-- No shared routing, no colour channels, no cross-contamination possible.
--
-- Config model:
--
--   me_bridge = "me_bridge"  (peripheral name; AP uses "me_bridge" on 1.21.1)
--
--   supply = {               -- chests to keep filled FROM ME
--     { chest = "chest_0",   item = "bigreactors:yellorium_ingot",
--       label = "Reactor A", min = 16, max = 64 },
--     { chest = "chest_1",   item = "bigreactors:yellorium_ingot",
--       label = "Reactor B", min = 16, max = 64 },
--   },
--
--   collect = {              -- chests to drain INTO ME
--     { chest = "chest_2",   label = "Waste A" },
--     { chest = "chest_3",   label = "Waste B" },
--   },
--
-- Route safety: waste items (cyanite/magentite/rossinite/waste) are NEVER
-- exported to a supply chest, even if explicitly configured.

local M = {}

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
    return nil, "no_method"
  end
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

-- Count a specific item in a standard inventory.
local function chest_count(wrapped, item_name)
  local items, _ = safe_call(wrapped, "list")
  if not items then return 0 end
  local n = 0
  for _, s in pairs(items) do
    if type(s) == "table" and s.name == item_name then
      n = n + (s.count or 0)
    end
  end
  return n
end

-- Count all items in a standard inventory (for collect chests).
local function chest_total(wrapped)
  local items, _ = safe_call(wrapped, "list")
  if not items then return 0 end
  local n = 0
  for _, s in pairs(items) do
    if type(s) == "table" then n = n + (s.count or 0) end
  end
  return n
end

-- ---- constructor ------------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = {
    config    = opts.config or {},
    log       = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    _state = {
      bridge        = nil,  -- wrapped ME Bridge
      supply_chests = {},   -- wrapped supply chests
      collect_chests= {},   -- wrapped collect chests
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

-- ---- peripheral discovery ---------------------------------------------------

function M:refresh_peripherals()
  local cfg = (self.config.logistics or self.config) or {}
  local bridge_name = cfg.me_bridge or "me_bridge"

  -- ME Bridge
  local bridge = nil
  if peripheral.isPresent(bridge_name) then
    local ok, w = pcall(peripheral.wrap, bridge_name)
    if ok and w then
      bridge = { name = bridge_name, wrapped = w }
      self.log("DEBUG", "Logistics: ME Bridge connected: " .. bridge_name)
    else
      self.warn_once("bridge_wrap", "Logistics: failed to wrap ME Bridge: " .. bridge_name)
    end
  else
    self.warn_once("bridge_absent", "Logistics: ME Bridge not present: " .. bridge_name)
  end
  self._state.bridge = bridge

  -- Supply chests (ME → chest)
  local supply = {}
  for i, entry in ipairs(cfg.supply or {}) do
    if not entry.chest or not entry.item then goto skip end
    if not peripheral.isPresent(entry.chest) then
      self.warn_once("supply_absent_" .. i, "Logistics: supply chest absent: " .. entry.chest)
      goto skip
    end
    local ok, w = pcall(peripheral.wrap, entry.chest)
    if ok and w then
      -- Detect Mekanism Logistical Transporter by type name or explicit flag.
      local ptype_str = tostring(peripheral.getType(entry.chest) or ""):lower()
      local is_transporter = entry.transporter == true
        or ptype_str:find("logistical_transporter", 1, true) ~= nil
      supply[#supply + 1] = {
        name           = entry.chest,
        label          = entry.label or entry.chest,
        item           = entry.item,
        min            = tonumber(entry.min) or 16,
        max            = tonumber(entry.max) or 64,
        is_transporter = is_transporter,
        wrapped        = w,
      }
    else
      self.warn_once("supply_wrap_" .. i, "Logistics: supply chest wrap failed: " .. entry.chest)
    end
    ::skip::
  end

  -- Collect chests (chest → ME)
  local collect = {}
  for i, entry in ipairs(cfg.collect or {}) do
    if not entry.chest then goto skip2 end
    if not peripheral.isPresent(entry.chest) then
      self.warn_once("collect_absent_" .. i, "Logistics: collect chest absent: " .. entry.chest)
      goto skip2
    end
    local ok, w = pcall(peripheral.wrap, entry.chest)
    if ok and w then
      collect[#collect + 1] = {
        name    = entry.chest,
        label   = entry.label or entry.chest,
        wrapped = w,
      }
    else
      self.warn_once("collect_wrap_" .. i, "Logistics: collect chest wrap failed: " .. entry.chest)
    end
    ::skip2::
  end

  self._state.supply_chests  = supply
  self._state.collect_chests = collect
  self.log("DEBUG", string.format(
    "Logistics: bridge=%s supply=%d collect=%d",
    bridge and bridge.name or "NONE", #supply, #collect
  ))
end

-- ---- supply cycle (ME → chests) ---------------------------------------------

function M:_run_supply(cycle_log)
  local bridge = self._state.bridge
  if not bridge then return 0, 0 end
  local exported, errors = 0, 0

  for _, target in ipairs(self._state.supply_chests) do
    -- Safety: waste must never go into a supply chest
    if is_waste(target.item) then
      self.warn_once("waste_supply:" .. target.item,
        "SAFETY BLOCK: waste item '" .. target.item .. "' configured as supply — skipping")
      goto continue
    end

    -- For Mekanism Logistical Transporters: skip fill check.
    -- Transporters move items immediately — list() shows near-empty in-transit state.
    -- Instead export a fixed batch every cycle as long as ME has enough.
    -- For standard chests: check actual fill level.
    local current, needed
    if target.is_transporter then
      -- Transporter: export up to 'max' items per cycle regardless of transporter state.
      current = 0
      needed  = target.max
    else
      current = chest_count(target.wrapped, target.item)
      if current >= target.min then goto continue end
      needed = target.max - current
      if needed <= 0 then goto continue end
    end

    -- How much is in ME?
    local me_info, _ = safe_call(bridge.wrapped, "getItem", { name = target.item })
    local in_me = type(me_info) == "table" and (me_info.amount or 0) or 0
    if in_me <= 0 then
      self.log("DEBUG", string.format(
        "Logistics: supply %s: %s not in ME", target.label, target.item))
      goto continue
    end

    local push = math.min(needed, in_me)
    local ok, result = pcall(bridge.wrapped.exportItemToPeripheral,
      { name = target.item, count = push }, target.name)
    if not ok then
      self.warn_once("exp_err:" .. target.name,
        "exportItemToPeripheral → " .. target.name .. ": " .. tostring(result))
      errors = errors + 1
    else
      local moved = type(result) == "number" and result or 0
      if moved > 0 then
        exported = exported + moved
        if target.is_transporter then
          cycle_log[#cycle_log + 1] = string.format(
            "ME→transporter[%s] %s x%d", target.label, target.item, moved)
        else
          cycle_log[#cycle_log + 1] = string.format(
            "ME→%s [%s] %s x%d (was %d/%d)",
            target.name, target.label, target.item, moved, current, target.max)
        end
      end
    end

    ::continue::
  end
  return exported, errors
end

-- ---- collect cycle (chests → ME) --------------------------------------------

function M:_run_collect(cycle_log)
  local bridge = self._state.bridge
  if not bridge then return 0, 0 end
  local imported, errors = 0, 0

  for _, src in ipairs(self._state.collect_chests) do
    local total = chest_total(src.wrapped)
    if total <= 0 then goto continue end

    -- Import everything from this chest into ME
    -- importItemFromPeripheral with no item filter imports all
    local ok, result = pcall(bridge.wrapped.importItemFromPeripheral,
      {}, src.name)
    if not ok then
      -- Fallback: some AP versions need an item specified; enumerate and import each
      local items, _ = safe_call(src.wrapped, "list")
      if items then
        for _, stack in pairs(items) do
          if type(stack) == "table" and stack.name then
            local ok2, res2 = pcall(bridge.wrapped.importItemFromPeripheral,
              { name = stack.name, count = stack.count or 64 }, src.name)
            if ok2 then
              local n = type(res2) == "number" and res2 or 0
              if n > 0 then
                imported = imported + n
                cycle_log[#cycle_log + 1] = string.format(
                  "%s→ME [%s] %s x%d", src.name, src.label, stack.name, n)
              end
            else
              errors = errors + 1
              self.warn_once("imp_err:" .. src.name .. ":" .. stack.name,
                "importItemFromPeripheral failed: " .. tostring(res2))
            end
          end
        end
      else
        errors = errors + 1
        self.warn_once("imp_err:" .. src.name,
          "importItemFromPeripheral failed: " .. tostring(result))
      end
    else
      local moved = type(result) == "number" and result or 0
      if moved > 0 then
        imported = imported + moved
        cycle_log[#cycle_log + 1] = string.format(
          "%s→ME [%s] all x%d", src.name, src.label, moved)
      end
    end

    ::continue::
  end
  return imported, errors
end

-- ---- main cycle -------------------------------------------------------------

function M:run_cycle()
  local cycle_log = {}
  local exp, err1 = self:_run_supply(cycle_log)
  local imp, err2 = self:_run_collect(cycle_log)
  local total_errors = err1 + err2

  self._state.total_exported = self._state.total_exported + exp
  self._state.total_imported = self._state.total_imported + imp
  self._state.total_errors   = self._state.total_errors   + total_errors

  self._state.last_cycle = {
    ts       = os.epoch("utc"),
    exported = exp, imported = imp, errors = total_errors,
    supply   = #self._state.supply_chests,
    collect  = #self._state.collect_chests,
    moves    = cycle_log,
  }

  if exp > 0 or imp > 0 then
    self.log("INFO", string.format(
      "Logistics: exported=%d imported=%d errors=%d | %s",
      exp, imp, total_errors, table.concat(cycle_log, " | ")))
  elseif total_errors > 0 then
    self.log("WARN", "Logistics: exported=0 imported=0 errors=" .. total_errors)
  else
    self.log("DEBUG", "Logistics: nothing to do")
  end
  return self._state.last_cycle
end

-- ---- service tick -----------------------------------------------------------

function M:tick()
  local cfg = (self.config.logistics or self.config) or {}
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
  local cfg = (self.config.logistics or self.config) or {}
  local supply_status = {}
  for _, t in ipairs(s.supply_chests) do
    local current = chest_count(t.wrapped, t.item)
    supply_status[#supply_status + 1] = {
      label   = t.label,
      item    = t.item,
      current = current,
      min     = t.min,
      max     = t.max,
      ok      = current >= t.min,
    }
  end
  return {
    enabled        = cfg.enabled == true,
    bridge         = s.bridge and s.bridge.name or nil,
    supply_count   = #s.supply_chests,
    collect_count  = #s.collect_chests,
    total_exported = s.total_exported,
    total_imported = s.total_imported,
    total_errors   = s.total_errors,
    supply         = supply_status,
    last_cycle     = s.last_cycle,
  }
end

return M
