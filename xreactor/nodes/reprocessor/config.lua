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
  -- Control rails tuning (shared defaults for RT nodes).
  DEFAULT_RAILS = {
    ramp_profiles = {
      NORMAL = { up = 1.0, down = 1.0 },
      SLOW = { up = 0.5, down = 0.5 },
      FAST = { up = 1.5, down = 1.5 }
    },
    turbine_flow = {
      deadband_up = 20,
      deadband_down = 20,
      hysteresis_up = 10,
      hysteresis_down = 10,
      max_step_up = 50,
      max_step_down = 50,
      cooldown_s = 1.0,
      min = 200,
      max = 1900,
      ema_alpha = 0.2
    },
    reactor_rods = {
      deadband_up = 5000,
      deadband_down = 5000,
      hysteresis_up = 500,
      hysteresis_down = 500,
      max_step_up = 5,
      max_step_down = 5,
      cooldown_s = 1.5,
      min = 0,
      max = 98,
      ema_alpha = 0.25
    },
    coil = {
      engage_rpm = 850,
      disengage_rpm = 750,
      cooldown_s = 1.0,
      ema_alpha = 0.2
    }
  },
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
    waste_item         = "bigreactors:cyanite_ingot",
    feed_amount        = 2,      -- Items pro Befüllung (Minimum zum Arbeiten)
    interval_min_s     = 20,     -- Mindest-Wartezeit zwischen Befüllungen
    interval_max_s     = 60,     -- Höchst-Wartezeit zwischen Befüllungen (zufällig dazwischen)
    valve_open_ms       = 2000,  -- Wie lange das Ventil offen bleibt
    discovery_interval = 60,
    --
    -- targets: eine Eintrag pro Reprocessor-Inlet (kein reactor_port nötig!)
    --   label = Anzeigename
    --   inlet = Transporter/Chest direkt am Reprocessor-Eingang
    -- { label = "Reprocessor A", inlet = "mekanism:transporter_2" },
    targets            = {},
    --
    -- redstone_tree: gleiches Format wie bei der Fuel-Node (siehe
    -- nodes/fuel/config.lua) -- eine flache Route pro Ziel mit geordnetem
    -- 'path'. Mekanism Pipes müssen auf "High Redstone = Interrupt" stehen.
    -- { reactor = "Reprocessor A", label = "Reprocessor A",
    --   path = { { side = "right" }, { side = "top" } } },
    -- { reactor = "Reprocessor B", label = "Reprocessor B",
    --   path = { { side = "right" }, { side = "bottom" } } },
    --   -- ^ "right" ist hier ein gemeinsames Trunk-Ventil ("Arm A") vor
    --   -- beiden Reprocessor-Zweigen -- einfach in beiden Pfaden
    --   -- wiederholt, keine Verschachtelung noetig.
    -- Hinweis: "reactor"-Feld referenziert hier den target.label.
    redstone_tree      = {},
  },
}
-- Fix (2026-07-13): CRITICAL (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Punkt 28.1, identischer Fund wie bei
-- nodes/fuel/config.lua). "rails = CONFIG.DEFAULT_RAILS" und
-- "feed = CONFIG.DEFAULT_FEED" standen bisher INNERHALB von CONFIG's
-- eigenem Tabellenkonstruktor -- CONFIG war zu diesem Zeitpunkt noch
-- nicht zugewiesen, ein Zugriff darauf waere ein Laufzeitfehler
-- gewesen. Zusaetzlich fehlte "return" komplett -- diese Datei war
-- dadurch, wie bei FUEL, vollstaendig wirkungslos, egal was
-- hineingeschrieben wurde. Jetzt als separate Zuweisungen nach dem
-- Tabellenkonstruktor, plus "return CONFIG" am Ende.
CONFIG.rails = CONFIG.DEFAULT_RAILS
CONFIG.feed  = CONFIG.DEFAULT_FEED
return CONFIG
