-- RT rewrite, step 5: MASTER connectivity as one explicit, testable signal.
--
-- rt2_state.lua's decide_next_state() needs a single boolean,
-- master_connected. The old code derived this ad hoc (is_master_connected()
-- closures scattered across main.lua) with no single place to see or test
-- the liveness rule. This module is that one place: feed it every message
-- timestamp from the MASTER role, ask it "connected right now?", done.
--
-- Debounced on purpose: a single missed heartbeat must not flip the node
-- into AUTONOM and back (that thrashing was an earlier bug this project
-- already hit and fixed once for the peer table in core/comms.lua --
-- reusing the same debounce-then-declare-down shape here rather than
-- inventing a new one).

local M = {}

-- 20s, bewusst identisch zum Default von comms.peer_timeout_s in
-- nodes/rt/config.lua: der Health-Check (nodes/rt/health_payload.lua) und
-- die Monitor-Anzeige lesen die Peer-Tabelle, diese Zustandsmaschine
-- liest dieses Modul. Laufen die beiden Schwellen auseinander, meldet die
-- Node "MASTER DOWN", waehrend sie selbst noch im Zustand MASTER regelt
-- (oder umgekehrt). rt2_engine.init() leitet den Wert zusaetzlich direkt
-- aus config.comms.peer_timeout_s ab, damit eine abweichend
-- konfigurierte Node ebenfalls konsistent bleibt.
M.TIMEOUT_MS = 20000  -- no message from MASTER within this window -> considered down

function M.new(opts)
  opts = opts or {}
  local self = {
    timeout_ms = tonumber(opts.timeout_ms) or M.TIMEOUT_MS,
    last_seen_ms = nil,
  }

  -- Call once per received message that carries the MASTER role.
  function self.note_seen(now_ms)
    self.last_seen_ms = tonumber(now_ms) or self.last_seen_ms
  end

  -- Pure given the object's own state: no argument mutates anything.
  --
  -- Ein Uhr-RUECKSPRUNG wird ausdruecklich behandelt. Ohne diese Pruefung
  -- war (now - last_seen) negativ und damit immer kleiner als das Zeitfenster:
  -- ein toter MASTER galt unbegrenzt als verbunden, bis die Uhr den Sprung
  -- aufgeholt hatte. Nachgemessen: ein Ruecksprung um einen Tag hielt
  -- is_connected() einen Tag lang auf true. Der Knoten waere in dieser Zeit
  -- im Zustand MASTER geblieben und haette der eingefrorenen
  -- Leistungsvorgabe gefolgt, obwohl niemand mehr vorgibt.
  --
  -- Jedes andere zeitabhaengige Teil des Reglers behandelt den Ruecksprung
  -- schon (rt2_unit.lua's Stellintervall, rt2_turbine.lua's Stellsperre,
  -- rt2_orchestrator.lua's push_rpm_sample) -- und zwar nach derselben
  -- Regel: ein Bezugspunkt aus der Zukunft ist wertlos, also wird er
  -- verworfen statt ausgesessen. Hier heisst das "nicht verbunden": der
  -- Knoten faellt fuer hoechstens einen Heartbeat nach AUTONOM, die naechste
  -- MASTER-Nachricht setzt den Zeitstempel auf die neue Uhr, und damit heilt
  -- es sich in Sekunden selbst.
  function self.is_connected(now_ms)
    if type(self.last_seen_ms) ~= "number" then return false end
    now_ms = tonumber(now_ms) or self.last_seen_ms
    local age_ms = now_ms - self.last_seen_ms
    if age_ms < 0 then return false end
    return age_ms < self.timeout_ms
  end

  function self.last_seen()
    return self.last_seen_ms
  end

  return self
end

return M
