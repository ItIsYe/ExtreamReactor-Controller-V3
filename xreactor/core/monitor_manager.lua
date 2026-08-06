local utils = require("core.utils")
local registry_lib = require("core.registry")
local monitor_adapter = require("adapters.monitor")

local manager = {}

local function safe_wrapped_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then
    return false, "missing method"
  end
  return pcall(function(...)
    return obj[method](...)
  end, ...)
end

local function classify_size(w, h, thresholds)
  local area = (w or 0) * (h or 0)
  local small = thresholds and thresholds.small_area or 600
  local medium = thresholds and thresholds.medium_area or 1100
  if area <= small then return "small" end
  if area <= medium then return "medium" end
  return "large"
end

local function classify_layout(width, height, size_tag)
  local area = (width or 0) * (height or 0)
  if size_tag == "large" or (area >= 900 and (width or 0) >= 48 and (height or 0) >= 18) then
    return "master_large"
  end
  if size_tag == "medium" then return "master_medium" end
  return "compact"
end

local function build_devices(names)
  local devices = {}
  for _, name in ipairs(names or {}) do
    local methods = utils.safe_get_methods(name) or {}
    table.insert(devices, { name = name, type = "monitor", kind = "monitor", methods = methods, bound = true, found = true })
  end
  return devices
end

local function prune_wrap_cache(self, present_names)
  for name, _ in pairs(self.wrap_cache or {}) do
    if not present_names[name] then self.wrap_cache[name] = nil end
  end
end

local function below_min_size(self, width, height)
  local min_w = tonumber(self.min_width) or 0
  local min_h = tonumber(self.min_height) or 0
  if min_w > 0 and (tonumber(width) or 0) < min_w then return true end
  if min_h > 0 and (tonumber(height) or 0) < min_h then return true end
  return false
end

local function min_size_message(self, name, width, height)
  return ("monitor %s too small: %sx%s, required >= %sx%s"):format(
    tostring(name), tostring(width or "?"), tostring(height or "?"), tostring(self.min_width or 0), tostring(self.min_height or 0)
  )
end

function manager:new_wrapped_monitor(name)
  local mon = utils.safe_wrap(name)
  if mon then self.wrap_cache[name] = mon else self.wrap_cache[name] = nil end
  return mon
end

function manager:get_wrapped_monitor(name)
  local mon = self.wrap_cache[name]
  if mon and type(mon.getSize) == "function" then return mon end
  return self:new_wrapped_monitor(name)
end

-- Feature (2026-07-06): Automatische, groessenabhaengige Skalierung statt
-- einer einzigen festen Skala fuer JEDEN Monitor. Vorher bekam z.B. ein
-- kleiner AUX-Monitor dieselbe Skala wie ein grosser Haupt-Monitor —
-- entweder zu grobe Schrift auf grossen Bildschirmen (viel ungenutzter
-- Platz) oder zu feine/gedraengte Darstellung auf kleinen. Ablauf: zuerst
-- Skala 0.5 setzen (feinste Stufe, damit getSize() die physische
-- Blockgroesse in Zeichen liefert), dann anhand der gemessenen Flaeche
-- eine passende finale Skala waehlen. Nur aktiv wenn KEINE feste Skala
-- (opts.scale) explizit uebergeben wurde — bestehende Konfigurationen mit
-- fest gesetzter monitor_scale bleiben unveraendert.
local function compute_auto_scale(mon, log_prefix)
  local ok_probe, err_probe = monitor_adapter.safe_set_scale(mon, nil, 0.5, log_prefix)
  local ok_size, w, h = safe_wrapped_call(mon, "getSize")
  if not ok_size or type(w) ~= "number" or type(h) ~= "number" then
    return 0.5
  end
  -- w/h sind hier Zeichen-Anzahl bei Skala 0.5. Ein 1x3-Block-Monitor
  -- (Ampel) zeigt bei Skala 0.5 ungefaehr 32 breit x 6 hoch — bleibt bei
  -- 0.5, damit die Ampel-Groessenerkennung (die exakt w=1,h=3 NACH einem
  -- eigenen setTextScale(1) braucht) unberuehrt bleibt; diese Funktion
  -- wird nur fuer normale/AUX-Monitore aufgerufen, nicht fuer den 1x3.
  local area = w * h
  if area >= 6000 then return 1.0 end   -- sehr grosser Monitor (z.B. 4x4+ Bloecke)
  if area >= 3000 then return 0.75 end  -- grosser Monitor (z.B. 3x2/2x3 Bloecke)
  return 0.5                            -- kompakter/AUX-Monitor: feinste Stufe, maximal Platz nutzen
end

function manager.new(opts)
  opts = opts or {}
  local scale = tonumber(opts.scale)
  local self = {
    log_prefix = opts.log_prefix or "MONITOR",
    scale = scale,
    thresholds = opts.thresholds or { small_area = 600, medium_area = 1100 },
    min_width = tonumber(opts.min_width) or 0,
    min_height = tonumber(opts.min_height) or 0,
    registry = registry_lib.new({ role = opts.role or "master_monitor", node_id = opts.node_id or "MASTER", path = opts.path }),
    disabled = {},
    scale_cache = {},
    wrap_cache = {}
  }
  return setmetatable(self, { __index = manager })
end

