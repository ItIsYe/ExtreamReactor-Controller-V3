-- tests/rt_engine_visibility_test.lua
--
-- Aus dem Livetest (Bild, node-101): 25 Turbinen bei 967-1256 RPM, FLOW
-- durchgehend 2.0k (Maximum), Spule bei ALLEN geloest -- also voller
-- Dampf ohne Last, genau das Verhalten, gegen das die v2-Engine gebaut
-- wurde. Unter v2 ist dieser Zustand unmoeglich: compute_coil_decision()
-- kuppelt oberhalb von Ziel+Band IMMER ein (BRAKE_TO_TARGET), und bei
-- Ziel 0 bremst sie bis zum Stillstand (BRAKE_TO_STOP). Der Knoten lief
-- also auf v1.
--
-- Wie er dorthin kommen kann, ohne dass es jemand merkt, ist der Kern
-- dieser Datei: config_normalizer.validate_config() stellt ein fehlendes
-- oder ungueltiges engine-Feld STILL auf "v1" zurueck, und ein spaeteres
-- write_config() (Monitor-Skalierung per Touch, SET_REACTOR_FILL_TARGET,
-- Schema-Migration) schreibt diese Herabstufung dauerhaft fest. Gemeldet
-- wird sie nur als Config-Warnung -- und die geht per utils.log() an den
-- Log-Collector, nicht auf den Bildschirm des Rechners.

package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local normalizer = require('nodes.rt.config_normalizer')
local rt2_turbine = require('nodes.rt.rt2_turbine')

-- ══ 1. Unter v2 kann der beobachtete Zustand nicht entstehen ═════════════

do
  -- Genau die Werte vom Bild.
  for _, rpm in ipairs({ 967, 1256 }) do
    local coil = rt2_turbine.compute_coil_decision({
      rpm = rpm, target_rpm = rt2_turbine.FULL_TARGET_RPM, currently_engaged = false,
    })
    assert_eq(coil.engaged, true, string.format(
      'bei %d RPM ueber dem Ziel muss v2 die Spule einkuppeln (Bremse), Grund war %s',
      rpm, tostring(coil.reason)))
  end

  -- Und auch eine abgewaehlte Turbine bleibt nicht frei drehend.
  local parked = rt2_turbine.compute_coil_decision({
    rpm = 1256, target_rpm = 0, currently_engaged = false,
  })
  assert_eq(parked.engaged, true, 'eine abgewaehlte, noch drehende Turbine muss gebremst werden')
  local parked_flow = rt2_turbine.compute_flow_decision({
    rpm = 1256, target_rpm = 0, current_flow = rt2_turbine.MAX_FLOW,
  })
  assert_eq(parked_flow.flow, 0, 'und ihren Dampf verlieren, nicht vollen Durchfluss behalten')
end

-- ══ 2. Die stille Herabstufung ist gemeldet ══════════════════════════════

