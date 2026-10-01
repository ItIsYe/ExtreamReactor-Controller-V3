package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- "FUEL laedt die eingestellten Ruten nicht" -- zum dritten Mal gemeldet.
--
-- Dieser Test bootet die ECHTE FUEL-Node (nodes/fuel/main.lua, mit ihrem
-- eigenen Bootstrap, Config-Laden und Normalisieren) gegen eine
-- vorgegebene /xreactor_config/fuel_routes.lua und haelt fest, was dabei
-- herauskommt. Vorher gab es dafuer keinen Test: die Routen werden in einem
-- Boot-Skript geladen, und ein Boot-Skript laesst sich nicht require()n.
--
-- Was der Boot zeigt -- vier Lagen, die der Betreiber NICHT unterscheiden
-- konnte, weil alle vier dasselbe ergaben (eine Anlage, die nichts tut):
--
--   A  alles gesetzt, Schalter AUS   -> Routen geladen, wirkungslos
--   B  alles gesetzt, Schalter AN    -> laeuft
--   C  export_chest fehlt            -> Logistik ZWANGSWEISE aus
--   D  reactor_id fehlt              -> Eintrag stillgelegt
--
-- In allen Faellen steht der Grund im Log. Im Log liest ihn niemand. Der
-- zweite Teil dieses Tests prueft daher, dass der SCHIRM die vier Lagen
-- auseinanderhalten kann -- insbesondere C: dort stand bisher
-- "logistics.enabled = false", also schaltete der Betreiber den Schalter
-- ein und bekam ihn beim naechsten Boot wieder aus. Es sah aus, als halte
-- der Schalter nicht.

local boot = require('support.cc_node_boot')
local ui_completion = require('nodes.fuel.ui_completion')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then
    error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' tatsaechlich=' .. tostring(a), 2)
  end
end

local ROUTE_FULL = [[return {
  export_chest = "mekanism:ultimate_logistical_transporter_0",
  reactors = {
    { reactor_id = "node-101:reactor:BigReactors-Reactor_7", label = "Reaktor A",
      path = { "valve-1", "valve-2" }, request_below = 0.5, fill_amount = 64,
      min_in_me = 100, resupply_cooldown_s = 30 },
  },
}]]

local ROUTE_NO_CHEST = [[return {
  reactors = {
    { reactor_id = "node-101:reactor:BigReactors-Reactor_7", label = "Reaktor A",
      path = { "valve-1" }, request_below = 0.5, fill_amount = 64 },
  },
}]]

local ROUTE_NO_ID = [[return {
  export_chest = "mekanism:ultimate_logistical_transporter_0",
  reactors = {
    { label = "Reaktor A", path = { "valve-1" }, request_below = 0.5, fill_amount = 64 },
  },
}]]

-- Bootet FUEL und gibt die Boot-Warnungen zurueck.
local function boot_fuel(routes, enabled)
  local env = boot.new({ computer_id = 202, node_id = 'fuel-1' })
  env:add_file('/xreactor_config/fuel_routes.lua', routes)
  env:add_file('/xreactor_config/fuel.lua',
    'return { logistics = { enabled = ' .. tostring(enabled) .. ' } }\n')
  env:add_file('/xreactor_config/role.lua', 'return { role = "fuel" }\n')
  env:add_modem('modem_0')
  env:add_peripheral('meBridge_0', 'meBridge', {
    listItems = function() return {} end,
    getItem = function() return { amount = 5000 } end,
    exportItem = function() return 64 end,
    isConnected = function() return true end,
  })
  env:add_peripheral('mekanism:ultimate_logistical_transporter_0', 'inventory', {
    list = function() return {} end, size = function() return 27 end,
  })
  env:install()
  env:boot('nodes/fuel/main.lua')
  return env
end

-- ── 1. Eine gueltige Routen-Datei wird geladen, nicht verworfen ───────────
--
-- Der wichtigste Einzelbefund: an der Datei selbst liegt es NICHT. Sie wird
-- gelesen und die Eintraege ueberleben das Normalisieren.
do
  local env = boot_fuel(ROUTE_FULL, true)
  assert_true(#env:find_logs('fuel_routes.lua konnte nicht geladen werden') == 0,
    'eine gueltige Routen-Datei darf nicht als unlesbar gemeldet werden')
  assert_true(#env:find_logs('stillgelegt') == 0,
    'ein vollstaendiger Eintrag darf nicht stillgelegt werden')
  assert_true(#env:find_logs('no fuel will be exported') == 0,
    'bei eingeschaltetem Schalter darf nicht "nichts wird exportiert" gemeldet werden')
  assert_true(#env:find_logs('export_chest missing') == 0,
    'der Uebergabepunkt ist gesetzt')
end

-- ── 2. Schalter AUS: geladen, aber wirkungslos -- und es wird gesagt ──────
do
  local env = boot_fuel(ROUTE_FULL, false)
  assert_true(#env:find_logs('no fuel will be exported') >= 1,
    'bei ausgeschaltetem Schalter muss der Boot sagen, dass nichts exportiert wird')
end

