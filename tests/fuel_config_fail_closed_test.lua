package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Fail-closed der FUEL-Logistik.
--
-- GEAENDERT (2026-09-25, auf Ansage des Betreibers): frueher legte EIN
-- unbrauchbarer Reaktor-Eintrag die Belieferung ALLER Reaktoren stiil --
-- logistics.enabled wurde global auf false gesetzt. Auf einer Anlage mit
-- vielen konfigurierten und wenigen laufenden Reaktoren ist ein Eintrag
-- ohne reactor_id der Normalfall (die Identitaet lernt der Knoten erst
-- aus der RT-Statusmeldung), und die ganze Anlage stand still, ohne dass
-- es irgendwo ablesbar war.
--
-- Fail-closed gilt unveraendert, nur enger gefasst:
--   * ein unbrauchbarer EINTRAG wird stillgelegt (r.disabled_reason) und
--     nie beliefert -- insbesondere faellt er NICHT in den
--     Always-Supply-Modus, der ohne reactor_id greifen wuerde;
--   * fehlt eine GLOBALE Voraussetzung (der gemeinsame Uebergabepunkt
--     export_chest), bleibt alles aus.
--
-- Die Zusicherung "ein kaputter Eintrag wird niemals beliefert" ist die
-- eigentliche Sicherheitseigenschaft -- sie steht hier jetzt explizit,
-- statt sich hinter dem globalen Schalter zu verstecken.

local normalizer = require('nodes.fuel.config_normalizer')
local utils = require('core.utils')
local function assert_true(v, m) if not v then error(m or 'assert_true failed') end end

local defaults = {
  role = 'FUEL-NODE', node_id = 'FUEL-1', heartbeat_interval = 2,
  status_interval = 5, channels = { control = 6500, status = 6501 }, comms = {},
  storage_bus = 'meBridge_0', minimum_reserve = 32, target = 32,
  logistics = {
    enabled = false, interval = 5, discovery_interval = 60, max_per_cycle = 64,
    me_bridge = 'me_bridge', export_chest = 'chest_0', reactors = {}, waste = {}, redstone_tree = {},
    valve_open_ms = 2000, sources = {}, destinations = {}, routes = {}
  }
}

local function normalize(cfg)
  local warnings = {}
  normalizer.normalize(cfg, defaults, function(w) warnings[#warnings + 1] = w end, utils)
  return warnings
end

local function with(reactors, mutate)
  local cfg = utils.deep_copy(defaults)
  cfg.logistics.enabled = true
  cfg.logistics.reactors = reactors
  if mutate then mutate(cfg) end
  return cfg
end

-- ── 1. Eintrag ohne reactor_id: stillgelegt, nicht always-supply ─────────

do
  local cfg = with({ { name = 'A', fill_amount = 64, min_in_me = 32 } })
  local warnings = normalize(cfg)

  assert_true(cfg.logistics.reactors[1].disabled_reason ~= nil,
    'ein Eintrag ohne reactor_id MUSS stillgelegt werden -- sonst liefe er in den'
      .. ' Always-Supply-Modus und bekaeme Brennstoff ohne bekannten Fuellstand')

  local saw = false
  for _, w in ipairs(warnings) do
    if tostring(w):find('reactor_id', 1, true) then saw = true end
  end
  assert_true(saw, 'und der Betreiber muss den Grund erfahren')
end

-- ── 2. Ein kaputter Eintrag legt die uebrigen NICHT still ────────────────
--
-- Der eigentliche Punkt der Aenderung.

do
  local cfg = with({
    { name = 'A', fill_amount = 64, min_in_me = 32 },                -- kaputt
    { reactor_id = 'node-1:REACTOR-abcd', request_below = 0.25,
      fill_amount = 64, min_in_me = 32 },                            -- gut
  })
  normalize(cfg)

  assert_true(cfg.logistics.enabled == true,
    'ein einzelner unbrauchbarer Eintrag darf die Logistik NICHT global abschalten')
  assert_true(cfg.logistics.reactors[1].disabled_reason ~= nil, 'der kaputte ist stillgelegt')
  assert_true(cfg.logistics.reactors[2].disabled_reason == nil,
    'der gute Eintrag bleibt unangetastet und wird weiter beliefert')
end

-- ── 3. Jeder ungueltige Wert legt seinen Eintrag stiil ───────────────────

do
  for _, case in ipairs({
    { field = 'request_below',      value = 1.2 },
    { field = 'fill_amount',        value = -5 },
    { field = 'min_in_me',          value = -1 },
    { field = 'resupply_cooldown_s', value = -3 },
    { field = 'path',               value = 'nicht-eine-liste' },
  }) do
    local entry = { reactor_id = 'node-1:REACTOR-abcd', request_below = 0.25,
      fill_amount = 64, min_in_me = 32 }
    entry[case.field] = case.value
    local cfg = with({ entry })
    normalize(cfg)
    assert_true(cfg.logistics.reactors[1].disabled_reason ~= nil,
      case.field .. '=' .. tostring(case.value) .. ' muss den Eintrag stilllegen')
  end
end

-- ── 4. Fehlende GLOBALE Voraussetzung schaltet weiterhin alles ab ────────
--
-- Ohne gemeinsamen Uebergabepunkt gibt es nichts, wohin exportiert werden
-- koennte -- das ist keine Eigenschaft eines einzelnen Reaktors.

do
  local cfg = with({
    { reactor_id = 'node-1:REACTOR-abcd', request_below = 0.25,
      fill_amount = 64, min_in_me = 32 },
  }, function(c) c.logistics.export_chest = nil end)
  normalize(cfg)
  assert_true(cfg.logistics.enabled == false,
    'ohne export_chest bleibt die Logistik komplett aus')
end

-- ── 5. Eine saubere Konfiguration bleibt an ──────────────────────────────

do
  local cfg = with({
    { reactor_id = 'node-1:REACTOR-abcd', request_below = 0.25,
      fill_amount = 64, min_in_me = 32 },
  })
  normalize(cfg)
  assert_true(cfg.logistics.enabled == true, 'valid logistics config must remain enabled')
  assert_true(cfg.logistics.reactors[1].disabled_reason == nil, 'und kein Eintrag stillgelegt')
end

print('fuel_config_fail_closed_test.lua: ok')
