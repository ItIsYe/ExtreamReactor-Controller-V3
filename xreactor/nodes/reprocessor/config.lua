-- CONFIG
--
-- REPROCESSOR-Node: befuellt mehrere Reprocessor-Maschinen mit Cyanite
-- ueber einen gemeinsamen Mekanism Logistical Sorter (siehe feed_router.lua
-- fuer die volle Erklaerung des physischen Aufbaus). Kein Ventil-Baum, kein
-- eigener Computer-Anschluss an den Reprocessor-Maschinen selbst -- alles
-- laeuft passiv ueber farbige Logistical Transporter.
local CONFIG = {
  DEFAULT_ROLE = "REPROCESSOR-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "REPROC-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = nil, -- Autodetect wireless modem unless explicitly configured.
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
  -- Feed-Logik fuer die REPROCESSOR-Node.
  --
  -- Reprocessoren haben KEINEN eigenen Computer-Port -- der Fuellstand kann
  -- nicht direkt abgefragt werden. Statt Fuellstand-basiertem Nachfuellen
  -- wird in zufaelligen Abstaenden reihum jeder Reprocessor mit genau
  -- feed_amount (Standard 2) Cyanite befuellt -- das Minimum damit der
  -- Reprocessor ueberhaupt arbeitet.
  --
  DEFAULT_FEED = {
    enabled            = false, -- Muss im Router-UI ("FEEDING") explizit eingeschaltet werden.
    me_bridge          = "me_bridge",
    -- Logistical Sorter, dessen Default-Farbe pro Feed auf die des
    -- aktuellen Ziels gesetzt wird (adapters/logistical_sorter.lua).
    -- Leer/Name nicht gefunden -> Fallback-Suche per Methodensignatur,
    -- genau wie bei me_bridge.
    sorter             = nil,
    -- sorter_chest: die SORTER-KISTE -- die eine Kiste, an der der Sorter
    -- physisch sitzt (ME-Bridge-Exportziel). Kein Default -- muss ueber
    -- das Router-UI gewaehlt werden (siehe config_normalizer.lua's Warnung).
    sorter_chest       = nil,
    waste_item         = "bigreactors:cyanite_ingot",
    feed_amount        = 2,      -- Items pro Befuellung (Minimum zum Arbeiten)
    interval_min_s     = 20,     -- Mindest-Wartezeit zwischen Befuellungen
    interval_max_s     = 60,     -- Hoechst-Wartezeit zwischen Befuellungen (zufaellig dazwischen)
    discovery_interval = 60,
    --
    -- targets: ein Eintrag pro Reprocessor
    --   label = Anzeigename
    --   color = Sorter-Farbe fuer diesen Reprocessor (Mekanism EnumColor,
    --           siehe adapters/logistical_sorter.lua's COLORS) -- per
    --           Router-UI zuweisbar (nodes/reprocessor/color_router_ui.lua)
    -- { label = "Reprocessor A", color = "RED" },
    targets            = {},
  },
}
-- "feed" muss als separate Zuweisung NACH dem CONFIG-Tabellenkonstruktor
-- stehen (CONFIG ist innerhalb des Konstruktors selbst noch nicht
-- zugewiesen).
CONFIG.feed  = CONFIG.DEFAULT_FEED
return CONFIG
