-- nodes/rt/turbine_control.lua
--
-- Turbinen-HARDWAREZUGRIFF. Dieses Modul regelt nichts.
--
-- Bis v768 lag hier v1s kompletter Turbinenregler (Flow-Rampe, Induktor-
-- Logik, Overspeed, Turbinen-Rotation, Autonom-Modus). Der ist entfernt:
-- die Regelung liegt vollstaendig in nodes/rt/rt2_engine.lua und schreibt
-- ueber nodes/rt/rt2_adapter.lua. Was hier bleibt:
--
--   * die Buchfuehrung je Turbine (ctrl-Eintraege), die der Quiesce
--     zurueckschreibt;
--   * der Sicherheitszustand fuer den Update-Quiesce (Flow 0, Turbine aus,
--     Coil eingehaengt) -- der einzige Schreibpfad hier, und er gehoert dem
--     Updater, nicht dem Regler.
--
-- Entfallen (v815/v817): das Lesen von Drehzahl und Durchfluss fuer den
-- zweiten Leseweg des Schirms, die Faehigkeiten-Ermittlung je Geraet
-- (build_capabilities/get_device_caps, ctx.capability_cache) und
-- clamp_turbine_flow. Welche Methoden eine Turbine hat, weiss allein
-- adapters/turbine.lua -- es merkt sich eine Liste nur, wenn sie
-- vollstaendig ist, und verwirft sie, wenn die Peripherie verschwindet.
--
-- SCHNITTSTELLE: Alle oeffentlichen Funktionen nehmen ctx als ersten Parameter.
--
-- ctx-Felder die dieses Modul liest/schreibt:
--   ctx.turbine_ctrl_store   -- { [name] = ctrl-Objekt } (interner State)
--   ctx.adapters             -- { turbine = adapters/turbine.lua } (Update-Quiesce)
--   ctx.config               -- turbines, reactors, ...
--   ctx.CONFIG               -- LOG_PREFIX
--   ctx.utils                -- utils-Modul (safe_peripheral_call)
--   ctx.binding              -- binding-Modul (Meldung "keine Turbinen")
--   ctx.runtime_config       -- { configured_reactors, configured_turbines }
--   ctx.log                  -- function(level, msg)

local M = {}

local function get_turbine_ctrl(ctx, name)
  ctx.turbine_ctrl_store = ctx.turbine_ctrl_store or {}
  local ctrl = ctx.turbine_ctrl_store[name]
  if not ctrl then
    ctrl = {}
    ctx.turbine_ctrl_store[name] = ctrl
  end
  return ctrl
end
-- Exportiert, damit main.lua den Eintrag fuer den Quiesce erreichen kann.
M.get_turbine_ctrl = get_turbine_ctrl

-- ── Buchfuehrung ────────────────────────────────────────────────────────────
-- Legt pro Turbine einen leeren ctrl-Eintrag an. Er traegt keine Sollwerte
-- mehr (v1s Rampen-/Startup-Felder sind mit v1 entfallen) -- nur noch das,
-- was apply_update_quiesce() nach einem bestaetigten Write zurueckschreibt.

