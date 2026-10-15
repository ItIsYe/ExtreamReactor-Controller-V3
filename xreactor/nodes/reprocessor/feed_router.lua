-- nodes/reprocessor/feed_router.lua
--
-- Physischer Aufbau (bestaetigt 2026-09-17): mehrere Reprocessor-Maschinen,
-- rein passiv beliefert -- KEIN eigener Computer-Anschluss an den
-- Maschinen selbst. Genau EINE gemeinsame SORTER-KISTE fuer alle: die
-- ME-Bridge exportiert Cyanite immer in diese eine Kiste (config.feed.
-- sorter_chest, per Router-UI gewaehlt -- eine normale Inventar-
-- Peripherie, keine ME-Peripherie). Ein Mekanism Logistical Sorter sitzt
-- physisch an dieser Kiste; vor jedem Export wird seine Default-Farbe
-- (adapters/logistical_sorter.lua) auf die des aktuellen Ziels gesetzt.
-- Ab dann uebernimmt Mekanism selbst, automatisch, ohne weitere Computer-
-- Aktion: der farbige Logistical Transporter zieht das Item aus der
-- Kiste durch den Sorter zum passenden Reprocessor. Ein Feed ist fuer den
-- Computer ein einziger synchroner Schritt (Farbe setzen, ME-Bridge ->
-- Sorter-Kiste exportieren) -- KEINE mehrstufige Transaktion, kein
-- Ventil-Pfad, kein Quiesce-Bedarf.
--
-- Da Reprocessoren keinen eigenen Computer-Port haben, kann ihr
-- Fuellstand nicht abgefragt werden -- statt fuellstandsbasiertem
-- Nachfuellen wird in zufaelligen Abstaenden reihum jeder konfigurierte
-- Reprocessor mit genau feed_amount (Standard: 2) Cyanite befuellt, das
-- Minimum damit er ueberhaupt zu arbeiten beginnt. feed_amount ist immer
-- gerade und mindestens 2 (normalize_feed_amount), die Farbe wechselt erst,
-- wenn die Sorter-Kiste leer ist, und ein Teil-Export wird sofort mit
-- derselben Farbe nachgeschoben -- jeder Reprocessor bekommt seine Barren
-- paarweise.
--
-- Config (config.feed):
--   enabled            = true/false  -- Router-UI "FEEDING"-Schalter
--   me_bridge          = "me_bridge"
--   sorter             = nil  -- Logistical Sorter, per Router-UI gewaehlt
--   sorter_chest       = nil  -- die SORTER-KISTE, per Router-UI gewaehlt
--   waste_item         = "bigreactors:cyanite_ingot"
--   feed_amount        = 2          -- Items pro Befuellung (gerade, >= 2)
--   interval_min_s     = 20         -- zufaelliges Intervall: min..max Sekunden
--   interval_max_s     = 60
--   discovery_interval = 60
--   targets = {
--     { label = "Reprocessor A", color = "RED" },
--     { label = "Reprocessor B", color = "BLUE" },
--   }
--   -- gueltige Farben: adapters/logistical_sorter.lua's sorter.COLORS
--   -- (Mekanism EnumColor) -- per Router-UI zugewiesen, siehe
--   -- nodes/reprocessor/color_router_ui.lua.

local logistical_sorter = require("adapters.logistical_sorter")
local me_bridge_compat = require("core.me_bridge_compat")

local M = {}

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return nil, "no_method" end
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

-- Waehlt eine zufaellige Wartezeit zwischen min und max Sekunden.
local function random_interval(cfg)
  local lo = tonumber(cfg.interval_min_s) or 20
  local hi = tonumber(cfg.interval_max_s) or 60
  if hi < lo then hi = lo end
  return lo + math.random() * (hi - lo)
end

