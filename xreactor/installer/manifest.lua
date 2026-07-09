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
    "core/control_rails.lua", "core/fluid.lua",
    "core/turbine_ctrl.lua", "core/turbine_regulator.lua",
    "nodes/rt/command_handler.lua", "nodes/rt/config_normalizer.lua",
    "nodes/rt/discovery_log.lua", "nodes/rt/discovery_runtime.lua",
    "nodes/rt/flow_apply_helpers.lua", "nodes/rt/health_payload.lua",
    "nodes/rt/module_lifecycle.lua", "nodes/rt/monitor_ui.lua",
    "nodes/rt/reactor_steam_guard.lua", "nodes/rt/startup_diagnostics.lua",
    "nodes/rt/state_handlers.lua", "nodes/rt/status_snapshot.lua",
  }
}

local function crc32(content)
  local CRC = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if bit32.band(c, 1) == 1 then
        c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
      else
        c = bit32.rshift(c, 1)
      end
    end
    CRC[i] = c
  end
  local crc = 0xFFFFFFFF
  for i = 1, #content do
    local idx = bit32.band(bit32.bxor(crc, string.byte(content, i)), 0xFF)
    crc = bit32.bxor(bit32.rshift(crc, 8), CRC[idx])
  end
  return string.format("%08x", bit32.bxor(crc, 0xFFFFFFFF))
end
M.crc32 = crc32

function M.is_current(path, entry)
  if not fs.exists(path) then return false, "missing" end
  local f = fs.open(path, "r")
  if not f then return false, "unreadable" end
  local content = f.readAll(); f.close()
  if entry.size_bytes and #content ~= entry.size_bytes then
    return false, "size_mismatch"
  end
  if entry.hash and entry.hash ~= "" then
    local actual = crc32(content)
    if actual:lower() ~= entry.hash:lower() then
      return false, "hash_mismatch"
    end
  end
  return true
end

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

-- Fix (2026-07-08): CRITICAL. Diese Funktion hatte seit dem "Phase 1"-
-- Rewrite (2026-06-28) keine Filterung fuer optional=true Eintraege mehr —
-- jeder passende Eintrag wurde unconditional aufgenommen, unabhaengig von
-- der Nutzerauswahl. Nur die eingebettete Kopie im monolithischen
-- /installer hatte die urspruengliche 3-Parameter-Version mit Feature-
-- Filterung noch (dort ueberlebt, weil der eingebettete Block seit dem
-- Rewrite nie neu gebaut wurde). Hier aus der eingebetteten Version
-- wiederhergestellt, damit installer/init.lua's interaktive Auswahl
-- (siehe dort) wieder tatsaechlich etwas bewirkt.
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

  for _, e in ipairs(manifest.base_files or {}) do
    if not is_log or e.always == true then add(e) end
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
