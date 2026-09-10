-- nodes/reprocessor/feed_router.lua
--
-- Reprocessoren haben KEINEN eigenen Computer-Port — der Füllstand kann
-- nicht abgefragt werden. Statt füllstandsbasiertem Nachfüllen wird in
-- zufälligen Abständen reihum jeder konfigurierte Reprocessor mit genau
-- feed_amount (Standard: 2) Cyanite befüllt — das Minimum damit der
-- Reprocessor überhaupt zu arbeiten beginnt.
--
-- Routing läuft über einen Mekanism Logistical Sorter statt über eine
-- Ventil-Baum-Topologie: alle Exporte gehen an denselben export_inlet
-- (der Sorter-Eingang), und vor jedem Export wird die Sorter-Default-
-- Farbe (adapters/logistical_sorter.lua) auf die des aktuellen Ziels
-- gesetzt. Farbige Mekanism Logistical Transporter transportieren das
-- Item dann zum passenden Reprocessor. Dadurch entfällt die
-- Pfad-öffnen/liefern/schließen-Zustandsmaschine komplett — ein Feed ist
-- ein einziger synchroner Schritt (Farbe setzen, exportieren).
--
-- Config (config.feed):
--   enabled            = true/false
--   me_bridge          = "me_bridge"
--   sorter             = "logistical_sorter_0"  -- Logistical Sorter, dessen
--                                                  Default-Farbe pro Feed
--                                                  gesetzt wird
--   export_inlet       = "mekanism:logistical_transporter_0"
--                                                -- gemeinsamer Export-
--                                                  Eingang (Sorter-Seite)
--   waste_item         = "bigreactors:cyanite_ingot"
--   feed_amount        = 2          -- Items pro Befüllung
--   interval_min_s     = 20         -- zufälliges Intervall: min..max Sekunden
--   interval_max_s     = 60
--   discovery_interval = 60
--   targets = {
--     { label = "Reprocessor A", color = "RED" },
--     { label = "Reprocessor B", color = "BLUE" },
--   }
--   -- gültige Farben: adapters/logistical_sorter.lua's sorter.COLORS
--   -- (Mekanism EnumColor) -- per Router-UI zugewiesen, siehe
--   -- nodes/reprocessor/color_router_ui.lua.
--   chest = { enabled = false, target = nil }
--   -- Optionale zweite Sammel-Kiste für rohes Cyanit (für den Fall, dass
--   -- man Cyanit unverarbeitet haben möchte statt es an einen Reprocessor
--   -- zu liefern) -- eigener An/Aus-Schalter, läuft auf ihrem eigenen
--   -- zufälligen Intervall, UNABHÄNGIG von der Reprocessor-Rotation oben.
--   -- Läuft NICHT über den Sorter/eine Farbe -- "target" ist der Name der
--   -- Kisten-Peripherie direkt, und wird per ME-Bridge/Wired-Modem-Export
--   -- direkt dorthin geliefert (siehe feed_chest()).

local logistical_sorter = require("adapters.logistical_sorter")
local me_bridge_compat = require("core.me_bridge_compat")

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
    _state = {
      bridge          = nil,
      bridge_name     = nil,
      sorter          = nil,
      sorter_name     = nil,
      last_refresh    = 0,
      next_feed_ts    = 0,   -- os.epoch("utc") wann der nächste Feed-Versuch ist
      target_index    = 1,   -- rotierender Index durch die targets-Liste
      last_target     = nil,
      total_feeds     = 0,
      last_feed_ts    = nil,
      last_error      = nil,
      -- Unabhängiger Zyklus für die optionale Cyanit-Sammel-Kiste
      -- (config.feed.chest) -- eigenes Intervall, eigener Fehlerstatus,
      -- läuft parallel zur Reprocessor-Rotation oben.
      next_chest_feed_ts = 0,
      chest_total_feeds  = 0,
      chest_last_feed_ts = nil,
      chest_last_error   = nil,
    },
  }
  return setmetatable(self, { __index = M })
end

-- ---- peripheral discovery --------------------------------------------------

-- Faellt, sofern kein expliziter Name konfiguriert ist, auf eine
-- Methodensignatur-Suche zurueck (core/me_bridge_compat.lua, deckt beide
-- Advanced-Peripherals-API-Generationen ab) -- Advanced Peripherals
-- vergibt generierte Namen wie "meBridge_0"/"me_bridge_3", nicht den
-- Konventions-Default "me_bridge".
local function find_me_bridge_by_methods()
  for _, name in ipairs(peripheral.getNames() or {}) do
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and type(methods) == "table" then
      local set = {}
      for _, m in ipairs(methods) do set[m] = true end
      if me_bridge_compat.is_bridge(set) then
        return name
      end
    end
  end
  return nil