-- ── 3. Fehlender Uebergabepunkt schaltet die Logistik ZWANGSWEISE aus ────
do
  local env = boot_fuel(ROUTE_NO_CHEST, true)
  assert_true(#env:find_logs('export_chest missing') >= 1,
    'der fehlende Uebergabepunkt muss gemeldet werden')
  assert_true(#env:find_logs('logistics disabled') >= 1,
    'und er schaltet die Logistik zwangsweise ab -- auch bei Schalter AN')
end

-- ── 4. Fehlende reactor_id legt genau diesen Eintrag still ───────────────
do
  local env = boot_fuel(ROUTE_NO_ID, true)
  assert_true(#env:find_logs('ohne reactor_id') >= 1,
    'ein Eintrag ohne reactor_id muss als solcher gemeldet werden')
  assert_true(#env:find_logs('stillgelegt') >= 1, 'und stillgelegt werden')
end

-- ══ Der Schirm muss die vier Lagen auseinanderhalten ════════════════════
--
-- compute_view_state ist rein -- hier also direkt mit den Payload-Formen,
-- die logistics_router:get_summary() liefert.

local function view(logistics)
  local payload = {
    logistics = logistics,
    bindings = { storage = 1 },
    valve_summary = { offline = 0, stale = 0 },
    master_connected = true,
  }
  return ui_completion.compute_view_state({ payload = payload }, {}, 100, 10)
end

-- ── 5. Schalter AUS: sagt, wie viele Routen betroffen sind ────────────────
do
  local v = view({
    enabled = false, configured_reactor_count = 2, reactors = {}, bridge = 'meBridge_0',
  })
  assert_eq(v.code, 'LOGISTICS_DISABLED',
    'bei ausgeschaltetem Schalter muss der Schirm genau das sagen')
  assert_true(v.detail:find('2', 1, true) ~= nil,
    'und wie viele Routen davon betroffen sind -- Detail war: ' .. tostring(v.detail))
  assert_true(v.action:find('EINSCHALTEN', 1, true) ~= nil,
    'mit der Handlung, die hilft')
end

-- ── 6. Zwangsweise aus: NICHT als "Schalter steht aus" melden ────────────
--
-- Der Kern. Vorher: "Logistik deaktiviert -- logistics.enabled = false".
-- Der Betreiber schaltet ein, der naechste Boot schaltet wieder aus, der
-- Schalter scheint nicht zu halten.
do
  local v = view({
    enabled = false, disabled_reason = 'EXPORT_CHEST_MISSING',
    configured_reactor_count = 1, reactors = {}, bridge = 'meBridge_0',
  })
  assert_eq(v.code, 'NO_EXPORT_CHEST',
    'ein fehlender Uebergabepunkt ist KEIN "der Schalter steht aus"')
  assert_true(v.detail:find('export_chest', 1, true) ~= nil,
    'der Grund muss benannt werden -- Detail war: ' .. tostring(v.detail))
  assert_true(v.action:find('UEBERGABEPUNKT', 1, true) ~= nil,
    'und die Handlung muss zum Uebergabepunkt fuehren, nicht zum Schalter')
end

-- ── 7. "Keine Reaktoren konfiguriert" nur, wenn wirklich keine da sind ───
--
-- logistics.reactors ist der BETRIEBSzustand und bleibt leer, solange
-- nichts laeuft. Daraus wurde "Konfiguration erforderlich", obwohl eine
-- fertige Route in der Datei stand -- wortwoertlich die Meldung "FUEL laedt
-- die eingestellten Ruten nicht".
do
  local configured_but_idle = view({
    enabled = true, configured_reactor_count = 1, reactors = {}, bridge = 'meBridge_0',
  })
  assert_true(configured_but_idle.code ~= 'CONFIG_REQUIRED', string.format(
    'eine konfigurierte, nur gerade nicht laufende Route darf nicht als'
      .. ' "Konfiguration erforderlich" erscheinen -- es kam %s',
    tostring(configured_but_idle.code)))

  local really_empty = view({
    enabled = true, configured_reactor_count = 0, reactors = {}, bridge = 'meBridge_0',
  })
  assert_eq(really_empty.code, 'CONFIG_REQUIRED',
    'ohne jede konfigurierte Route bleibt es bei "Konfiguration erforderlich"')

  -- Alte Payloads ohne das neue Feld: dann gilt wie zuvor die Betriebsliste.
  local legacy = view({ enabled = true, reactors = {}, bridge = 'meBridge_0' })
  assert_eq(legacy.code, 'CONFIG_REQUIRED',
    'ohne configured_reactor_count bleibt das alte Verhalten')
end

-- ── 8. Stillgelegter Eintrag bleibt sichtbar ─────────────────────────────
do
  local v = view({
    enabled = true, configured_reactor_count = 1, bridge = 'meBridge_0',
    reactors = { { label = 'Reaktor A', disabled_reason = 'ohne reactor_id' } },
  })
  assert_eq(v.code, 'ENTRY_DISABLED', 'ein stillgelegter Eintrag muss auf dem Schirm stehen')
  assert_true(v.detail:find('Reaktor A', 1, true) ~= nil, 'mit dem Namen des Reaktors')
end

print('ok fuel_boot_routes_test')
