-- Nur .version wird tatsaechlich gelesen (services/telemetry_service.lua
-- stempelt es als payload.meta.schema_version). Ein frueheres .base/.roles
-- Feldverzeichnis wurde nirgends konsumiert und war laengst veraltet (z.B.
-- fehlte WATER.clusters komplett, FUEL listete nur 1 von ~8 echten
-- Top-Level-Feldern) -- entfernt statt gepflegt, da niemand es liest.
local telemetry_schema = {
  version = 1,
}

return telemetry_schema
