package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local function reset_modules()
  package.loaded["core.utils"] = nil
  package.loaded["adapters.reactor"] = nil
end

local function make_peripheral_stub(device)
  _G.peripheral = {
    isPresent = function(name) return name == "reactor_0" end,
    getMethods = function(name)
      if name ~= "reactor_0" then return {} end
      return device.methods
    end,
    getType = function() return "BigReactors-Reactor" end,
    call = function(name, method, ...)
      if name ~= "reactor_0" then
        error("missing peripheral")
      end
      local fn = device.calls[method]
      if not fn then
        error("method missing: " .. tostring(method))
      end
      return fn(...)
    end,
  }
end

local function test_read_control_rods_uses_getControlRods_fallback()
  reset_modules()
  local rods = {
    { level = 10 },
    { level = 30 },
  }
  make_peripheral_stub({
    methods = { "getControlRods" },
    calls = {
      getControlRods = function() return rods end,
    },
  })
  local reactor = require("adapters.reactor")
  local level, err = reactor.read_control_rods("reactor_0", "TEST")
  if err ~= nil then
    error("expected fallback read to succeed, got error " .. tostring(err))
  end
  if math.abs(level - 20) > 0.001 then
    error("expected average rod level 20 from fallback, got " .. tostring(level))
  end
end

local function test_apply_control_rods_uses_getControlRods_setLevel_fallback()
  reset_modules()
  local applied = {}
  local rods = {
    { setLevel = function(_, value) applied[1] = value end },
    { setLevel = function(_, value) applied[2] = value end },
  }
  make_peripheral_stub({
    methods = { "getControlRods" },
    calls = {
      getControlRods = function() return rods end,
    },
  })
  local reactor = require("adapters.reactor")
  local ok, err = reactor.apply_rod_level("reactor_0", 42, "TEST")
  if not ok or err ~= nil then
    error("expected fallback write to succeed, got " .. tostring(err))
  end
  if applied[1] ~= 42 or applied[2] ~= 42 then
    error("expected fallback write to set every rod to 42")
  end
end

local function test_apply_control_rods_uses_setControlRodLevel_fallback_and_clamps()
  reset_modules()
  local calls = {}
  make_peripheral_stub({
    methods = { "setControlRodLevel", "getControlRodLevels" },
    calls = {
      getControlRodLevels = function() return { 10, 20, 30 } end,
      setControlRodLevel = function(index, value)
        table.insert(calls, { index = index, value = value })
        return true
      end,
    },
  })
  local reactor = require("adapters.reactor")
  local ok, err = reactor.apply_rod_level("reactor_0", 175, "TEST")
  if not ok or err ~= nil then
    error("expected indexed fallback write to succeed, got " .. tostring(err))
  end
  if #calls ~= 3 then
    error("expected setControlRodLevel to be called for each rod, got " .. tostring(#calls))
  end
  for idx, call in ipairs(calls) do
    if call.index ~= (idx - 1) then
      error("unexpected rod index: " .. tostring(call.index))
    end
    if call.value ~= 100 then
      error("expected clamped rod value 100, got " .. tostring(call.value))
    end
  end
end

local function test_apply_control_rods_prefers_setControlRodLevel_over_getControlRods()
  reset_modules()
  local indexed_calls = 0
  local rod_set_calls = 0
  local rods = {
    { setLevel = function() rod_set_calls = rod_set_calls + 1 end },
    { setLevel = function() rod_set_calls = rod_set_calls + 1 end },
  }
  make_peripheral_stub({
    methods = { "setControlRodLevel", "getControlRodLevels", "getControlRods" },
    calls = {
      getControlRodLevels = function() return { 5, 15 } end,
      getControlRods = function() return rods end,
      setControlRodLevel = function() indexed_calls = indexed_calls + 1; return true end,
    },
  })
  local reactor = require("adapters.reactor")
  local ok, err = reactor.apply_rod_level("reactor_0", 50, "TEST")
  if not ok or err ~= nil then
    error("expected setControlRodLevel path to succeed, got " .. tostring(err))
  end
  if indexed_calls ~= 2 then
    error("expected indexed fallback path to update every rod")
  end
  if rod_set_calls ~= 0 then
    error("expected getControlRods fallback to be skipped when setControlRodLevel exists")
  end
end

test_read_control_rods_uses_getControlRods_fallback()
test_apply_control_rods_uses_getControlRods_setLevel_fallback()
test_apply_control_rods_uses_setControlRodLevel_fallback_and_clamps()
test_apply_control_rods_prefers_setControlRodLevel_over_getControlRods()
print("reactor_control_rods_regression_test.lua: ok")
