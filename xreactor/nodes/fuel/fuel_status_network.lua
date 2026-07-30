-- nodes/fuel/fuel_status_network.lua
--
-- Feature (2026-07-09): Modularisierungs-Rewrite. Buendelt alles rund um
-- den netzwerkbasierten Reaktor-Fuellstand (siehe Kommentar-Historie in
-- logistics_router.lua: FUEL hat keinen Wired-Modem-Zugriff auf die
-- Reaktoren, nur aufs ME-System) an einer Stelle:
--   1. Der Cache selbst (master_relay + direct_heard, je [reactor_id] = {..}).
--   2. Ingestion von Master-Relay-Daten (via FUEL_STATUS-Kommando, siehe
--      command_handler.lua's on_fuel_status-Callback).
--   3. Der Fallback-Listener-Service, der RT->Master Status-Broadcasts
--      direkt mithoert (falls Master laengere Zeit nicht relayed hat).
--
-- logistics_router.lua konsumiert den Cache weiterhin selbst (liest
-- master_relay/direct_heard direkt, waehlt die juengere Quelle) -- dieses
-- Modul ist nur fuer die BEFUELLUNG des Caches zustaendig, nicht fuer den
-- Lesezugriff beim Beliefern.

local M = {}

function M.new()
  return {
    master_relay = {},   -- [reactor_id] = { fuel_amount, fuel_capacity, ts }
    direct_heard = {},   -- [reactor_id] = { fuel_amount, fuel_capacity, ts }
  }
end

-- Wird vom command_handler.lua aufgerufen, wenn ein FUEL_STATUS-Kommando
-- von Master ankommt (siehe master/fuel_relay.lua fuer die Gegenseite).
-- value = { [reactor_id] = { fuel_amount, fuel_capacity, label, source_node, ts, source_age_ms } }
function M.ingest_master_relay(cache, value)
  if type(value) ~= "table" then return end
  local now = os.epoch("utc")
  for reactor_id, entry in pairs(value) do
    if type(entry) == "table" then
      -- Fix (2026-07-13): CRITICAL (MASTER-P1.2, siehe docs/CODING_AI_
      -- OTHER_NODES_PERFORMANCE_2026-07-12.md). Bisher wurde hier IMMER
      -- die lokale Empfangszeit als ts verwendet -- das schuetzte zwar
      -- vor Uhrenabweichungen zwischen den Computern, ignorierte aber
      -- komplett, WIE ALT die zugrunde liegende RT-Messung tatsaechlich
      -- war (Master hat das bisher selbst falsch gemeldet, siehe
      -- master/fuel_relay.lua-Fix vom selben Datum). Jetzt: Master sendet
      -- source_age_ms (eine reine ZEITSPANNE, komplett auf Masters
      -- eigener Uhr berechnet, kein Abgleich zweier absoluter Uhren
      -- noetig) -- ts wird daraus lokal verankert ("now - source_age_ms"),
      -- damit ein laengst ausgefallener RT-Node NICHT mehr beliebig lange
      -- als "gerade frisch gemessen" erscheint, waehrend der urspruengliche
      -- Schutz vor Uhrenabweichungen (kein direkter Vergleich von Masters
      -- absolutem Zeitstempel gegen FUELs eigene Uhr) vollstaendig erhalten
      -- bleibt.
      local age_ms = tonumber(entry.source_age_ms) or 0
      cache.master_relay[reactor_id] = {
        fuel_amount = entry.fuel_amount,
        fuel_capacity = entry.fuel_capacity,
        ts = now - age_ms,
      }
    end
  end
end

-- Fallback-Pfad: RT->Master Status-Broadcasts direkt mithoeren, falls
-- Master laengere Zeit nicht relayed hat (z.B. Master-Ausfall). Der
-- STATUS-Kanal ist auf jedem Node ohnehin schon geoeffnet (siehe
-- core/network.lua open_modem()) — hier wird er zusaetzlich passiv
-- mitgehoert, ohne selbst etwas zu senden.
function M.make_overhear_service(cache, constants)
  return { name = "fuel_status_overhear", wants_events = true, tick = function(_self, dt, event)
    if not (event and event[1] == "modem_message") then return end
    local message = event[5]
    if type(message) ~= "table" then return end
    if message.type ~= constants.message_types.STATUS then return end
    if message.role ~= constants.roles.RT_NODE then return end
    local reactors = message.payload and message.payload.reactors
    if type(reactors) ~= "table" then return end
    local now = os.epoch("utc")
    for _, r in ipairs(reactors) do
      if type(r) == "table" and r.id and (r.fuel_amount ~= nil or r.fuel_capacity ~= nil) then
        cache.direct_heard[r.id] = {
          fuel_amount = r.fuel_amount,
          fuel_capacity = r.fuel_capacity,
          ts = now,
        }
      end
    end
  end }
end

return M