end

-- Gleiche Fallback-Logik wie find_me_bridge_by_methods(), fuer den
-- Logistical Sorter: adapters/logistical_sorter.lua's Methoden-Check
-- entscheidet, nicht der Peripherie-Name.
local function find_sorter_by_methods()
  for _, name in ipairs(peripheral.getNames() or {}) do
    local adapter = logistical_sorter.detect(name, "REPROC")
    if adapter then
      return name, adapter
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

  local sorter_name = cfg.sorter
  local sorter_adapter = nil
  if type(sorter_name) == "string" and sorter_name ~= "" and peripheral.isPresent(sorter_name) then
    sorter_adapter = logistical_sorter.detect(sorter_name, "REPROC")
  end
  if not sorter_adapter then
    local found_sorter_name, found_adapter = find_sorter_by_methods()
    if found_adapter then
      sorter_name, sorter_adapter = found_sorter_name, found_adapter
    end
  end
  if sorter_adapter then
    self._state.sorter = sorter_adapter
    self._state.sorter_name = sorter_name
  else
    self.warn_once("sorter_abs", "FeedRouter: Logistical Sorter nicht gefunden: " .. tostring(cfg.sorter))
    self._state.sorter = nil
  end

  self._state.last_refresh = os.epoch("utc")
end

-- ---- feed cycle -------------------------------------------------------------

-- Führt eine Befüllung für genau EIN Target durch (Rotation durch die Liste):
-- Sorter-Default-Farbe auf die des Ziels setzen, dann exportieren. Beide
-- Schritte sind einzelne synchrone Peripherie-Calls -- anders als beim
-- frueheren Ventil-Pfad-System gibt es keine mehrstufige Transaktion mehr,
-- die ueber mehrere tick()-Aufrufe laufen muesste.
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

  if not target or not target.color then
    self.warn_once("bad_target:" .. tostring(idx), "FeedRouter: target ohne Farbe, übersprungen")
    return
  end

  local bridge = self._state.bridge
  if not bridge then
    self.warn_once("no_bridge", "FeedRouter: keine ME-Bridge verfügbar, Feed übersprungen")
    return
  end

  local sorter = self._state.sorter
  if not sorter then
    self.warn_once("no_sorter", "FeedRouter: kein Logistical Sorter verfügbar, Feed übersprungen")
    return
  end

  local export_inlet = cfg.export_inlet
  if type(export_inlet) ~= "string" or export_inlet == "" then
    self.warn_once("no_export_inlet", "FeedRouter: kein export_inlet konfiguriert, Feed übersprungen")
    return
  end

  local item   = cfg.waste_item or "bigreactors:cyanite_ingot"
  local amount = tonumber(cfg.feed_amount) or 2

  -- Verfügbarkeit in ME prüfen
  local me_info = safe_call(bridge, "getItem", { name = item })
  local in_me = me_bridge_compat.item_amount(me_info)
  if in_me < amount then
    self.warn_once("me_low:" .. tostring(target.label),
      string.format("FeedRouter: ME hat nur %d %s (brauche %d) — übersprungen", in_me, item, amount))
    return
  end

  local color_ok, color_err = sorter.setDefaultColor(target.color)
  if not color_ok then
    self._state.last_error = "sorter_color_failed:" .. tostring(color_err)
    self.warn_once("sorter_color_fail:" .. tostring(target.label),
      "FeedRouter: Sorter-Farbe fuer " .. tostring(target.label) .. " (" .. tostring(target.color)
        .. ") konnte nicht gesetzt werden: " .. tostring(color_err))
    return
  end

  local ok, result = me_bridge_compat.export_to(bridge, { name = item, count = amount }, export_inlet)
  local err = nil
  if not ok then err = result; result = nil end
  local exported = type(result) == "table" and me_bridge_compat.item_amount(result)
    or (type(result) == "number" and result or 0)
  if exported and exported > 0 then
    self._state.total_feeds = self._state.total_feeds + 1
    self._state.last_feed_ts = os.epoch("utc")
    self._state.last_target = target.label
    self._state.last_error = nil
    self.log("INFO", string.format(
      "FeedRouter: %s fed with %d/%d %s (color=%s)", target.label, exported, amount, item, tostring(target.color)))
  else
    self._state.last_error = tostring(err or "export failed")
    self.warn_once("feed_fail:" .. tostring(target.label),
      "FeedRouter: feed failed for " .. tostring(target.label) .. ": " .. tostring(err))
  end
