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
local rt2_capacity = require("nodes.rt.rt2_capacity")
local rt2_safety = require("nodes.rt.rt2_safety")
local rt2_projection = require("nodes.rt.rt2_projection")
local rt2_tuning = require("nodes.rt.rt2_tuning")
local rt2_turbine_model = require("nodes.rt.rt2_turbine_model")
local rt2_turbine = require("nodes.rt.rt2_turbine")
local rt2_reactor = require("nodes.rt.rt2_reactor")
local utils = require("core.utils")

local M = {}

-- Deliberately a SEPARATE file from CONFIG.CAPACITY_CACHE_PATH (v1's
-- cache): the persisted shape differs (count-keyed, no per-turbine
-- identity signature -- see rt2_capacity.lua's header on why) and the
-- two engines must never read each other's cache.
M.CACHE_PATH = "/xreactor_config/rt2_capacity_cache.lua"
-- The measured reactor plant profile (see rt2_tuning.lua). Separate file
-- from the capacity cache: it is derived from entirely different readings
-- and stays valid when the turbine count changes, which invalidates the
-- capacity but says nothing about how the steam tank responds.
M.TUNING_PATH = "/xreactor_config/rt2_reactor_tuning.lua"
-- Die Kennlinien der einzelnen Turbinen (siehe rt2_turbine_model.lua).
-- Wieder eine eigene Datei: sie beschreiben die Turbinen, nicht den
-- Reaktor, und sie ueberleben einen Umbau am Reaktor unveraendert.
M.TURBINE_MODEL_PATH = "/xreactor_config/rt2_turbine_model.lua"

local engine
local last_result
local cache_path
local last_logged_capacity_diag
local last_logged_safety_reason
local last_projection
local tuning_path
local turbine_model_path
-- Je Reaktor (Schluessel: Name): Sicherheitszustand, letzte gemeldete
-- Sicherheitslage, ob sein Anlagenprofil schon geschrieben wurde.
local reactor_state = {}
local last_saved_max_output

-- Die Reaktoren dieses Knotens (Peripherienamen). Die Turbinen bleiben
-- EINE Flotte: sie haengen alle am selben Dampfnetz, und jeder Reaktor
-- regelt sich unabhaengig aus seinem eigenen Tank.
local reactor_names = {}

local function read_config(path)
  return (utils.load_config(path, {}))
end

local function write_config(path, data)
  return (utils.write_config(path, data))
end

-- opts.turbine_count: how many turbines discovery just found -- required
-- to validate (or reject) a persisted cache from a genuinely different
-- fleet size. opts.cache_path overrides M.CACHE_PATH (mainly for tests).
function M.init(opts)
  opts = opts or {}
  cache_path = opts.cache_path or M.CACHE_PATH
  tuning_path = opts.tuning_path or M.TUNING_PATH
  turbine_model_path = opts.turbine_model_path or M.TURBINE_MODEL_PATH

  reactor_names = {}
  for _, name in ipairs((opts.config and opts.config.reactors) or {}) do
    reactor_names[#reactor_names + 1] = name
  end

  -- Kapazitaet: EINE fuer den Knoten, wie bisher.
  local loaded, load_err = rt2_capacity.load({
    path = cache_path, read_config = read_config, turbine_count = opts.turbine_count,
  })
  last_saved_max_output = loaded and loaded.max_output or nil
  if type(opts.log) == "function" then
    if loaded then
      opts.log("INFO", string.format("v2 Kapazitaet aus Cache: max_output=%.0f", loaded.max_output))
    elseif load_err then
      opts.log("INFO", "v2 Kapazitaets-Cache nicht genutzt: " .. tostring(load_err))
    end
  end

  -- Anlagenprofil: je Reaktor, denn jeder hat seinen eigenen Dampftank.
  local profiles = rt2_tuning.load_units({ path = tuning_path, read_config = read_config })

  reactor_state = {}
  local specs = {}
  for index, name in ipairs(reactor_names) do
    local key = name or ("reactor" .. index)
    local tuned = profiles[key]
    reactor_state[key] = { safety = rt2_safety.new_state(), tuning_saved = tuned ~= nil }
    specs[#specs + 1] = { name = name, tuning_profile = tuned }
    if tuned and type(opts.log) == "function" then
      opts.log("INFO", string.format(
        "v2 Reaktorprofil fuer %s aus Messung geladen: max_step=%d Stellintervall=%dms",
        key, tuned.max_step, tuned.min_adjust_interval_ms))
    end
  end

  -- Turbinenkennlinien: je Turbine, ueberdauert Neustarts. Ohne sie faengt
  -- jede Turbine wieder mit dem tastenden Regler an.
  local turbine_models = rt2_turbine_model.load_units({
    path = turbine_model_path, read_config = read_config,
  })
  local modelled = 0
  for _ in pairs(turbine_models) do modelled = modelled + 1 end
  if modelled > 0 and type(opts.log) == "function" then
    opts.log("INFO", string.format("v2 Turbinenkennlinien geladen: %d Turbine(n)", modelled))
  end

  last_logged_safety_reason = nil
  last_logged_capacity_diag = nil
  last_projection = nil
  engine = orchestrator.new({
    initial_state = opts.initial_state,
    master_timeout_ms = opts.master_timeout_ms,
    initial_capacity = loaded,
    reactors = specs,
    -- Auch fuer Reaktoren, die die Discovery erst NACH init() bindet --
    -- der Orchestrator baut deren Einheit dann selbst und holt sich das
    -- gemessene Profil hier ab.
    tuning_profiles = profiles,
    turbine_models = turbine_models,
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
-- Ein abgelehnter Schreibbefehl war bisher voellig unsichtbar.
--
-- rt2_adapter.apply_reactor()/apply_turbine() geben ihr Ergebnis samt
-- Fehlertext zurueck -- rt2_engine.tick() hat es weggeworfen. Scheitert
-- der Stabbefehl also dauerhaft (Teilschreibung, unbekannte Methoden,
-- fehlgeschlagene Rueckleseprobe), rechnet der Regler jeden Takt sauber
-- eine neue Stellung aus, die Hardware nimmt sie nie an, der Messwert
-- bleibt stehen -- und der Knoten sagt kein Wort. Von aussen sieht das
-- exakt so aus wie "der Regler tut nichts".
--
-- Genau dieses Bild kam aus dem Betrieb: beide Reaktoren unveraendert auf
-- RODS 100%, ohne eine einzige Meldung.
local rod_write_said, turbine_write_said = {}, nil

local function announce_rod_write(ctx, name, decision, write)
  local rod_failed = not (write and write.ok == true)
  local rod_err = write and write.err or "ohne Fehlertext"
  -- Der EINSCHALTBEFEHL ist ein eigener Schreibvorgang mit eigenem
  -- Ergebnis. Er wurde bisher nirgends ausgewertet -- und genau er ist
  -- gemeint, wenn der Betreiber sagt "die Reaktoren wurden gar nicht
  -- angemacht": der Regler fordert das Einschalten in JEDEM Takt an
  -- (compute_active_decision), der Reaktor bleibt trotzdem aus, und kein
  -- Wort dazu. Extreme Reactors verweigert setActive unter anderem ohne
  -- Brennstoff und bei unvollstaendigem Multiblock.
  local wanted_active = decision and decision.activate == true
  local active_failed = wanted_active and not (write and write.active_ok == true)
  local active_err = write and write.active_err or "ohne Fehlertext"

  local key = (rod_failed and ("ROD|" .. tostring(rod_err)) or "ROD_OK")
    .. "/" .. (active_failed and ("ON|" .. tostring(active_err)) or "ON_OK")
  if rod_write_said[name] == key then return end
  local previous = rod_write_said[name]
  rod_write_said[name] = key

  if not rod_failed and not active_failed then
    if previous ~= nil then
      ctx.log("INFO", "v2 " .. tostring(name) .. ": Befehle werden wieder angenommen")
    end
    return
  end
  if rod_failed then
    local msg = string.format(
      "v2 %s: Stabbefehl ABGELEHNT (Soll %s%%) -- %s. Der Regler rechnet weiter,"
        .. " die Hardware nimmt nichts an: die Staebe bleiben stehen, wo sie sind.",
      tostring(name), tostring(decision and decision.rods), tostring(rod_err))
    ctx.log("ERROR", msg)
    pcall(print, "[RT] " .. msg)
  end
  if active_failed then
    local msg = string.format(
      "v2 %s: EINSCHALTEN ABGELEHNT -- %s. Der Regler fordert es in jedem Takt an;"
        .. " der Reaktor bleibt aus. Haeufigste Gruende: kein Brennstoff im Reaktor,"
        .. " oder der Multiblock ist unvollstaendig.",
      tostring(name), tostring(active_err))
    ctx.log("ERROR", msg)
    pcall(print, "[RT] " .. msg)
  end
end

-- Die Flotte gesammelt: bei 50 Turbinen waere eine Zeile je Turbine kein
-- Hinweis mehr, sondern ein Vorhang.
local function note_turbine_write(acc, write, name)
  if type(write) ~= "table" then return end
  local err = (write.flow_ok == false or write.flow_err) and (write.flow_err or "Durchfluss abgelehnt")
    or ((write.coil_ok == false or write.coil_err) and (write.coil_err or "Kupplung abgelehnt"))
    or nil
  if not err then return end
  acc.count = acc.count + 1
  acc.first_error = acc.first_error or tostring(err)
  acc.first_name = acc.first_name or tostring(name)
end

local function announce_turbine_writes(ctx, acc)
  local key = acc.count > 0 and (acc.count .. "|" .. tostring(acc.first_error)) or "OK"
  if turbine_write_said == key then return end
  turbine_write_said = key
  if acc.count == 0 then
    ctx.log("INFO", "v2 Turbinenbefehle werden wieder angenommen")
    return
  end
  local msg = string.format(
    "v2 %d Turbine(n) nehmen keine Befehle an, z.B. %s: %s -- Durchfluss und Kupplung"
      .. " bleiben stehen, wo sie sind.",
    acc.count, tostring(acc.first_name), tostring(acc.first_error))
  ctx.log("ERROR", msg)
  pcall(print, "[RT] " .. msg)
end

-- Warum die Staebe stehen, wo sie stehen.
--
-- Im Betrieb gemeldet (2 Reaktoren, 50 Turbinen): beide Reaktoren auf
-- RODS 100%, kein Dampf, der Knoten kam nie aus dem Einlernen. 100%
-- Einfahrung ist im Regler aber EIN Ergebnis mit mehreren voellig
-- verschiedenen Ursachen -- und keine davon war irgendwo ablesbar:
--
--   NO_STEAM_READING   GAR KEIN Dampfmesswert -> es wird sicherheitshalber
--                      voll eingefahren. Ausdruecklich NICHT der Fall bei
--                      Fuellstand 0: das ist ein gueltiger Messwert (ein
--                      Geraet, das lange aus war, steht eben auf 0) und
--                      fuehrt regulaer zum Ausfahren der Staebe.
--   SAFETY_FULL_INSERT Ausloesung oder Knoten auf SAFE.
--   DEADBAND/CONVERGING der Tank steht, wo er soll -- alles in Ordnung.
--
-- Dazu der umgekehrte Fall: Staebe am unteren Anschlag (70%) und der Tank
-- bleibt trotzdem leer. Das ist laut rt2_reactor.lua ausdruecklich KEIN
-- Reglerfehler, sondern die Anlage fordert mehr Dampf, als die bewusst
-- gesetzte 70%-Grenze hergibt -- bei 50 Turbinen an 2 Reaktoren genau die
-- Frage, die der Betreiber beantwortet haben will.
local rod_reason_said = {}

local function announce_rod_reason(ctx, name, decision, input)
  local reading = input and input.reactor or nil
  local fill = reading and tonumber(reading.fill_ratio) or nil
  local key = tostring(decision.reason)
  if decision.reason == "NO_STEAM_READING" then
    key = "NO_STEAM_READING"
  elseif decision.rods and decision.rods <= rt2_reactor.ROD_MIN
      and fill and fill < (rt2_reactor.DEFAULT_TARGET_FILL - rt2_reactor.DEADBAND) then
    key = "AT_POWER_CAP"
  else
    key = "OK"
  end
  if rod_reason_said[name] == key then return end
  rod_reason_said[name] = key

  local msg
  if key == "NO_STEAM_READING" then
    msg = string.format(
      "v2 %s: GAR KEIN Dampfmesswert (nicht 0 -- 0 ist ein gueltiger Messwert und loest das hier"
        .. " nicht aus) -- die Staebe bleiben sicherheitshalber voll eingefahren (%d%%)."
        .. " Ohne Messwert faehrt dieser Reaktor nicht hoch.",
      tostring(name), rt2_reactor.ROD_MAX)
  elseif key == "AT_POWER_CAP" then
    msg = string.format(
      "v2 %s: Staebe am unteren Anschlag (%d%%) und der Dampftank bleibt bei %.0f%% -- die Flotte"
        .. " fordert mehr Dampf, als die gesetzte %d%%-Grenze hergibt. Das ist eine Lastfrage,"
        .. " kein Reglerfehler.",
      tostring(name), rt2_reactor.ROD_MIN, fill * 100, rt2_reactor.ROD_MIN)
  end
  if msg then
    ctx.log("WARN", msg)
    pcall(print, "[RT] " .. msg)
  end
end

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

  local write_errors = { count = 0 }
  for _, t in ipairs(result.turbines) do
    note_turbine_write(write_errors,
      adapter.apply_turbine(ctx.adapters.turbine, t.name, ctx.CONFIG.LOG_PREFIX, t), t.name)
  end
  for index, decision in ipairs(result.reactors) do
    -- Der Name aus der Entscheidung selbst, nicht ueber die Position:
    -- die Einheitenliste wird je Takt an die gemeldeten Reaktoren
    -- angeglichen, ihre Reihenfolge muss also nicht mehr mit
    -- reactor_names uebereinstimmen. Ueber den Index zu paaren hiesse,
    -- einem Reaktor die Staebe des anderen zu stellen.
    local name = decision.name or reactor_names[index]
    if name then
      local write = adapter.apply_reactor(ctx.adapters.reactor, name, ctx.CONFIG.LOG_PREFIX, decision)
      announce_rod_write(ctx, name, decision, write)
      announce_rod_reason(ctx, name, decision, reactor_inputs[index])
    end
  end

  announce_turbine_writes(ctx, write_errors)

  -- Einlernen sichtbar machen.
  local cap = result.capacity
  local waiting = (cap.max_output or 0) <= 0
  local diag = string.format("%s|%d|%s|%s", tostring(cap.reason),
    math.floor((cap.max_output or 0) / 1000), tostring(cap.ready), tostring(waiting))
  do
    local msg
    if cap.reason == "MEASURING" then
      msg = string.format("v2 Einlernen laeuft: bisher %.0f RF/t gemessen (%d von %d Turbinen am Ziel)",
        cap.max_output or 0, cap.at_target or 0, cap.total_turbines or 0)
    elseif cap.reason == "MEASURED" then
      msg = string.format("v2 Einlernen FERTIG: %.0f RF/t aus %d Turbinen gemessen",
        cap.max_output or 0, cap.sustainable_turbines or 0)
      if (cap.sustainable_turbines or 0) < (cap.total_turbines or 0) then
        msg = msg .. string.format(" -- %d der %d Turbinen waren dabei nie gleichzeitig am Ziel",
          (cap.total_turbines or 0) - (cap.sustainable_turbines or 0), cap.total_turbines or 0)
      end
    elseif cap.reason == "FLOW_SATURATED" then
      msg = string.format(
        "v2 Einlernen: %d Turbine(n) fahren VOLLEN Flow (%d) und erreichen trotzdem keine %d RPM"
        .. " -- im Zielbereich %d von %d, noetig %d.",
        cap.saturated or 0, rt2_turbine.MAX_FLOW, rt2_capacity.TARGET_RPM,
        cap.at_target or 0, cap.total_turbines or 0, cap.required_at_target or 0)
    elseif cap.reason == "BELOW_FRACTION" and waiting then
      msg = string.format(
        "v2 Einlernen wartet: %d von %d Turbinen im Zielbereich (%d RPM +/- %d), noetig sind %d",
        cap.at_target or 0, cap.total_turbines or 0, rt2_capacity.TARGET_RPM,
        rt2_capacity.TOLERANCE_RPM, cap.required_at_target or 0)
    elseif cap.reason == "TOPOLOGY_CHANGED" then
      msg = string.format("v2 Turbinenzahl geaendert (%d) -- Anlage wird neu vermessen", cap.total_turbines or 0)
    elseif cap.reason == "NO_TURBINES" then
      msg = waiting and "v2 noch keine Turbine gefunden -- warte auf Discovery"
        or "v2 keine Turbine lesbar -- gelernter Wert bleibt erhalten"
    end
    -- Den Schluessel nur fortschreiben, wenn auch gemeldet wurde.
    if msg and diag ~= last_logged_capacity_diag then
      last_logged_capacity_diag = diag
      ctx.log("INFO", msg)
      pcall(print, "[RT] " .. msg)
    end
  end

  if cap.ready and cap.max_output ~= last_saved_max_output then
    if rt2_capacity.save(cap, { path = cache_path, write_config = write_config }) then
      last_saved_max_output = cap.max_output
      ctx.log("INFO", string.format("v2 Kapazitaet gesichert: max_output=%.0f", cap.max_output))
    end
  end

  -- Anlagenprofile: je Reaktor, einmalig geschrieben.
  local profiles, tuning_changed = {}, false
  for index, unit in ipairs(engine.reactors) do
    local key = unit.name or ("reactor" .. index)
    if unit.tuning_profile then
      profiles[key] = unit.tuning_profile
      local st = reactor_state[key]
      if st and not st.tuning_saved then
        st.tuning_saved = true
        tuning_changed = true
        local msg = string.format(
          "v2 Reaktor %s selbst vermessen: %d Messwerte -> max_step=%d, Stellintervall=%dms",
          key, unit.tuning_profile.samples or 0, unit.tuning_profile.max_step,
          unit.tuning_profile.min_adjust_interval_ms)
        ctx.log("INFO", msg)
        pcall(print, "[RT] " .. msg)
      end
    end
  end
  if tuning_changed then
    rt2_tuning.save_units(profiles, { path = tuning_path, write_config = write_config })
  end

  -- Turbinenkennlinien: je Turbine einmalig, sobald sie entstanden ist.
  -- result.new_turbine_models enthaelt nur die in DIESEM Takt neuen, also
  -- wird nur dann geschrieben und nur dann gemeldet.
  if #(result.new_turbine_models or {}) > 0 then
    for _, entry in ipairs(result.new_turbine_models) do
      local msg = string.format(
        "v2 Turbine %s selbst vermessen: %d Betriebspunkte -> %.2f RPM je mB/t"
          .. " (%.0f mB/t fuer 900 RPM), Stellintervall=%dms",
        tostring(entry.name), entry.profile.samples or 0, entry.profile.slope,
        rt2_turbine_model.flow_for(entry.profile, 900) or -1,
        entry.profile.min_adjust_interval_ms)
      ctx.log("INFO", msg)
      pcall(print, "[RT] " .. msg)
    end
    rt2_turbine_model.save_units(result.turbine_models,
      { path = turbine_model_path, write_config = write_config })
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
  local models = last_result.turbine_models or {}
  local modelled = 0
  for _, t in ipairs(last_result.turbines) do
    local model = t.name and models[t.name] or nil
    if model then modelled = modelled + 1 end
    turbines[#turbines + 1] = {
      id = t.name,
      target_rpm = t.target_rpm,
      flow = t.flow_decision and t.flow_decision.flow or nil,
      coil_engaged = t.coil_decision and t.coil_decision.engaged or nil,
      -- Warum dieser Durchfluss -- ohne den Grund laesst sich am Schirm
      -- nicht unterscheiden, ob eine Turbine ruhig steht (SETTLED)
      -- oder nur gerade wartet (SETTLING).
      flow_reason = t.flow_decision and t.flow_decision.reason or nil,
      model_slope = model and model.slope or nil,
    }
  end
  return {
    mode = last_result.state,
    -- What payload.state should report -- node_state_machine itself stays
    -- untouched under v2 (see rt2_projection.lua's header on why).
    node_state = last_projection and last_projection.node_state
      or rt2_projection.node_state(last_result.state),
    capacity_ready = last_result.capacity.ready,
    -- Der Zweck des ganzen Einlernens: wieviel RF/t dieser Knoten
    -- tatsaechlich liefern kann. MASTER teilt seinen Bedarf gegen genau
    -- diese Zahl auf (rt_sync.node_capacity -> uniform_pct), also muss sie
    -- gemessen und nicht hochgerechnet sein -- siehe rt2_capacity.
    capacity_max = last_result.capacity.max_output,
    capacity_total_turbines = last_result.capacity.total_turbines,
    -- MASTER liest diese beiden Namen (message_handlers.lua) und baut
    -- daraus seine Lernanzeige. v2 schickte stattdessen capacity_at_target
    -- und capacity_reason -- also Felder, die MASTER gar nicht kennt. Auf
    -- dem MASTER-Schirm stand deshalb waehrend des gesamten Einlernens
    -- "LEARNING 0/25 Turbinen stabil", egal wie weit der Knoten war.
    capacity_stable_turbines = last_result.capacity.at_target,
    capacity_source = last_result.capacity.reason,
    -- Neu: wieviele Turbinen diese Anlage nachweislich traegt. Damit kann
    -- MASTER den Fortschritt des Suchlaufs zeigen und erkennen, dass ein
    -- Knoten seine Flotte bewusst nur teilweise fahren kann.
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
    power_target = (last_result.capacity.ready and last_result.capacity.max_output or 0)
      * ((tonumber(last_result.master_percent) or 0) / 100),
    turbines = turbines,
    -- Wieviele Turbinen sich schon selbst vermessen haben. Solange das
    -- unter der Flottengroesse liegt, tasten sich die uebrigen noch heran.
    turbines_modelled = modelled,
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
