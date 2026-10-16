-- core/alert_rules.lua -- welche Zustaende der Anlage MASTER meldet.
--
-- Neu geschrieben (v833, Betreiber 2026-10-16: "an die Meldungen,
-- Warnungen, Stoerungen muss was dran ... die kommen so schnell wieder,
-- dass es nichts bringt"). Bis v832 kamen viele Meldungen aus ganz
-- normalem Regelbetrieb:
--   - TURBINE_RPM_LOW / COIL_EARLY: der RT-Regler stellt bei Teillast
--     Turbinen ab, bremst sie mit der Spule bis zum Stillstand und wechselt
--     alle 5 Minuten, welche steht. Jeder Wechsel gab Warnungen.
--   - MATRIX_NEAR_FULL ab 90 %: ein voller Speicher ist das Ziel (die
--     IDLE-Schwelle liegt standardmaessig ebenfalls bei 90 %).
--   - ENERGY_LOW bei 25 % ohne Abstand zwischen Kommen und Gehen.
--   - NODE_COMMS_DOWN auch dann, wenn die NODE meldete, sie hoere MASTER
--     nicht -- obwohl MASTER ihre Meldung gerade bekam. Nach 12 s wurde
--     daraus eine Stoerung.
--   - REACTOR_RODS_STUCK konnte unter dem neuen Regler nie ausloesen
--     (Dampf-Sollwert immer 0).
-- Alle gestrichen. Probleme einer RT-Node (zu wenig Leistung, Drehzahl
-- nicht lesbar, Ueberdrehzahl) entscheidet die Node selbst
-- (nodes/rt/rt2_problems.lua) und MASTER zeigt sie als RT_PROBLEM.
--
-- Jede Regel hat eine feste Klasse -- keine Hochstufung mehr:
--   CRITICAL = Stoerung (rot, Hupe), WARN = Warnung (orange),
--   INFO = Meldung (grau).
--
-- Schnittstelle unveraendert: rules.new(config), rules:evaluate(context)
-- -> alerts (zu meldende Eintraege), clears (Schluessel, die gehen).

local constants = require("shared.constants")
local health = require("core.health")

local rules = {}

local function now_ms()
  return os.epoch("utc")
end

local function has_reason(reasons, code)
  if type(reasons) ~= "table" then return false end
  if reasons[code] then return true end
  for _, entry in ipairs(reasons) do
    if entry == code then return true end
  end
  return false
end

local function number_or(value, fallback)
  if type(value) == "number" then return value end
  local parsed = tonumber(value)
  if parsed ~= nil then return parsed end
  return fallback
end

local function build_source(node, device_id)
  return { node_id = node.id, role = node.role, device_id = device_id }
end

-- Kritische Rollen: ohne sie laeuft die Anlage nicht weiter (wie
-- optional/master_ampel.lua). Faellt eine davon aus, ist das eine
-- Stoerung; jede andere Node ist eine Warnung.
local CRITICAL_ROLES = {
  [constants.roles.RT_NODE] = true,
  [constants.roles.ENERGY_NODE] = true,
  [constants.roles.FUEL_NODE] = true,
}

-- Gruende, aus denen eine Node "eingeschraenkt" ist, mit Klartext. Nicht
-- dabei: COMMS_DOWN (die Node hoert MASTER nicht -- MASTER hoert sie aber,
-- sonst kaeme diese Meldung nicht an; der echte Ausfall ist
-- NODE_COMMS_DOWN), PROTO_MISMATCH (eigene Regel), NO_MATRIX bei ENERGY
-- (MATRIX_MISSING), TIMER_LOST (die Node laeuft weiter; steht auf ihrer
-- eigenen Diagnoseseite).
local DEGRADE_REASONS = {
  { code = health.reasons.DISCOVERY_FAILED, text = "Geraeteerkennung fehlgeschlagen" },
  { code = health.reasons.CONTROL_DEGRADED, text = "Regelung eingeschraenkt" },
  { code = health.reasons.NO_STORAGE, text = "kein Speicher (ME-Bridge)" },
  { code = health.reasons.STALE_DATA, text = "Daten veraltet" },
  { code = health.reasons.NO_MATRIX, text = "keine Matrix", skip_role = constants.roles.ENERGY_NODE },
}

local function degrade_text(node)
  local reasons = node.health and node.health.reasons
  local parts = {}
  for _, entry in ipairs(DEGRADE_REASONS) do
    if node.role ~= entry.skip_role and has_reason(reasons, entry.code) then
      parts[#parts + 1] = entry.text
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

local function rule_state(self, key)
  local state = self.state[key]
  if not state then
    state = { active = false, since = nil, clear_since = nil, last_emit = 0 }
    self.state[key] = state
  end
  return state
end

-- Entprellung: kommt erst, wenn die Bedingung raise_after_s lang ansteht,
-- geht erst, wenn sie clear_after_s lang weg ist. Solange sie ansteht, wird
-- der Eintrag alle cooldown_s aufgefrischt (Text, z. B. "seit 45 s").
local function should_raise(state, active, now, opts)
  local raise_ms = (opts.raise_after_s or 0) * 1000
  local clear_ms = (opts.clear_after_s or 0) * 1000
  local cooldown_ms = (opts.cooldown_s or 0) * 1000
  if active then
    state.clear_since = nil
    if not state.active then
      state.since = state.since or now
      if now - state.since >= raise_ms then
        state.active = true
        state.last_emit = now
        return "raise"
      end
    elseif now - (state.last_emit or 0) >= cooldown_ms then
      state.last_emit = now
      return "raise"
    end
  else
    state.since = nil
    if state.active then
      state.clear_since = state.clear_since or now
      if now - state.clear_since >= clear_ms then
        state.active = false
        state.clear_since = nil
        return "clear"
      end
    end
  end
  return nil
end

function rules.new(config)
  local self = { config = config or {}, state = {} }
  return setmetatable(self, { __index = rules })
end

-- Alles, was zu einer Node gehoert, vergessen (master "Node vergessen").
function rules:forget_node(node_id)
  local marker = "|" .. tostring(node_id)
  for key in pairs(self.state) do
    local tail = key:sub(-#marker)
    if tail == marker or key:find(marker .. "|", 1, true) then self.state[key] = nil end
  end
end

function rules:evaluate(context)
  context = context or {}
  local now = context.now or now_ms()
  local cfg = context.config or self.config or {}
  local nodes = context.nodes or {}
  local alerts = {}
  local clears = {}

  local base = {
    raise_after_s = cfg.alert_raise_after_s or cfg.alert_debounce_s or 2,
    clear_after_s = cfg.alert_clear_after_s or cfg.alert_clear_s or 3,
    cooldown_s = cfg.alert_cooldown_s or 6,
  }
  local function opts(raise_after_s, clear_after_s, cooldown_s)
    return {
      raise_after_s = raise_after_s or base.raise_after_s,
      clear_after_s = clear_after_s or base.clear_after_s,
      cooldown_s = cooldown_s or base.cooldown_s,
    }
  end

  local function emit(key, active, emit_opts, builder)
    local state = rule_state(self, key)
    local action = should_raise(state, active, now, emit_opts or base)
    if action == "raise" then
      local entry = builder(state)
      if entry then
        entry.key = key
        alerts[#alerts + 1] = entry
      end
    elseif action == "clear" then
      clears[#clears + 1] = key
    end
  end

  local stored, capacity = 0, 0
  local active_rt, total_capacity = {}, 0
  -- Reaktornamen sind nur innerhalb EINES RT-Installers eindeutig; MASTER
  -- sieht alle Reaktorlisten und kann Doppelte ueber Nodes hinweg finden.
  local alias_seen = {}

  for _, node in pairs(nodes) do
    local reasons = node.health and node.health.reasons
    local offline = node.offline == true

    -- Node offline: nur MASTERs eigene Sicht (master/runtime_ops_rt.lua
    -- check_timeouts() setzt node.offline nach dem Funk-Timeout). Klasse
    -- fest nach Rolle.
    local critical_role = CRITICAL_ROLES[node.role] == true
    emit(string.format("NODE_COMMS_DOWN|%s", tostring(node.id)), offline, opts(), function(state)
      local since = tonumber(node.down_since) or state.since
      local down_for = since and math.max(0, math.floor((now - since) / 1000)) or nil
      return {
        code = "NODE_COMMS_DOWN",
        severity = critical_role and "CRITICAL" or "WARN",
        scope = "NODE",
        source = build_source(node),
        title = "Node offline",
        message = down_for and string.format("%s antwortet nicht (seit %d s)", tostring(node.id), down_for)
          or string.format("%s antwortet nicht", tostring(node.id)),
        details = { down_for_s = down_for },
      }
    end)

    local reachable = not offline and node.stale ~= true and node.recovering ~= true

    local degraded = reachable and degrade_text(node) or nil
    emit(string.format("NODE_DEGRADED|%s", tostring(node.id)), degraded ~= nil, opts(10, 10), function()
      local text = degrade_text(node) or "?"
      return {
        code = "NODE_DEGRADED",
        severity = "WARN",
        scope = "NODE",
        source = build_source(node),
        title = "Node eingeschraenkt",
        message = string.format("%s: %s", tostring(node.id), text),
        details = { reasons = text },
      }
    end)

    emit(string.format("PROTO_MISMATCH|%s", tostring(node.id)), has_reason(reasons, health.reasons.PROTO_MISMATCH),
      opts(), function()
        local version = node.proto_ver or "?"
        return {
          code = "PROTO_MISMATCH",
          severity = node.role == constants.roles.RT_NODE and "CRITICAL" or "WARN",
          scope = "NODE",
          source = build_source(node),
          title = "Protokoll passt nicht",
          message = string.format("%s spricht Protokoll %s", tostring(node.id), tostring(version)),
          details = { proto = version },
        }
      end)

    if node.role == constants.roles.ENERGY_NODE then
      stored = stored + number_or(node.stored, 0)
      capacity = capacity + number_or(node.capacity, 0)
      local energy_down = offline or has_reason(reasons, health.reasons.COMMS_DOWN)
        or node.status == constants.status_levels.OFFLINE
      local matrix_missing = (not energy_down) and reachable and node.managed ~= false
        and has_reason(reasons, health.reasons.NO_MATRIX)
      emit(string.format("MATRIX_MISSING|%s", tostring(node.id)), matrix_missing, opts(), function()
        -- Die Zaehler stehen im Energy-Payload (node.energy), nicht oben in
        -- der Node-Tabelle (master/message_handlers.lua).
        local e = (type(node.energy) == "table" and node.energy) or node
        local matrix_count = e.matrix_count or node.matrix_count or node.matrix_bound or 0
        local storage_count = e.storage_bound_count or node.storage_bound_count or 0
        local nothing = storage_count == 0 and matrix_count == 0
        return {
          code = "MATRIX_MISSING",
          severity = nothing and "CRITICAL" or "WARN",
          scope = "NODE",
          source = build_source(node),
          title = "Keine Matrix angebunden",
          message = string.format("%s findet keine Energiematrix", tostring(node.id)),
          details = { matrix_count = matrix_count, storage_count = storage_count },
        }
      end)
    end

    if node.role == constants.roles.RT_NODE then
      if tostring(node.assignment_state or "") == "active" then active_rt[#active_rt + 1] = node end
      total_capacity = total_capacity + number_or(node.capacity_max, 0)

      local node_state = tostring(node.state or "")
      emit(string.format("RT_SAFE_MODE|%s", tostring(node.id)), node_state == "SAFE" or node_state == "EMERGENCY",
        opts(), function()
          return {
            code = "RT_SAFE_MODE",
            severity = "CRITICAL",
            scope = "NODE",
            source = build_source(node),
            title = "RT im Schutzzustand",
            message = string.format("%s steht auf %s", tostring(node.id), node_state),
            details = { state = node_state },
          }
        end)

      -- Was die RT-Node selbst als Problem meldet (rt2_problems.lua), schon
      -- dort entprellt. Einzelheiten stehen in details.lines und auf dem
      -- RT-Monitor.
      local problems = type(node.rt) == "table" and type(node.rt.problems) == "table" and node.rt.problems or {}
      emit(string.format("RT_PROBLEM|%s", tostring(node.id)), reachable and #problems > 0, opts(0), function()
        local lines = {}
        for _, line in ipairs(problems) do lines[#lines + 1] = tostring(line) end
        local more = #lines > 1 and string.format(" (+%d)", #lines - 1) or ""
        return {
          code = "RT_PROBLEM",
          severity = "WARN",
          scope = "NODE",
          source = build_source(node),
          title = "RT meldet ein Problem",
          message = string.format("%s: %s%s -- Details am RT-Monitor", tostring(node.id), tostring(lines[1] or "?"), more),
          details = { lines = lines },
        }
      end)

      for _, reactor in ipairs(node.reactors or {}) do
        if type(reactor.alias) == "string" and reactor.alias ~= "" then
          local alias_key = reactor.alias:lower()
          local global_id = tostring(node.id) .. ":" .. tostring(reactor.id or reactor.name)
          local occurrences = alias_seen[alias_key]
          if not occurrences then occurrences = {}; alias_seen[alias_key] = occurrences end
          local listed = false
          for _, occ in ipairs(occurrences) do
            if occ.global_id == global_id then listed = true break end
          end
          if not listed then occurrences[#occurrences + 1] = { global_id = global_id, alias = reactor.alias } end
        end
      end
    end
  end

  -- Fuer jeden in DIESEM Durchlauf gesehenen Namen, damit ein umbenannter
  -- Reaktor die Meldung wieder gehen laesst.
  for alias_key, occurrences in pairs(alias_seen) do
    emit("REACTOR_NAME_DUPLICATE|" .. alias_key, #occurrences > 1, opts(), function()
      local ids = {}
      for _, occ in ipairs(occurrences) do ids[#ids + 1] = occ.global_id end
      table.sort(ids)
      return {
        code = "REACTOR_NAME_DUPLICATE",
        severity = "WARN",
        scope = "SYSTEM",
        source = { node_id = "MASTER", role = "MASTER" },
        title = "Reaktorname doppelt",
        message = string.format("Name '%s' ist mehrfach vergeben: %s", occurrences[1].alias, table.concat(ids, ", ")),
        details = { alias = occurrences[1].alias, reactors = ids },
      }
    end)
  end

  -- Energie niedrig, mit Abstand zwischen Kommen und Gehen: kommt bei
  -- alarm_energy_low_pct, geht erst wieder ab alarm_energy_low_clear_pct.
  if capacity > 0 then
    local pct = (stored / capacity) * 100
    local low = number_or(cfg.alarm_energy_low_pct, 10)
    local clear = math.max(low, number_or(cfg.alarm_energy_low_clear_pct, 15))
    local state = rule_state(self, "ENERGY_LOW")
    local low_active = pct <= low or (state.active and pct < clear)
    emit("ENERGY_LOW", low_active, opts(), function()
      return {
        code = "ENERGY_LOW",
        severity = "WARN",
        scope = "SYSTEM",
        source = { node_id = "MASTER", role = "MASTER" },
        title = "Energie niedrig",
        message = string.format("Speicher %.1f %% (Warnung ab %.0f %%, weg ab %.0f %%)", pct, low, clear),
        details = { percent = pct, low = low, clear = clear },
      }
    end)
  end

  -- Nur noch ein RT-Node liefert, und ohne ihn reichte der Rest nicht fuer
  -- den Bedarf. Lange Entprellung: MASTER verschiebt Zuweisungen selbst.
  do
    local sole = (#active_rt == 1) and active_rt[1] or nil
    local target = tonumber(context.power_target) or 0
    local redundancy_active = sole ~= nil and target > 0
      and (total_capacity - number_or(sole.capacity_max, 0)) < target
    emit("RT_NO_REDUNDANCY", redundancy_active, opts(60, 30, 60), function()
      return {
        code = "RT_NO_REDUNDANCY",
        severity = "WARN",
        scope = "SYSTEM",
        source = sole and build_source(sole) or { node_id = "MASTER", role = "MASTER" },
        title = "Keine RT-Reserve",
        message = string.format("Nur %s liefert -- faellt sie aus, reicht der Rest nicht",
          sole and tostring(sole.id) or "eine RT-Node"),
        details = { total_capacity = total_capacity, power_target = context.power_target },
      }
    end)
  end

  if context.recovery_notice then
    local recovery = context.recovery_notice
    emit("UPDATE_RECOVERY", recovery.active, opts(), function()
      return {
        code = "UPDATE_RECOVERY",
        severity = "INFO",
        scope = "SYSTEM",
        source = { node_id = "MASTER", role = "MASTER" },
        title = "Update-Rueckfall",
        message = recovery.message or "Update-Rueckfall ausgefuehrt",
        details = recovery.details,
      }
    end)
  end

  return alerts, clears
end

return rules