-- Der Reprocessor verarbeitet Cyanit immer paarweise (Extreme Reactors:
-- 2 Cyanit + 1000 mB Wasser -> 1 Blutonium); ein einzelner Barren bleibt in
-- der Maschine liegen, bis ein zweiter kommt. Deshalb ist feed_amount immer
-- eine ganze, gerade Zahl und mindestens 2: 1 -> 2, 3 -> 4, 2.5 -> 4.
M.MIN_FEED_AMOUNT = 2

function M.normalize_feed_amount(value)
  local n = tonumber(value)
  if not n or n ~= n or n == math.huge or n == -math.huge then
    return M.MIN_FEED_AMOUNT
  end
  n = math.ceil(n)
  if n < M.MIN_FEED_AMOUNT then n = M.MIN_FEED_AMOUNT end
  if n % 2 ~= 0 then n = n + 1 end
  return n
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
      next_feed_ts    = 0,   -- os.epoch("utc") wann der naechste Feed-Versuch ist
      target_index    = 1,   -- rotierender Index durch die targets-Liste
      last_target     = nil,
      total_feeds     = 0,
      last_feed_ts    = nil,
      last_error      = nil,
      -- Einmalige Sorter-Einstellung (ensure_sorter_setup): fuer welchen
      -- Sorter sie gelungen ist, ob der letzte Versuch klappte, wann er war.
      sorter_setup_done_for = nil,
      sorter_setup_for      = nil,
      sorter_setup_ok       = nil,
      sorter_setup_error    = nil,
      sorter_setup_ts       = 0,
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

  -- Eine ausdrueckliche Bindung ist verbindlich.
  --
  -- Vorher startete die allgemeine Methodensuche auch dann, wenn ein
  -- konkreter Name KONFIGURIERT, aber gerade nicht verfuegbar war -- und
  -- band dann einen beliebigen anderen Sorter. Der verstellt seine
  -- Default-Farbe und damit sein Routing (siehe feed_cycle unten), und auf
  -- einem gemeinsamen Peripherie-Netz mit FUEL gehoert der naechste
  -- gefundene Sorter oft einem ganz anderen Zweig der Anlage.
  --
  -- Gegenprobe vorher: konfiguriert "sorter_mine", vorhanden nur
  -- "sorter_fremd" -> gebunden wurde "sorter_fremd", und zwar ohne jede
  -- Meldung (die Warnung kam nur, wenn gar nichts gefunden wurde).
  --
  -- Dieselbe Unterscheidung macht der ME-Bridge-Zweig oben schon: ein
  -- ausgelieferter Konventionsname darf per Fahigkeitssuche aufgeloest
  -- werden, ein selbst gesetzter Name nicht. Fuer den Sorter gibt es
  -- keinen Konventionsnamen (config.lua: sorter = nil), die Trennung ist
  -- hier also schlicht "konfiguriert" gegen "nicht konfiguriert".
  local sorter_name = cfg.sorter
  local sorter_adapter = nil
  local sorter_is_bound = type(sorter_name) == "string" and sorter_name ~= ""
  if sorter_is_bound then
    if peripheral.isPresent(sorter_name) then
      sorter_adapter = logistical_sorter.detect(sorter_name, "REPROC")
    end
    if not sorter_adapter then
      self.warn_once("sorter_bound_missing",
        "FeedRouter: gebundener Logistical Sorter fehlt: " .. tostring(sorter_name)
          .. " -- es wird KEIN anderer Sorter ersatzweise gebunden")
    end
  else
    -- Nichts konfiguriert: dann darf die Methodensuche entscheiden.
    local found_sorter_name, found_adapter = find_sorter_by_methods()
    if found_adapter then
      sorter_name, sorter_adapter = found_sorter_name, found_adapter
    end
  end
  if sorter_adapter then
    self._state.sorter = sorter_adapter
    self._state.sorter_name = sorter_name
  else
    if not sorter_is_bound then
      self.warn_once("sorter_abs", "FeedRouter: Logistical Sorter nicht gefunden: " .. tostring(cfg.sorter))
    end
    self._state.sorter = nil
  end

  self._state.last_refresh = os.epoch("utc")
