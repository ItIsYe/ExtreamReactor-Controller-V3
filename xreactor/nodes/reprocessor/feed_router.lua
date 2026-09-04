-- nodes/reprocessor/feed_router.lua
--
-- Reprocessoren haben KEINEN eigenen Computer-Port — der Füllstand kann
-- nicht abgefragt werden. Statt füllstandsbasiertem Nachfüllen wird in
-- zufälligen Abständen reihum jeder konfigurierte Reprocessor mit genau
-- feed_amount (Standard: 2) Cyanite befüllt — das Minimum damit der
-- Reprocessor überhaupt zu arbeiten beginnt.
--
-- Routing nutzt dieselbe Baum-Topologie wie die Fuel-Node (redstone_router):
-- ein Ventil-Pfad wird geöffnet, das Item exportiert, dann wird der Pfad
-- wieder blockiert. So bekommt nur EIN Reprocessor pro Zyklus Material.
--
-- Config (config.feed):
--   enabled            = true/false
--   me_bridge          = "me_bridge"
--   waste_item         = "bigreactors:cyanite_ingot"
--   feed_amount        = 2          -- Items pro Befüllung
--   interval_min_s     = 20         -- zufälliges Intervall: min..max Sekunden
--   interval_max_s     = 60
--   valve_open_ms      = 2000
--   discovery_interval = 60
--   targets = {
--     { label = "Reprocessor A", inlet = "mekanism:transporter_2" },
--     { label = "Reprocessor B", inlet = "mekanism:transporter_3" },
--   }
--   redstone_tree = { ... }  -- siehe nodes/fuel/redstone_router.lua

local redstone_router_lib = require("nodes.fuel.redstone_router")

local M = {}

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return nil, "no_method" end
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

-- Wählt eine zufällige Wartezeit zwischen min und max Sekunden.
local function random_interval(cfg)
  local lo = tonumber(cfg.interval_min_s) or 20
  local hi = tonumber(cfg.interval_max_s) or 60
  if hi < lo then hi = lo end
  return lo + math.random() * (hi - lo)
end

