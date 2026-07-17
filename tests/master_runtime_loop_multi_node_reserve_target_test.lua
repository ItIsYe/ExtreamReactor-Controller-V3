-- Funktionaler Verifikationstest fuer die MASTER-P1-Fixes in
-- xreactor/master/runtime_loop.lua (set_fuel_reserve / set_water_target),
-- siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md Abschnitt 9.
-- Extrahiert die exakten Funktionen aus der echten Datei und prueft, dass
-- ALLE Nodes einer Rolle das Command erhalten (statt nur des ersten
-- gefundenen, nicht-deterministisch per pairs()-Reihenfolge), wenn die
-- Zielauswahl (siehe master/config_edits.lua, MASTER-P1-Folgefix
-- 2026-07-17, Abschnitt 10) auf "ALL" steht -- dem Default fuer eine
-- frische runtime.state.config_edits-Tabelle wie hier.
--
-- Fix (2026-07-17): set_fuel_reserve/set_water_target delegieren jetzt
-- vollstaendig an das echte, require()-bare master/config_edits.lua
-- (require_applied=true, message_id-Tracking je Ziel) statt Command-
-- Versand direkt selbst zu implementieren -- dieser Test extrahiert
-- weiterhin den echten Funktionsliteral, treibt ihn aber jetzt gegen das
-- echte config_edits-Modul statt einer inline nachgebauten Schleife.

local REPO = os.getenv("REPO_ROOT") or "."
package.path = table.concat({ REPO .. "/xreactor/?.lua", REPO .. "/xreactor/?/init.lua", package.path }, ";")
local config_edits = require("master.config_edits")
-- Die extrahierten Funktionsliterale (siehe fuel_src/water_src unten)
-- referenzieren "config_edits" als freie Variable -- load() ohne
-- expliziten env-Parameter loest das ueber die globale Umgebung auf, nicht
-- ueber lokale Variablen dieser Datei.
_G.config_edits = config_edits
-- Ebenso referenziert der extrahierte Funktionsliteral "log" (das lokale
-- log() aus runtime_loop.lua) als freie Variable.
_G.log = function() end

local function read_file(p)
  local f = assert(io.open(p, "r"))
  local c = f:read("*a")
  f:close()
  return c
end

