-- nodes/fuel/route_identity.lua
--
-- FUEL-Routen auf die GLOBALE Reaktor-Kennung umstellen.
--
-- Eine Route (/xreactor_config/fuel_routes.lua, reactors[*].reactor_id)
-- sagt, wessen Fuellstand ueber eine Lieferung entscheidet. Die kurze
-- Kennung eines Reaktors (core/registry.lua: "REACTOR-<hash>" aus
-- Peripheriename, Typ und Methoden) ist nur INNERHALB eines RT-Rechners
-- eindeutig -- CC:Tweaked nummeriert die Peripherie je Rechner, gleich
-- gebaute Reaktoren auf zwei RT-Knoten haben dieselbe kurze Kennung. Auf
-- der Anlage des Betreibers: 16 Reaktoren, 2 kurze Kennungen.
--
-- Eindeutig ist die globale Kennung "<node_id>:<kurze Kennung>"
-- (core/reactor_identity.lua). MASTER (master/fuel_relay.lua) und das
-- Mithoeren (fuel_status_network.lua) fuehren den Fuellstand unter ihr; die
-- kurze Kennung bleibt dort nur als Alias, solange genau EIN RT-Knoten sie
-- benutzt, und verschwindet bei einer Kollision. Eine Route mit kurzer
-- Kennung bekommt dann keinen Fuellstand mehr, der Reaktor wird nie
-- beliefert. Neu eingelernte Routen tragen die globale Kennung schon
-- (reactor_targets.lua); aeltere nicht.
--
-- Dieses Modul stellt solche Routen um -- vorsichtig:
--
--   * nur, wenn der Name der Route (label) unter den Reaktoren mit dieser
--     kurzen Kennung genau EINEN trifft. Die Kennung allein reicht nicht:
--     ist sie gerade eindeutig, kann das daran liegen, dass der andere
--     RT-Knoten nur kurz nicht sendet. Die Namen kommen aus
--     reactor_names.lua und sind anlagenweit eindeutig (doppelte meldet
--     MASTER als Alarm).
--   * nie, wenn derselbe Reaktor schon unter seiner globalen Kennung eine
--     Route hat -- dann ist die alte ueberzaehlig, der Betreiber loescht sie.
--   * alles andere bleibt, wie es ist, und wird gemeldet: "neu einlernen".
--
-- Entschieden wird rein aus den Daten (plan); geschrieben wird ueber die
-- Funktionen, die der Aufrufer mitgibt (apply) -- in nodes/fuel/main.lua
-- derselbe atomare Schreibweg wie beim SPEICHERN im Router.

local M = {}

local function nonempty(value)
  if value == nil then return nil end
  local text = tostring(value)
  if text == "" then return nil end
  return text
end

local function name_key(value)
  local text = nonempty(value)
  if not text then return nil end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  return text:lower()
end

-- Alle Reaktoren, die das Netz gerade kennt, je globale Kennung einmal
-- (die kurzen Aliase in denselben Tabellen zeigen auf dieselben Eintraege).
function M.known_reactors(cache)
  local out = {}
  for _, bucket_name in ipairs({ "master_relay", "direct_heard" }) do
    local bucket = type(cache) == "table" and cache[bucket_name] or nil
    if type(bucket) == "table" then
      for _, entry in pairs(bucket) do
        local global_id = type(entry) == "table" and nonempty(entry.global_reactor_id) or nil
        if global_id and nonempty(entry.local_reactor_id) and not out[global_id] then
          out[global_id] = entry
        end
      end
    end
  end
  return out
end

-- Was ist mit einer einzelnen Route zu tun?
--
--   "global"          traegt schon eine globale Kennung, die das Netz kennt
--   "upgrade"         kurze Kennung, Name trifft genau einen Reaktor -> to
--   "duplicate"       der getroffene Reaktor hat schon eine eigene Route
--   "ambiguous"       mehrere Reaktoren mit dieser kurzen Kennung und Name
--   "label_mismatch"  Reaktoren mit dieser kurzen Kennung, keiner heisst so
--   "no_label"        kurze Kennung, aber die Route hat keinen Namen
--   "unknown"         das Netz kennt die Kennung (gerade) nicht -- RT aus,
--                     Funk weg oder schon global fuer einen stillen Knoten
--   "missing"         die Route hat gar keine Kennung
-- reactor_port ist der alte Name von reactor_id (config_normalizer.lua).
local function route_id(route)
  if type(route) ~= "table" then return nil end
  return nonempty(route.reactor_id) or nonempty(route.reactor_port)
end

