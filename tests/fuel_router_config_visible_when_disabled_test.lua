package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: "auf der FUEL-UI werden die konfigurierten Reaktoren/Routen
-- nicht geladen".
--
-- Geladen WURDEN sie: main.lua liest /xreactor_config/fuel_routes.lua nach
-- config.logistics.reactors, und config_normalizer.normalize() laesst sie
-- stehen. Die Oberflaeche liest den Reaktor-Zustand aber nicht aus der
-- Config, sondern aus dem Statuspayload -> logistics_router:get_summary()
-- -> self._state.reactors. Und _state.reactors wurde ausschliesslich von
-- refresh_peripherals() gefuellt, das nur hinter `if cfg.enabled ~= true
-- then return end` in tick() erreichbar ist.
--
-- logistics.enabled ist per Default false (Sicherheitsschalter) und wird
-- vom Normalizer zusaetzlich zwangsweise auf false gesetzt, solange
-- export_chest fehlt. Die Folge: dauerhaft "Keine Reaktoren konfiguriert"
-- (ui_completion.lua's CONFIG_REQUIRED), obwohl alles konfiguriert war.

local logistics_router = require('nodes.fuel.logistics_router')
local ui_completion = require('nodes.fuel.ui_completion')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function make_config(enabled)
  return {
    logistics = {
      enabled = enabled,
      interval = 5,
      discovery_interval = 60,
      reactors = {
        { reactor_id = 'RT-1:reactor_0', label = 'Reaktor Nord', path = { 'VALVE-7' },
          request_below = 0.25, fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30 },
        { reactor_id = 'RT-2:reactor_0', label = 'Reaktor Sued', path = { 'VALVE-8' },
          request_below = 0.30, fill_amount = 64, min_in_me = 32, resupply_cooldown_s = 30 },
      },
    },
  }
end

local function new_router(config)
  return logistics_router.new({
    config = config,
    log = function() end,
    warn_once = function() end,
    fuel_status = { master_relay = {}, direct_heard = {} },
  })
end

-- 1. Bei abgeschalteter Logistik kennt der Router seine Reaktoren trotzdem.
do
  local router = new_router(make_config(false))
  assert_eq(#router._state.reactors, 0, 'sanity: nothing known before the first tick')

  router:tick()

  assert_eq(#router._state.reactors, 2, 'disabled logistics must still map the configured reactors')
  assert_eq(router._state.reactors[1].reactor_id, 'RT-1:reactor_0')
  assert_eq(router._state.reactors[1].label, 'Reaktor Nord')
  assert_eq(#router._state.reactors[1].path, 1, 'the valve path must survive')
  assert_eq(router._state.reactors[2].reactor_id, 'RT-2:reactor_0')

  local summary = router:get_summary()
  assert_eq(#summary.reactors, 2, 'get_summary must report them -- this is what the UI reads')
end

-- 2. Und die Oberflaeche meldet dann nicht mehr "Keine Reaktoren konfiguriert",
--    sondern den tatsaechlichen Grund (Logistik abgeschaltet).
do
  local router = new_router(make_config(false))
  router:tick()
  local view = ui_completion.compute_view_state(
    { payload = { logistics = { reactors = router:get_summary().reactors, enabled = false },
      bindings = { storage = 1 }, valve_summary = {} } },
    {}, 0, 0)
  assert_true(view.code ~= 'CONFIG_REQUIRED', string.format(
    'the UI must not claim "no reactors configured" (got code=%s)', tostring(view.code)))
  assert_eq(view.code, 'LOGISTICS_DISABLED', 'the real reason must surface instead')
end

-- 3. Der abgeschaltete Zweig hat keine Nebenwirkungen: kein Lieferzyklus,
--    kein Redstone-Router, keine Peripherie-Bindung.
do
  local router = new_router(make_config(false))
  local ran = false
  router.run_cycle = function() ran = true end
  router:tick()
  assert_true(not ran, 'a disabled router must never run a supply cycle')
  assert_eq(router._state.rs_router, nil, 'a disabled router must not build a redstone router')
  assert_eq(router._state.bridge, nil, 'a disabled router must not bind the ME bridge')
  assert_eq(router._state.last_run_ts, 0, 'a disabled router must not advance its cycle clock')
end

-- 4. Stillgelegte Eintraege bleiben als stillgelegt sichtbar (sie
--    verschwinden nicht, damit der Grund ablesbar bleibt).
do
  local config = make_config(false)
  config.logistics.reactors[2].disabled_reason = 'ohne reactor_id -- Eintrag stillgelegt'
  local router = new_router(config)
  router:tick()
  assert_eq(#router._state.reactors, 2, 'a disabled entry must stay listed')
  assert_eq(router._state.reactors[2].disabled_reason, 'ohne reactor_id -- Eintrag stillgelegt')
end

print('fuel_router_config_visible_when_disabled_test.lua: ok')
