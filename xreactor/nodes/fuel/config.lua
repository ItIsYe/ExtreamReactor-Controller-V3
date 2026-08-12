-- CONFIG
local CONFIG = {
  DEFAULT_ROLE = "FUEL-NODE", -- Node role identifier.
  DEFAULT_NODE_ID = "FUEL-1", -- Default node_id used if none is set.
  DEFAULT_WIRELESS_MODEM = nil, -- Autodetect wireless modem unless explicitly configured.
  DEFAULT_STORAGE_BUS = "meBridge_0", -- Default storage bus peripheral name.
  DEFAULT_TARGET = 2000, -- Default fuel reserve target.
  DEFAULT_MINIMUM_RESERVE = 2000, -- Minimum reserve used for safety.
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
  DEFAULT_DEBUG_LOGGING = false, -- Enable debug logging to /xreactor_logs/fuel.log.
  DEFAULT_RESET_LOG_ON_START = true, -- Truncate runtime log at startup to keep disk usage bounded.
  -- Logistics routing for the FUEL node.
  --
  -- Each reactor has its OWN entry. Fix (2026-07-08): FUEL has NO Wired
  -- Modem link to the reactors themselves, only to the ME system — fuel
  -- levels come via network (Master relay, with a direct-overhear
  -- fallback if Master is down; see nodes/fuel/logistics_router.lua and
  -- master/fuel_relay.lua). Only exports fuel to the reactor that is
  -- actually requesting it, prioritized by lowest fuel level first when
  -- multiple reactors request simultaneously.
  --
  -- Hardware (FUEL computer must have):
  --   Wired Modem → ME Bridge + each reactor's dedicated inlet transporter/chest
  --   Wireless Modem → MASTER communication + reactor fuel-level relay
  --   (Redstone valve control, if used: see nodes/valve/main.lua — those
  --   are separate standalone computers on their own dedicated channel,
  --   not wired to this computer at all.)
  --
  DEFAULT_LOGISTICS = {
    enabled            = false,
    interval           = 5,       -- seconds between supply checks (short for responsiveness)
    discovery_interval = 60,
    me_bridge          = "me_bridge",   -- AP 1.21.1+; "meBridge" on older
    --
    -- reactors: one entry per reactor.
    --   reactor_id    = ID of the reactor as reported by its RT node's status
    --                   (Fix 2026-07-08: FUEL has no Wired Modem link to the
    --                   reactor itself, only to the ME system — fuel level
    --                   comes via network relay from Master, see
    --                   master/fuel_relay.lua, not a local peripheral read.
    --                   Check the RT node's own log/dashboard for the exact
    --                   reactor id string it reports.)
    --   inlet         = where to deliver fuel (transporter or chest — must be dedicated
    --                   to THIS reactor; no shared pipes for targeted delivery)
    --   item          = fuel item name
    --   request_below = fuel ratio below which reactor requests resupply (0.0–1.0)
    --   fill_amount   = how many items to export per resupply event
    --   min_in_me     = minimum ME stock to maintain (never export below this)
    --
    -- Example (two reactors, RT-reported fuel level, ME-connected delivery):
    -- { name          = "Reaktor A",
    --   reactor_id    = "node-52-reactor-0",
    --   inlet         = "mekanism:ultimate_logistical_transporter_0",
    --   item          = "bigreactors:yellorium_ingot",
    --   request_below = 0.25,
    --   fill_amount   = 64,
    --   min_in_me     = 128 },
    -- { name          = "Reaktor B",
    --   reactor_id    = "node-52-reactor-1",
    --   inlet         = "mekanism:ultimate_logistical_transporter_1",
    --   item          = "bigreactors:yellorium_ingot",
    --   request_below = 0.25,
    --   fill_amount   = 64,
    --   min_in_me     = 128 },
    reactors           = {},
    --
    -- waste: peripheral(s) where reactor waste arrives — CC drains into ME.
    -- { name = "Reaktor A Waste", outlet = "mekanism:ultimate_logistical_transporter_2" },
    waste              = {},
    --
    -- redstone_tree: one route per reactor, each with an ORDERED list of
    -- valves ("path") that must be blocked/opened together for that
    -- reactor's export. Pipe must be configured: "High Redstone =
    -- Interrupt" in Mekanism. CC blocks ALL known valves, then opens ONLY
    -- the target reactor's own path.
    --
    -- Fix (2026-07-19): this used to be a NESTED tree (side/children) --
    -- the only way to express multiple valves in series (e.g. one shared
    -- trunk valve before several reactor-specific branch valves) was to
    -- nest a valve's 'children'. That is still understood automatically
    -- (see nodes/fuel/redstone_router.lua's normalize_tree()), but the
    -- CURRENT, simpler format is a flat list: repeat the SAME
    -- {side=,integrator=} step in more than one reactor's path to express
    -- a shared valve -- no nesting needed. The in-game Router page (4/4,
    -- EDIT tab) builds exactly this format: pick a reactor, then tap
    -- valves one at a time to build its chain.
    --
    -- path[i].side: built-in CC side (top/bottom/left/right/front/back) --
    --   this is the side on the FUEL computer itself (direct redstone) OR,
    --   if 'integrator' is set, the side on THAT integrator/VALVE node.
    -- path[i].integrator (optional): identifies a separate valve
    --   controller.
    --   Fix (2026-07-09): in this setup the "integrator" is itself a small
    --   standalone CC:Tweaked computer sitting at the valve (role VALVE,
    --   see nodes/valve/main.lua) -- it has no Wired Modem to FUEL, only
    --   a Wireless Modem, and is addressed by its node_id (auto-discovered
    --   once it's online and broadcasting, see redstone_router.lua
    --   refresh()). Set integrator = "<valve node_id>" here, e.g.
    --   "VALVE-1" (check the VALVE node's own boot log for its assigned
    --   node_id). A local Mekanism Redstone Integrator peripheral (wired
    --   directly to FUEL) also still works as a fallback if the name
    --   doesn't match a known VALVE node_id.
    -- valve_open_ms: how long to keep valve open after export (default 2000ms)
    --
    -- { reactor = "RT-1", label = "Reaktor A", path = { { side = "right" } } },
    -- { reactor = "RT-2", label = "Reaktor B", path = { { side = "left" } } },
    -- { reactor = "RT-3", label = "Reaktor C",
    --   path = { { side = "back" }, { side = "front", integrator = "VALVE-1" } } },
    --   -- ^ two valves in series: a shared trunk valve ("back", local to
    --   -- FUEL) plus Reaktor C's own branch valve on VALVE-1. Repeating
    --   -- { side = "back" } as the first step of another reactor's path
    --   -- means that reactor shares the same trunk valve.
    redstone_tree      = {},
    valve_open_ms      = 2000,
  },
}
-- Fix (2026-07-13): CRITICAL (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Punkt 28.1). "logistics = CONFIG.DEFAULT_LOGISTICS" stand bisher INNERHALB
-- von CONFIG's eigenem Tabellenkonstruktor -- zu diesem Zeitpunkt ist
-- die lokale Variable "CONFIG" noch nicht zugewiesen (klassische Lua-
-- Falle: die Zuweisung passiert erst, wenn der GESAMTE rechte Ausdruck
-- fertig ausgewertet ist), ein Zugriff darauf waere ein Laufzeitfehler
-- ("attempt to index a nil value") gewesen, sobald diese Datei je
-- tatsaechlich ausgefuehrt wurde. Da bisher zusaetzlich kein "return"
-- existierte (siehe Fix weiter unten), wurde dieser Fehler nie sichtbar
-- -- niemand hat diese Datei je erfolgreich geladen. Jetzt als separate
-- Zuweisungen NACH dem Tabellenkonstruktor, wenn CONFIG bereits
-- existiert.
CONFIG.logistics = CONFIG.DEFAULT_LOGISTICS
-- Fix (2026-07-13): CRITICAL (siehe docs/CODING_AI_OTHER_NODES_
-- PERFORMANCE_2026-07-12.md, Punkt 28.1). Diese Datei hatte bisher
-- UEBERHAUPT KEIN "return" -- dofile()/require() darauf lieferte
-- dadurch immer nil statt der Config-Tabelle zurueck. utils.load_config()
-- faellt in diesem Fall (data ist kein table) still auf DEFAULT_CONFIG
-- zurueck -- diese ganze Datei war dadurch WIRKUNGSLOS, egal was
-- hineingeschrieben wurde. Betraf auch die GLOBAL-P0-Migration (siehe
-- main.lua): die kopiert den ROHEN TEXT dieser Datei unveraendert in die
-- neue geschuetzte Nutzerdatei -- ohne dieses "return" waere auch die
-- MIGRIERTE Datei dauerhaft wirkungslos geblieben, trotz korrekt
-- geschuetztem Pfad.
return CONFIG