end

-- ---- feed cycle -------------------------------------------------------------

-- Liest den Inhalt der Sorter-Kiste. Rueckgabe: Stueckzahl (0 = leer) und
-- das erste gefundene Item -- oder nil plus Fehlertext, wenn die Kiste
-- sich nicht auslesen laesst.
local function chest_contents(chest_name)
  local ok, items = pcall(peripheral.call, chest_name, "list")
  if not ok or type(items) ~= "table" then
    return nil, tostring(items)
  end
  local count, first = 0, nil
  for _, stack in pairs(items) do
    if type(stack) == "table" then
      count = count + (tonumber(stack.count) or 1)
      first = first or stack.name
    end
  end
  return count, first
end

local function exported_count(result)
  if type(result) == "table" then return me_bridge_compat.item_amount(result) end
  return type(result) == "number" and result or 0
end

-- Exportiert `amount` Stueck in die Sorter-Kiste. Kommt beim ersten Mal
-- weniger an (Kiste kurz voll, ME-Bridge liefert nur einen Teil), wird der
-- Rest sofort nachgeschoben -- noch mit derselben Sorter-Farbe, also zum
-- selben Reprocessor. Rueckgabe: bewegte Stueckzahl, letzter Fehler.
local function export_amount(bridge, item, amount, chest_name)
  local moved, last_err = 0, nil
  for _ = 1, 2 do
    local want = amount - moved
    if want <= 0 then break end
    local ok, result = me_bridge_compat.export_to(bridge, { name = item, count = want }, chest_name)
    if ok then
      local n = exported_count(result)
      moved = moved + n
      if n <= 0 then last_err = "export moved nothing" end
    else
      last_err = result
    end
  end
  return moved, last_err
end

