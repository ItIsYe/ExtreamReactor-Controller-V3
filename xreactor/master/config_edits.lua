-- master/config_edits.lua
--
-- Feature (2026-07-17): MASTER-P1 (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md Abschnitt 10 "Config-Editor behauptet
-- Uebernahme vor ACK_APPLIED"). Vorher aenderte der Config-Editor den
-- lokal ANGEZEIGTEN Wert sofort, sendete das Command IMMER an ALLE Nodes
-- einer Rolle (keine Einzelziel-Auswahl), forderte kein require_applied
-- an, und verknuepfte eingehende ACK_APPLIED-Ergebnisse nicht mit dem
-- konkret ausgeloesten Edit. Ein abgelehntes oder ausbleibendes Ergebnis
-- war fuer den Bediener am Monitor nicht von einem echten Erfolg zu
-- unterscheiden.
--
-- Dieses Modul ist die einzige Autoritaet fuer:
--   - Zielauswahl je Einstellung (ALLE oder eine konkrete Node-ID),
--   - Senden mit require_applied=true und Festhalten der ausgehenden
--     message_id je Ziel,
--   - Status je Ziel: QUEUED -> DELIVERED -> APPLIED / REJECTED / TIMEOUT,
--   - der angezeigte "bestaetigte" Wert wird ERST uebernommen, wenn ALLE
--     angeschriebenen Ziele APPLIED gemeldet haben -- vorher bleibt der
--     alte bestaetigte Wert sichtbar, der laufende Edit erscheint separat
--     als "pending" mit Fortschritt/Fehlerzustand.
--
-- Bewusst ein reines Datenmodul ohne eigenen Zustand (kein M.new()) --
-- der Aufrufer (master/runtime_loop.lua) haelt den State in
-- runtime.state.config_edits[setting_key] und reicht ihn hier durch.
-- Das haelt das Modul leicht test- und wiederverwendbar (message_handlers.
-- lua/housekeeping.lua brauchen fuer ACK-/Timeout-Verarbeitung nur diese
-- eine Tabelle, nicht den kompletten runtime-Kontext).

local M = {}

-- Welche Rolle/welcher Commandtarget zu welchem Einstellungsschluessel
-- gehoert. role_key wird gegen constants.roles nachgeschlagen (das Modul
-- haelt selbst keine Abhaengigkeit zu core/comms.lua o.ae.).
M.SETTINGS = {
  fuel_reserve = { role_key = "FUEL_NODE", command_target = "SET_RESERVE" },
  water_target = { role_key = "WATER_NODE", command_target = "SET_TARGET" },
  reactor_fill_target = { role_key = "RT_NODE", command_target = "SET_REACTOR_FILL_TARGET" },
}

local function ensure_setting_state(edits_state, key)
  edits_state[key] = edits_state[key] or { target = "ALL" }
  return edits_state[key]
end

-- Sortierte Liste aller bekannten Node-IDs mit der angegebenen Rolle.
function M.available_targets(nodes, role)
  local out = {}
  for id, node in pairs(nodes or {}) do
    if type(node) == "table" and node.role == role then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

-- Schaltet die Zielauswahl fuer eine Einstellung weiter: ALLE -> Node1 ->
-- Node2 -> ... -> ALLE. Persistierung ist Aufgabe des Aufrufers (siehe
-- runtime_loop.lua), dieses Modul kennt keine Config-Dateien.
function M.cycle_target(edits_state, key, nodes, constants)
  local def = M.SETTINGS[key]
  if not def then return nil end
  local role = constants.roles[def.role_key]
  local st = ensure_setting_state(edits_state, key)
  local options = { "ALL" }
  for _, id in ipairs(M.available_targets(nodes, role)) do options[#options + 1] = id end
  local cur_idx = 1
  for i, opt in ipairs(options) do
    if opt == st.target then cur_idx = i; break end
  end
  local next_idx = (cur_idx % #options) + 1
  st.target = options[next_idx]
  return st.target
end

-- Sendet einen neuen Wert an die aktuell ausgewaehlten Ziele (ALLE Nodes
-- der Rolle, oder genau der ausgewaehlte Node, falls er noch existiert und
-- weiterhin zur erwarteten Rolle gehoert -- sonst Fallback auf ALLE mit
-- Warnung, damit ein verschwundener/umbenannter Node keinen "toten"
-- Editor hinterlaesst). opts = { nodes=, comms=, constants=, log= }.
function M.send_edit(edits_state, key, value, opts)
  local def = M.SETTINGS[key]
  if not def then return false, "unbekannte Einstellung: " .. tostring(key) end
  local role = opts.constants.roles[def.role_key]
  local st = ensure_setting_state(edits_state, key)

  local target_ids
  if st.target == "ALL" then
    target_ids = M.available_targets(opts.nodes, role)
  elseif opts.nodes[st.target] and opts.nodes[st.target].role == role then
    target_ids = { st.target }
  else
    target_ids = M.available_targets(opts.nodes, role)
    if opts.log then
      opts.log(("Config-Edit-Ziel %s (%s) nicht mehr verfuegbar -- sende an ALLE"):format(tostring(st.target), key), "WARN")
    end
  end

  if #target_ids == 0 then
    return false, ("kein Node mit Rolle %s gefunden"):format(tostring(role))
  end

  local pending = { value = value, started_ts = (os.epoch and os.epoch("utc")) or 0, targets = {} }
  local sent = 0
  for _, id in ipairs(target_ids) do
    local entry = opts.comms:send_command(id, { target = def.command_target, value = value }, { require_applied = true })
    local message_id = entry and entry.message and entry.message.message_id
    if message_id then
      pending.targets[id] = { status = "QUEUED", message_id = message_id }
      sent = sent + 1
    else
      pending.targets[id] = { status = "SEND_FAILED" }
    end
  end
  if sent == 0 then return false, "Senden an alle Ziele fehlgeschlagen" end
  st.pending = pending
  return true, sent
end

-- Findet den Ziel-Eintrag, dessen ausgehende message_id zu einer
-- eingehenden ACK/einem Timeout passt (message_id == ack_for). Linear
-- ueber die wenigen bekannten Einstellungen/Ziele -- kein Hot-Path.
local function find_pending(edits_state, message_id)
  if not message_id then return nil end
  for key, st in pairs(edits_state) do
    if st.pending then
      for node_id, t in pairs(st.pending.targets) do
        if t.message_id == message_id then return key, st, node_id, t end
      end
    end
  end
  return nil
end

local function all_terminal(pending)
  for _, t in pairs(pending.targets) do
    if t.status == "QUEUED" or t.status == "DELIVERED" then return false end
  end
  return true
end

local function all_applied(pending)
  for _, t in pairs(pending.targets) do
    if t.status ~= "APPLIED" then return false end
  end
  return true
end

-- Uebernimmt den bestaetigten Wert erst, wenn ALLE angeschriebenen Ziele
-- APPLIED gemeldet haben -- bei jedem anderen Endzustand (REJECTED/
-- TIMEOUT/SEND_FAILED bei mindestens einem Ziel) bleibt der alte
-- bestaetigte Wert unveraendert sichtbar, der Edit bleibt als "resolved,
-- aber nicht vollstaendig uebernommen" pending stehen, bis der Bediener
-- einen neuen Edit ausloest.
local function resolve_if_terminal(st)
  if not st.pending or not all_terminal(st.pending) then return end
  if all_applied(st.pending) then
    st.confirmed_value = st.pending.value
    st.pending = nil
  else
    st.pending.resolved = true
  end
end

function M.handle_ack_delivered(edits_state, message)
  local _, _, _, t = find_pending(edits_state, message and message.ack_for)
  if not t then return false end
  if t.status == "QUEUED" then t.status = "DELIVERED" end
  return true
end

function M.handle_ack_applied(edits_state, message)
  local _, st, _, t = find_pending(edits_state, message and message.ack_for)
  if not t then return false end
  local result = message.payload and message.payload.result or {}
  if result.ok == false then
    t.status = "REJECTED"
    t.error = result.error or result.reason_code
  else
    t.status = "APPLIED"
  end
  resolve_if_terminal(st)
  return true
end

function M.handle_timeout(edits_state, message_id)
  local _, st, _, t = find_pending(edits_state, message_id)
  if not t then return false end
  t.status = "TIMEOUT"
  resolve_if_terminal(st)
  return true
end

-- Modell fuer die UI: bestaetigter Wert (oder fallback, falls noch nie
-- editiert), aktuelle Zielauswahl, und -- falls ein Edit gerade laeuft
-- oder gerade (teilweise) fehlgeschlagen abgeschlossen ist -- eine
-- kompakte Fortschritts-/Fehlerzusammenfassung.
function M.model_for(edits_state, key, fallback_value)
  local st = edits_state[key]
  if not st then
    return { target = "ALL", confirmed_value = fallback_value, pending = nil }
  end
  local pending_summary = nil
  if st.pending then
    local applied, total, failed_ids = 0, 0, {}
    for id, t in pairs(st.pending.targets) do
      total = total + 1
      if t.status == "APPLIED" then
        applied = applied + 1
      elseif t.status == "REJECTED" or t.status == "TIMEOUT" or t.status == "SEND_FAILED" then
        failed_ids[#failed_ids + 1] = id
      end
    end
    pending_summary = {
      value = st.pending.value, applied = applied, total = total,
      failed = failed_ids, resolved = st.pending.resolved == true,
    }
  end
  return {
    target = st.target or "ALL",
    confirmed_value = st.confirmed_value ~= nil and st.confirmed_value or fallback_value,
    pending = pending_summary,
  }
end

return M
