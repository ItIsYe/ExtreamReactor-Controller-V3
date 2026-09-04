local utils = require("core.utils")
local fluid = require("core.fluid")

local reactor = {}
local warned = {}

local function log_once(prefix, key, message)
  if warned[key] then return end
  warned[key] = true
  utils.log(prefix or "REACTOR", message, "WARN")
end

local function safe_call(name, method, log_prefix, ...)
  if not method then return nil end
  local result, err = utils.safe_peripheral_call(name, method, ...)
  if err then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method),
      "Reactor call failed for " .. tostring(name) .. "." .. tostring(method) .. ": " .. tostring(err))
  end
  return result
end

local function read_number(name, method, log_prefix)
  local value = safe_call(name, method, log_prefix)
  if type(value) == "number" then return value end
  if type(value) == "string" then local parsed = tonumber(value); if parsed then return parsed end end
  if value ~= nil then
    log_once(log_prefix, tostring(name) .. ":" .. tostring(method) .. ":type",
      "Reactor metric type mismatch peripheral=" .. tostring(name) .. " method=" .. tostring(method)
        .. " type=" .. type(value) .. " value=" .. tostring(value))
  end
  return "n/a"
end

local function has_method(set, key) return set and set[key] == true end

local function safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return false, "missing method" end
  return pcall(function(...) return obj[method](...) end, ...)
end

local function build_method_set(name)
  local methods = utils.safe_get_methods(name) or {}
  local set = {}
  for _, method in ipairs(methods) do set[method] = true end
  return methods, set
end

local function normalize_rod_level(value)
  if type(value) == "number" then return value end
  if type(value) ~= "table" then return nil end
  if type(value.level) == "number" then return value.level end
  if type(value.inserted) == "number" then return value.inserted end
  if type(value.insertion) == "number" then return value.insertion end
  return nil
end

local function normalize_write_level(level)
  local numeric = tonumber(level)
  if not numeric then return nil end
  if numeric < 0 then numeric = 0 elseif numeric > 100 then numeric = 100 end
  return math.floor(numeric + 0.5)
end

