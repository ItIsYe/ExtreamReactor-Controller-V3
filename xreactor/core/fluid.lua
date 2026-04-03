local fluid = {}

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(obj[method], ...)
end

function fluid.sum_tanks(obj)
  local ok, tank_data = safe_call(obj, "tanks")
  if not ok then
    return nil, tank_data
  end
  if type(tank_data) ~= "table" then
    return nil, "invalid tanks response"
  end
  local total = 0
  for _, info in pairs(tank_data) do
    if type(info) == "table" and type(info.amount) == "number" then
      total = total + info.amount
    end
  end
  return total
end

function fluid.read_amount(obj, legacy_methods)
  local total, err = fluid.sum_tanks(obj)
  if type(total) == "number" then
    return total
  end
  for _, method in ipairs(legacy_methods or {}) do
    local ok, value = safe_call(obj, method)
    if ok and type(value) == "number" then
      return value
    end
    if ok then
      err = "invalid " .. tostring(method) .. " response"
    else
      err = value
    end
  end
  return nil, err
end

function fluid.normalize_fraction(value)
  local numeric = tonumber(value)
  if type(numeric) ~= "number" then
    return nil
  end
  if numeric >= 0 and numeric <= 1 then
    return numeric, "fraction"
  end
  if numeric >= 0 and numeric <= 100 then
    return numeric / 100, "percent"
  end
  return nil
end

function fluid.resolve_ratio(amount, amount_max, filled_percentage)
  local ratio, ratio_source = fluid.normalize_fraction(filled_percentage)
  if type(ratio) == "number" then
    return ratio, "getCoolantFilledPercentage(" .. tostring(ratio_source) .. ")"
  end

  local current = tonumber(amount)
  local maximum = tonumber(amount_max)
  if type(current) == "number" and type(maximum) == "number" and maximum > 0 then
    return current / maximum, "getCoolantAmount/getCoolantAmountMax"
  end

  return nil, "UNAVAILABLE"
end

local function parse_numeric(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

function fluid.read_coolant_sample(reactor, safe_call)
  local reader = safe_call
  if type(reader) ~= "function" then
    reader = function(obj, method)
      if not obj or type(obj[method]) ~= "function" then
        return false, "missing method"
      end
      return pcall(obj[method])
    end
  end

  local function call_metric(method)
    if not reactor or type(reactor[method]) ~= "function" then
      return nil, "METHOD_UNAVAILABLE", method
    end
    local ok, value = reader(reactor, method)
    local parsed = ok and parse_numeric(value) or nil
    if parsed == nil then
      return nil, ok and "INVALID_VALUE" or "CALL_FAILED", method
    end
    return parsed, "OK", method
  end

  local amount, amount_state, amount_method = call_metric("getCoolantAmount")
  local amount_max, max_state, max_method = call_metric("getCoolantAmountMax")
  local filled_percentage, percent_state, percent_method = call_metric("getCoolantFilledPercentage")
  local ratio, ratio_source = fluid.resolve_ratio(amount, amount_max, filled_percentage)
  local measurement_state = "FRESH"
  if type(ratio) ~= "number" then
    measurement_state = "INVALID"
  end

  local source_method = "UNAVAILABLE"
  if ratio_source:find("getCoolantFilledPercentage", 1, true) then
    source_method = percent_method
  elseif ratio_source:find("getCoolantAmount/getCoolantAmountMax", 1, true) then
    source_method = (amount_method or "getCoolantAmount") .. "+" .. (max_method or "getCoolantAmountMax")
  end

  return {
    coolant_amount = amount,
    coolant_amount_max = amount_max,
    coolant_filled_percentage = filled_percentage,
    coolant_ratio = ratio,
    source = ratio_source,
    source_method = source_method,
    measurement_state = measurement_state,
    amount_state = amount_state,
    amount_max_state = max_state,
    filled_percentage_state = percent_state
  }
end

return fluid
