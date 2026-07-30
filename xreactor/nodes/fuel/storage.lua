-- nodes/fuel/storage.lua
--
-- Feature (2026-07-09): Modularisierungs-Rewrite. Buendelt die allgemeine
-- Fluessig-Reserve-Verfolgung (storage_bus) an einer Stelle -- bewusst
-- getrennt von der Item-Logistik (logistics_router.lua/ME Bridge), da es
-- sich um ein separates Peripheral fuer einen separaten Zweck handelt
-- (siehe config.lua Dokumentation). Haelt seinen eigenen State (der
-- gewrappte storage-Peripheral) -- main.lua ruft nur die Funktionen hier
-- auf, ohne den Wrap-Zustand selbst verwalten zu muessen.

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

function M.read_fuel(warn_once, support_runtime)
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

function M.enforce_reserve(current, reserve, safety, utils)
  local adjusted, changed = safety.with_reserve(current, reserve)
  if changed then utils.log("FUEL", "Reserve enforced at " .. adjusted) end
  return adjusted
end

return M
