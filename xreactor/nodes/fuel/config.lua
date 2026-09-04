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
  -- Each reactor has its OWN entry. FUEL has NO Wired Modem link to the
  -- reactors themselves, only to the ME system — fuel levels come via
  -- network (Master relay, with a direct-overhear fallback if Master is
  -- down; see nodes/fuel/logistics_router.lua and master/fuel_relay.lua).
  -- Only exports fuel to the reactor that is actually requesting it,
  -- prioritized by lowest fuel level first when multiple reactors request
  -- simultaneously.
  --
  -- Hardware (FUEL computer must have):
  --   Wired Modem → ME Bridge + the ONE shared export_chest (see below)
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
    -- export_chest: the ONE physical hand-off point every delivery, for
    -- every reactor, exports into -- e.g. "mekanism:ultimate_logistical_
    -- transporter_0". There is no per-reactor delivery target. A Mekanism
    -- logistics network (sorters + VALVE-Nodes) carries everything
    -- downstream from this single chest; which reactor a given delivery
    -- actually reaches is decided purely by which valves are open at
    -- export time (redstone_router.lua blocks every other route before
    -- opening the target reactor's own `path`, see below, and only then
    -- runs the export).
    export_chest       = nil,
    --
    -- reactors: one entry per reactor. reactor_id and label are learned
    -- from the owning RT node's own broadcasts (router_ui.lua's reactor-
    -- teach flow), never typed by hand -- the FUEL router page lists every
    -- currently-broadcasting RT reactor by its real name; tapping one
    -- takes over its reactor_id/label here.
    --   reactor_id    = ID of the reactor as reported by its RT node's status
    --                   (fuel level comes via network relay from Master, see
    --                   master/fuel_relay.lua, not a local peripheral read.)
    --   label         = the reactor's real display name, as reported by RT.
    --   path          = ordered list of VALVE-Node ids to open for this
    --                   reactor's delivery (see redstone_tree note below —
    --                   this is the only place a route is configured; FUEL
    --                   derives the topology redstone_router.lua consumes
    --                   from this field automatically).
    --   request_below = fuel ratio below which reactor requests resupply (0.0–1.0)
    --   fill_amount   = how many ingot-equivalent items to export per resupply event
    --   min_in_me     = minimum ME stock to maintain (never export below this)
    --
    -- No `item` field: FUEL decides Uranium vs Blutonium, and Ingot vs
    -- Block, automatically on every delivery, based on which currently has
    -- more ME stock (see logistics_router.lua's build_fuel_families()/
    -- pick_fuel_family()/pick_fuel_form(), fed by config.reserve_items).
    --
    -- Example (export_chest + two reactors, RT-reported fuel level):
    -- export_chest = "mekanism:ultimate_logistical_transporter_0",
    -- reactors = {
    -- { reactor_id    = "node-52-reactor-0",
    --   label         = "Reaktor A",
    --   path          = { "VALVE-1" },
    --   request_below = 0.25,
    --   fill_amount   = 64,
    --   min_in_me     = 128 },
    -- { reactor_id    = "node-52-reactor-1",
    --   label         = "Reaktor B",
    --   path          = { "VALVE-2" },
    --   request_below = 0.25,
    --   fill_amount   = 64,
    --   min_in_me     = 128 },
    -- }
    reactors           = {},
    --
    -- waste: peripheral(s) where reactor waste arrives — CC drains into ME.
    -- { name = "Reaktor A Waste", outlet = "mekanism:ultimate_logistical_transporter_2" },
    waste              = {},
    --
    -- redstone_tree: NOT hand-configured. logistics_router.lua's
    -- refresh_peripherals() rebuilds it automatically, every refresh, from
    -- each entry in `reactors` above (reactor_id + label + path) -- this
    -- key only exists so redstone_router.lua (shared with
    -- nodes/reprocessor/feed_router.lua, which manages its own, unrelated
    -- redstone_tree) has something to consume; whatever is written here
    -- directly is overwritten on the next refresh.
    --
    -- path[i]: the node_id of a VALVE-Node (a small standalone CC:Tweaked
    --   computer sitting at the valve, role VALVE, see nodes/valve/main.lua)
    --   -- it has no Wired Modem to FUEL, only Wireless, addressed by its
    --   node_id (auto-discovered once online). Pipe must be configured:
    --   "High Redstone = Interrupt" in Mekanism. CC blocks ALL known
    --   valves, then opens ONLY the target reactor's own path. Repeating
    --   the same VALVE id in more than one reactor's path expresses a
    --   shared trunk valve -- no nesting needed.
    -- valve_open_ms: how long to keep valve open after export (default 2000ms)
    redstone_tree      = {},
    valve_open_ms      = 2000,
  },
}
-- Muss NACH dem Tabellenkonstruktor stehen -- CONFIG existiert innerhalb
-- des eigenen Konstruktors noch nicht (klassische Lua-Falle).
CONFIG.logistics = CONFIG.DEFAULT_LOGISTICS
return CONFIG