local function extract(s, start_marker, end_marker)
  local a = s:find(start_marker, 1, true)
  assert(a, "start marker not found: " .. start_marker)
  local b = s:find(end_marker, a, true)
  assert(b, "end marker not found: " .. end_marker)
  return s:sub(a, b + #end_marker - 1)
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local src = read_file(REPO .. "/xreactor/master/runtime_loop.lua")

local fuel_src = extract(src,
  "set_fuel_reserve = function(amount)",
  "\n    end,")
local water_src = extract(src,
  "set_water_target = function(amount)",
  "\n    end,")

local constants = {
  roles = { FUEL_NODE = "FUEL-NODE", WATER_NODE = "WATER-NODE", RT_NODE = "RT-NODE" },
  command_targets = { SET_RESERVE = "SET_RESERVE", SET_TARGET = "SET_TARGET" },
}

local function make_runtime(nodes)
  local sent = {}
  local runtime = {
    state = { nodes = nodes, config_edits = {} },
    refs = {
      comms = {
        send_command = function(self, id, payload, opts)
          local msg_id = "MSG-" .. (#sent + 1)
          table.insert(sent, { id = id, payload = payload, opts = opts })
          return { message = { message_id = msg_id } }
        end,
      },
    },
    log = function() end,
  }
  return runtime, sent
end

------------------------------------------------------------------------------
-- set_fuel_reserve: mehrere FUEL-Nodes
------------------------------------------------------------------------------

do
  local nodes = {
    a = { role = constants.roles.FUEL_NODE },
    b = { role = constants.roles.FUEL_NODE },
    c = { role = constants.roles.WATER_NODE },
  }
  local runtime, sent = make_runtime(nodes)
  local chunk = assert(load(
    "local runtime, constants = ...\nreturn { " .. fuel_src .. " }",
    "=set_fuel_reserve"))
  local wrapper = chunk(runtime, constants)

  local ok, sent_count = wrapper.set_fuel_reserve(4200)
  check(ok == true, "set_fuel_reserve should succeed when FUEL nodes exist")
  check(sent_count == 2, "set_fuel_reserve should report 2 nodes sent (got " .. tostring(sent_count) .. ")")
  check(#sent == 2, "exactly 2 send_command calls expected (got " .. #sent .. ")")
  local ids = { [sent[1].id] = true, [sent[2].id] = true }
  check(ids.a and ids.b, "both FUEL nodes 'a' and 'b' must receive the command")
  check(not ids.c, "WATER node 'c' must not receive the FUEL command")
  for _, s in ipairs(sent) do
    check(s.payload.target == "SET_RESERVE", "target must be SET_RESERVE")
    check(s.payload.value == 4200, "value must be forwarded unchanged")
  end
end

------------------------------------------------------------------------------
-- set_fuel_reserve: kein FUEL-Node vorhanden
------------------------------------------------------------------------------

do
  local nodes = { a = { role = constants.roles.WATER_NODE } }
  local runtime, sent = make_runtime(nodes)
  local chunk = assert(load(
    "local runtime, constants = ...\nreturn { " .. fuel_src .. " }",
    "=set_fuel_reserve_none"))
  local wrapper = chunk(runtime, constants)

  local ok, err = wrapper.set_fuel_reserve(1000)
  check(ok == false, "set_fuel_reserve should fail when no FUEL node exists")
  check(err == "kein Node mit Rolle FUEL-NODE gefunden", "error message should match (got " .. tostring(err) .. ")")
  check(#sent == 0, "no send_command call expected")
end

------------------------------------------------------------------------------
-- set_water_target: mehrere WATER-Nodes
------------------------------------------------------------------------------

do
  local nodes = {
    a = { role = constants.roles.WATER_NODE },
    b = { role = constants.roles.WATER_NODE },
    c = { role = constants.roles.FUEL_NODE },
  }
  local runtime, sent = make_runtime(nodes)
  local chunk = assert(load(
    "local runtime, constants = ...\nreturn { " .. water_src .. " }",
    "=set_water_target"))
  local wrapper = chunk(runtime, constants)

  local ok, sent_count = wrapper.set_water_target(777)
  check(ok == true, "set_water_target should succeed when WATER nodes exist")
  check(sent_count == 2, "set_water_target should report 2 nodes sent (got " .. tostring(sent_count) .. ")")
  check(#sent == 2, "exactly 2 send_command calls expected (got " .. #sent .. ")")
  local ids = { [sent[1].id] = true, [sent[2].id] = true }
  check(ids.a and ids.b, "both WATER nodes 'a' and 'b' must receive the command")
  check(not ids.c, "FUEL node 'c' must not receive the WATER command")
  for _, s in ipairs(sent) do
    check(s.payload.target == "SET_TARGET", "target must be SET_TARGET")
    check(s.payload.value == 777, "value must be forwarded unchanged")
  end
end

------------------------------------------------------------------------------
-- set_water_target: kein WATER-Node vorhanden
------------------------------------------------------------------------------

do
  local nodes = { a = { role = constants.roles.FUEL_NODE } }
  local runtime, sent = make_runtime(nodes)
  local chunk = assert(load(
    "local runtime, constants = ...\nreturn { " .. water_src .. " }",
    "=set_water_target_none"))
  local wrapper = chunk(runtime, constants)

  local ok, err = wrapper.set_water_target(50)
  check(ok == false, "set_water_target should fail when no WATER node exists")
  check(err == "kein Node mit Rolle WATER-NODE gefunden", "error message should match (got " .. tostring(err) .. ")")
  check(#sent == 0, "no send_command call expected")
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
