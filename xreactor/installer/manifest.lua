-- installer/manifest.lua
-- Manifest laden, Dateien vergleichen, erwartete Dateien pro Rolle bestimmen.

local M = {}

local LOG_ROLES = { LOG = true, LOG_COLLECTOR = true }

local SKIP = {
  ["nodes/energy/adapter_probe.lua"] = true,
  ["nodes/rt/commands.lua"]          = true,
  ["nodes/rt/controllers.lua"]       = true,
  ["nodes/rt/discovery.lua"]         = true,
  ["nodes/rt/ramp.lua"]              = true,
  ["nodes/rt/safety.lua"]            = true,
  ["nodes/rt/state.lua"]             = true,
  ["nodes/rt/telemetry.lua"]         = true,
}

local ROLE_EXTRAS = {
  RT = {
    "adapters/reactor.lua", "adapters/turbine.lua",
    "core/control_rails.lua", "core/fluid.lua", "core/turbine_regulator.lua",
    "nodes/rt/command_handler.lua", "nodes/rt/config_normalizer.lua",
    "nodes/rt/discovery_log.lua", "nodes/rt/discovery_runtime.lua",
    "nodes/rt/flow_apply_helpers.lua", "nodes/rt/health_payload.lua",
    "nodes/rt/module_lifecycle.lua", "nodes/rt/monitor_ui.lua",
    "nodes/rt/reactor_steam_guard.lua", "nodes/rt/startup_diagnostics.lua",
    "nodes/rt/state_handlers.lua", "nodes/rt/status_snapshot.lua",
  }
}

-- Lookup-Tabelle nur einmal beim Laden dieses Moduls aufbauen, nicht bei
-- jedem crc32()-Aufruf neu (M.install() ruft crc32() fuer JEDE Datei auf).
local CRC_TABLE = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if bit32.band(c, 1) == 1 then
      c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
    else
      c = bit32.rshift(c, 1)
    end
  end
  CRC_TABLE[i] = c
end

-- Fix: bei groesseren Dateien im Manifest (FUEL-Rolle bringt mit Abstand die
-- groessten Einzeldateien im gesamten Manifest mit, z.B. redstone_router.lua
-- ~58KB, router_ui.lua ~40KB) konnte diese Byte-fuer-Byte-Schleife ohne
-- jeden Yield auf einem ausgelasteten Server CC:Tweaked's Watchdog-Limit
-- ("too long without yielding") ueberschreiten -- der Installer blieb dann
-- mitten im Fortschrittsbalken haengen, OHNE Fehlermeldung (der Watchdog
-- killt die Coroutine hart, statt einen catchbaren Fehler zu werfen).
--
-- Ein erster Versuch mit os.sleep(0) alle 4096 Bytes reichte unter Server-
-- last nicht: os.sleep() wartet selbst im 0-Fall mindestens einen echten
-- Server-Tick (und unter genau der Last, vor der wir uns schuetzen wollen,
-- dauert ein Tick laenger) -- das haette bei sehr kleiner Yield-Distanz
-- die Installation spuerbar verlangsamt, war bei 4096 Bytes aber trotzdem
-- noch zu selten (naechster beobachteter Haenger bei einer kleineren,
-- aber nicht winzigen 18KB-Datei). os.queueEvent()+os.pullEvent() auf ein
-- selbst gewaehltes, garantiert ungenutztes Event yieldet die Coroutine
-- genauso wirksam (setzt den Watchdog zurueck) OHNE auf den naechsten Tick
-- zu warten -- das Event wird noch in derselben Tick-Verarbeitung wieder
-- zugestellt. Dadurch kann CRC_YIELD_EVERY deutlich kleiner sein, ohne die
-- Installation spuerbar zu verlangsamen. os/os.queueEvent existieren in
-- Offline-Tests (Host-Lua) nicht, daher der type()-Check.
local CRC_YIELD_EVERY = 512
local CRC_YIELD_EVENT = "__xr_crc32_yield"

local function crc32(content)
  local can_yield = type(os) == "table"
    and type(os.queueEvent) == "function" and type(os.pullEvent) == "function"
  local crc = 0xFFFFFFFF
  local len = #content
  for i = 1, len do
    local idx = bit32.band(bit32.bxor(crc, string.byte(content, i)), 0xFF)
    crc = bit32.bxor(bit32.rshift(crc, 8), CRC_TABLE[idx])
    if can_yield and i % CRC_YIELD_EVERY == 0 then
      os.queueEvent(CRC_YIELD_EVENT)
      os.pullEvent(CRC_YIELD_EVENT)
    end
  end
  return string.format("%08x", bit32.bxor(crc, 0xFFFFFFFF))
end
M.crc32 = crc32

function M.load_remote(url, http_mod)
  local body, err = http_mod.download(url)
  if not body then return nil, err end
  if http_mod.is_html(body) then return nil, "unexpected HTML" end
  local loader, lerr = load(body, "=manifest", "t", {})
  if not loader then return nil, "parse: " .. tostring(lerr) end
  local ok, result = pcall(loader)
  if not ok or type(result) ~= "table" then
    return nil, "invalid manifest: " .. tostring(result)
  end
  return result
end

-- Muss optional=true-Eintraege gegen selected_features filtern, sonst hat
-- installer/init.lua's interaktive Auswahl keine Wirkung.
function M.files_for_role(manifest, role_label, selected_features)
  local is_log = LOG_ROLES[role_label:upper()] == true
  selected_features = selected_features or {}
  local expected = {}

  local function add(entry)
    if type(entry) == "string" then entry = { path = entry } end
    if type(entry) ~= "table" or not entry.path then return end
    if SKIP[entry.path] then return end
    if entry.optional == true then
      local feature = entry.feature or entry.path
      if selected_features[feature] ~= true then return end
    end
    expected[entry.path] = entry
  end

  -- required_for muss auch fuer base_files-Eintraege ausgewertet werden,
  -- nicht nur fuer roles.*-Eintraege -- sonst ginge eine Datei trotz
  -- required_for-Feld an jede nicht-LOG-Rolle.
  local function base_role_matches(entry)
    local rf = entry.required_for
    if type(rf) ~= "table" then return true end
    for _, v in ipairs(rf) do
      if tostring(v):upper() == role_label:upper() then return true end
    end
    return false
  end

  for _, e in ipairs(manifest.base_files or {}) do
    if (not is_log or e.always == true) and base_role_matches(e) then add(e) end
  end

  for rkey, rentries in pairs(manifest.roles or {}) do
    for _, e in ipairs(rentries or {}) do
      if type(e) == "table" then
        local rf = e.required_for
        local matches = e.always == true
        if not matches and type(rf) == "table" then
          for _, v in ipairs(rf) do
            if tostring(v):upper() == role_label:upper() then matches = true; break end
          end
        end
        if matches then add(e) end
      end
    end
  end

  local installer_files = {
    "installer/http.lua", "installer/manifest.lua", "installer/stage.lua",
    "installer/ui.lua", "installer/auto_update.lua", "installer/init.lua",
    "manifest.lua", "release.lua", "start.lua",
  }
  for _, p in ipairs(installer_files) do
    if not expected[p] then expected[p] = { path = p, always = true } end
  end

  local extras = ROLE_EXTRAS[role_label:upper()] or {}
  for _, p in ipairs(extras) do
    if not SKIP[p] and not expected[p] then expected[p] = { path = p } end
  end

  return expected
end

return M
