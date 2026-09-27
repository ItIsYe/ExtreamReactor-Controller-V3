-- nodes/rt/reactor_control.lua
--
-- Reaktor-HARDWAREZUGRIFF. Dieses Modul regelt nichts mehr.
--
-- Bis v768 lag hier v1s Steam-Margin-Regler (global und pro Reaktor),
-- die Coolant-Ueberwachung, der SAFE-Zweig und die Rod-Rampen-
-- Buchfuehrung. Alles entfernt: die Regelung liegt vollstaendig in
-- nodes/rt/rt2_engine.lua (Staebe je Reaktor aus dem EIGENEN Dampftank,
-- siehe rt2_unit.lua) und schreibt ueber nodes/rt/rt2_adapter.lua.
--
-- Was hier bleibt:
--   * Dampfmessung fuer die Statusaufnahme und den lokalen Schirm
--     (externer Tank, sonst Summe der Reaktor-Innentanks).
--   * Die Rod-Grenzen aus der Konfiguration -- sie beschreiben die Anlage,
--     nicht eine Regelentscheidung.
--   * Die initiale Rod-Stellung beim Boot (voll eingefahren).
--   * Der Sicherheitszustand fuer den Update-Quiesce (Staebe 100%,
--     Reaktor aus) -- er gehoert dem Updater, nicht dem Regler.
--
-- SCHNITTSTELLE: Alle oeffentlichen Funktionen nehmen ctx als ersten Parameter.
--
-- ctx-Felder die dieses Modul liest/schreibt:
--   ctx.reactor_ctrl      -- { [name] = { last_applied, last_known_rods, ... } }
--   ctx.peripherals       -- { reactors = { [name] = peripheral } }
--   ctx.warned            -- { [key] = true } einmalige Warn-Flags
--   ctx.last_applied_rods -- letzter geschriebener Rod-Level
--   ctx.last_rod_apply_ts -- os.clock() wann zuletzt geschrieben
--   ctx.steam_tank_name   -- gecachter Name des Steam-Tanks
--   ctx.config            -- node config (reactors, turbines, rails)
--   ctx.CONFIG            -- Konstanten (ROD_MIN, ROD_MAX, INITIAL_ROD_LEVEL)
--   ctx.adapters          -- { reactor = ..., turbine }
--   ctx.safety            -- safety-Modul
--   ctx.fluid             -- fluid-Modul
--   ctx.utils             -- utils-Modul
--   ctx.log               -- function(level, msg)
--   ctx.warn_once         -- function(key, msg)

local M = {}

-- ── Rod-Grenzen aus der Konfiguration ───────────────────────────────────────

function M.get_effective_regulator_rod_caps(ctx)
  local rod_rails = ctx.config.rails and ctx.config.rails.reactor_rods or {}
  local cfg_min = type(rod_rails.min) == "number" and rod_rails.min or ctx.CONFIG.ROD_MIN
  local cfg_max = type(rod_rails.max) == "number" and rod_rails.max or ctx.CONFIG.ROD_MAX
  cfg_min = ctx.safety.clamp(cfg_min, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)
  cfg_max = ctx.safety.clamp(cfg_max, ctx.CONFIG.ROD_MIN, ctx.CONFIG.ROD_MAX)
  if cfg_min > cfg_max then cfg_min, cfg_max = cfg_max, cfg_min end
  return cfg_min, cfg_max
end

function M.clamp_rods(ctx, level, allow_overmax)
  if type(level) ~= "number" then level = ctx.CONFIG.ROD_MAX end
  local max_limit = allow_overmax and 100 or ctx.CONFIG.ROD_MAX
  return ctx.safety.clamp(level, ctx.CONFIG.ROD_MIN, max_limit)
end

-- ── Steam-Quellen-Erkennung und -Messung ────────────────────────────────────
function M.resolve_steam_tank_name(ctx)
  if ctx.steam_tank_name and peripheral.isPresent(ctx.steam_tank_name) then
    return ctx.steam_tank_name
  end
  for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    if ptype and string.find(ptype, "ultimate_fluid_tank") then
      ctx.steam_tank_name = name
      return ctx.steam_tank_name
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    if string.find(string.lower(name), "steam") then
      local tank = ctx.utils.safe_wrap(name)
      if tank and (tank.tanks or tank.getFluidAmount) then
        ctx.steam_tank_name = name
        return ctx.steam_tank_name
      end
    end
  end
  return nil
end

function M.read_steam_tank_amount(ctx)
  local name = M.resolve_steam_tank_name(ctx)
  if not name then return nil end
  local tank, err = ctx.utils.safe_wrap(name)
  if not tank then
    ctx.warn_once("steam_tank_wrap:" .. name,
      "Steam tank wrap failed for " .. name .. ": " .. tostring(err))
    return nil
  end
  local amount, read_err = ctx.fluid.read_amount(tank, { "getFluidAmount" })
  if type(amount) == "number" then return amount end
  ctx.warn_once("steam_tank_read:" .. tostring(name),
    "Steam tank read failed for " .. tostring(name) .. ": " .. tostring(read_err))
  return nil
end

function M.read_reactor_steam_amount(ctx)
  local total, found = 0, false
  for _, name in ipairs(ctx.config.reactors or {}) do
    local reactor = ctx.peripherals.reactors[name]
    if not reactor then
      local wrapped, err = ctx.utils.safe_wrap(name)
      if wrapped then reactor = wrapped
      else ctx.warn_once("reactor_wrap:" .. name,
        "Reactor wrap failed for " .. name .. ": " .. tostring(err)) end
    end
    if reactor then
      local amount = ctx.fluid.read_amount(reactor,
        { "getHotFluidAmount", "getSteamAmount", "getSteam" })
      if type(amount) == "number" then total = total + amount; found = true end
    end
  end
  return found and total or nil
