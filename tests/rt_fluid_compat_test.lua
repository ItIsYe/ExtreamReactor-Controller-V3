package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local fluid = require("core.fluid")

local modern = {
  tanks = function()
    return {
      [1] = { name = "steam", amount = 1250 },
      [3] = { name = "steam", amount = 750 },
    }
  end
}

local legacy = {
  getFluidAmount = function() return 900 end
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

print("rt_fluid_compat_test.lua: ok")
