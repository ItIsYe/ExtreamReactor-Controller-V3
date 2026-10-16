package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Aus dem Betrieb (MC 1.21.1, ATM10), im Klartext auf dem Schirm:
--
--   EXPORT_FEHLER -- Reaktor 14: die ME Bridge lehnte den Export ab
--   (alltheores:uranium_block -> minecraft:chest_0):
--   bad argument #1 (string expected, got table)
--
-- Das ist CC:Tweakeds Pruefung der Java-Parameter: diese Bridge will an
-- Position 1 KEINE Tabelle. Die Advanced-Peripherals-Dokumentation nennt
-- exportItemToPeripheral(item: table, container: string) -- gilt aber
-- ausdruecklich fuer 0.7 und aelter; fuer 1.21 kommt mit 0.8 ein neues
-- Bridge-System.
--
-- Daher wird die Konvention nicht mehr angenommen, sondern ermittelt.

local compat = require('core.me_bridge_compat')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- ══ 1. Genau das Fehlerbild aus dem Betrieb ════════════════════════════

do
  compat.forget_conventions()
  local seen = {}
  local bridge = {
    -- Erwartet (container, item) -- die umgekehrte Reihenfolge.
    exportItemToPeripheral = function(a, b)
      seen[#seen + 1] = type(a) .. ',' .. type(b)
      if type(a) ~= 'string' then
        error('bad argument #1 (string expected, got ' .. type(a) .. ')', 0)
      end
      return 64
    end,
  }

  local ok, moved, convention = compat.export_to(bridge,
    { name = 'alltheores:uranium_block', count = 8 }, 'minecraft:chest_0')

  assert_true(ok, 'die Lieferung muss durchgehen, auch wenn die Reihenfolge anders ist')
  assert_eq(moved, 64)
  assert_eq(convention, 'target_filter')
  assert_eq(seen[1], 'table,string', 'zuerst wird die dokumentierte 0.7er Reihenfolge versucht')
  assert_eq(seen[2], 'string,table', 'danach die umgekehrte')
end

-- ══ 2. Einmal ermittelt, nicht bei jeder Lieferung neu durchprobiert ═══
--
-- Sonst kostet jede Lieferung einen Fehlversuch -- und in CC:Tweaked
-- kostet jeder Peripherie-Aufruf einen Server-Tick.

do
  compat.forget_conventions()
  local calls = 0
  local bridge = {
    exportItemToPeripheral = function(a, _)
      calls = calls + 1
      if type(a) ~= 'string' then error('bad argument #1 (string expected, got table)', 0) end
      return 1
    end,
  }
  compat.export_to(bridge, { name = 'x', count = 1 }, 'chest_0')
  assert_eq(calls, 2, 'beim ersten Mal ein Fehlversuch plus der Treffer')
  calls = 0
  compat.export_to(bridge, { name = 'x', count = 1 }, 'chest_0')
  assert_eq(calls, 1, 'danach nur noch der Treffer')
  assert_eq(compat.learned_convention('exportItemToPeripheral').id, 'target_filter')
end

-- ══ 3. Die dokumentierte Reihenfolge bleibt unangetastet ═══════════════

do
  compat.forget_conventions()
  local calls = 0
  local bridge = {
    exportItemToPeripheral = function(a, b)
      calls = calls + 1
      assert_eq(type(a), 'table'); assert_eq(type(b), 'string')
      return 32
    end,
  }
  local ok, moved, convention = compat.export_to(bridge, { name = 'x', count = 4 }, 'chest_0')
  assert_true(ok); assert_eq(moved, 32)
  assert_eq(convention, 'filter_target', 'wo die 0.7er Konvention laeuft, wird nichts anderes versucht')
  assert_eq(calls, 1, 'und zwar ohne einen einzigen Fehlversuch')
end

-- ══ 4. Ein ECHTER Fehler wird nicht weiterprobiert ═════════════════════
--
-- Entscheidend fuer die Sicherheit: nur ein Argumentfehler rechtfertigt
-- einen weiteren Versuch, denn er entsteht, BEVOR der Mod etwas bewegt.
-- Bei jeder anderen Antwort koennte ein zweiter Versuch ein zweites Mal
-- Gegenstaende verschieben -- und ausserdem verschleiert er die Aussage.

do
  compat.forget_conventions()
  local calls = 0
  local bridge = {
    exportItemToPeripheral = function(_, _)
      calls = calls + 1
      error('No such container minecraft:chest_0', 0)
    end,
  }
  local ok, err = compat.export_to(bridge, { name = 'x', count = 1 }, 'chest_0')
  assert_true(not ok)
  assert_true(tostring(err):find('No such container', 1, true) ~= nil,
    'der Wortlaut der Bridge bleibt unveraendert stehen')
  assert_eq(calls, 1, 'ein echter Fehler darf NICHT mit anderen Signaturen wiederholt werden')
  assert_eq(compat.learned_convention('exportItemToPeripheral'), nil,
    'und er lehrt nichts -- gemerkt wird nur, was angenommen wurde')
end

-- ══ 5. Eine gemerkte Konvention wird nach einem Mod-Update neu gemessen ═

do
  compat.forget_conventions()
  local mode = 'target_filter'
  local bridge = {
    exportItemToPeripheral = function(a, _)
      local want = mode == 'target_filter' and 'string' or 'table'
      if type(a) ~= want then
        error('bad argument #1 (' .. want .. ' expected, got ' .. type(a) .. ')', 0)
      end
      return 1
    end,
  }
  compat.export_to(bridge, { name = 'x', count = 1 }, 'chest_0')
  assert_eq(compat.learned_convention('exportItemToPeripheral').id, 'target_filter')

  mode = 'filter_target'  -- die Bridge wurde ausgetauscht
  local ok, _, convention = compat.export_to(bridge, { name = 'x', count = 1 }, 'chest_0')
  assert_true(ok, 'nach einem Mod-Update darf der Knoten nicht dauerhaft scheitern')
  assert_eq(convention, 'filter_target', 'er misst dann neu')
end

-- ══ 6. Fehlt die Methode ganz, ist das eine Aussage, kein Absturz ══════

do
  compat.forget_conventions()
  local ok, err = compat.export_to({}, { name = 'x', count = 1 }, 'chest_0')
  assert_true(not ok)
  assert_true(tostring(err):find('no_method', 1, true) ~= nil, tostring(err))
end

-- ══ 7. Die Methodenliste der Bridge ist die Bodenwahrheit ══════════════

do
  local names = compat.transfer_methods({
    exportItem = function() end,
    importItemFromPeripheral = function() end,
    getItem = function() end,
    getEnergyStorage = function() end,
  })
  local joined = table.concat(names, ',')
  assert_true(joined:find('exportItem', 1, true) ~= nil, joined)
  assert_true(joined:find('importItemFromPeripheral', 1, true) ~= nil, joined)
  assert_true(joined:find('getEnergyStorage', 1, true) == nil,
    'nur was mit dem Warenverkehr zu tun hat: ' .. joined)
end

print('me_bridge_export_convention_probe_test.lua: ok')