local function summarize_value(value)
  local value_type = type(value)
  if value_type == "number" or value_type == "string" or value_type == "boolean" or value_type == "nil" then
    return tostring(value)
  end
  if value_type == "table" then return "table(len=" .. tostring(#value) .. ")" end
  return value_type
end

local function log_rod_error(log_prefix, name, method, detail)
  log_once(log_prefix, tostring(name) .. ":rod:" .. tostring(method) .. ":" .. tostring(detail),
    "Reactor rod access failed peripheral=" .. tostring(name)
      .. " expected=" .. tostring(method) .. " detail=" .. tostring(detail))
end

local function log_rod_path(log_prefix, name, method, detail)
  utils.log(log_prefix or "REACTOR",
    "Reactor rod write path peripheral=" .. tostring(name) .. " method=" .. tostring(method)
      .. " detail=" .. tostring(detail), "INFO")
end

local function read_first_number(name, method_set, methods, log_prefix)
  for _, method in ipairs(methods or {}) do
    if has_method(method_set, method) then
      local value = read_number(name, method, log_prefix)
      if type(value) == "number" then return value end
    end
  end
  return "n/a"
end

local function read_active(name, method_set, log_prefix)
  if has_method(method_set, "getActive") then
    local active = safe_call(name, "getActive", log_prefix)
    if type(active) == "boolean" then return active end
  end
  if has_method(method_set, "getStatus") then
    local status = safe_call(name, "getStatus", log_prefix)
    if type(status) == "boolean" then return status end
    if type(status) == "string" then
      local normalized = status:lower()
      if normalized == "online" or normalized == "active" or normalized == "running" then return true end
      if normalized == "offline" or normalized == "inactive" or normalized == "stopped" then return false end
    end
  end
  return false
end

local function count_rods(name, method_set)
  if has_method(method_set, "getControlRodsLevels") then
    local levels = utils.safe_peripheral_call(name, "getControlRodsLevels")
    if type(levels) == "table" then
      local count = 0; for _ in pairs(levels) do count = count + 1 end
      if count > 0 then return count end
    end
  end
  if has_method(method_set, "getControlRodLevels") then
    local levels = utils.safe_peripheral_call(name, "getControlRodLevels")
    if type(levels) == "table" and #levels > 0 then return #levels end
  end
  if has_method(method_set, "getControlRods") then
    local rods = utils.safe_peripheral_call(name, "getControlRods")
    if type(rods) == "table" then
      local count = 0; for _ in pairs(rods) do count = count + 1 end
      if count > 0 then return count end
    end
  end
  return nil
end

function reactor.inspect(name, log_prefix)
  if not name or not peripheral.isPresent(name) then return nil, "peripheral missing" end
  local type_name = peripheral.getType(name) or "reactor"
  local methods, method_set = build_method_set(name)
  local active = read_active(name, method_set, log_prefix)
  local temp = read_first_number(name, method_set,
    { "getFuelTemperature", "getTemperature", "getCasingTemperature" }, log_prefix)
  local energy, energy_output_from_stats, fuel, waste
  if has_method(method_set, "getEnergyStats") then
    local stats = safe_call(name, "getEnergyStats", log_prefix)
    if type(stats) == "table" then
      energy = type(stats.energyStored) == "number" and stats.energyStored or nil
      energy_output_from_stats = type(stats.energyProducedLastTick) == "number" and stats.energyProducedLastTick or nil
    end
  end
  if energy == nil then energy = read_first_number(name, method_set, { "getEnergyStored", "getEnergyProducedLastTick" }, log_prefix) end
  local fuel_max
  if has_method(method_set, "getFuelStats") then
    local fstats = safe_call(name, "getFuelStats", log_prefix)
    if type(fstats) == "table" then
      fuel = type(fstats.fuelAmount) == "number" and fstats.fuelAmount or nil
      waste = type(fstats.wasteAmount) == "number" and fstats.wasteAmount or nil
      fuel_max = type(fstats.fuelCapacity) == "number" and fstats.fuelCapacity or nil
    end
  end
  if fuel == nil then fuel = read_number(name, "getFuelAmount", log_prefix) end
  if waste == nil then waste = read_number(name, "getWasteAmount", log_prefix) end
  if fuel_max == nil then fuel_max = read_number(name, "getFuelAmountMax", log_prefix) end
  local rods = reactor.read_control_rods(name, log_prefix)
  local steam = read_number(name,
    has_method(method_set, "getHotFluidAmount") and "getHotFluidAmount"
      or has_method(method_set, "getSteamAmount") and "getSteamAmount"
      or has_method(method_set, "getSteam") and "getSteam", log_prefix)
  local steam_max = read_number(name,
    has_method(method_set, "getHotFluidAmountMax") and "getHotFluidAmountMax"
      or has_method(method_set, "getSteamAmountMax") and "getSteamAmountMax"
      or has_method(method_set, "getHotFluidCapacity") and "getHotFluidCapacity"
      or has_method(method_set, "getSteamCapacity") and "getSteamCapacity", log_prefix)
  local steam_fill_ratio = nil
  if type(steam) == "number" and type(steam_max) == "number" and steam_max > 0 then steam_fill_ratio = steam / steam_max end
  local coolant_amount = read_number(name, has_method(method_set, "getCoolantAmount") and "getCoolantAmount" or nil, log_prefix)
  local coolant_amount_max = read_number(name, has_method(method_set, "getCoolantAmountMax") and "getCoolantAmountMax" or nil, log_prefix)
  local coolant_filled_percentage = read_number(name,
    has_method(method_set, "getCoolantFilledPercentage") and "getCoolantFilledPercentage" or nil, log_prefix)
  local coolant_ratio, coolant_ratio_source = fluid.resolve_ratio(coolant_amount, coolant_amount_max, coolant_filled_percentage)
  return {
    name = name, type = type_name, adapter = "reactor",
    features = {
      active = has_method(method_set, "getStatus") or has_method(method_set, "getActive"),
      temperature = has_method(method_set, "getFuelTemperature") or has_method(method_set, "getTemperature"),
      fuel = has_method(method_set, "getFuelAmount"), waste = has_method(method_set, "getWasteAmount"),
      energy_stored = has_method(method_set, "getEnergyStored"),
      energy_output = has_method(method_set, "getEnergyProducedLastTick"),
      actively_cooled = has_method(method_set, "isActivelyCooled"),
      rods = has_method(method_set, "getControlRodLevel") or has_method(method_set, "getControlRodLevels")
        or has_method(method_set, "getControlRodsLevels") or has_method(method_set, "getControlRods"),
      steam = has_method(method_set, "getHotFluidAmount") or has_method(method_set, "getSteamAmount") or has_method(method_set, "getSteam"),
      steam_capacity = has_method(method_set, "getHotFluidAmountMax") or has_method(method_set, "getSteamAmountMax")
        or has_method(method_set, "getHotFluidCapacity") or has_method(method_set, "getSteamCapacity"),
      coolant = has_method(method_set, "getCoolantAmount") or has_method(method_set, "getCoolantAmountMax")
        or has_method(method_set, "getCoolantFilledPercentage")
    },
    schema = {
      active = "boolean", temperature = "number", fuel = "number", fuel_max = "number",
      waste = "number", energy_stored = "number", energy_output = "number", is_actively_cooled = "boolean",
      control_rod_level = "number", steam = "number", steam_amount_max = "number", steam_fill_ratio = "number",
      coolant_amount = "number", coolant_amount_max = "number", coolant_filled_percentage = "number", coolant_ratio = "number"
    },
    active = active, temperature = temp, fuel = fuel, fuel_max = fuel_max, waste = waste,
    energy_stored = energy,
    energy_output = energy_output_from_stats or read_number(name, "getEnergyProducedLastTick", log_prefix),
    is_actively_cooled = has_method(method_set, "isActivelyCooled") and (safe_call(name, "isActivelyCooled", log_prefix) == true) or false,
    control_rod_level = rods, steam = steam, steam_amount_max = steam_max, steam_fill_ratio = steam_fill_ratio,
    coolant_amount = coolant_amount, coolant_amount_max = coolant_amount_max,
    coolant_filled_percentage = coolant_filled_percentage, coolant_ratio = coolant_ratio,
    coolant_ratio_source = coolant_ratio_source, methods = methods
  }
end

-- Returns aggregate and completeness data. Safety callers must use minimum +
-- complete, not only average insertion.
function reactor.read_control_rods_detail(name, log_prefix)
  if not name then return nil, "missing peripheral" end
  local _, method_set = build_method_set(name)

  local function summarize(levels, expected_count, source)
    local sum, count, min_level, max_level = 0, 0, nil, nil
    for _, value in pairs(levels or {}) do
      local level = normalize_rod_level(value)
      if type(level) == "number" then
        sum = sum + level; count = count + 1
        min_level = min_level == nil and level or math.min(min_level, level)
        max_level = max_level == nil and level or math.max(max_level, level)
      end
    end
    if count < 1 then return nil end
    return {
      average = sum / count, min = min_level, max = max_level, count = count,
      expected_count = expected_count,
      complete = type(expected_count) == "number" and expected_count > 0 and count == expected_count,
      source = source,
    }
  end

  if has_method(method_set, "getControlRodsLevels") then
    local levels, err = utils.safe_peripheral_call(name, "getControlRodsLevels")
    if type(levels) == "table" then
      local expected = 0; for _ in pairs(levels) do expected = expected + 1 end
      local detail = summarize(levels, expected, "getControlRodsLevels")
      if detail then return detail end
    end
    log_rod_error(log_prefix, name, "getControlRodsLevels", err or ("unexpected value " .. summarize_value(levels)))
  end
  if has_method(method_set, "getControlRodLevels") then
    local levels, err = utils.safe_peripheral_call(name, "getControlRodLevels")
    if type(levels) == "table" and #levels > 0 then
      local detail = summarize(levels, #levels, "getControlRodLevels")
      if detail then return detail end
    end
    log_rod_error(log_prefix, name, "getControlRodLevels", err or ("unexpected value " .. summarize_value(levels)))
  end
  if has_method(method_set, "getControlRods") then
    local rods, err = utils.safe_peripheral_call(name, "getControlRods")
    if type(rods) == "table" then
      local levels, total = {}, 0
      for _, rod in pairs(rods) do
        total = total + 1
        local level = normalize_rod_level(rod)
        if level == nil and rod and rod.getLevel then
          local ok_level, value = safe_wrapped_call(rod, "getLevel")
          if ok_level then level = normalize_rod_level(value) or (type(value) == "number" and value or nil) end
        end
        if type(level) == "number" then levels[#levels + 1] = level end
      end
      local detail = summarize(levels, total, "getControlRods")
      if detail then return detail end
      return nil, "empty or unreadable rods"
    end
    return nil, err or "unexpected getControlRods result"
  end
  if has_method(method_set, "getControlRodLevel") then
    local level, err = utils.safe_peripheral_call(name, "getControlRodLevel", 0)
    if type(level) == "number" then
      return { average = level, min = level, max = level, count = 1,
        expected_count = nil, complete = false, source = "getControlRodLevel" }
    end
    return nil, err or "unreadable control rod"
  end
  return nil, "unsupported methods"
end

local function confirm_safe_full_insertion(name, normalized_level, log_prefix)
  if normalized_level < 100 then return true end
  local detail, err = reactor.read_control_rods_detail(name, log_prefix)
  if not detail then return nil, "safe readback failed: " .. tostring(err) end
  if detail.complete ~= true then
    return nil, "safe readback incomplete count=" .. tostring(detail.count)
      .. " expected=" .. tostring(detail.expected_count)
  end
  if type(detail.min) ~= "number" or detail.min < 99.5 then
    return nil, "safe readback minimum rod=" .. tostring(detail.min)
  end
  return true
end

function reactor.apply_rod_level(name, level, log_prefix)
  if not name or level == nil then return nil, "missing data" end
  local normalized_level = normalize_write_level(level)
  if normalized_level == nil then return nil, "invalid level " .. tostring(level) end
  local methods, method_set = build_method_set(name)

  local function confirmed_success(method, detail)
    local safe, safe_err = confirm_safe_full_insertion(name, normalized_level, log_prefix)
    if safe ~= true then
      log_rod_error(log_prefix, name, method, safe_err)
      return nil, safe_err
    end
    log_rod_path(log_prefix, name, method, detail)
    return true
  end

  if has_method(method_set, "setAllControlRodLevels") then
    local ok, err = utils.safe_peripheral_call(name, "setAllControlRodLevels", normalized_level)
    if err or ok == false then return nil, err or "returned false" end
    return confirmed_success("setAllControlRodLevels", "level=" .. tostring(normalized_level))
  end

  if has_method(method_set, "setControlRodsLevels") then
    local rod_count = count_rods(name, method_set)
    if not rod_count or rod_count < 1 then return nil, "unable to resolve rod count" end
    local levels = {}; for index = 1, rod_count do levels[index] = normalized_level end
    local ok, err = utils.safe_peripheral_call(name, "setControlRodsLevels", levels)
    if err or ok == false then return nil, err or "returned false" end
    return confirmed_success("setControlRodsLevels",
      "count=" .. tostring(rod_count) .. " level=" .. tostring(normalized_level))
  end

  if has_method(method_set, "setControlRodLevel") then
    -- count_rods() only recognises bulk getters; peripherals exposing solely
    -- the indexed setControlRodLevel/getControlRodLevel pair (no bulk method)
    -- resolve to nil here and default to a single rod at index 0/1.
    local rod_count = count_rods(name, method_set) or 1
    local changed, last_err = 0, nil
    for index = 0, rod_count - 1 do
      local ok, err = utils.safe_peripheral_call(name, "setControlRodLevel", index, normalized_level)
      if err and index == 0 and rod_count == 1 then
        -- Some peripherals are 1-indexed; retry index 1 before giving up.
        local ok_one, err_one = utils.safe_peripheral_call(name, "setControlRodLevel", 1, normalized_level)
        if not err_one and ok_one ~= false then changed = changed + 1 else last_err = err_one or "returned false" end
      elseif err then last_err = err
      elseif ok == false then last_err = "returned false"
      else changed = changed + 1 end
    end
    if changed ~= rod_count then
      return nil, string.format("partial rod write %d/%d: %s", changed, rod_count, tostring(last_err or "unknown"))
    end
    return confirmed_success("setControlRodLevel",
      "count=" .. tostring(changed) .. " level=" .. tostring(normalized_level))
  end

  if has_method(method_set, "getControlRods") then
    local rods, rods_err = utils.safe_peripheral_call(name, "getControlRods")
    if type(rods) ~= "table" then return nil, rods_err or "unexpected rods result" end
    local total, writable, changed, last_err = 0, 0, 0, nil
    for _, rod in pairs(rods) do
      total = total + 1
      if rod and type(rod.setLevel) == "function" then
        writable = writable + 1
        local ok_set, set_err = safe_wrapped_call(rod, "setLevel", normalized_level)
        if ok_set then changed = changed + 1 else last_err = set_err end
      end
    end
    if total < 1 or writable ~= total or changed ~= total then
      return nil, string.format("partial rod write changed=%d writable=%d total=%d err=%s",
        changed, writable, total, tostring(last_err or "none"))
    end
    return confirmed_success("getControlRods.setLevel",
      "changed=" .. tostring(changed) .. " level=" .. tostring(normalized_level))
  end

  return nil, "unsupported methods (available=" .. tostring(#methods) .. ")"
end

function reactor.read_control_rods(name, log_prefix)
  local detail, err = reactor.read_control_rods_detail(name, log_prefix)
  if detail then return detail.average end
  return nil, err
end

function reactor.set_active(name, enabled, log_prefix)
  if not name then return nil, "missing peripheral" end
  local ok, err = utils.safe_peripheral_call(name, "setActive", enabled and true or false)
  if err then
    log_once(log_prefix, tostring(name) .. ":setActive",
      "Reactor active failed for " .. tostring(name) .. ": " .. tostring(err))
  end
  return ok, err
end

return reactor
