-- XReactor start.lua
-- Liest Rolle, startet Node + Auto-Update Loop parallel.

local INSTALL_ROOT = "/xreactor"
local ROLE_PATH    = INSTALL_ROOT .. "/config/role.lua"
local RELEASE_PATH = INSTALL_ROOT .. "/release.lua"

local ROLE_ENTRY = {
  MASTER        = INSTALL_ROOT .. "/master/main.lua",
  RT            = INSTALL_ROOT .. "/nodes/rt/main.lua",
  ENERGY        = INSTALL_ROOT .. "/nodes/energy/main.lua",
  WATER         = INSTALL_ROOT .. "/nodes/water/main.lua",
  FUEL          = INSTALL_ROOT .. "/nodes/fuel/main.lua",
  REPROCESSING  = INSTALL_ROOT .. "/nodes/reprocessor/main.lua",
  LOG           = INSTALL_ROOT .. "/nodes/log_collector/mockup_main.lua",
  LOG_COLLECTOR = INSTALL_ROOT .. "/nodes/log_collector/mockup_main.lua",
}

local function p(msg) pcall(print, tostring(msg)) end

local function cleanup_space()
  if not fs.getFreeSpace then return end
  local ok, free = pcall(fs.getFreeSpace, "/")
  if ok and type(free) == "number" and free < 4096 then
    pcall(fs.delete, "/xreactor_logs");      pcall(fs.makeDir, "/xreactor_logs")
    pcall(fs.delete, "/xreactor_stage")
    pcall(fs.delete, "/xreactor_backup_prev")
    p("STARTUP: Speicher bereinigt")
  end
end
cleanup_space()

local function read_role()
  if not fs.exists(ROLE_PATH) then return nil, "Role config fehlt" end
  local f = fs.open(ROLE_PATH, "r"); if not f then return nil, "Kann role.lua nicht lesen" end
  local src = f.readAll(); f.close()
  local loader, err = load(src, "=role", "t", {})
  if not loader then return nil, "role.lua Syntax: " .. tostring(err) end
  local ok, result = pcall(loader)
  if not ok or type(result) ~= "table" or type(result.role) ~= "string" then
    return nil, "role.lua ungültig"
  end
  return result.role
end

local role, role_err = read_role()
if not role then p("[BOOT] FEHLER: " .. tostring(role_err)); error(role_err, 0) end

local entry = ROLE_ENTRY[role]
if not entry then p("[BOOT] Unbekannte Rolle: " .. role); error("Unbekannte Rolle: " .. role, 0) end

local rel_v = "?"
if fs.exists(RELEASE_PATH) then
  local f = fs.open(RELEASE_PATH, "r"); if f then
    local src = f.readAll(); f.close()
    local v = src:match('release_id%s*=%s*"([^"]+)"')
    if v then rel_v = v end
  end
end
p("[BOOT] XReactor " .. role .. " | " .. rel_v)

local DELAYS = { LOG = 0, LOG_COLLECTOR = 0, MASTER = 2 }
local delay = DELAYS[role] or 8
if delay > 0 then
  local reason = role == "MASTER" and "LOG_COLLECTOR" or "LOG_COLLECTOR + MASTER"
  p("[BOOT] Warte " .. delay .. "s auf " .. reason .. "...")
  for i = delay, 1, -1 do p("  Start in " .. i .. "s..."); os.sleep(1) end
end

local auto_loop = nil
local auto_path = INSTALL_ROOT .. "/installer/auto_update.lua"
if fs.exists(auto_path) then
  local ok_load, auto_mod = pcall(dofile, auto_path)
  if ok_load and type(auto_mod) == "table" and type(auto_mod.make_loop) == "function" then
    local interval = 120
    local cfg_path = INSTALL_ROOT .. "/config/remote_update.lua"
    if fs.exists(cfg_path) then
      local f = fs.open(cfg_path, "r"); if f then
        local src = f.readAll(); f.close()
        local loader = load(src, "=cfg", "t", {})
        if loader then
          local ok2, cfg = pcall(loader)
          if ok2 and type(cfg) == "table" then interval = tonumber(cfg.check_interval_s) or 120 end
        end
      end
    end
    auto_loop = auto_mod.make_loop(interval)
    p("[BOOT] Auto-Update Loop bereit (" .. interval .. "s)")
  else
    p("[BOOT] WARN: auto_update.lua Fehler: " .. tostring(auto_mod))
  end
else
  p("[BOOT] WARN: installer/auto_update.lua fehlt")
end

local function run()
  if auto_loop then
    parallel.waitForAny(function() dofile(entry) end, auto_loop)
  else
    dofile(entry)
  end
end

local ok, err = pcall(run)
if not ok then
  p("[BOOT] FEHLER: " .. tostring(err))
  -- Fix (2026-07-07): CRITICAL. parallel.waitForAny(role_loop, auto_loop)
  -- bedeutet: wirft EINE der beiden Coroutinen (z.B. der Auto-Updater beim
  -- Ausfuehren eines frisch heruntergeladenen, evtl. fehlerhaften
  -- Installer-Skripts via dofile(tmp)) einen unabgefangenen Fehler, stirbt
  -- die GESAMTE parallel.waitForAny-Ausfuehrung — inklusive der eigentlich
  -- gesunden Rollen-Hauptschleife. Bisher wurde der Fehler hier zwar
  -- geloggt, aber dann per error(...) ERNEUT geworfen — das crashte den
  -- gesamten Computer bis in die CraftOS-Shell, wo er ohne physisches
  -- Eingreifen fuer immer haengen blieb (vermutliche Hauptursache fuer
  -- "Node laeuft seit Stunden, loggt aber seit dem letzten Neustart
  -- nichts mehr"). Jetzt: statt erneut zu werfen, nach kurzer Pause ein
  -- automatischer Reboot-Versuch — der Computer heilt sich selbst, auch
  -- wenn der Fehler in der naechsten Runde erneut auftritt (dann eben
  -- wiederholter Reboot statt endlosem Stillstand).
  os.sleep(2)
  if os and os.reboot then os.reboot() end
  error("Failed: " .. role, 0)
end
