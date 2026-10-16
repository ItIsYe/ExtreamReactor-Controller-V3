-- Die gemeinsame Grundform des Statuspayloads aller Nicht-RT-Rollen
-- (ENERGY, FUEL, WATER, REPROCESSOR).
--
-- Hier steht NUR, was auch jemand liest. Beim Kommunikations-Durchgang am
-- 2026-09-29 wurde fuer jedes Feld der Leser gesucht -- im MASTER, in den
-- node-eigenen Oberflaechen, im Pocket-Pfad, in core/alert_rules.lua und
-- in den Knoten, die auf dem Statuskanal mithoeren (nodes/fuel/
-- fuel_status_network.lua). Sechs Felder hatten ueberhaupt keinen:
--
--   ts                 Der Umschlag traegt bereits einen Zeitstempel
--                      (core/protocol.lua setzt ts/src/node_id/role), und
--                      gelesen wird auch nur der.
--   version            nirgends.
--   master_seen_s      nirgends. Ob ein Knoten MASTER sieht, steht in
--                      master_connected -- das liest die FUEL-Oberflaeche.
--   discovery_failed   nirgends. Der Befund steckt ohnehin in health.reasons
--                      (DISCOVERY_FAILED), und DAS wird gelesen.
--   peers              nirgends -- und der Block ist nicht klein: je
--                      bekanntem Gegenueber last_seen, last_message_type,
--                      role, label, proto_ver und die Entprellzaehler, bei
--                      acht Knoten rund 1,3 KB je Status.
--   alerts             Das sind die Alarme, die MASTER dem Knoten geschickt
--                      hat, unveraendert zurueckgespiegelt. MASTER liest
--                      seine eigenen Alarme nicht zurueck.
--
-- Was bleibt, und wer es braucht:
--   node_id, role      master/message_handlers.lua leitet daraus die Rolle
--                      ab, services/comms_service.lua baut daraus seinen
--                      Dedup-Schluessel
--   health             MASTERs Gesundheitsanzeige und Alarmregeln
--   master_connected   nodes/fuel/ui_completion.lua
--   protocol_mismatch  nodes/fuel/ui_completion.lua
--   registry           master/ui/resources.lua (nur .summary -- die
--                      Geraeteliste selbst geht seit v781 nicht mehr raus)
--   queue              MASTERs Diagnoseseite
--   last_command,      MASTERs Diagnoseseite
--   last_command_ts

local M = {}

function M.build_base(args)
  return {
    node_id = args.node_id,
    role = args.role,
    health = args.health,
    master_connected = args.master_connected,
    registry = args.registry,
    queue = args.queue,
    protocol_mismatch = args.protocol_mismatch,
    last_command = args.last_command,
    last_command_ts = args.last_command_ts
  }
end

return M
