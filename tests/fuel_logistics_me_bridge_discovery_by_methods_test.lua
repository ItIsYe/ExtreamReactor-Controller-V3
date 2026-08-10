package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test for the ME Bridge discovery fix (siehe nodes/fuel/
-- logistics_router.lua M:refresh_peripherals()). Vor diesem Fix wurde die
-- ME Bridge ausschliesslich ueber peripheral.isPresent("me_bridge") (bzw.
-- den konfigurierten Namen) gesucht -- das tatsaechliche Advanced-
-- Peripherals-Peripheral heisst aber automatisch vergeben z.B.
-- "meBridge_0", nicht "me_bridge". Ohne manuell exakt gesetzten
-- config.logistics.me_bridge-Namen meldete sich eine korrekt verkabelte
-- ME Bridge dauerhaft als "absent". Jetzt faellt die Discovery bei
-- fehlendem konfiguriertem Namen auf eine Methodensignatur-Suche
-- (getItem + exportItemToPeripheral + importItemFromPeripheral) zurueck.

local logistics_router = require('nodes.fuel.logistics_router')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_bridge_peripheral()
  return {
    getItem = function() return nil end,
    exportItemToPeripheral = function() return 0 end,
    importItemFromPeripheral = function() return 0 end,
  }
end

local function set_peripheral_mock(names_to_methods, present_names)
  _G.peripheral = {
    getNames = function()
      local out = {}
      for name in pairs(names_to_methods) do out[#out + 1] = name end
      table.sort(out)
      return out
    end,
    getMethods = function(name)
      local methods = names_to_methods[name]
      if not methods then return nil end
      local out = {}
      for m in pairs(methods) do out[#out + 1] = m end
      return out
    end,
    isPresent = function(name) return present_names[name] == true end,
    wrap = function(name)
      if not names_to_methods[name] then return nil end
      return make_bridge_peripheral()
    end,
  }
end

-- 1. Kein expliziter me_bridge-Name konfiguriert, das Peripheral heisst
--    "meBridge_0" (Advanced-Peripherals-Konvention) statt "me_bridge" --
--    muss trotzdem per Methodensignatur gefunden und gebunden werden.
do
  set_peripheral_mock({
    ["meBridge_0"] = { getItem = true, exportItemToPeripheral = true, importItemFromPeripheral = true },
  }, {})

  local router = logistics_router.new({ config = { logistics = { enabled = true, reactors = {} } } })
  router:refresh_peripherals()

  assert_true(router._state.bridge ~= nil, 'ME Bridge must be found via method-signature fallback')
  assert_eq(router._state.bridge.name, 'meBridge_0', 'discovered bridge name should be the actual peripheral name')
end

-- 2. Der AUSGELIEFERTE Config-Default setzt me_bridge="me_bridge". Wenn
--    genau dieser Konventionsname nicht existiert, muss trotzdem meBridge_0
--    per Methodensignatur gefunden werden; sonst blockiert der Default selbst
--    den Autodiscovery-Fallback.
do
  set_peripheral_mock({
    ["meBridge_0"] = { getItem = true, exportItemToPeripheral = true, importItemFromPeripheral = true },
  }, {})

  local router = logistics_router.new({ config = { logistics = { enabled = true, reactors = {}, me_bridge = "me_bridge" } } })
  router:refresh_peripherals()

  assert_true(router._state.bridge ~= nil, 'shipped me_bridge default must still allow method-signature fallback')
  assert_eq(router._state.bridge.name, 'meBridge_0', 'default fallback should bind the actual generated peripheral name')
end

-- 3. Der konfigurierte Default-Name "me_bridge" ist direkt vorhanden --
--    weiterhin der bevorzugte, schnelle Pfad (kein Scan noetig).
do
  set_peripheral_mock({
    ["me_bridge"] = { getItem = true, exportItemToPeripheral = true, importItemFromPeripheral = true },
  }, { me_bridge = true })

  local router = logistics_router.new({ config = { logistics = { enabled = true, reactors = {} } } })
  router:refresh_peripherals()

  assert_true(router._state.bridge ~= nil, 'ME Bridge must be found via the configured/default name')
  assert_eq(router._state.bridge.name, 'me_bridge', 'discovered bridge name should be the configured name')
end

-- 4. Ein EXPLIZIT konfigurierter me_bridge-Name, der (noch) nicht
--    angeschlossen ist, darf NICHT stillschweigend durch eine andere im
--    Netzwerk gefundene ME Bridge ersetzt werden -- klar als absent
--    melden, damit Fehlkonfigurationen sichtbar bleiben.
do
  set_peripheral_mock({
    ["meBridge_0"] = { getItem = true, exportItemToPeripheral = true, importItemFromPeripheral = true },
  }, {})

  local router = logistics_router.new({ config = { logistics = { enabled = true, reactors = {}, me_bridge = "me_bridge_upstairs" } } })
  router:refresh_peripherals()

  assert_true(router._state.bridge == nil, 'an explicitly configured but absent me_bridge name must not silently bind a different bridge')
end

-- 5. Kein passendes Peripheral im Netzwerk -- bridge bleibt nil, kein
--    Absturz.
do
  set_peripheral_mock({
    ["monitor_0"] = { setTextScale = true },
  }, {})

  local router = logistics_router.new({ config = { logistics = { enabled = true, reactors = {} } } })
  router:refresh_peripherals()

  assert_true(router._state.bridge == nil, 'no ME Bridge should be bound when nothing matches')
end

print("fuel_logistics_me_bridge_discovery_by_methods_test.lua: ok")
