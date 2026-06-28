-- installer/init.lua
-- Einstiegspunkt. Wird von /installer via dofile aufgerufen.

local http_mod     = dofile("/xreactor/installer/http.lua")
local manifest_mod = dofile("/xreactor/installer/manifest.lua")
local stage_mod    = dofile("/xreactor/installer/stage.lua")
local ui_mod       = dofile("/xreactor/installer/ui.lua")

local INSTALL_ROOT    = "/xreactor"
local STARTUP_PATH    = "/startup.lua"
local STARTUP_CONTENT = "-- XReactor startup\nshell.run(\"/xreactor/start.lua\")\n"
local GITHUB_RAW      = "https://raw.githubusercontent.com/ItIsYe/ExtreamReactor-Controller-V3/"

local function p(msg) pcall(print, tostring(msg)) end

local sha = http_mod.resolve_sha()
local base_url = sha
  and (GITHUB_RAW .. sha .. "/xreactor/")
  or  (GITHUB_RAW .. "beta/xreactor/")
p(sha and ("SHA-PIN: " .. sha:sub(1,10)) or "WARN: SHA nicht auflösbar")

local manifest, merr = manifest_mod.load_remote(base_url .. "manifest.lua", http_mod)
if not manifest then error("Manifest: " .. tostring(merr), 0) end
p("Manifest: " .. tostring(manifest.manifest_id or manifest.manifest_version))

-- Rolle bestimmen
local role = nil
local role_path = INSTALL_ROOT .. "/config/role.lua"
if fs.exists(role_path) then
  local f = fs.open(role_path, "r"); if f then
    local src = f.readAll(); f.close()
    local loader = load(src, "=role", "t", {})
    if loader then
      local ok, result = pcall(loader)
      if ok and type(result) == "table" and type(result.role) == "string" then
        local existing = result.role
        p("Vorhandene Rolle: " .. existing)
        if _G.__xreactor_remote_update or ui_mod.confirm("Rolle '" .. existing .. "' behalten?") then
          role = { key = existing:lower(), label = existing:upper() }
        end
      end
    end
  end
end
if not role then
  role = ui_mod.select_role()
  if not role then error("Ungültige Rolle", 0) end
end

ui_mod.header("Installiere " .. role.label)

-- Wichtige Dateien sichern
local PRESERVE = { "config/node_id.txt", "config/capacity_cache.lua" }
local preserved = {}
for _, rel in ipairs(PRESERVE) do
  local src = INSTALL_ROOT .. "/" .. rel
  if fs.exists(src) then
    local f = fs.open(src, "r"); if f then preserved[rel] = f.readAll(); f.close() end
  end
end

-- Alte Installation löschen
if fs.exists(INSTALL_ROOT) then
  p("Entferne alte Installation..."); pcall(fs.delete, INSTALL_ROOT)
end
pcall(fs.makeDir, INSTALL_ROOT)

-- Dateien installieren
local expected = manifest_mod.files_for_role(manifest, role.label)
local file_list = {}
for rel, entry in pairs(expected) do table.insert(file_list, { path = rel, entry = entry }) end
table.sort(file_list, function(a, b)
  local sa = tonumber((a.entry or {}).size_bytes) or 0
  local sb = tonumber((b.entry or {}).size_bytes) or 0
  if sa ~= sb then return sa > sb end
  return a.path < b.path
end)

p("Installiere " .. #file_list .. " Dateien...")
local ok, err = stage_mod.install(file_list, INSTALL_ROOT, http_mod, sha,
  function(done, total, rel) ui_mod.progress(done, total, rel) end)
if not ok then error("Installation: " .. tostring(err), 0) end

-- Gesicherte Dateien wiederherstellen
for rel, content in pairs(preserved) do
  local dst = INSTALL_ROOT .. "/" .. rel
  local dir = fs.getDir(dst)
  if dir and dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  local f = fs.open(dst, "w"); if f then f.write(content); f.close() end
  p("Wiederhergestellt: " .. rel)
end

-- Rolle konfigurieren
stage_mod.write(INSTALL_ROOT .. "/config/role.lua",
  string.format("return { role = %q }\n", role.label))

-- startup.lua
local existing_startup = nil
if fs.exists(STARTUP_PATH) then
  local f = fs.open(STARTUP_PATH, "r"); if f then existing_startup = f.readAll(); f.close() end
end
local is_xreactor = existing_startup and (
  existing_startup:find("/xreactor/start.lua", 1, true) or
  existing_startup:find("XReactor", 1, true))
if not existing_startup or is_xreactor then
  stage_mod.write(STARTUP_PATH, STARTUP_CONTENT); p("startup.lua konfiguriert")
else
  p("WARN: startup.lua nicht von XReactor — unverändert")
end

-- Auto-Update Config
local auto_cfg = INSTALL_ROOT .. "/config/remote_update.lua"
if not fs.exists(auto_cfg) then
  stage_mod.write(auto_cfg,
    "return {\n  enabled = true,\n  auto_update = true,\n  check_interval_s = 120,\n}\n")
  p("Auto-Update Config angelegt")
end

ui_mod.ok("Installation abgeschlossen: " .. role.label)
_G.__xreactor_installer_completed = true
_G.__xreactor_installer_role = role.label
