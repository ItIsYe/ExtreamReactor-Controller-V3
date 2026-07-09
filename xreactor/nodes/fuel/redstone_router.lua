-- nodes/fuel/redstone_router.lua
-- Tree-topology redstone valve routing for Mekanism pipe networks.

local M = {}

local BUILTIN_SIDES = {
  top=true, bottom=true, left=true, right=true, front=true, back=true
}

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return nil, "no_method" end
  local ok, r = pcall(obj[method], ...)
  if not ok then return nil, tostring(r) end
  return r, nil
end

local function collect_all_valves(tree, out)
  out = out or {}
  for _, node in ipairs(tree or {}) do
    if node.side then out[#out + 1] = { side = node.side, integrator = node.integrator } end
    collect_all_valves(node.children or {}, out)
  end
  return out
end

local function find_path(tree, target_id, path)
  path = path or {}
  for _, node in ipairs(tree or {}) do
    local valve = node.side and { side = node.side, integrator = node.integrator } or nil
    local next_path = valve and (function()
      local p = {}
      for _, v in ipairs(path) do p[#p + 1] = v end
      p[#p + 1] = valve
      return p
    end)() or path
    if node.reactor == target_id or node.label == target_id then return next_path end
    local found = find_path(node.children or {}, target_id, next_path)
    if found then return found end
  end
  return nil
end

-- Feature (2026-07-08): strukturelle Baum-Validierung vor Aktivierung.
-- Rein statisch (keine Peripherie-Pruefung -- Integratoren koennen online
-- kommen/gehen, das gehoert nicht in eine Struktur-Validierung, sondern
-- bleibt Aufgabe von M:refresh()'s Laufzeit-Warnungen).
-- Rueckgabe: { ok=bool, errors={ {code=..., message=...}, ... } }
local function path_key(path)
  local parts = {}
  for _, v in ipairs(path) do
    parts[#parts + 1] = tostring(v.side) .. ":" .. tostring(v.integrator or "")
  end
  return table.concat(parts, ">")
end

function M.validate_tree(tree)
  local errors = {}
  local function err(code, message)
    errors[#errors + 1] = { code = code, message = message }
  end

  if type(tree) ~= "table" then
    err("tree_not_table", "redstone_tree ist keine Tabelle (nil oder falscher Typ)")
    return { ok = false, errors = errors }
  end

  local seen_reactors = {}
  local seen_valve_positions = {}  -- side:integrator -> Pfad-Praefix, an dem es zuerst auftrat
  local reactor_paths = {}         -- reactor_id -> path_key
  local visiting = setmetatable({}, { __mode = "k" })  -- Zyklen-Schutz (Tabellen-Identitaet)

  local function walk(nodes, path, depth)
    if visiting[nodes] then
      err("cycle_detected", "Zyklische Struktur erkannt (Tabelle verweist auf sich selbst)")
      return
    end
    visiting[nodes] = true
    if depth > 32 then
      err("depth_exceeded", "Baumtiefe > 32 — vermutlich fehlerhafte/zyklische Struktur")
      visiting[nodes] = nil
      return
    end

    for i, node in ipairs(nodes or {}) do
      if type(node) ~= "table" then
        err("invalid_node", "Knoten #" .. i .. " auf Tiefe " .. depth .. " ist keine Tabelle")
        goto next_node
      end

      -- fehlende side
      if not node.side and not node.reactor then
        err("missing_side", "Knoten ohne 'side' und ohne 'reactor' (Tiefe " .. depth .. ", Index " .. i .. ")")
      end
      -- ungueltige side
      if node.side and not BUILTIN_SIDES[node.side] then
        err("invalid_side", "Ungueltige Redstone-Seite '" .. tostring(node.side)
          .. "' (erlaubt: top/bottom/left/right/front/back)")
      end

      local valve = node.side and { side = node.side, integrator = node.integrator } or nil
      local next_path = path
      if valve then
        next_path = {}
        for _, v in ipairs(path) do next_path[#next_path + 1] = v end
        next_path[#next_path + 1] = valve

        -- gleiches Ventil an widerspruechlichen Stellen: dieselbe
        -- side+integrator-Kombination taucht an einer STRUKTURELL
        -- ANDEREN Position im Baum auf (anderer Pfad-Praefix davor).
        local pos_key = tostring(node.side) .. ":" .. tostring(node.integrator or "")
        local prefix_key = path_key(path)
        if seen_valve_positions[pos_key] and seen_valve_positions[pos_key] ~= prefix_key then
          err("conflicting_valve_reuse", "Ventil '" .. pos_key
            .. "' erscheint an mehreren widerspruechlichen Baumpositionen")
        end
        seen_valve_positions[pos_key] = prefix_key
      end

      -- Reaktor-Endpunkt
      if node.reactor then
        if seen_reactors[node.reactor] then
          err("duplicate_reactor", "Reaktor-Ziel '" .. tostring(node.reactor) .. "' mehrfach im Baum")
        end
        seen_reactors[node.reactor] = true

        local pk = path_key(next_path)
        for other_id, other_pk in pairs(reactor_paths) do
          if other_pk == pk then
            err("identical_paths", "Reaktoren '" .. tostring(node.reactor) .. "' und '"
              .. tostring(other_id) .. "' haben identische Ventil-Pfade — nicht unterscheidbar")
          end
        end
        reactor_paths[node.reactor] = pk

        if type(node.children) == "table" and #node.children > 0 then
          err("reactor_with_children", "Reaktor '" .. tostring(node.reactor)
            .. "' hat zusaetzlich 'children' — ein Reaktor-Endpunkt darf keine weiteren Aeste haben")
        end
      end

      -- toter Ast: weder reactor noch children
      if not node.reactor and (type(node.children) ~= "table" or #node.children == 0) then
        err("dead_end", "Knoten '" .. tostring(node.side or node.label or ("#" .. i))
          .. "' fuehrt nirgendwohin (kein 'reactor', keine 'children')")
      end

      if type(node.children) == "table" then
        walk(node.children, next_path, depth + 1)
      end

      ::next_node::
    end
    visiting[nodes] = nil
  end

  walk(tree, {}, 1)
  return { ok = #errors == 0, errors = errors }
end

function M.new(opts)
  opts = opts or {}
  local self = {
    config = opts.config or {},
    log = opts.log or function() end,
    warn_once = opts.warn_once or function() end,
    _state = {
      all_valves = {},
      integrators = {},
      active_target = nil,
      active_path = nil,
      last_target = nil,
      last_path = nil,
      last_active_ts = nil,
      tree_valid = nil,
      tree_errors = {},
    },
  }
  return setmetatable(self, { __index = M })
end

function M:refresh()
  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}

  -- Feature (2026-07-08): strukturelle Validierung VOR jeder Aktivierung.
  -- Bei einem ungueltigen Baum: alle Ventile blockieren (Fail-Safe-
  -- Grundzustand, kein Fuel-Transfer moeglich), all_valves/integrators
  -- NICHT aus dem fehlerhaften Baum laden (route_count() bleibt 0, damit
  -- logistics_router.lua sauber auf den ungerouteten Direkt-Export-Pfad
  -- zurueckfaellt statt mit einer kaputten Struktur zu arbeiten), und der
  -- Fehler wird geloggt (landet damit auch im Log-Collector-System) sowie
  -- ueber get_validation() fuer UI/zukuenftige Master-Alerts bereitgestellt.
  local validation = M.validate_tree(tree)
  self._state.tree_valid = validation.ok
  self._state.tree_errors = validation.errors

  if not validation.ok then
    for _, e in ipairs(validation.errors) do
      self.warn_once("tree_invalid:" .. e.code, "RedstoneRouter: UNGUELTIGER BAUM [" .. e.code .. "] " .. e.message)
    end
    self._state.all_valves = {}
    self._state.integrators = {}
    self:block_all()
    self.log("ERROR", string.format(
      "RedstoneRouter: redstone_tree ungueltig (%d Fehler) — alle Ventile blockiert, kein Routing aktiv",
      #validation.errors))
    return
  end

  local all = collect_all_valves(tree)
  self._state.all_valves = all

  local int_names = {}
  for _, v in ipairs(all) do if v.integrator then int_names[v.integrator] = true end end
  local integrators = {}
  for name in pairs(int_names) do
    if peripheral.isPresent(name) then
      local ok, w = pcall(peripheral.wrap, name)
      if ok and w then
        integrators[name] = w
        self.log("DEBUG", "RedstoneRouter: integrator " .. name)
      else
        self.warn_once("int:" .. name, "RedstoneRouter: integrator wrap failed: " .. name)
      end
    else
      self.warn_once("int_abs:" .. name, "RedstoneRouter: integrator absent: " .. name)
    end
  end
  self._state.integrators = integrators
  self:block_all()
  self.log("DEBUG", string.format("RedstoneRouter: tree loaded, %d total valves", #all))
end

function M:_set_valve(valve, high)
  local side = valve.side
  if valve.integrator then
    local w = self._state.integrators[valve.integrator]
    if w then
      local ok = safe_call(w, "setOutput", side, high)
      if ok == nil then
        -- Fix (2026-07-08): setOutput() selbst kann fehlschlagen (z.B.
        -- Integrator kurzzeitig nicht reagierend) — vorher wurde das
        -- Ergebnis von safe_call() komplett ignoriert.
        self.warn_once("valve_set_fail:" .. valve.integrator .. ":" .. tostring(side),
          "RedstoneRouter: Ventil-Schaltung fehlgeschlagen (" .. valve.integrator .. "/" .. tostring(side) .. ")")
        return false
      end
      return true
    end
    -- Fix (2026-07-08): Integrator offline/nicht gewrapped — vorher
    -- passierte hier STILLSCHWEIGEND gar nichts (kein Log, kein
    -- Fehlerstatus). Ein Ventil, das nicht geschaltet werden kann, bleibt
    -- in unbekanntem Zustand — sicherheitsrelevant genug fuer eine
    -- explizite Warnung.
    self.warn_once("int_offline:" .. valve.integrator,
      "RedstoneRouter: Integrator '" .. valve.integrator .. "' offline — Ventil (" .. tostring(side) .. ") nicht schaltbar")
    return false
  elseif BUILTIN_SIDES[side] then
    local ok = pcall(redstone.setOutput, side, high)
    if not ok then
      self.warn_once("valve_rs_fail:" .. tostring(side),
        "RedstoneRouter: redstone.setOutput fehlgeschlagen fuer Seite '" .. tostring(side) .. "'")
      return false
    end
    return true
  else
    self.warn_once("bad_side:" .. tostring(side), "RedstoneRouter: unknown side '" .. tostring(side) .. "'")
    return false
  end
end

function M:block_all()
  local all_ok = true
  for _, v in ipairs(self._state.all_valves) do
    if not self:_set_valve(v, true) then all_ok = false end
  end
  return all_ok
end

function M:open_path_to(target_id)
  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}
  local path = find_path(tree, target_id)
  if not path then
    self.log("WARN", "RedstoneRouter: no path found for target: " .. tostring(target_id))
    self:block_all()
    return false
  end

  local path_set = {}
  for _, v in ipairs(path) do path_set[(v.integrator or "") .. ":" .. v.side] = true end
  -- Fix (2026-07-08): Ventil-Schaltfehler auf dem eigentlichen Ziel-Pfad
  -- (Ventil sollte OFFEN sein) werden jetzt als Routing-Fehlschlag
  -- gewertet -- vorher wurde stur weitergemacht, selbst wenn ein noetiges
  -- Ventil wegen offline-Integrator gar nicht geoeffnet werden konnte.
  local path_open_failed = false
  for _, v in ipairs(self._state.all_valves) do
    local key = (v.integrator or "") .. ":" .. v.side
    local should_be_open = path_set[key]
    local ok = self:_set_valve(v, not should_be_open)
    if should_be_open and not ok then path_open_failed = true end
  end

  if path_open_failed then
    self.log("ERROR", "RedstoneRouter: Pfad zu " .. tostring(target_id)
      .. " konnte nicht vollstaendig geoeffnet werden (Ventil-Fehler) — blockiere sicherheitshalber alles")
    self:block_all()
    return false
  end

  local sides = {}
  for _, v in ipairs(path) do sides[#sides + 1] = v.side end
  self._state.active_target = target_id
  self._state.active_path = sides
  self._state.last_target = target_id
  self._state.last_path = sides
  self._state.last_active_ts = os.epoch and os.epoch("utc") or nil

  self.log("DEBUG", string.format("RedstoneRouter: routing to %s via [%s]", tostring(target_id), table.concat(sides, " → ")))
  return true
end

function M:route_and_act(target_id, action_fn, valve_open_ms)
  if #self._state.all_valves == 0 then
    if action_fn then action_fn() end
    return
  end
  local ok = self:open_path_to(target_id)
  if not ok then
    self.log("WARN", "RedstoneRouter: cannot route to " .. tostring(target_id))
    self:block_all()
    self._state.active_target = nil
    self._state.active_path = nil
    return
  end
  os.sleep(0.05)
  if action_fn then action_fn() end
  os.sleep((tonumber(valve_open_ms) or 2000) / 1000)
  self:block_all()
  self._state.active_target = nil
  self._state.active_path = nil
end

function M:valve_count()
  return #self._state.all_valves
end

function M:route_count()
  return #self:get_routing_table()
end

function M:get_tree()
  local cfg = self.config.logistics or self.config or {}
  return cfg.redstone_tree or {}
end

function M:get_path_to(target_id)
  local cfg = self.config.logistics or self.config or {}
  local path = find_path(cfg.redstone_tree or {}, target_id) or {}
  local sides = {}
  for _, v in ipairs(path) do sides[#sides + 1] = v.side end
  return sides
end

function M:get_active_route()
  return {
    target = self._state.active_target,
    path = self._state.active_path,
    last_target = self._state.last_target,
    last_path = self._state.last_path,
    last_active_ts = self._state.last_active_ts,
  }
end

-- Feature (2026-07-08): Validierungsstatus fuer UI/Alerts (siehe
-- validate_tree() / M:refresh() oben).
function M:get_validation()
  return { ok = self._state.tree_valid, errors = self._state.tree_errors or {} }
end

function M:get_routing_table()
  local cfg = self.config.logistics or self.config or {}
  local tree = cfg.redstone_tree or {}
  local result = {}
  local function walk(nodes)
    for _, node in ipairs(nodes) do
      if node.reactor then
        local path = find_path(tree, node.reactor) or {}
        local sides = {}
        for _, v in ipairs(path) do sides[#sides + 1] = v.side end
        result[#result + 1] = {
          reactor = node.reactor,
          label = node.label or node.reactor,
          path = sides,
        }
      end
      walk(node.children or {})
    end
  end
  walk(tree)
  return result
end

return M
