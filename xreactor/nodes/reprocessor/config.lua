-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "REPROCESSOR-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "REPROC-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = nil, -- Autodetect wireless modem unless explicitly configured.
  DEFAULT_BUFFERS = { "chemical_tank_0" }, -- Default buffer peripheral names.
  DEFAULT_HEARTBEAT_INTERVAL = 2, -- Seconds between status heartbeats.
  DEFAULT_DISCOVERY_INTERVAL = 15, -- Seconds between discovery rescans.
  DEFAULT_STATUS_INTERVAL = 5, -- Seconds between status payloads.
  DEFAULT_CONTROL_CHANNEL = 6500, -- Control channel for MASTER commands.
  DEFAULT_STATUS_CHANNEL = 6501, -- Status channel for telemetry.
  DEFAULT_COMMS_ACK_TIMEOUT = 3.0, -- Seconds before retrying a command.
  DEFAULT_COMMS_MAX_RETRIES = 4, -- Maximum retries per message.
  DEFAULT_COMMS_BACKOFF_BASE = 0.6, -- Base backoff seconds.
  DEFAULT_COMMS_BACKOFF_CAP = 6.0, -- Max backoff seconds.
  DEFAULT_COMMS_DEDUPE_TTL = 30, -- Seconds to keep dedupe entries.
  DEFAULT_COMMS_DEDUPE_LIMIT = 200, -- Max dedupe entries per peer.
  DEFAULT_COMMS_PEER_TIMEOUT = 12.0, -- Seconds before marking peer down.
  DEFAULT_COMMS_QUEUE_LIMIT = 200, -- Max queued outbound messages.
  DEFAULT_COMMS_DROP_SIMULATION = 0, -- Drop rate (0-1) for testing comms.
  DEFAULT_DEBUG_LOGGING = false, -- Enable debug logging to /xreactor_logs/reprocessor.log.
  DEFAULT_RESET_LOG_ON_START = true, -- Truncate runtime log at startup to keep disk usage bounded.
  -- Feed-Logik für die REPROCESSOR-Node.
  --
  -- Reprocessoren haben KEINEN eigenen Computer-Port — der Füllstand kann
  -- nicht direkt abgefragt werden. Statt Füllstand-basiertem Nachfüllen wird
  -- in zufälligen Abständen reihum jeder Reprocessor mit genau
  -- feed_amount (Standard 2) Cyanite befüllt — das Minimum damit der
  -- Reprocessor überhaupt arbeitet.
  --
  DEFAULT_FEED = {
    enabled            = false,
    me_bridge          = "me_bridge",
    -- Logistical Sorter, dessen Default-Farbe pro Feed auf die des
    -- aktuellen Ziels gesetzt wird (adapters/logistical_sorter.lua).
    -- Leer/Name nicht gefunden -> Fallback-Suche per Methodensignatur,
    -- genau wie bei me_bridge.
    sorter             = "logistical_sorter_0",
    -- Gemeinsamer Export-Eingang (Sorter-Seite) -- ALLE Exporte gehen
    -- hierher, die Sorter-Farbe entscheidet, welcher farbige Logistical
    -- Transporter das Item danach zum jeweiligen Reprocessor traegt.
    export_inlet       = "mekanism:logistical_transporter_0",
    waste_item         = "bigreactors:cyanite_ingot",
    feed_amount        = 2,      -- Items pro Befüllung (Minimum zum Arbeiten)
    interval_min_s     = 20,     -- Mindest-Wartezeit zwischen Befüllungen
    interval_max_s     = 60,     -- Höchst-Wartezeit zwischen Befüllungen (zufällig dazwischen)
    discovery_interval = 60,
    --
    -- targets: ein Eintrag pro Reprocessor
    --   label = Anzeigename
    --   color = Sorter-Farbe fuer diesen Reprocessor (Mekanism EnumColor,
    --           siehe adapters/logistical_sorter.lua's COLORS) -- per
    --           Router-UI zuweisbar (nodes/reprocessor/color_router_ui.lua)
    -- { label = "Reprocessor A", color = "RED" },
    targets            = {},
    -- chest: optionale zweite Sammel-Kiste fuer rohes Cyanit, unabhaengig
    -- von der Reprocessor-Rotation oben -- eigener An/Aus-Schalter + eigene
    -- Sorter-Farbe, per Router-UI einstellbar
    -- (nodes/reprocessor/color_router_ui.lua). Laeuft auf ihrem eigenen
    -- zufaelligen Intervall, unabhaengig davon ob/wann Reprocessoren
    -- befuellt werden.
    chest = {
      enabled = false,
      color   = nil,
    },
  },
}
-- "feed" muss als separate Zuweisung NACH dem CONFIG-Tabellenkonstruktor
-- stehen (CONFIG ist innerhalb des Konstruktors selbst noch nicht
-- zugewiesen).
CONFIG.feed  = CONFIG.DEFAULT_FEED
return CONFIG
