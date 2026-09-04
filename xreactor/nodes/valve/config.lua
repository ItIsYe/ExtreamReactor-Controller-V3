-- nodes/valve/config.lua
--
-- Eigenstaendiger Valve-Controller: der "Integrator" ist selbst ein
-- CC:Tweaked-Computer direkt am Ventil, hat kein Wired Modem zu FUEL,
-- wird per Wireless Modem ueber den CONTROL-Kanal angesprochen (siehe
-- nodes/valve/main.lua, Kommando SET_VALVE). redstone_router.lua auf der
-- FUEL-Seite adressiert diesen Node ueber seine node_id.
--
-- Steuert bevorzugt einen Mekanism Logistical Sorter (setAutoMode()).
-- sorter_name wird bei nil automatisch per Methodensignatur erkannt, wie
-- wireless_modem -- nur bei mehreren Sortern am selben Computer explizit
-- setzen. Wird KEIN Sorter gefunden, ist redstone_side (top/bottom/left/
-- right/front/back) ein optionaler Redstone-Fallback-Aktor -- sobald
-- irgendein Sorter ansteuerbar ist, haelt der Controller ohnehin JEDE
-- Redstone-Seite aktiv auf false (siehe nodes/valve/controller.lua), damit
-- ein Redstone-Signal die per API gesetzte Ejection nie uebersteuern kann.
--
-- Fest eingebauter 1x1-Statusmonitor (gruen=offen, rot=blockiert), wird
-- automatisch erkannt -- kein Config-Feld noetig, anders als das geteilte
-- xreactor/optional/ampel.lua-Modul mit seiner 1x3-Turmform.
return {
  role            = "VALVE-NODE",
  node_id         = "VALVE-1",
  debug_logging   = false,
  reset_log_on_start = true,
  wireless_modem  = nil,   -- nil = automatisch erkennen
  sorter_name     = nil,   -- nil = automatisch erkennen
  redstone_side   = nil,   -- nil = kein Redstone-Fallback (nur bei fehlendem Sorter relevant)
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