-- Fuehrt eine Befuellung fuer genau EIN Target durch (Rotation durch die
-- Liste): Sorter-Default-Farbe auf die des Ziels setzen, dann exportieren.
-- Beide Schritte sind einzelne synchrone Peripherie-Calls -- ein Feed ist
-- fuer den Computer ein einziger Schritt, keine mehrstufige Transaktion.
local function feed_one(self, cfg)
  local targets = cfg.targets or {}
  if #targets == 0 then
    self.warn_once("no_targets", "FeedRouter: keine targets konfiguriert")
    return
  end

  -- Rotierend naechstes Target waehlen. Weitergeschaltet wird in jedem
  -- Fall -- ausser die Sorter-Kiste ist noch belegt (siehe unten): dann
  -- kam dieses Ziel gar nicht zum Zug und bleibt dran.
  local idx = self._state.target_index
  if idx > #targets then idx = 1 end
  local target = targets[idx]
  self._state.target_index = idx + 1

  if not target or not target.color then
    self.warn_once("bad_target:" .. tostring(idx), "FeedRouter: target ohne Farbe, uebersprungen")
    return
  end

  local bridge = self._state.bridge
  if not bridge then
    self.warn_once("no_bridge", "FeedRouter: keine ME-Bridge verfuegbar, Feed uebersprungen")
    return
  end

  local sorter = self._state.sorter
  if not sorter then
    self.warn_once("no_sorter", "FeedRouter: kein Logistical Sorter verfuegbar, Feed uebersprungen")
    return
  end

  local sorter_chest_name = cfg.sorter_chest
  if type(sorter_chest_name) ~= "string" or sorter_chest_name == "" then
    self.warn_once("no_sorter_chest", "FeedRouter: keine Sorter-Kiste konfiguriert, Feed uebersprungen")
    return
  end
  -- Ein konfigurierter Name allein reicht nicht -- die Kiste kann entfernt/
  -- umbenannt worden sein. Ohne diesen Check versucht export_to() stumm
  -- gegen eine nicht existierende Peripherie und scheitert nur mit einem
  -- generischen "export failed" (feed_fail) -- diese Warnung benennt die
  -- eigentliche Ursache klar.
  if not peripheral.isPresent(sorter_chest_name) then
    self.warn_once("sorter_chest_abs", "FeedRouter: Sorter-Kiste nicht gefunden: " .. tostring(sorter_chest_name) .. ", Feed uebersprungen (im Router-UI die SORTER-KISTE neu waehlen)")
    return
  end

  -- Erst wenn die Sorter-Kiste leer ist, darf die Farbe wechseln. Liegt
  -- dort noch etwas, ist die vorige Lieferung noch nicht durch den Sorter
  -- -- ein Farbwechsel jetzt schickte den Rest zum NAECHSTEN Reprocessor,
  -- und beide bekaemen nur einen Barren (der Reprocessor braucht immer 2).
  local in_chest, chest_item = chest_contents(sorter_chest_name)
  if in_chest == nil then
    self.warn_once("sorter_chest_unreadable",
      "FeedRouter: Sorter-Kiste " .. tostring(sorter_chest_name)
        .. " laesst sich nicht auslesen (" .. tostring(chest_item)
        .. ") -- Leer-Pruefung vor dem Farbwechsel entfaellt")
  elseif in_chest > 0 then
    self._state.target_index = idx
    self._state.last_error = string.format(
      "Sorter-Kiste nicht leer (%dx %s) -- vorige Lieferung noch unterwegs, %s wartet",
      in_chest, tostring(chest_item), tostring(target.label))
    self.warn_once("sorter_chest_busy",
      "FeedRouter: " .. self._state.last_error
        .. " (bleibt das so, haengt der Sorter/Transporter oder ein fremdes Item liegt in der Kiste)")
    return
  end

  local item   = cfg.waste_item or "bigreactors:cyanite_ingot"
  local amount = M.normalize_feed_amount(cfg.feed_amount)

  -- Verfuegbarkeit in ME pruefen
  local me_info = safe_call(bridge, "getItem", { name = item })
  local in_me = me_bridge_compat.item_amount(me_info)
  if in_me < amount then
    self.warn_once("me_low:" .. tostring(target.label),
      string.format("FeedRouter: ME hat nur %d %s (brauche %d) — uebersprungen", in_me, item, amount))
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

  local exported, err = export_amount(bridge, item, amount, sorter_chest_name)
  if exported >= amount then
    self._state.total_feeds = self._state.total_feeds + 1
    self._state.last_feed_ts = os.epoch("utc")
    self._state.last_target = target.label
    self._state.last_error = nil
    self.log("INFO", string.format(
      "FeedRouter: %s fed with %d/%d %s (color=%s)", target.label, exported, amount, item, tostring(target.color)))
  elseif exported > 0 then
    self._state.last_target = target.label
    self._state.last_error = string.format("nur %d von %d %s exportiert (%s)",
      exported, amount, item, tostring(target.label))
    self.warn_once("feed_short:" .. tostring(target.label),
      "FeedRouter: " .. self._state.last_error .. ": " .. tostring(err))
  else
    self._state.last_error = tostring(err or "export failed")
    self.warn_once("feed_fail:" .. tostring(target.label),
      "FeedRouter: feed failed for " .. tostring(target.label) .. ": " .. tostring(err))
  end
end

-- Es gibt keine asynchrone Transaktion, die abgebrochen werden muesste
-- (siehe Modulkommentar oben) -- bleibt als No-Op fuer die main.lua-
-- Schnittstelle erhalten, falls ein Feed-Zyklus spaeter doch wieder
-- mehrstufig wird.
function M:cancel(_reason)
end