function M.classify(route, known, taken)
  local id = route_id(route)
  if not id then return "missing" end
  if known[id] then return "global" end

  local candidates = {}
  for global_id, entry in pairs(known) do
    if tostring(entry.local_reactor_id) == id then
      candidates[#candidates + 1] = { global_id = global_id, entry = entry }
    end
  end
  if #candidates == 0 then return "unknown" end

  local label = name_key(route.label)
  if not label or label == name_key(id) then return "no_label" end

  local matches = {}
  for _, c in ipairs(candidates) do
    if name_key(c.entry.label) == label then matches[#matches + 1] = c end
  end
  if #matches == 0 then return "label_mismatch" end
  if #matches > 1 then return "ambiguous" end

  local target = matches[1].global_id
  if taken and taken[target] then return "duplicate", target end
  return "upgrade", target
end

-- Plan fuer eine ganze Routenliste.
--   changes  = { { index, from, to, label } }  -- umzustellen
--   problems = { { index, id, label, status, target } }  -- melden
function M.plan(reactors, cache)
  local known = M.known_reactors(cache)
  local taken = {}
  for _, route in ipairs(reactors or {}) do
    local id = route_id(route)
    if id and known[id] then taken[id] = true end
  end

  local result = { changes = {}, problems = {} }
  for index, route in ipairs(reactors or {}) do
    local status, target = M.classify(route, known, taken)
    if status == "upgrade" then
      taken[target] = true
      result.changes[#result.changes + 1] = {
        index = index, from = route_id(route), to = target,
        label = route.label,
      }
    elseif status ~= "global" and status ~= "unknown" and status ~= "missing" then
      -- "missing" meldet schon config_normalizer.lua (Eintrag stillgelegt).
      result.problems[#result.problems + 1] = {
        index = index, id = route_id(route),
        label = type(route) == "table" and route.label or nil,
        status = status, target = target,
      }
    end
  end
  return result
end

local function signature(changes)
  local parts = {}
  for _, c in ipairs(changes) do parts[#parts + 1] = c.from .. ">" .. c.to end
  return table.concat(parts, ";")
end

local RETRY_AFTER_FAILURE_MS = 10 * 60 * 1000

-- Plan ausfuehren.
--
--   lg     config.logistics (reactors, export_chest) -- die Laufzeitquelle
--   cache  fuel_status_network-Cache
--   deps   busy()          -> true: jetzt nicht (Router wird bearbeitet,
--                             Lieferung laeuft)
--          save(snapshot)  -> ok, err   schreibt { export_chest, reactors }
--          copy(entry)     -> Kopie eines Eintrags, wie sie gespeichert wird
--          on_applied(changes)  nach erfolgreichem Schreiben (Router neu
--                             laden, Abklingzeiten umhaengen)
--          state           Tabelle, die zwischen Aufrufen bestehen bleibt
--          now             Millisekunden (Tests)
--
-- Rueckgabe: Zahl der umgestellten Routen, problems, Grund (oder nil).
-- Geschrieben wird erst die Datei; nur wenn das gelingt, aendert sich die
-- Laufzeit-Konfiguration -- ein Fehlschlag laesst beides wie es war.
function M.apply(lg, cache, deps)
  deps = deps or {}
  local state = deps.state or {}
  if type(lg) ~= "table" or type(lg.reactors) ~= "table" or #lg.reactors == 0 then
    return 0, {}, "no_routes"
  end
  if deps.busy and deps.busy() then return 0, nil, "busy" end

  local plan = M.plan(lg.reactors, cache)
  if #plan.changes == 0 then return 0, plan.problems, nil end

  local sig = signature(plan.changes)
  local now = tonumber(deps.now) or (os.epoch and os.epoch("utc")) or 0
  if state.failed_sig == sig and now - (state.failed_at or 0) < RETRY_AFTER_FAILURE_MS then
    return 0, plan.problems, "backoff"
  end

  local copy = deps.copy or function(entry)
    local out = {}
    for k, v in pairs(entry) do out[k] = v end
    return out
  end
  local snapshot = { export_chest = lg.export_chest, reactors = {} }
  for i, route in ipairs(lg.reactors) do snapshot.reactors[i] = copy(route) end
  for _, change in ipairs(plan.changes) do
    snapshot.reactors[change.index].reactor_id = change.to
  end

  local ok, err = false, "kein Schreibweg"
  if deps.save then ok, err = deps.save(snapshot) end
  if not ok then
    state.failed_sig, state.failed_at = sig, now
    return 0, plan.problems, "save_failed: " .. tostring(err)
  end
  state.failed_sig, state.failed_at = nil, nil

  for _, change in ipairs(plan.changes) do
    lg.reactors[change.index].reactor_id = change.to
  end
  if deps.on_applied then deps.on_applied(plan.changes) end
  return #plan.changes, plan.problems, nil, plan.changes
end

-- Meldetext je Problem, fuer das Log und den Rechner.
function M.describe_problem(problem)
  local who = string.format("FUEL-Route '%s' (%s)", tostring(problem.label or "?"), tostring(problem.id or "?"))
  if problem.status == "duplicate" then
    return who .. ": derselbe Reaktor hat schon eine Route mit globaler Kennung "
      .. tostring(problem.target) .. " -- die alte Route im ROUTER loeschen"
  elseif problem.status == "ambiguous" then
    return who .. ": kurze Kennung und Name treffen mehrere Reaktoren -- im ROUTER neu einlernen"
  elseif problem.status == "label_mismatch" then
    return who .. ": kein Reaktor mit dieser kurzen Kennung heisst so -- im ROUTER neu einlernen"
  elseif problem.status == "no_label" then
    return who .. ": kurze Kennung ohne Namen, nicht eindeutig zuzuordnen -- im ROUTER neu einlernen"
  end
  return who .. ": " .. tostring(problem.status)
end

return M