function manager:scan()
  local names = {}
  local present_names = {}
  for _, name in ipairs(peripheral.getNames() or {}) do
    if peripheral.getType(name) == "monitor" then
      table.insert(names, name)
      present_names[name] = true
    end
  end
  table.sort(names)
  prune_wrap_cache(self, present_names)
  monitor_adapter.sync_names(names)
  if #names == 0 then
    local ok, w, h = pcall(term.getSize)
    local width = ok and w or 0
    local height = ok and h or 0
    if below_min_size(self, width, height) then
      self.disabled.TERM = min_size_message(self, "term", width, height)
      utils.log(self.log_prefix, "Disabling terminal UI fallback: " .. self.disabled.TERM, "ERROR")
      return {}
    end
    local size_tag = classify_size(width, height, self.thresholds)
    return { { id = "TERM", name = "term", mon = term, size_tag = size_tag, width = width, height = height, is_terminal = true } }
  end
  self.registry:sync(build_devices(names))
  local order = self.registry:get_order_index()
  local entries = {}
  for _, entry in ipairs(self.registry:list("monitor")) do
    if entry and entry.name and peripheral.isPresent(entry.name) then table.insert(entries, entry) end
  end
  table.sort(entries, function(a, b)
    local rank_a = order[a.id] or math.huge
    local rank_b = order[b.id] or math.huge
    if rank_a ~= rank_b then return rank_a < rank_b end
    return tostring(a.name) < tostring(b.name)
  end)
  local monitors = {}
  for _, entry in ipairs(entries) do
    local mon = self:get_wrapped_monitor(entry.name)
    if mon then
      if self.scale then
        local cached_scale = self.scale_cache[entry.name]
        local should_apply_scale = cached_scale == nil or tonumber(cached_scale) ~= tonumber(self.scale)
        if should_apply_scale then
          local scale_ok, scale_err = monitor_adapter.safe_set_scale(mon, entry.name, self.scale, self.log_prefix)
          if not scale_ok then
            self.disabled[entry.name] = "setTextScale failed: " .. tostring(scale_err)
            utils.log(self.log_prefix, "Disabling monitor " .. tostring(entry.name) .. " during scan (setTextScale failed: " .. tostring(scale_err) .. ")", "WARN")
            self.wrap_cache[entry.name] = nil
            goto continue
          end
          self.scale_cache[entry.name] = self.scale
          utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " text scale applied=" .. tostring(self.scale), "DEBUG")
        else
          utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " text scale unchanged=" .. tostring(self.scale), "DEBUG")
        end
      elseif self.auto_scale ~= false then
        -- Feature (2026-07-06): keine feste Skala konfiguriert -> pro
        -- Monitor automatisch anhand der physischen Groesse berechnen.
        -- Nur einmal pro Monitor-Name berechnen (gecached), nicht bei
        -- jedem Scan-Durchlauf neu, da compute_auto_scale() selbst schon
        -- einen setTextScale(0.5)-Sondierungsschritt braucht.
        local cached_scale = self.scale_cache[entry.name]
        if cached_scale == nil then
          local auto_scale = compute_auto_scale(mon, self.log_prefix)
          local scale_ok, scale_err = monitor_adapter.safe_set_scale(mon, entry.name, auto_scale, self.log_prefix)
          if scale_ok then
            self.scale_cache[entry.name] = auto_scale
            utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " auto scale applied=" .. tostring(auto_scale), "DEBUG")
          else
            utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " auto scale failed: " .. tostring(scale_err), "WARN")
          end
        end
      end
      local effective_scale = self.scale
      local scale_read_ok, scale_read = safe_wrapped_call(mon, "getTextScale")
      if scale_read_ok then effective_scale = tonumber(scale_read) or effective_scale end
      local ok, w, h = safe_wrapped_call(mon, "getSize")
      if not ok then
        self.wrap_cache[entry.name] = nil
        mon = self:new_wrapped_monitor(entry.name)
        ok, w, h = safe_wrapped_call(mon, "getSize")
      end
      if not ok then
        self.disabled[entry.name] = "getSize failed: " .. tostring(w)
        utils.log(self.log_prefix, "Disabling monitor " .. tostring(entry.name) .. " during scan (getSize failed: " .. tostring(w) .. ")", "WARN")
        goto continue
      end
      local width = ok and w or 0
      local height = ok and h or 0
      if below_min_size(self, width, height) then
        local msg = min_size_message(self, entry.name, width, height)
        -- Fix: nur einmal loggen wenn sich der Grund nicht geändert hat (kein ERROR-Spam)
        if self.disabled[entry.name] ~= msg then
          utils.log(self.log_prefix, "Disabling monitor during scan: " .. msg, "ERROR")
        end
        self.disabled[entry.name] = msg
        goto continue
      end
      local size_tag = classify_size(width, height, self.thresholds)
      if self.disabled[entry.name] then
        self.disabled[entry.name] = nil
        utils.log(self.log_prefix, "Monitor " .. tostring(entry.name) .. " recovered and re-enabled", "INFO")
      end
      table.insert(monitors, {
        id = entry.id or entry.name,
        name = entry.name,
        mon = mon,
        width = width,
        height = height,
        size_tag = size_tag,
        text_scale = effective_scale,
        layout_class = classify_layout(width, height, size_tag),
        last_applied_scale = self.scale_cache[entry.name]
      })
    else
      utils.log(self.log_prefix, "Monitor wrap failed for " .. tostring(entry.name), "WARN")
      self.disabled[entry.name] = "wrap failed"
      self.wrap_cache[entry.name] = nil
    end
    ::continue::
  end
  return monitors
end

return manager