end

function M.get_available_steam(ctx)
  local tank_amount = M.read_steam_tank_amount(ctx)
  if type(tank_amount) == "number" then return tank_amount end
  return M.read_reactor_steam_amount(ctx)
end

-- ── Buchfuehrung ────────────────────────────────────────────────────────────

function M.ensure_reactor_ctrl(ctx, name)
  local ctrl = ctx.reactor_ctrl[name]
  if not ctrl then
    ctrl = { last_applied = nil, last_known_rods = nil }
    ctx.reactor_ctrl[name] = ctrl
  end
  return ctrl
end

function M.init_reactor_ctrl(ctx)
  ctx.reactor_ctrl = {}
  for _, name in ipairs(ctx.config.reactors or {}) do
    ctx.reactor_ctrl[name] = { last_applied = nil, last_known_rods = nil }
  end
end

-- ── Rod-Ansteuerung ─────────────────────────────────────────────────────────

-- Prueft, ob ein Reaktor-Peripheral ueberhaupt einen Rod-Write-Pfad hat.
-- Genutzt von der Discovery/Bindung, nicht von einer Regelung.
function M.has_reactor_rod_write_path(caps)
  if type(caps) ~= "table" then return false end
  return (
    caps.setAllControlRodLevels or
    caps.setControlRodsLevels   or
    caps.setControlRodLevel     or
    caps.getControlRods
  ) and true or false
end

-- Schreibt EINEN Rod-Level auf alle konfigurierten Reaktoren. Der einzige
-- Aufrufer ist apply_initial_reactor_rods() -- die laufende Rod-Regelung
-- macht rt2_engine.lua ueber rt2_adapter.lua, pro Reaktor und mit eigener
-- Ratenbegrenzung. Deshalb steht hier bewusst KEINE Rails-Begrenzung, keine
-- Richtungs-Buchfuehrung und keine Mindest-Wartezeit mehr: das waren
-- Bestandteile des alten Reglers, und zwei Regler an denselben Staeben sind
-- genau das Problem, das dieser Umbau beseitigt.
function M.applyReactorRods(ctx, target, source)
  if type(target) ~= "number" then return false end
  source = source or "UNSPECIFIED"
  local clamped = M.clamp_rods(ctx, target)

  local applied = false
  for name, ctrl in pairs(ctx.reactor_ctrl) do
    local ok_apply, err_apply = ctx.adapters.reactor.apply_rod_level(
      name, clamped, ctx.CONFIG.LOG_PREFIX)
    if ok_apply then
      ctrl.last_applied = clamped
      ctrl.last_known_rods = clamped
      applied = true
    else
      ctx.warn_once("reactor_rods:" .. name,
        "Reactor control rod write failed for " .. tostring(name)
        .. ": " .. tostring(err_apply))
    end
  end
  if not applied then return false end

  ctx.last_applied_rods = clamped
  ctx.last_rod_apply_ts = os.clock()
  ctx.log("INFO", string.format("Rods auf %d%% geschrieben (%s)", clamped, source))
  return true
end


-- Update quiesce: every configured
-- reactor must have a successful 100%-rod write followed by a fresh readback.
-- setActive(false) is also applied/verified when that API exists. The caller
-- retries this function while the update handshake remains requested.
function M.apply_update_quiesce(ctx)
  local result = { ok = true, reactors = {} }
  for _, name in ipairs(ctx.config.reactors or {}) do
    local item = { name = name }
    local write_ok, write_err = ctx.adapters.reactor.apply_rod_level(name, 100, ctx.CONFIG.LOG_PREFIX)
    item.rod_write = write_ok == true
    item.rod_error = write_err
    local rods = ctx.adapters.reactor.read_control_rods(name, ctx.CONFIG.LOG_PREFIX)
    item.rods = rods
    item.rods_safe = type(rods) == "number" and rods >= 99.5

    local reactor = ctx.peripherals and ctx.peripherals.reactors and ctx.peripherals.reactors[name] or nil
    if not reactor and ctx.utils and type(ctx.utils.safe_wrap) == "function" then
      reactor = select(1, ctx.utils.safe_wrap(name))
    end
    item.present = reactor ~= nil
    item.active_safe = true
    if reactor and type(reactor.setActive) == "function" then
      local ok_set, set_result = pcall(reactor.setActive, false)
      item.active_write = ok_set and set_result ~= false
      if type(reactor.getActive) == "function" then
        local ok_read, active = pcall(reactor.getActive)
        item.active_readback = ok_read and type(active) == "boolean"
        item.active = active
        item.active_safe = ok_read and active == false
      else
        item.active_safe = item.active_write
      end
    elseif not reactor then
      item.active_safe = false
    end

    item.ok = item.present and item.rod_write and item.rods_safe and item.active_safe
    if item.ok then
      local ctrl = M.ensure_reactor_ctrl(ctx, name)
      ctrl.last_applied = 100
      ctrl.last_known_rods = rods
      ctrl.active_state = false
    else
      result.ok = false
    end
    result.reactors[#result.reactors + 1] = item
  end
  return result.ok, result
end

-- Beim Boot fahren die Staebe voll ein. Der Regler holt sie von dort
-- herunter, sobald der Dampftank Bedarf zeigt -- nie umgekehrt.
function M.apply_initial_reactor_rods(ctx)
  M.applyReactorRods(ctx, ctx.CONFIG.INITIAL_ROD_LEVEL, "STARTUP_INIT")
end

return M
