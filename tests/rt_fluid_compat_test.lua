package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local fluid = require("core.fluid")

local modern = {
  tanks = function(extra)
    if extra ~= nil then
      error("wrapped tanks() call must not receive implicit self argument")
    end
    return {
      [1] = { name = "steam", amount = 1250 },
      [3] = { name = "steam", amount = 750 },
    }
  end
}

local legacy = {
  getFluidAmount = function(extra)
    if extra ~= nil then
      error("wrapped getFluidAmount() call must not receive implicit self argument")
    end
    return 900
  end
}

local broken = {
  tanks = function() error("boom") end,
  getSteamAmount = function() return 400 end
}

local modern_value, modern_err = fluid.read_amount(modern, { "getFluidAmount" })
if modern_value ~= 2000 or modern_err ~= nil then
  error("expected modern tanks API to be preferred")
end

local legacy_value = fluid.read_amount(legacy, { "getFluidAmount" })
if legacy_value ~= 900 then
  error("expected legacy fallback to work")
end

local broken_value = fluid.read_amount(broken, { "getSteamAmount" })
if broken_value ~= 400 then
  error("expected fallback after tanks error")
end

local ratio_percent, source_percent = fluid.resolve_ratio(nil, nil, 75)
if ratio_percent ~= 0.75 or source_percent ~= "getCoolantFilledPercentage(percent)" then
  error("expected coolant percentage normalization to ratio")
end

local ratio_fraction, source_fraction = fluid.resolve_ratio(nil, nil, 0.42)
if ratio_fraction ~= 0.42 or source_fraction ~= "getCoolantFilledPercentage(fraction)" then
  error("expected coolant fraction passthrough")
end

local ratio_amount, source_amount = fluid.resolve_ratio(420, 1000, nil)
if ratio_amount ~= 0.42 or source_amount ~= "getCoolantAmount/getCoolantAmountMax" then
  error("expected amount/max fallback for coolant ratio")
end

local coolant_sample = fluid.read_coolant_sample({
  getCoolantAmount = function() return 420 end,
  getCoolantAmountMax = function() return 1000 end,
  getCoolantFilledPercentage = function() return 42 end
})
if coolant_sample.coolant_ratio ~= 0.42 then
  error("coolant sample helper must normalize ratio")
end
if coolant_sample.measurement_state ~= "FRESH" then
  error("coolant sample helper must classify valid measurements as fresh")
end
if coolant_sample.source_method ~= "getCoolantFilledPercentage" then
  error("coolant sample helper must report selected API method")
end

print("rt_fluid_compat_test.lua: ok")
