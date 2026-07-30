-- master/fuel_relay.lua
--
-- Feature (2026-07-08): FUEL-Nodes haben keinen Wired-Modem-Zugriff auf die
-- Reaktoren selbst (nur aufs ME-System via ME Bridge) — der Fuellstand kann
-- also nicht lokal per Peripherie ausgelesen werden. RT-Nodes haben den
-- Wired-Zugriff bereits (fuer Steuerung) und schicken fuel_amount/
-- fuel_capacity ohnehin schon in ihrem regulaeren Status-Update an Master
-- mit (siehe nodes/rt/status_snapshot.lua). Dieses Modul sammelt diese
-- Werte aus allen bekannten RT-Peers ein und leitet sie periodisch an alle
-- FUEL-Nodes weiter — passend zur sonst durchgehend master-zentrierten
-- Architektur (Steuerung, Status, Alerts laufen ebenfalls alle ueber
-- Master).
--
-- Kein Direktkanal RT->FUEL noetig; FUEL-seitig ergaenzt das nur die
-- ohnehin schon vorhandene konservative Fallback-Logik (siehe
-- nodes/fuel/logistics_router.lua: fehlende/veraltete Daten -> Reaktor
-- diesen Zyklus ueberspringen statt zu raten).

local M = {}

local RELAY_INTERVAL_MS = 10000  -- alle 10s reicht, Fuel-Verbrauch ist langsam

-- Sammelt { [reactor_id] = { fuel_amount=.., fuel_capacity=.., ts=.. } }
-- aus allen bekannten RT-Peers.
--
-- Fix (2026-07-13): CRITICAL (MASTER-P1.2, siehe docs/CODING_AI_OTHER_
-- NODES_PERFORMANCE_2026-07-12.md). "ts = os.epoch(\"utc\")" setzte hier
-- bisher bei JEDEM Relay-Durchlauf einen KOMPLETT NEUEN Zeitstempel,
-- unabhaengig davon, wie alt der zugrunde liegende RT-Snapshot
-- tatsaechlich war. Ein laengst ausgefallener RT-Node konnte dadurch
-- indirekt weiterhin scheinbar frische Fuelwerte liefern -- solange sein
-- letzter bekannter Zustand im MASTER gespeichert blieb, wurde er alle
-- 10s erneut als "gerade jetzt gemessen" an FUEL weitergereicht. FUEL
-- selbst vertraut (bewusst, siehe fuel_status_network.lua) der eigenen
-- Empfangszeit statt eines von Master gesendeten Zeitstempels -- das
-- Problem war dadurch fuer FUEL komplett unsichtbar, es haette den
-- Reaktor-Fuellstand fuer beliebig lange als "aktuell ueberwacht"
-- gehalten, obwohl die zugrunde liegende Messung laengst eingefroren war.
-- Jetzt: node.last_seen (der ECHTE Zeitpunkt der letzten RT-Aktualisierung,
-- von check_timeouts() bereits gepflegt) wird als ts uebernommen, ein
-- als stale/offline markierter RT-Node wird komplett uebersprungen (kein
-- Relay seiner Daten mehr), und zusaetzlich eine explizite Altersgrenze
-- durchgesetzt, selbst wenn der Node noch nicht formal als down gilt.
local MAX_SAMPLE_AGE_MS = 60000  -- aelter als 60s -> nicht mehr relayen

local function collect_reactor_fuel(runtime)
  local constants = runtime.libs.constants
  local now = os.epoch("utc")
  local out = {}
  for _, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.RT_NODE and type(node.rt) == "table"
        and type(node.rt.reactors) == "table"
        and not node.stale and not node.offline then
      local sample_ts = node.last_seen or now
      local age_ms = now - sample_ts
      if age_ms <= MAX_SAMPLE_AGE_MS then
        for _, r in ipairs(node.rt.reactors) do
          if r.id and (r.fuel_amount ~= nil or r.fuel_capacity ~= nil) then
            out[r.id] = {
              fuel_amount   = r.fuel_amount,
              fuel_capacity = r.fuel_capacity,
              label         = r.alias or r.name or r.id,
              source_node   = node.id,
              ts            = sample_ts,
              source_age_ms = age_ms,
            }
          end
        end
      end
    end
  end
  return out
end

function M.tick(runtime)
  local constants = runtime.libs.constants
  local now = os.epoch("utc")
  runtime.state._fuel_relay_last = runtime.state._fuel_relay_last or 0
  if (now - runtime.state._fuel_relay_last) < RELAY_INTERVAL_MS then return end

  local fuel_nodes = {}
  for id, node in pairs(runtime.state.nodes or {}) do
    if node.role == constants.roles.FUEL_NODE then
      fuel_nodes[#fuel_nodes + 1] = id
    end
  end
  if #fuel_nodes == 0 then return end  -- keine FUEL-Node da, nichts zu tun

  local snapshot = collect_reactor_fuel(runtime)
  runtime.state._fuel_relay_last = now

  for _, id in ipairs(fuel_nodes) do
    runtime.refs.comms:send_command(id, {
      target = constants.command_targets.FUEL_STATUS,
      value = snapshot,
    })
  end
end

return M
