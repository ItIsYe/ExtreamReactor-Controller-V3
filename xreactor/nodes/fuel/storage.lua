-- nodes/fuel/storage.lua
--
-- Buendelt die Reserve-Verfolgung (storage_bus) -- item-basiert ueber
-- config.reserve_items, wenn storage_bus eine ME Bridge ist (haeufigster
-- Fall), sonst fluid-basiert (tanks()/getFluidAmount()) fuer einen
-- dedizierten Tank-Block. Kann dasselbe physische Peripheral wie die
-- Item-Logistik (logistics_router.lua/ME Bridge) sein, ist aber eine
-- eigene Config/eigener State -- main.lua ruft nur die Funktionen auf.

local M = {}

local storage = nil

-- Wrapped (oder entfernt) das storage_bus-Peripheral basierend auf dem
-- aktuellen devices.storage_name (von der Discovery gesetzt).
function M.refresh(devices, utils)
  storage = nil
  if devices.storage_name and peripheral.isPresent(devices.storage_name) then
    local wrapped, err = utils.safe_wrap(devices.storage_name)
    if wrapped then
      storage = wrapped
    else
      utils.log("FUEL", "WARN: storage bus wrap failed: " .. tostring(err))
    end
  end
end

-- Aktuell gewrapptes Storage-Peripheral (oder nil). Fuer Health-Checks
-- ("has_storage = storage.get() ~= nil") und Aehnliches.
function M.get()
  return storage
end

-- ME Bridge (Advanced Peripherals) ist eine Item-Schnittstelle, kein
-- Fluid-Tank -- die Reserve ist die Summe der konfigurierten Fuel-Items
-- (config.reserve_items) im ME-System, per getItem() abgefragt.
-- unit_multiplier rechnet z.B. Bloecke in Ingot-Aequivalent um, damit
-- das Ergebnis in derselben Einheit wie target/minimum_reserve steht.
local function read_items(config, warn_once, support_runtime)
  local items = config and config.reserve_items
  if type(items) ~= "table" or #items == 0 then return nil end
  local total = 0
  local any_ok = false
  for _, entry in ipairs(items) do
    local item_id = type(entry) == "table" and entry.item or nil
    if type(item_id) == "string" and item_id ~= "" then
      local ok, info = support_runtime.safe_wrapped_call(storage, "getItem", { name = item_id })
      if ok then
        any_ok = true
        local amount = type(info) == "table" and tonumber(info.amount) or 0
        local multiplier = tonumber(entry.unit_multiplier) or 1
        total = total + (amount or 0) * multiplier
      else
        warn_once("storage_read_item:" .. item_id, "Storage getItem failed for " .. item_id .. ": " .. tostring(info))
      end
    end
  end
  if any_ok then return total end
  return nil
end

function M.read_fuel(config, warn_once, support_runtime)
  if storage and storage.getItem then
    local total = read_items(config, warn_once, support_runtime)
    if total ~= nil then return total end
  end
  if storage and storage.tanks then
    local ok, tank_data = support_runtime.safe_wrapped_call(storage, "tanks")
    if ok and type(tank_data) == "table" then
      local total = 0
      for _, tank in pairs(tank_data) do
        if type(tank) == "table" and type(tank.amount) == "number" then total = total + tank.amount end
      end
      return total
    elseif not ok then
      warn_once("storage_read", "Storage tanks read failed: " .. tostring(tank_data))
    end
  end
  if storage and storage.getFluidAmount then
    local ok, value = support_runtime.safe_wrapped_call(storage, "getFluidAmount")
    if ok and type(value) == "number" then return value end
    if not ok then warn_once("storage_read_legacy", "Storage read failed: " .. tostring(value)) end
  end
  return 0
end

local _last_enforced = nil
function M.enforce_reserve(current, reserve, safety, utils)
  local adjusted, changed = safety.with_reserve(current, reserve)
  if changed and adjusted ~= _last_enforced then
    utils.log("FUEL", "Reserve enforced at " .. tostring(adjusted))
    _last_enforced = adjusted
  end
  return adjusted
end

return M