end

-- Befüllt die optionale Sammel-Kiste (config.feed.chest) mit rohem Cyanit --
-- ANDERS als feed_one(): kein Sorter, keine Farbe -- der ME-Bridge-Export
-- geht per Wired-Modem-Netzwerk DIREKT an chest.target (eigene
-- Peripherie-Auswahl, siehe color_router_ui.lua). Das ist die einzige
-- Peripherie-Anforderung: die Kiste muss per Wired Modem am selben
-- ME-Netzwerk hängen wie die ME-Bridge.
local function feed_chest(self, cfg)
  local chest = cfg.chest
  if not chest or chest.enabled ~= true then return end
  if type(chest.target) ~= "string" or chest.target == "" then
    self.warn_once("chest_no_target", "FeedRouter: Kiste aktiv, aber kein Ziel-Peripheral gesetzt, übersprungen")
    return
  end

  local bridge = self._state.bridge
  if not bridge then
    self.warn_once("chest_no_bridge", "FeedRouter: keine ME-Bridge verfügbar, Kiste übersprungen")
    return
  end

  local item   = cfg.waste_item or "bigreactors:cyanite_ingot"
  local amount = tonumber(cfg.feed_amount) or 2

  local me_info = safe_call(bridge, "getItem", { name = item })
  local in_me = me_bridge_compat.item_amount(me_info)
  if in_me < amount then
    self.warn_once("chest_me_low", string.format(
      "FeedRouter: ME hat nur %d %s (brauche %d) für Kiste — übersprungen", in_me, item, amount))
    return
  end

  local ok, result = me_bridge_compat.export_to(bridge, { name = item, count = amount }, chest.target)
  local err = nil
  if not ok then err = result; result = nil end
  local exported = type(result) == "table" and me_bridge_compat.item_amount(result)
    or (type(result) == "number" and result or 0)
  if exported and exported > 0 then
    self._state.chest_total_feeds = self._state.chest_total_feeds + 1
    self._state.chest_last_feed_ts = os.epoch("utc")
    self._state.chest_last_error = nil
    self.log("INFO", string.format(
      "FeedRouter: Kiste (%s) befüllt mit %d/%d %s", tostring(chest.target), exported, amount, item))
  else
    self._state.chest_last_error = tostring(err or "export failed")
    self.warn_once("chest_feed_fail", "FeedRouter: Befüllung der Kiste fehlgeschlagen: " .. tostring(err))
  end
end

-- Es gibt keine asynchrone Transaktion mehr, die abgebrochen werden
-- muesste (siehe Modulkommentar oben) -- bleibt als No-Op fuer die main.lua-
-- Schnittstelle (enter_standby() ruft dies weiterhin auf) erhalten.
function M:cancel(_reason)
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

  -- Sammel-Kiste läuft auf ihrem eigenen zufälligen Intervall, unabhängig
  -- von der Reprocessor-Rotation unten -- eigener Zeitplan, eigener Toggle.
  local chest = cfg.chest
  if chest and chest.enabled == true then
    if self._state.next_chest_feed_ts == 0 then
      self._state.next_chest_feed_ts = now + random_interval(cfg) * 1000
    elseif now >= self._state.next_chest_feed_ts then
      feed_chest(self, cfg)
      self._state.next_chest_feed_ts = now + random_interval(cfg) * 1000
    end
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
    sorter_bound   = self._state.sorter ~= nil,
    chest_enabled       = cfg.chest ~= nil and cfg.chest.enabled == true,
    chest_total_feeds   = self._state.chest_total_feeds,
    chest_last_feed_ts  = self._state.chest_last_feed_ts,
    chest_last_feed_age_s = self._state.chest_last_feed_ts and math.floor((now - self._state.chest_last_feed_ts) / 1000) or nil,
    chest_next_feed_in_s = self._state.next_chest_feed_ts > 0 and math.max(0, math.floor((self._state.next_chest_feed_ts - now) / 1000)) or nil,
    chest_last_error    = self._state.chest_last_error,
  }
end

return M