function M.new(opts)
  opts = opts or {}
  local self = {
    config    = opts.config or {},
    log       = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    rs_router = opts.rs_router or redstone_router_lib.new({
      config    = opts.config,
      log       = opts.log,
      warn_once = opts.warn_once,
    }),
    _state = {
      bridge          = nil,
      bridge_name     = nil,
      last_refresh    = 0,
      next_feed_ts    = 0,   -- os.epoch("utc") wann der nächste Feed-Versuch ist
      target_index    = 1,   -- rotierender Index durch die targets-Liste
      last_target     = nil,
      total_feeds     = 0,
      last_feed_ts    = nil,
      last_error      = nil,
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- peripheral discovery --------------------------------------------------

-- Faellt, sofern kein expliziter Name konfiguriert ist, auf eine
-- Methodensignatur-Suche zurueck (getItem + exportItemToPeripheral) --
-- Advanced Peripherals vergibt generierte Namen wie "meBridge_0", nicht
-- den Konventions-Default "me_bridge".
local function find_me_bridge_by_methods()
  for _, name in ipairs(peripheral.getNames() or {}) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      local set = {}
      for _, m in ipairs(methods) do set[m] = true end
      if set.getItem and set.exportItemToPeripheral then
        return name
      end
    end
  end
  return nil
end

function M:refresh_peripherals()
  local cfg = self.config.feed or {}
  local name = cfg.me_bridge or "me_bridge"
  local found_name = nil
  if peripheral.isPresent(name) then
    found_name = name
  elseif cfg.me_bridge == nil or cfg.me_bridge == ""
      or cfg.me_bridge == "me_bridge" or cfg.me_bridge == "meBridge" then
    -- Shipped convention defaults are eligible for capability fallback; only
    -- genuinely custom names are strict bindings.
    found_name = find_me_bridge_by_methods()
  end
  if found_name then
    local ok, w = pcall(peripheral.wrap, found_name)
    if ok and w then
      self._state.bridge = w
      self._state.bridge_name = found_name
    else
      self.warn_once("bridge_wrap", "FeedRouter: ME-Bridge wrap failed: " .. found_name)
      self._state.bridge = nil
    end
  else
    self.warn_once("bridge_abs", "FeedRouter: ME-Bridge absent: " .. name)
    self._state.bridge = nil
  end
  self.rs_router:refresh()
  self._state.last_refresh = os.epoch("utc")
end

-- ---- feed cycle -------------------------------------------------------------

-- Führt eine Befüllung für genau EIN Target durch (Rotation durch die Liste).
local function feed_one(self, cfg)
  local targets = cfg.targets or {}
  if #targets == 0 then
    self.warn_once("no_targets", "FeedRouter: keine targets konfiguriert")
    return
  end

  -- Rotierend nächstes Target wählen
  local idx = self._state.target_index
  if idx > #targets then idx = 1 end
  local target = targets[idx]
  self._state.target_index = idx + 1

  if not target or not target.inlet then
    self.warn_once("bad_target:" .. tostring(idx), "FeedRouter: target ohne inlet, übersprungen")
    return
  end

  local bridge = self._state.bridge
  if not bridge then
    self.warn_once("no_bridge", "FeedRouter: keine ME-Bridge verfügbar, Feed übersprungen")
    return
  end

  local item   = cfg.waste_item or "bigreactors:cyanite_ingot"
  local amount = tonumber(cfg.feed_amount) or 2

  -- Verfügbarkeit in ME prüfen
  local me_info = safe_call(bridge, "getItem", { name = item })
  local in_me = type(me_info) == "table" and (me_info.amount or 0) or 0
  if in_me < amount then
    self.warn_once("me_low:" .. tostring(target.label),
      string.format("FeedRouter: ME hat nur %d %s (brauche %d) — übersprungen", in_me, item, amount))
    return
  end

  -- Asynchrone Zustandsmaschine (begin_transaction() + tick() in
  -- redstone_router.lua, von M:tick() regelmaessig aufgerufen) statt
  -- blockierendem route_and_act(). "busy" tritt praktisch nur auf, wenn
  -- eine vorherige Befuellung noch nicht abgeschlossen ist -- wird dann
  -- einfach uebersprungen, das naechste Intervall versucht es erneut.
  local started, reason = self.rs_router:begin_transaction(target.label, function()
    local result, err = safe_call(bridge, "exportItemToPeripheral", { name = item, count = amount }, target.inlet)
    local exported = type(result) == "table" and (result.amount or 0) or (type(result) == "number" and result or 0)
    if exported and exported > 0 then
      self._state.total_feeds = self._state.total_feeds + 1
      self._state.last_feed_ts = os.epoch("utc")
      self._state.last_target = target.label
      self._state.last_error = nil
      self.log("INFO", string.format(
        "FeedRouter: %s fed with %d/%d %s", target.label, exported, amount, item))
    else
      self._state.last_error = tostring(err or "export failed")
      self.warn_once("feed_fail:" .. tostring(target.label),
        "FeedRouter: feed failed for " .. tostring(target.label) .. ": " .. tostring(err))
    end
  end, cfg.valve_open_ms, {
    -- Muss last_error explizit setzen, wenn die Transaktion VOR dem Export
    -- abbricht (Ventil-ACK-Fehler, Phasen-Timeout) -- sonst bliebe
    -- last_error stumm auf dem letzten, moeglicherweise veralteten Wert
    -- stehen, obwohl diese Befuellung tatsaechlich gescheitert ist.
    on_error = function(reason)
      self._state.last_error = "routing_failed:" .. tostring(reason)
      self.warn_once("feed_route_fail:" .. tostring(target.label),
        "FeedRouter: Routing-Transaktion fuer " .. tostring(target.label) .. " abgebrochen (" .. tostring(reason) .. ")")
    end,
  })
  if not started then
    self.warn_once("router_busy:" .. tostring(reason),
      "FeedRouter: Befuellung fuer " .. tostring(target.label) .. " uebersprungen (" .. tostring(reason) .. ")")
  end
end

-- Bricht eine laufende Ventil-Transaktion sofort ab (z.B. beim Uebergang in
-- Standby/MASTER-Timeout). shutdown_now() ruft dabei tx.on_error() auf,
-- was automatisch last_error setzt -- der Abbruch bleibt fuer Diagnose/UI sichtbar.
function M:cancel(reason)
  self.rs_router:shutdown_now(reason)
end

function M:tick()
  local cfg = self.config.feed or self.config or {}
  if cfg.enabled ~= true then return end

  local now = os.epoch("utc")

  -- Peripherals periodisch neu erkennen
  local refresh_ms = (tonumber(cfg.discovery_interval) or 60) * 1000
  if now - self._state.last_refresh >= refresh_ms then
    self:refresh_peripherals()
  end

  -- Zufälliges Intervall: beim ersten Tick sofort einen Timer setzen
  if self._state.next_feed_ts == 0 then
    self._state.next_feed_ts = now + random_interval(cfg) * 1000
    return
  end

  if now < self._state.next_feed_ts then return end

  feed_one(self, cfg)

  -- Nächstes zufälliges Intervall planen
  self._state.next_feed_ts = now + random_interval(cfg) * 1000
end

-- ---- status / introspection -------------------------------------------------

function M:get_summary()
  local cfg = self.config.feed or {}
  local now = os.epoch("utc")
  return {
    enabled        = cfg.enabled == true,
    total_feeds    = self._state.total_feeds,
    last_target    = self._state.last_target,
    last_feed_ts   = self._state.last_feed_ts,
    last_feed_age_s = self._state.last_feed_ts and math.floor((now - self._state.last_feed_ts) / 1000) or nil,
    next_feed_in_s = self._state.next_feed_ts > 0 and math.max(0, math.floor((self._state.next_feed_ts - now) / 1000)) or nil,
    last_error     = self._state.last_error,
    target_count   = #(cfg.targets or {}),
  }
end

return M
