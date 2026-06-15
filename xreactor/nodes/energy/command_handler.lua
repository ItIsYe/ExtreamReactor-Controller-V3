-- Energy-Node empfängt keine Commands vom Master.
-- Design-Entscheidung: Energy sendet nur Telemetrie (Status-Payload + Heartbeat).
-- handle_message() verarbeitet weiterhin eingehende Status-Nachrichten vom Master
-- (PROTO_MISMATCH, Master-Alerts) — aber keine COMMAND-Pakete.
local M = {}

function M.new(opts)
  opts = opts or {}
  local constants = assert(opts.constants, "constants required")
  local mark_master_seen = opts.mark_master_seen
  local on_master_alerts = opts.on_master_alerts
  local on_proto_mismatch = opts.on_proto_mismatch

  local handler = {}

  -- handle_message: verarbeitet Status-Nachrichten vom Master.
  -- Keine Command-Verarbeitung — Energy ist rein sendend.
  function handler.handle_message(message)
    if message.type == constants.message_types.ERROR
        and message.payload
        and message.payload.code == "PROTO_MISMATCH" then
      if on_proto_mismatch then on_proto_mismatch() end
      return
    end
    if message.role == constants.roles.MASTER then
      if mark_master_seen then mark_master_seen() end
      if message.type == constants.message_types.STATUS
          and message.payload
          and message.payload.alerts
          and on_master_alerts then
        on_master_alerts(message.payload.alerts)
      end
    end
  end

  return handler
end

return M
