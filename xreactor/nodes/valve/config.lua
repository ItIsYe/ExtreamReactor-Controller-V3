-- nodes/valve/config.lua
--
-- Feature (2026-07-09): eigenstaendiger Valve-Controller.
-- Physischer Hintergrund: der "Integrator" an diesem Pipe-Netz ist selbst
-- ein CC:Tweaked-Computer (nicht ein direkt am FUEL-Computer gewrapptes
-- Mekanism-Peripheral) -- er sitzt direkt am Ventil/an der Pipe, hat KEIN
-- Wired Modem zu FUEL, sondern wird per Wireless Modem ueber den normalen
-- CONTROL-Kanal angesprochen (siehe nodes/valve/main.lua, Kommando
-- SET_VALVE). redstone_router.lua auf der FUEL-Seite adressiert diesen
-- Node ueber seine node_id (config.logistics.redstone_tree Eintraege mit
-- integrator = "<diese node_id>").
--
-- Fix (2026-07-20): der urspruengliche Redstone-Aktor (actuator_type =
-- "redstone", direktes redstone.setOutput() ueber "side") ist entfernt --
-- jede VALVE-Node steuert ausschliesslich einen Mekanism Logistical
-- Sorter per CC:Tweaked (setAutoMode()). Kein "side"/"actuator_type"-Feld
-- mehr. sorter_name (der Peripherie-Name des Logistical Sorters) wird bei
-- nil automatisch per Methodensignatur erkannt, genau wie wireless_modem
-- -- nur bei mehreren Sortern am selben Computer explizit setzen (z.B.
-- "logisticalSorter_1").
--
-- Fix (2026-07-20): fest eingebauter (NICHT optionaler, NICHT ueber das
-- Installer-Feature "ampel" gesteuerter) 1x1-Statusmonitor: gruen=offen,
-- rot=blockiert. Wird automatisch erkannt, falls einer angeschlossen ist --
-- kein Config-Feld dafuer noetig, kein Formcheck (anders als das gemeinsame
-- xreactor/optional/ampel.lua-Modul mit seiner 1x3-Turmform, das andere
-- Rollen weiterhin optional nutzen).
return {
  role            = "VALVE-NODE",
  node_id         = "VALVE-1",
  debug_logging   = false,
  reset_log_on_start = true,
  wireless_modem  = nil,   -- nil = automatisch erkennen
  sorter_name     = nil,   -- nil = automatisch erkennen
  -- Fail-Safe-Grundzustand beim Boot/bei Verbindungsverlust: Ventil
  -- geschlossen (high=true -> Sorter-Auto-Modus AUS, siehe main.lua
  -- write_actuator()).
  default_blocked = true,
  heartbeat_interval = 2,
  status_interval    = 5,
  channels = { control = 6500, status = 6501 },
  comms = {
    ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0
  }
}
