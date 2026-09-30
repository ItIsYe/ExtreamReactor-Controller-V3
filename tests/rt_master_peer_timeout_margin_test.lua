package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression: "beide RT-Nodes zeigen MASTER DOWN, obwohl der MASTER laeuft".
--
-- Ursache war kein Fehler in der Peer-Logik von core/comms.lua (die haelt
-- einer Simulation mit 5s-Heartbeat ueber 60s stand), sondern die Marge:
-- der MASTER war die EINZIGE Rolle mit heartbeat_interval=5 (alle Nodes: 2),
-- waehrend die RT-Node mit comms.peer_timeout_s=12 arbeitete. Der MASTER
-- durfte damit nur ~2 Heartbeats verlieren, eine Node dagegen 6 -- und ein
-- einzelner blockierender Discovery-Scan im RT-Slow-Loop (alle 10s, haelt
-- die gesamte Lua-VM an) reichte aus, um ihn auf DOWN zu setzen.
--
-- Zweiter Teil des Fixes: nodes/rt/health_payload.lua und
-- nodes/rt/monitor_ui.lua lesen den MASTER-Zustand aus der Peer-Tabelle
-- (peer_timeout_s), die Zustandsmaschine dagegen aus rt2_master_link
-- (TIMEOUT_MS). Diese beiden Schwellen MUESSEN uebereinstimmen, sonst
-- meldet der Schirm DOWN, waehrend der Regler noch im Zustand MASTER
-- laeuft (oder umgekehrt).

local rt_default_config = require('nodes.rt.config')
local config_normalizer = require('nodes.rt.config_normalizer')
local rt2_master_link = require('nodes.rt.rt2_master_link')
local rt2_engine = require('nodes.rt.rt2_engine')
local master_config = require('master.config')
local master_context = require('master.context')

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or 'assert_eq failed') .. ': expected=' .. tostring(expected) .. ' actual=' .. tostring(actual))
  end
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

local function deep_copy(t)
  if type(t) ~= 'table' then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end

-- 1. Die Marge selbst: der RT-Timeout muss mindestens vier MASTER-
--    Heartbeats abdecken. Bei 12s/5s waren es zwei -- genau der Zustand,
--    der in der Welt zu "MASTER DOWN" fuehrte.
do
  local hb = master_config.heartbeat_interval
  local timeout = rt_default_config.comms.peer_timeout_s
  assert_true(type(hb) == 'number' and hb > 0, 'master heartbeat_interval must be a positive number')
  assert_true(type(timeout) == 'number' and timeout > 0, 'rt comms.peer_timeout_s must be a positive number')
  assert_true(timeout >= 4 * hb, string.format(
    'RT peer_timeout_s (%s) must cover at least four MASTER heartbeats (%s) -- at 12/5 the MASTER was allowed only two',
    tostring(timeout), tostring(hb)))
end

-- 2. Der MASTER-Heartbeat darf nicht langsamer sein als der jeder anderen
--    Rolle -- er war bisher der einzige Ausreisser.
do
  for _, role in ipairs({ 'nodes.water.config', 'nodes.energy.config' }) do
    local node_config = require(role)
    assert_true(master_config.heartbeat_interval <= node_config.heartbeat_interval, string.format(
      'MASTER heartbeat (%s) must not be slower than %s (%s)',
      tostring(master_config.heartbeat_interval), role, tostring(node_config.heartbeat_interval)))
  end
end

-- 3. Der groessere Status-Takt bleibt erhalten: nur der winzige Heartbeat
--    wird haeufiger, nicht die grosse Master-Status-Payload.
do
  local cfg = deep_copy(master_config)
  master_context.normalize_config(cfg)
  assert_eq(cfg.heartbeat_interval, 2, 'master heartbeat interval after normalize_config')
  assert_eq(cfg.status_interval, 5, 'master status interval must stay at 5s (big payload)')
end

-- 4. Zustandsmaschine und Health-Check/Anzeige benutzen dieselbe Schwelle.
do
  assert_eq(rt2_master_link.TIMEOUT_MS, rt_default_config.comms.peer_timeout_s * 1000,
    'rt2_master_link.TIMEOUT_MS must match the peer table threshold the UI/health check reads')
end

-- 5. Eine abweichend konfigurierte Node bleibt ebenfalls konsistent:
--    rt2_engine.init() leitet die Schwelle aus config.comms.peer_timeout_s ab.
do
  local engine = rt2_engine.init({
    turbine_count = 0,
    config = { reactors = {}, comms = { peer_timeout_s = 8.0 } },
    log = function() end,
  })
  assert_eq(engine.master_link.timeout_ms, 8000,
    'engine must derive the MASTER liveness threshold from config.comms.peer_timeout_s')

  -- Ohne comms-Block bleibt der Modul-Default stehen (kein nil-Timeout).
  local fallback = rt2_engine.init({ turbine_count = 0, config = { reactors = {} }, log = function() end })
  assert_eq(fallback.master_link.timeout_ms, rt2_master_link.TIMEOUT_MS,
    'without a comms block the module default must apply')
end

-- 6. Altconfig-Migration: eine bereits installierte /xreactor_config/rt.lua
--    haelt den alten 12.0-Wert dauerhaft fest -- validate_config() fasst
--    eine valide Zahl nicht an. Nur der historische DEFAULT wird migriert.
do
  local warnings = {}
  local cfg = { version = 5, comms = { peer_timeout_s = 12.0 } }
  local changed = config_normalizer.migrate_schema_version(cfg, rt_default_config,
    function(w) table.insert(warnings, w) end)
  assert_true(changed, 'migration must report a change')
  assert_eq(cfg.comms.peer_timeout_s, rt_default_config.comms.peer_timeout_s,
    'historical 12.0 default must migrate to the new default')
  assert_eq(cfg.version, rt_default_config.version, 'version must be bumped')
  assert_true(#warnings >= 1, 'migration should log what it changed')
end

do
  local cfg = { version = 5, comms = { peer_timeout_s = 30.0 } }
  config_normalizer.migrate_schema_version(cfg, rt_default_config, function() end)
  assert_eq(cfg.comms.peer_timeout_s, 30.0, 'a deliberately customized value must not be overwritten')
end

do
  local cfg = deep_copy(rt_default_config)
  cfg.comms.peer_timeout_s = 12.0
  local changed = config_normalizer.migrate_schema_version(cfg, rt_default_config, function() end)
  assert_true(not changed, 'a config already on the current schema version must not be touched again')
  assert_eq(cfg.comms.peer_timeout_s, 12.0, 'once migrated past, a later user-set 12.0 must be respected')
end

print('rt_master_peer_timeout_margin_test.lua: ok')