function M.init_turbine_ctrl(ctx)
  ctx.turbine_ctrl_store = {}
  local turbines = ctx.config.turbines or {}
  ctx.log("INFO", "Detected " .. tostring(#turbines) .. " turbines")
  if #turbines < 1 then
    ctx.log("ERROR", ctx.binding.missing_devices_message(
      "turbine", ctx.binding.build_policy(
        ctx.runtime_config.configured_reactors,
        ctx.runtime_config.configured_turbines)))
    return
  end
  for _, name in ipairs(turbines) do
    get_turbine_ctrl(ctx, name)
  end
end

-- ── Update-Quiesce: der einzige Schreibpfad hier ────────────────────────────
-- Flow 0, Turbine aus, Coil eingehaengt -- und jeweils zurueckgelesen. Er
-- gehoert dem Updater, nicht dem Regler.
--
-- NAMENSBASIERT ueber adapters/turbine.lua, denselben Weg, den der Regler
-- nimmt (rt2_adapter.lua). Bis v813 liefen Schreiben und Rueckmessung hier
-- ueber ein wrap-Handle und den Faehigkeiten-Cache der Discovery (beide
-- seit v817 entfernt). Beide schrieb die Discovery einmal und erneuerte sie
-- nicht, solange der Name gebunden blieb. Kam eine
-- Turbine nach dem Laden der Anlage-Chunks zuerst mit verkuerzter
-- Methodenliste zurueck (Multiblock im Zusammenbau), blieben beide auf
-- diesem Stand: der Durchfluss liess sich nicht mehr zuruecklesen, der
-- Quiesce wurde nie bestaetigt, und installer/auto_update.lua erzwang das
-- Update nach 60 s ohne Bestaetigung. Der Adapter merkt sich eine
-- unvollstaendige Methodenliste nicht und verwirft die einer
-- verschwundenen Peripherie.
--
-- Je Turbine hoechstens drei Stellbefehle und drei Rueckmessungen, wie
-- vorher -- bei 50 Turbinen je Knoten zaehlt jeder Peripherie-Aufruf.
-- Gestellt und zurueckgelesen wird nur, was die Turbine laut ihrer
-- Methodenliste kann; der Durchfluss muss immer zuruecklesbar sein.
local FLOW_READBACK_METHOD = "getFluidFlowRateMax"

local function write_ok(ok, err)
  return err == nil and ok ~= nil and ok ~= false
end

local function read_back(ctx, name, method)
  local value, err = ctx.utils.safe_peripheral_call(name, method)
  if err ~= nil then return nil end
  return value
end

function M.apply_update_quiesce(ctx)
  local result = { ok = true, turbines = {} }
  local adapter = ctx.adapters and ctx.adapters.turbine
  local prefix = ctx.CONFIG and ctx.CONFIG.LOG_PREFIX or "RT"
  for _, name in ipairs(ctx.config.turbines or {}) do
    local item = { name = name }
    local methods = adapter and adapter.method_set(name, prefix) or nil
    item.present = methods ~= nil
    if not methods then
      item.ok = false
      result.ok = false
      result.turbines[#result.turbines + 1] = item
      goto continue
    end

    item.flow_write = write_ok(adapter.set_flow(name, 0, prefix))
    if methods[FLOW_READBACK_METHOD] then
      local flow = read_back(ctx, name, FLOW_READBACK_METHOD)
      if type(flow) == "number" then
        item.flow = flow
        item.flow_source = FLOW_READBACK_METHOD
      end
    end
    item.flow_safe = type(item.flow) == "number" and math.abs(item.flow) <= 0.01

    item.active_safe = true
    if methods.setActive then
      item.active_write = write_ok(adapter.set_active(name, false, prefix))
      if methods.getActive then
        local active = read_back(ctx, name, "getActive")
        item.active_readback = type(active) == "boolean"
        item.active = active
        item.active_safe = active == false
      else
        item.active_safe = item.active_write
      end
    end

    item.inductor_safe = true
    if methods.setInductorEngaged then
      item.inductor_write = write_ok(adapter.set_coils(name, true, prefix))
      if methods.getInductorEngaged then
        local engaged = read_back(ctx, name, "getInductorEngaged")
        item.inductor_readback = type(engaged) == "boolean"
        item.inductor_engaged = engaged
        item.inductor_safe = engaged == true
      else
        item.inductor_safe = item.inductor_write
      end
    end

    item.ok = item.flow_write and item.flow_safe and item.active_safe and item.inductor_safe
    if item.ok then
      local ctrl = get_turbine_ctrl(ctx, name)
      ctrl.flow = 0
      ctrl.requested_flow = 0
      ctrl.confirmed_flow = 0
      ctrl.active_state = false
      if item.inductor_write then ctrl.inductor_engaged = true end
    else
      result.ok = false
    end
    result.turbines[#result.turbines + 1] = item
    ::continue::
  end
  return result.ok, result
end

return M
