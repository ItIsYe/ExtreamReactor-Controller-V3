-- nodes/valve/config.lua
--
-- Feature (2026-07-09): eigenstaendiger Redstone-Valve-Controller.
-- Physischer Hintergrund: der "Integrator" an diesem Pipe-Netz ist selbst
-- ein CC:Tweaked-Computer (nicht ein direkt am FUEL-Computer gewrapptes
-- Mekanism-Peripheral) -- er sitzt direkt am Ventil/an der Pipe, hat KEIN
-- Wired Modem zu FUEL, sondern wird per Wireless Modem ueber den normalen
-- CONTROL-Kanal angesprochen (siehe nodes/valve/main.lua, Kommando
-- SET_VALVE). redstone_router.lua auf der FUEL-Seite adressiert diesen
-- Node ueber seine node_id (config.logistics.redstone_tree Eintraege mit
-- integrator = "<diese node_id>").
--
-- side: welche Redstone-Seite DIESES Computers am Ventil haengt.
-- Erlaubt: top / bottom / left / right / front / back
return {
  role            = "VALVE-NODE",
  node_id         = "VALVE-1",
  debug_logging   = false,
  reset_log_on_start = true,
  wireless_modem  = nil,   -- nil = automatisch erkennen
  side            = "front",
  -- Fail-Safe-Grundzustand beim Boot/bei Verbindungsverlust: Ventil
  -- geschlossen (high=true blockiert bei Mekanism "High Redstone =
  -- Interrupt"-Konfiguration -- siehe redstone_router.lua Kommentar).
  default_blocked = true,
  heartbeat_interval = 2,
  status_interval    = 5,
  channels = { control = 6500, status = 6501 },
  comms = {
    ack_timeout_s = 3.0, max_retries = 4, backoff_base_s = 0.6, backoff_cap_s = 6.0,
    dedupe_ttl_s = 30, dedupe_limit = 200, peer_timeout_s = 12.0, queue_limit = 200, drop_simulation = 0
  }
}