-- Stellt den gebundenen Sorter EINMAL ein (Betreiber 2026-10-15: "der
-- Sorter soll nur beim Starten einmalig eingestellt werden"): Single Item
-- aus, Auto an -- siehe prepare_for_feeding() in adapters/
-- logistical_sorter.lua. Erst wenn FEEDING an ist (ein Sorter im Auto-
-- Modus zieht sofort, was in der Kiste liegt). Gelungen ist gelungen: fuer
-- diesen Sorter nie wieder in diesem Lauf, auch wenn jemand im Spiel
-- umstellt. Misslingt es (Sicherheit nicht "Oeffentlich", Sorter noch nicht
-- geladen), wird hoechstens einmal je Erkennungsintervall neu versucht,
-- bis es einmal klappt; befuellt wird trotzdem -- die Leer-Pruefung der
-- Sorter-Kiste haelt beide Barren auch im Einzel-Modus beim selben Ziel.
local function ensure_sorter_setup(self, cfg, now)
  local sorter = self._state.sorter
  if not sorter or type(sorter.prepare_for_feeding) ~= "function" then return end
  local sorter_name = self._state.sorter_name
  if self._state.sorter_setup_done_for == sorter_name then return end
  local retry_ms = (tonumber(cfg.discovery_interval) or 60) * 1000
  if self._state.sorter_setup_ok == false and self._state.sorter_setup_for == sorter_name
      and now - self._state.sorter_setup_ts < retry_ms then
    return
  end
  self._state.sorter_setup_ts = now
  self._state.sorter_setup_for = sorter_name
  local ok, err = sorter.prepare_for_feeding()
  if ok then
    self._state.sorter_setup_done_for = sorter_name
    self._state.sorter_setup_ok = true
    self._state.sorter_setup_error = nil
    self.log("INFO", "FeedRouter: Sorter " .. tostring(sorter_name)
      .. " eingestellt (Single Item aus, Auto an)")
  else
    self._state.sorter_setup_ok = false
    self._state.sorter_setup_error = tostring(err)
    self.warn_once("sorter_setup_fail:" .. tostring(sorter_name),
      "FeedRouter: Sorter " .. tostring(sorter_name) .. " liess sich nicht einstellen ("
        .. tostring(err) .. ") -- Sicherheit auf Oeffentlich? Neuer Versuch je Erkennungsintervall")
  end
end

function M:tick()
  local cfg = self.config.feed or self.config or {}
  local now = os.epoch("utc")

  -- Peripherals periodisch neu erkennen -- UNABHAENGIG vom enabled-
  -- Schalter: die Diagnose-Seite (main.lua's build_requirements(),
  -- ui_pages.lua) zeigt ME-BRIDGE/SORTER anhand von get_summary()'s
  -- bridge_bound/sorter_bound, die ausschliesslich hier gesetzt werden.
  local refresh_ms = (tonumber(cfg.discovery_interval) or 60) * 1000
  if now - self._state.last_refresh >= refresh_ms then
    self:refresh_peripherals()
  end

  if cfg.enabled ~= true then return end

  ensure_sorter_setup(self, cfg, now)

  -- Zufaelliges Intervall: beim ersten Tick sofort einen Timer setzen
  if self._state.next_feed_ts == 0 then
    self._state.next_feed_ts = now + random_interval(cfg) * 1000
    return
  end

  if now < self._state.next_feed_ts then return end

  feed_one(self, cfg)

  -- Naechstes zufaelliges Intervall planen
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
    feed_amount    = M.normalize_feed_amount(cfg.feed_amount),
    target_count   = #(cfg.targets or {}),
    targets        = cfg.targets or {},
    bridge_bound   = self._state.bridge ~= nil,
    bridge_name    = self._state.bridge_name,
    sorter_bound   = self._state.sorter ~= nil,
    sorter_name    = self._state.sorter_name,
    -- nil: noch nicht versucht (FEEDING aus / kein Sorter)
    sorter_setup_ok    = self._state.sorter_setup_ok,
    sorter_setup_error = self._state.sorter_setup_error,
  }
end

return M
