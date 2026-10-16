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

-- Stufen nach ME-Bestand (v828; Betreiber 2026-10-15: "wenn sehr viel
-- Cyanit da ist, die Barrenanzahl erhoehen von 2 auf 4, 6, 8, 10 ... und
-- die Zeit bis zum naechsten Push etwas verringern"). Je volle
-- stock_per_level Cyanit im ME eine Stufe: je Stufe 2 Barren mehr
-- (hoechstens max_amount) und eine um interval_cut_per_level kuerzere
-- Pause (hoechstens um max_interval_cut). Unter der ersten Stufe gilt
-- feed_amount und die eingestellte Pause unveraendert.
--
-- Die Vorgaben stehen hier und nicht nur in config.lua: die REPROC-Config
-- wird beim ersten Start einmal nach /xreactor_config/reprocessor.lua
-- kopiert, spaetere Felder in config.lua erreichen bestehende Rechner nie.
-- Kommt ein Reprocessor mit dem Verarbeiten nicht nach, bleibt die
-- Sorter-Kiste belegt und feed_one() wartet -- mehr als die Maschinen
-- schaffen, wird so nie nachgeschoben.
M.BOOST_DEFAULTS = {
  enabled                = true,
  stock_per_level        = 1000,
  max_amount             = 16,
  interval_cut_per_level = 0.10,
  max_interval_cut       = 0.50,
}

-- Hoechstens 90 % kuerzer -- eine Pause von null gibt es nicht.
local MAX_INTERVAL_CUT_LIMIT = 0.9

local function finite_number(value)
  local n = tonumber(value)
  if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
  return n
end

-- Bereinigte Kopie von cfg.boost; fehlende Felder bekommen die Vorgabe,
-- ungueltige ebenfalls (mit warn(text), falls uebergeben).
function M.normalize_boost(boost, warn)
  local d = M.BOOST_DEFAULTS
  local src = type(boost) == "table" and boost or {}
  local function bad(field, value, fallback)
    if warn and value ~= nil then
      warn(string.format("feed.boost.%s %s ungueltig; nehme %s", field, tostring(value), tostring(fallback)))
    end
    return fallback
  end
  local out = {}
  if src.enabled == nil then
    out.enabled = d.enabled
  elseif type(src.enabled) == "boolean" then
    out.enabled = src.enabled
  else
    out.enabled = bad("enabled", src.enabled, d.enabled)
  end
  local per = finite_number(src.stock_per_level)
  out.stock_per_level = (per and per >= 1) and math.floor(per)
    or bad("stock_per_level", src.stock_per_level, d.stock_per_level)
  local max_amount = finite_number(src.max_amount)
  out.max_amount = max_amount and M.normalize_feed_amount(max_amount)
    or bad("max_amount", src.max_amount, d.max_amount)
  local cut = finite_number(src.interval_cut_per_level)
  out.interval_cut_per_level = (cut and cut >= 0 and cut <= 1) and cut
    or bad("interval_cut_per_level", src.interval_cut_per_level, d.interval_cut_per_level)
  local max_cut = finite_number(src.max_interval_cut)
  out.max_interval_cut = (max_cut and max_cut >= 0 and max_cut <= MAX_INTERVAL_CUT_LIMIT) and max_cut
    or bad("max_interval_cut", src.max_interval_cut, d.max_interval_cut)
  return out
end

-- Stufe zum ME-Bestand: 0 unter stock_per_level, dann je volle Menge +1.
function M.boost_level(stock, boost)
  if not boost or boost.enabled == false then return 0 end
  local s = finite_number(stock) or 0
  if s <= 0 then return 0 end
  return math.floor(s / boost.stock_per_level)
end

-- Barren je Lieferung: feed_amount + 2 je Stufe, hoechstens max_amount
-- (aber nie unter feed_amount), nie mehr als gerade im ME liegt, immer
-- gerade.
function M.boosted_amount(base, level, boost, stock)
  local amount = base + 2 * (level or 0)
  local cap = math.max(base, boost and boost.max_amount or base)
  if amount > cap then amount = cap end
  local s = finite_number(stock)
  if s and amount > s then
    amount = math.max(base, s - s % 2)
  end
  return M.normalize_feed_amount(amount)
end

-- Faktor fuer die Pause: 1 - Stufe * Kuerzung, hoechstens um max_interval_cut.
function M.interval_factor(level, boost)
  if not boost or boost.enabled == false then return 1 end
  local cut = (level or 0) * boost.interval_cut_per_level
  if cut > boost.max_interval_cut then cut = boost.max_interval_cut end
  return 1 - cut
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
      -- Stufe nach ME-Bestand (v828), aus der letzten ME-Lesung in feed_one
      me_stock        = nil,
      boost_level     = 0,
      current_amount  = nil,
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
  local base   = M.normalize_feed_amount(cfg.feed_amount)

  -- ME-Bestand: entscheidet, ob genug da ist, und die Stufe (Barren je
  -- Lieferung, Pause bis zur naechsten -- siehe M.BOOST_DEFAULTS).
  local me_info = safe_call(bridge, "getItem", { name = item })
  local in_me = me_bridge_compat.item_amount(me_info)
  local boost = M.normalize_boost(cfg.boost)
  local level = M.boost_level(in_me, boost)
  local amount = M.boosted_amount(base, level, boost, in_me)
  self._state.me_stock = in_me
  self._state.boost_level = level
  self._state.current_amount = amount
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

  -- Naechstes zufaelliges Intervall planen -- je Stufe etwas kuerzer
  -- (Stufe aus der letzten ME-Lesung in feed_one).
  local factor = M.interval_factor(self._state.boost_level, M.normalize_boost(cfg.boost))
  self._state.next_feed_ts = now + random_interval(cfg) * factor * 1000
end

-- ---- status / introspection -------------------------------------------------

local function chest_present(name)
  if type(name) ~= "string" or name == "" then return false end
  local ok, present = pcall(peripheral.isPresent, name)
  return ok and present == true
end

-- Farbe fuer die optionale Ampel (optional/ampel.lua), Regeln vom
-- Betreiber freigegeben (2026-10-15) -- die erste zutreffende gilt:
--   grau   (muted)     FEEDING aus
--   rot    (EMERGENCY) FEEDING an, aber es kann nicht geliefert werden:
--                      ME-Bridge, Sorter oder Sorter-Kiste fehlt, oder der
--                      Sorter nimmt Farbe/Einstellung nicht an
--   orange (WARNING)   letzte Lieferung mit Fehler (z.B. "nur 1 von 2"),
--                      oder kein Ziel angelegt
--   gelb   (LIMITED)   wartet: Sorter-Kiste noch belegt, oder zu wenig
--                      Cyanit im ME
--   gruen  (OK)        laeuft
function M.ampel_status(summary)
  local s = type(summary) == "table" and summary or {}
  if s.enabled ~= true then return "muted" end
  local err = s.last_error ~= nil and tostring(s.last_error) or nil
  if not s.bridge_bound or not s.sorter_bound or s.sorter_chest_present ~= true
      or s.sorter_setup_ok == false
      or (err and err:find("sorter_color_failed", 1, true) == 1) then
    return "EMERGENCY"
  end
  local waiting = err and err:find("Sorter-Kiste nicht leer", 1, true) == 1
  if (tonumber(s.target_count) or 0) == 0 or (err and not waiting) then return "WARNING" end
  if waiting then return "LIMITED" end
  local stock, amount = tonumber(s.me_stock), tonumber(s.feed_amount)
  if stock and amount and stock < amount then return "LIMITED" end
  return "OK"
end

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
    -- Barren der letzten/naechsten Lieferung (mit Stufe), Stufe, ME-Bestand
    feed_amount    = self._state.current_amount or M.normalize_feed_amount(cfg.feed_amount),
    boost_level    = self._state.boost_level or 0,
    me_stock       = self._state.me_stock,
    target_count   = #(cfg.targets or {}),
    targets        = cfg.targets or {},
    bridge_bound   = self._state.bridge ~= nil,
    bridge_name    = self._state.bridge_name,
    sorter_bound   = self._state.sorter ~= nil,
    sorter_name    = self._state.sorter_name,
    sorter_chest_present = chest_present(cfg.sorter_chest),
    -- nil: noch nicht versucht (FEEDING aus / kein Sorter)
    sorter_setup_ok    = self._state.sorter_setup_ok,
    sorter_setup_error = self._state.sorter_setup_error,
  }
end

return M