do
  local defaults = require('nodes.rt.config')

  -- validate_config braucht von utils nur diese beiden.
  local real_utils = require('core.utils')
  local utils_stub = {
    normalize_node_id = function(v) return tostring(v or "RT-1") end,
    deep_copy = real_utils.deep_copy,
  }

  local function check(value, label)
    local warnings = {}
    local cfg = { engine = value }
    normalizer.validate_config(cfg, defaults, function(m) warnings[#warnings + 1] = m end, utils_stub)
    assert_eq(cfg.engine, 'v1', label .. ': muss auf v1 zurueckfallen')
    local mentioned = false
    for _, w in ipairs(warnings) do
      if tostring(w):find('engine', 1, true) then mentioned = true end
    end
    assert_true(mentioned, label .. ': die Herabstufung muss gemeldet werden, sonst passiert sie lautlos')
  end

  check(nil, 'fehlendes engine-Feld')
  check('V2', 'falsch geschriebenes engine-Feld')
  check(2, 'engine-Feld mit falschem Typ')

  -- Ein gueltiges v2 darf NICHT angefasst werden -- sonst waere der
  -- Schutz oben der Fehler selbst.
  local keep = { engine = 'v2' }
  normalizer.validate_config(keep, defaults, function() end, utils_stub)
  assert_eq(keep.engine, 'v2', 'ein gueltiges engine = "v2" muss erhalten bleiben')
end

-- ══ 3. Der Knoten sagt, welche Engine regelt ═════════════════════════════
--
-- Das ist die eigentliche Lehre aus dem Bild: dass der Knoten auf v1 lief,
-- war weder am Bildschirm noch am Rechner abzulesen. Gemeldet hat sich
-- bisher NUR v2.

local function read(p)
  local f = assert(io.open(p, 'r'))
  local s = f:read('*a'); f:close(); return s
end

do
  local src = read('xreactor/nodes/rt/main.lua')

  local msg_pos = src:find('local engine_msg', 1, true)
  assert_true(msg_pos ~= nil, 'main.lua muss die aktive Engine melden')

  -- Die Meldung darf NICHT im v2-Zweig stehen, sonst schweigt v1 weiter.
  local branch = src:find('if config.engine == "v2" then', 1, true)
  local branch_end = src:find('\n  end\n', branch, true)
  assert_true(branch ~= nil and branch_end ~= nil, 'v2-Zweig nicht gefunden')
  assert_true(msg_pos > branch_end,
    'die Engine-Meldung muss AUSSERHALB des v2-Zweigs stehen -- sonst meldet sich'
      .. ' weiterhin nur v2, und ein auf v1 zurueckgefallener Knoten schweigt')

  assert_true(src:find('pcall(print, "[RT] " .. engine_msg)', 1, true) ~= nil,
    'und direkt auf den Rechner gehen -- utils.log() routet zum Log-Collector,'
      .. ' nicht auf den lokalen Bildschirm')

  -- Auch MASTER soll es erfahren.
  assert_true(src:find('payload.engine = "v2"', 1, true) ~= nil,
    'der Statuspayload muss die Engine nennen (v2)')
  assert_true(src:find('payload.engine = "v1"', 1, true) ~= nil,
    'und ebenso im v1-Fall')
end

do
  -- Und am Bildschirm, auf jeder Seite.
  local src = read('xreactor/nodes/rt/mockup_pages.lua')
  local count = 0
  for _ in src:gmatch('with_engine%(model,') do count = count + 1 end
  assert_true(count >= 5, 'jede der vier Seiten muss die Engine in der Fusszeile zeigen, gefunden: '
    .. tostring(count - 1))
end

-- ══ 4. Ein stiller Regelstillstand ist jetzt laut ════════════════════════
--
-- Der eigentliche Befund aus dem Bild ist nicht der Zustand selbst,
-- sondern dass er STILL war: service_manager faengt einen werfenden
-- Regeltakt per pcall ab und meldet ihn ueber utils.log() -- das routet
-- zum Log-Collector, nicht auf den Bildschirm des Rechners. Die
-- Oberflaeche laeuft als eigener Service weiter und sieht dabei voellig
-- normal aus.

do
  local src = read('xreactor/nodes/rt/main.lua')
  local branch = src:find('if engine_v2 then\n    -- Wirft der Regeltakt', 1, true)
  assert_true(branch ~= nil,
    'control_tick() muss den v2-Takt absichern, statt ihn blind aufzurufen')
  assert_true(src:find('REGELTAKT ABGEBROCHEN', 1, true) ~= nil,
    'ein geworfener Regeltakt muss direkt am Rechner stehen')
  assert_true(src:find('error(err, 0)', 1, true) ~= nil,
    'und trotzdem weitergereicht werden, damit service_manager seine'
      .. ' Wiederholung behaelt')
end

do
  local src = read('xreactor/nodes/rt/rt2_engine.lua')
  assert_true(src:find('v2 REGELT NICHT', 1, true) ~= nil,
    'die Engine muss melden, wenn sie Geraete kennt aber keines ansteuert')
  assert_true(src:find('Engine nicht initialisiert', 1, true) ~= nil,
    'und ebenso, wenn sie gar nicht initialisiert wurde -- vorher gab sie'
      .. ' dann still nil zurueck und der Knoten regelte nichts')
  -- Gedaempft: die Meldung darf nicht in jedem Takt erscheinen.
  assert_true(src:find('if idle_reason ~= last_idle_reason then', 1, true) ~= nil,
    'die Meldung muss entprellt sein, sonst ist der Bildschirm zugemuellt')
end

print('rt_engine_visibility_test.lua: ok')
