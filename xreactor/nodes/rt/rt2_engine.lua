-- RT rewrite, step 9 (cutover glue): the ONLY module main.lua talks to
-- for the "v2" engine path. Owns the single rt2_orchestrator instance for
-- this RT process and bridges it to main.lua's existing ctx (peripheral
-- adapters, config, logging) via rt2_adapter.
--
-- main.lua's discovery/comms/monitor/status-publishing machinery is
-- UNCHANGED for v2 -- only the control decision + hardware write step
-- (this module's M.tick()) and command handling (M.handle_command())
-- are redirected here when config.engine == "v2".
--
-- Single-reactor limitation is enforced by main.lua before this module
-- is ever initialized (see main.lua's engine-selection guard) -- this
-- module itself only ever looks at devices.reactors[1].

local orchestrator = require("nodes.rt.rt2_orchestrator")
local adapter = require("nodes.rt.rt2_adapter")
local rt2_state = require("nodes.rt.rt2_state")
local rt2_safety = require("nodes.rt.rt2_safety")
local rt2_projection = require("nodes.rt.rt2_projection")
local rt2_reactor = require("nodes.rt.rt2_reactor")
local rt2_turbine = require("nodes.rt.rt2_turbine")

local M = {}

local engine
local last_result
local last_logged_capacity_diag
-- Der zuletzt gemeldete Leistungswert. Nur dazu da, eine Erhoehung nach
-- dem Einlernen von der Erstmessung zu unterscheiden -- sonst stuende bei
-- jeder Nachfuehrung wieder "EINLERNEN FERTIG" auf dem Schirm.
local last_logged_max_output
-- Der zuletzt GEMELDETE Grund. Ohne ihn liess sich "das Einlernen ist
-- gerade fertig geworden" nicht von "es ist laengst fertig" unterscheiden:
-- der Vergleichsschluessel unten enthaelt auch at_target/saturated, und
-- die schwanken im Normalbetrieb staendig (eine Turbine faellt kurz aus
-- dem Zielband, eine andere kommt hinein). Jede dieser Schwankungen liess
-- erneut "EINLERNEN FERTIG" mit derselben Zahl auflaufen -- im
-- Dauerbetrieb mit knappem Dampf dutzendfach.
local last_logged_reason
-- Wie stark die gemessene Leistung steigen muss, damit die Nachfuehrung
-- ueberhaupt gemeldet wird. Ohne Schwelle stand im Protokoll
-- "Leistung nach oben korrigiert: 18040 -> 18041 RF/t" -- eine Zeile, die
-- nichts aussagt und nur die echten Meldungen verdraengt.
local MIN_REPORTED_OUTPUT_RISE = 0.01
local last_projection
-- Je Reaktor (Schluessel: Name): Sicherheitszustand und letzte gemeldete
-- Sicherheitslage.
local reactor_state = {}

-- Die Reaktoren dieses Knotens (Peripherienamen). Die Turbinen bleiben
-- EINE Flotte: sie haengen alle am selben Dampfnetz, und jeder Reaktor
-- regelt sich unabhaengig aus seinem eigenen Tank.
local reactor_names = {}

function M.init(opts)
  opts = opts or {}

  reactor_names = {}
  for _, name in ipairs((opts.config and opts.config.reactors) or {}) do
    reactor_names[#reactor_names + 1] = name
  end

  reactor_state = {}
  local specs = {}
  for index, name in ipairs(reactor_names) do
    local key = name or ("reactor" .. index)
    reactor_state[key] = { safety = rt2_safety.new_state() }
    specs[#specs + 1] = { name = name }
  end

  last_logged_capacity_diag = nil
  last_logged_max_output = nil
  last_logged_reason = nil
  last_projection = nil
  -- Die MASTER-Liveness-Schwelle der Zustandsmaschine folgt
  -- config.comms.peer_timeout_s, weil Health-Check und Monitor-Anzeige
  -- (nodes/rt/health_payload.lua, nodes/rt/monitor_ui.lua) ihren
  -- MASTER-Zustand aus der Peer-Tabelle von core/comms.lua lesen, die
  -- genau mit diesem Wert arbeitet. Zwei unterschiedliche Schwellen
  -- hiessen: "MASTER DOWN" auf dem Monitor, waehrend der Regler noch im
  -- Zustand MASTER laeuft.
  local master_timeout_ms = opts.master_timeout_ms
  if master_timeout_ms == nil then
    local comms_cfg = opts.config and opts.config.comms
    local peer_timeout_s = comms_cfg and tonumber(comms_cfg.peer_timeout_s) or nil
    if peer_timeout_s and peer_timeout_s > 0 then
      master_timeout_ms = peer_timeout_s * 1000
    end
  end
  engine = orchestrator.new({
    initial_state = opts.initial_state,
    master_timeout_ms = master_timeout_ms,
    reactors = specs,
  })
  last_result = nil
  return engine
end

function M.note_master_seen(now_ms)
  if engine then engine.note_master_seen(now_ms) end
end

function M.handle_command(command)
  if not engine then
    return { ok = false, error = "v2 engine not initialized", reason_code = "NOT_READY" }
  end
  return engine.handle_command(command)
end

function M.current_state()
  if not engine then return rt2_state.states.INIT end
  return engine.current_state()
end

-- ctx: main.lua's RT ctx. Needs:
--   ctx.config.turbines / ctx.config.reactors -- discovered peripheral names
--   ctx.adapters.turbine / ctx.adapters.reactor -- adapters/turbine.lua, adapters/reactor.lua
--   ctx.CONFIG.LOG_PREFIX
function M.tick(ctx)
  if not engine then return nil end
  local now_ms = os.epoch and os.epoch("utc") or 0

  -- Discovery laeuft nach init(), deshalb die Reaktorliste hier frisch
  -- nehmen. Die Turbinen bleiben EINE Flotte.
  local live = (ctx.config and ctx.config.reactors) or {}
  if #live > 0 then
    -- Nach INHALT vergleichen, nicht nur nach Anzahl: tauscht die
    -- Discovery zwei Reaktoren (gleiche Anzahl, andere Namen), waere die
    -- Liste sonst still veraltet und jeder Reaktor bekaeme die
    -- Entscheidung des anderen.
    local differs = (#live ~= #reactor_names)
    if not differs then
      for index = 1, #live do
        if live[index] ~= reactor_names[index] then differs = true; break end
      end
    end
    if differs then
      reactor_names = {}
      for _, name in ipairs(live) do reactor_names[#reactor_names + 1] = name end
    end
  end

  local turbine_readings = {}
  for _, name in ipairs((ctx.config and ctx.config.turbines) or {}) do
    local info = ctx.adapters.turbine.inspect(name, ctx.CONFIG.LOG_PREFIX)
    local reading = adapter.read_turbine(name, info)
    if reading then turbine_readings[#turbine_readings + 1] = reading end
  end

  -- Sicherheit VOR der Regelentscheidung, je Reaktor: eine Ausloesung
  -- muss diesen Takt gewinnen, nicht den naechsten.
  local reactor_inputs = {}
  for index, name in ipairs(reactor_names) do
    local key = name or ("reactor" .. index)
    reactor_state[key] = reactor_state[key] or { safety = rt2_safety.new_state() }

    local info = ctx.adapters.reactor.inspect(name, ctx.CONFIG.LOG_PREFIX)
    local reading = adapter.read_reactor(info) or {}
    local safety_result = rt2_safety.evaluate(reactor_state[key].safety, reading,
      (ctx.config and ctx.config.safety) or nil)

    local previous = reactor_state[key].last_safety_reason
    if safety_result.reason ~= previous then
      reactor_state[key].last_safety_reason = safety_result.reason
      local label = (#reactor_names > 1) and (" an " .. key) or ""
      if safety_result.tripped then
        local msg = string.format(
          "v2 SAFETY-TRIP%s: %s (Temperatur=%s, Kuehlmittel=%s) -- dessen Staebe voll eingefahren",
          label, tostring(safety_result.reason), tostring(safety_result.temperature),
          tostring(safety_result.coolant_ratio))
        ctx.log("WARN", msg)
        pcall(print, "[RT] " .. msg)
      elseif previous ~= nil then
        ctx.log("INFO", "v2 Sicherheitslage" .. label .. " wieder normal")
      end
    end

    reactor_inputs[index] = { name = name, safety_tripped = safety_result.tripped, reactor = reading }
  end

  local result = engine.tick({
    now_ms = now_ms,
    hardware_ready = (#reactor_names > 0) and (#turbine_readings > 0),
    turbines = turbine_readings,
    reactors = reactor_inputs,
  })

  for _, t in ipairs(result.turbines) do
    adapter.apply_turbine(ctx.adapters.turbine, t.name, ctx.CONFIG.LOG_PREFIX, t)
  end
  for index, decision in ipairs(result.reactors) do
    -- Der Name aus der Entscheidung selbst, nicht ueber die Position:
    -- die Einheitenliste wird je Takt an die gemeldeten Reaktoren
    -- angeglichen, ihre Reihenfolge muss also nicht mehr mit
    -- reactor_names uebereinstimmen. Ueber den Index zu paaren hiesse,
    -- einem Reaktor die Staebe des anderen zu stellen.
    local name = decision.name or reactor_names[index]
    if name then
      adapter.apply_reactor(ctx.adapters.reactor, name, ctx.CONFIG.LOG_PREFIX, decision)
    end
  end

  -- Die gemeldete Leistung sichtbar machen, wenn sie sich aendert.
  local cap = result.capacity
  local diag = string.format("%s|%d|%d|%d|%d", tostring(cap.reason),
    math.floor((cap.max_output or 0) / 1000), cap.total_turbines or 0,
    cap.at_target or 0, cap.saturated or 0)
  if diag ~= last_logged_capacity_diag then
    last_logged_capacity_diag = diag
    local previous_reason = last_logged_reason
    local msg
    if cap.reason == "NO_TURBINES" then
      msg = "v2 noch keine Turbine gefunden -- warte auf Discovery"
    elseif cap.reason == "TOPOLOGY_CHANGED" then
      msg = string.format("v2 Turbinenzahl geaendert (%d) -- die Anlage wird neu vermessen",
        cap.total_turbines or 0)
    elseif cap.reason == "TOPOLOGY_PENDING" then
      msg = "v2 Turbinenzahl schwankt -- der gelernte Wert bleibt vorerst stehen"
    elseif cap.reason == orchestrator.LEARNING then
      if (cap.saturated or 0) > 0 then
        msg = string.format(
          "v2 EINLERNEN: %d Turbine(n) fahren VOLLEN Durchfluss und erreichen trotzdem"
            .. " keine %d RPM -- im Zielband %d von %d, noetig %d. Fehlt Dampf?",
          cap.saturated, orchestrator.TARGET_RPM, cap.at_target or 0,
          cap.total_turbines or 0, cap.required_at_target or 0)
      elseif (cap.best_output or 0) > 0 then
        msg = string.format(
          "v2 EINLERNEN laeuft: bisher %.0f RF/t gemessen (%d von %d Turbinen im Zielband)",
          cap.best_output or 0, cap.at_target or 0, cap.total_turbines or 0)
      else
        msg = string.format(
          "v2 EINLERNEN wartet: %d von %d Turbinen im Zielband (%d RPM +/- %d), noetig sind %d."
            .. " Die MASTER-Vorgabe ist so lange uebersteuert, die ganze Flotte faehrt.",
          cap.at_target or 0, cap.total_turbines or 0, orchestrator.TARGET_RPM,
          orchestrator.LEARN_TOLERANCE_RPM, cap.required_at_target or 0)
      end
    elseif cap.reason == orchestrator.MEASURED then
      -- Drei verschiedene Lagen, die frueher durcheinandergingen:
      --
      --   1. Das Einlernen ist GERADE fertig geworden (der vorige
      --      gemeldete Grund war noch LEARNING) -> die Fertigmeldung,
      --      genau einmal. Sie darf nicht davon abhaengen, ob der
      --      Messwert in diesem Takt zufaellig noch ein Stueck gestiegen
      --      ist -- sonst stand beim ersten Einlernen statt "FERTIG" eine
      --      "nach oben korrigiert"-Meldung mit einem Ausgangswert, den
      --      nie jemand gesehen hat.
      --   2. Es war laengst fertig und die Leistung ist gestiegen -> die
      --      Nachfuehrmeldung.
      --   3. Es war laengst fertig und nichts ist gestiegen -> nichts.
      --      Der Vergleichsschluessel oben enthaelt auch at_target und
      --      saturated, und die schwanken im Normalbetrieb staendig.
      --      Ohne diesen Zweig lief bei knappem Dampf dutzendfach
      --      "EINLERNEN FERTIG" mit derselben Zahl auf.
      local already_measured = previous_reason == orchestrator.MEASURED
        or previous_reason == orchestrator.OBSERVED
      if not already_measured then
        msg = string.format(
          "v2 EINLERNEN FERTIG: %.0f RF/t aus %d Turbinen gemessen (roh %.0f, abzueglich"
            .. " %.0f %% Reserve). Normale Regelung nach MASTER-Vorgabe.",
          cap.max_output or 0, cap.sustainable_turbines or 0, cap.best_output or 0,
          orchestrator.LEARN_SAFETY_MARGIN * 100)
        if (cap.sustainable_turbines or 0) < (cap.total_turbines or 0) then
          msg = msg .. string.format(" -- %d der %d Turbinen waren dabei nie gleichzeitig im Zielband",
            (cap.total_turbines or 0) - (cap.sustainable_turbines or 0), cap.total_turbines or 0)
        end
      elseif last_logged_max_output
          and (cap.max_output or 0) >= last_logged_max_output * (1 + MIN_REPORTED_OUTPUT_RISE) then
        -- Nachgefuehrt: die Flotte hat mehr geliefert als beim Einlernen.
        -- Nur nach oben, siehe rt2_orchestrator.lua.
        msg = string.format(
          "v2 Leistung nach oben korrigiert: %.0f -> %.0f RF/t aus %d Turbinen"
            .. " (roh %.0f, abzueglich %.0f %% Reserve)",
          last_logged_max_output, cap.max_output or 0,
          cap.sustainable_turbines or 0, cap.best_output or 0,
          orchestrator.LEARN_SAFETY_MARGIN * 100)
      end
    end
    -- Der Bezugswert wandert nur mit, wenn auch wirklich gemeldet wurde.
    -- Sonst waere jede unterdrueckte Kleinigkeit trotzdem verbraucht: ein
    -- langsames Ansteigen in vielen winzigen Schritten wuerde den
    -- Schwellwert nie erreichen und damit nie gemeldet.
    if cap.reason ~= orchestrator.MEASURED or msg ~= nil then
      last_logged_max_output = cap.max_output or 0
    end
    last_logged_reason = cap.reason
    -- Einen Abbruch auf Zeit gibt es nicht mehr (siehe rt2_orchestrator.lua):
    -- das Einlernen wartet, bis die geforderten Turbinen da sind, und sagt
    -- in jedem Takt, wie viele noch fehlen.
    if msg then
      ctx.log("INFO", msg)
      pcall(print, "[RT] " .. msg)
    end
  end

  -- Jeder Reaktor wird nach seinem eigenen Messwert und seiner eigenen
  -- Sicherheitslage beurteilt.
  local by_name = {}
  for index, ri in ipairs(reactor_inputs) do
    local decision = result.reactors[index]
    if ri.name then
      by_name[ri.name] = { reading = ri.reactor, tripped = ri.safety_tripped == true }
    end
    local _ = decision
  end
  last_projection = rt2_projection.project(result, ctx.modules, { by_name = by_name })
  for id, projected in pairs(last_projection.modules) do
    local module = ctx.modules and ctx.modules[id]
    if module then
      module.state = projected.state
      module.progress = projected.progress
    end
  end

  last_result = result
  return result
end

-- Fields merged into the status payload sent to MASTER -- mirrors the
-- shape status_snapshot.lua's build_status_payload() already produces
-- (mode/turbines/capacity_*) so MASTER-side code needs no v2-specific
-- branching to read it.
function M.status_fields()
  if not last_result then
    return { mode = M.current_state(), node_state = rt2_projection.node_state(M.current_state()) }
  end
  local turbines = {}
  for _, t in ipairs(last_result.turbines) do
    turbines[#turbines + 1] = {
      id = t.name,
      target_rpm = t.target_rpm,
      flow = t.flow_decision and t.flow_decision.flow or nil,
      coil_engaged = t.coil_decision and t.coil_decision.engaged or nil,
      -- Warum dieser Durchfluss -- ohne den Grund laesst sich am Schirm
      -- nicht unterscheiden, ob eine Turbine ruhig steht (SETTLED)
      -- oder nur gerade wartet (SETTLING).
      flow_reason = t.flow_decision and t.flow_decision.reason or nil,
    }
  end
  return {
    mode = last_result.state,
    -- What payload.state should report -- node_state_machine itself stays
    -- untouched under v2 (see rt2_projection.lua's header on why).
    node_state = last_projection and last_projection.node_state
      or rt2_projection.node_state(last_result.state),
    capacity_ready = last_result.capacity.ready,
    -- Wieviel RF/t dieser Knoten nachweislich liefert. MASTER teilt seinen
    -- Bedarf gegen genau diese Zahl auf (rt_sync.node_capacity ->
    -- uniform_pct), also ist es der hoechste Ausstoss, der wirklich schon
    -- geflossen ist -- nichts Hochgerechnetes (siehe rt2_orchestrator).
    capacity_max = last_result.capacity.max_output,
    capacity_total_turbines = last_result.capacity.total_turbines,
    -- MASTER liest diese beiden Namen (message_handlers.lua).
    capacity_stable_turbines = last_result.capacity.at_target,
    -- Wieviele Turbinen in diesem Takt ueberhaupt laufen SOLLEN. Ohne das
    -- laesst sich "3 von 3 am Ziel" nicht von "3 von 50" unterscheiden.
    -- Wieviele Turbinen fuer den Messpunkt noetig sind (80 % der Flotte).
    -- Ohne das laesst sich "40 im Band" nicht als Fortschritt lesen.
    capacity_required_turbines = last_result.capacity.required_at_target,
    capacity_learning = last_result.capacity.learning == true,
    capacity_source = last_result.capacity.reason,
    -- Wieviele Turbinen liefen, als der Hoechstwert floss. Traegt die
    -- Anlage ihre ganze Flotte, ist das schlicht die Flottengroesse.
    capacity_sustainable_turbines = last_result.capacity.sustainable_turbines,
    -- Aliase unter den alten v2-Namen beibehalten: die RT-eigene UI und
    -- der Integrationstest lesen sie.
    capacity_at_target = last_result.capacity.at_target,
    capacity_reason = last_result.capacity.reason,
    -- Die Leistungsvorgabe, gegen die dieser Takt geregelt hat, und was
    -- sie in RF/t bedeutet. Beides braucht die RT-eigene Oberflaeche:
    -- sie las bisher v1's ctx.targets, das unter v2 niemand mehr fuellt,
    -- und zeigte deshalb dauerhaft "SOLL 0.0 / MASTER % 0.0".
    master_percent = last_result.master_percent,
    power_target = (last_result.capacity.max_output or 0)
      * ((tonumber(last_result.effective_percent or last_result.master_percent) or 0) / 100),
    turbines = turbines,
    control_rod_level = last_result.reactor_decision and last_result.reactor_decision.rods or nil,
    -- Je Reaktor, weil ein Knoten mehrere haben kann und sie unabhaengig
    -- regeln -- control_rod_level allein zeigte nur den ersten.
    reactors = (function()
      local out = {}
      for _, decision in ipairs(last_result.reactors or {}) do
        out[#out + 1] = {
          id = decision.name,
          control_rod_level = decision.rods,
          reason = decision.reason,
          safety_tripped = decision.safety_tripped == true,
        }
      end
      return out
    end)(),
    tripped_reactors = last_result.tripped_reactors or 0,
  }
end

return M
