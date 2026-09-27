-- RT rewrite, step 13: EIN Reaktor als eigenstaendiger Regelkreis.
--
-- Der Knoten fasst seine Anlage als EIN System auf: eine Turbinenflotte,
-- ein gemeinsames Dampfnetz, eine Kapazitaet, eine Leistungsvorgabe. Was
-- sich nicht teilen laesst, ist die Reaktorregelung selbst -- jeder
-- Reaktor hat seinen eigenen Dampftank, und genau daraus regelt er seine
-- Staebe. Zwei Reaktoren am selben Netz regeln sich damit von allein
-- gegenseitig ein: zieht die Flotte mehr, fallen beide Tanks, beide
-- fahren die Staebe aus. Faellt einer aus, leert sich der Tank des
-- anderen schneller, und er faehrt nach. Dafuer braucht es keine
-- Absprache zwischen ihnen -- und deshalb auch keine Zuordnung, welche
-- Turbine an welchem Reaktor haengt.
--
-- Diese Datei haelt also alles, wovon es PRO REAKTOR eines gibt:
-- Stellrate, letzter Messwert und Sicherheitslage. Turbinen und
-- Betriebszustand gehoeren dagegen dem Knoten und liegen beim
-- Orchestrator.
--
-- Was hier NICHT mehr passiert: ein gemessenes Anlagenprofil ableiten.
-- rt2_tuning hat aus dem Tankverlauf Stellweite und Stellintervall
-- gelernt und damit die Reaktorregelung von Lauf zu Lauf veraendert. Die
-- Regelung arbeitet jetzt mit den festen Werten aus rt2_reactor.lua --
-- eine Vorgabe, keine Vermutung.

local rt2_reactor = require('nodes.rt.rt2_reactor')
local rt2_state = require('nodes.rt.rt2_state')

local M = {}

-- opts.name -- Peripheriename (Schluessel fuer Diagnose)
function M.new(opts)
  opts = opts or {}
  local self = {
    name = opts.name,
    last_rod_change_ms = 0,
    last_rod_fill = nil,
    safety_tripped = false,
  }

  -- MESSEN. Laeuft vor der Zustandsentscheidung des Knotens.
  -- input: now_ms, safety_tripped, reactor { fill_ratio, current_rods }
  function self.observe(input)
    input = input or {}
    self.safety_tripped = input.safety_tripped == true
    -- Ein ausgeloester Reaktor misst nicht: seine Staebe sind eingefahren,
    -- was dort gemessen wuerde, beschriebe keine Regelung.
    if self.safety_tripped then return self end

    return self
  end

  -- ENTSCHEIDEN. Braucht den inzwischen feststehenden Betriebszustand.
  function self.decide(input)
    input = input or {}
    local now_ms = input.now_ms
    local node_state = input.node_state or rt2_state.states.INIT
    -- Dieser Reaktor faehrt ein, wenn ER ausgeloest hat oder der ganze
    -- Knoten SAFE ist. Ein Ausloeser am NACHBARREAKTOR beruehrt ihn nicht
    -- -- er uebernimmt dann einfach dessen Dampflast, was seinen Tank
    -- schneller leert und ihn von selbst hochfahren laesst.
    local override = self.safety_tripped or node_state == rt2_state.states.SAFE
    local fill = input.reactor and input.reactor.fill_ratio or nil

    local adjust_due = (now_ms or 0) - self.last_rod_change_ms >= rt2_reactor.MIN_ADJUST_INTERVAL_MS

    local decision = rt2_reactor.compute_rod_level({
      fill_ratio = fill,
      target_fill = input.reactor and input.reactor.target_fill or nil,
      current_rods = input.reactor and input.reactor.current_rods or nil,
      safety_override = override,
      previous_fill = adjust_due and self.last_rod_fill or nil,
    })

    -- Nur die gewoehnliche Tankregelung wird verzoegert; eine Ausloesung
    -- und jeder andere Sicherheitspfad wirkt sofort.
    if not adjust_due
        and (decision.reason == "TANK_FULL_INSERT" or decision.reason == "TANK_LOW_WITHDRAW") then
      local current_rods = tonumber(input.reactor and input.reactor.current_rods)
      if current_rods then
        decision = { rods = current_rods, reason = "RATE_LIMITED" }
      end
    end

    if adjust_due then
      self.last_rod_change_ms = now_ms or self.last_rod_change_ms
      self.last_rod_fill = fill
    end

    -- Einen ausgeloesten Reaktor nicht wieder einschalten -- sonst
    -- kaempfte die Einschaltlogik gegen die Sicherheitsabschaltung.
    decision.activate = (not override)
      and rt2_reactor.compute_active_decision(input.reactor and input.reactor.active)
      or false
    decision.name = self.name
    decision.safety_tripped = self.safety_tripped

    return decision
  end

  return self
end

return M
