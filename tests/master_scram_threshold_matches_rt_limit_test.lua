package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- MASTERs Notfall-Schwelle darf nicht unter der liegen, ab der die Anlage
-- selbst ausloest.
--
-- master/startup_sequencer.lua's should_emergency() stuft einen
-- Sequencer-Timeout als EMERGENCY statt LIMITED ein, wenn die gemeldete
-- Brennstofftemperatur ueber config.scram_temperature liegt. Dort stand
-- fest 950 Grad -- weniger als die Haelfte der Grenze, an der die RT-Node
-- selbst trippt (nodes/rt/config.lua: safety.max_temperature = 2000, mit
-- Hysterese und 3 Messwerten Entprellung). Eine aktiv gekuehlte Anlage
-- faehrt im NORMALBETRIEB ueber 950.
--
-- Folgenlos war das nur, weil should_emergency() den Wert aus
-- payload.snapshot.max_temp liest und dort bis v776 nie eine Temperatur
-- ankam (RT schickte versehentlich ein Modul statt einer Aufnahme, siehe
-- rt_status_snapshot_master_fields_test.lua). Mit der Behebung waere aus
-- jedem Sequencer-Timeout ein EMERGENCY-Alarm bei normaler
-- Betriebstemperatur geworden.
--
-- Dieser Test haelt die beiden Zahlen zusammen. Wer eine davon aendert,
-- muss die andere mitdenken.

local sequencer = require('master.startup_sequencer')
local rt_config = require('nodes.rt.config')
local safety = require('core.safety')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local rt_limit = rt_config.safety and rt_config.safety.max_temperature
assert_true(type(rt_limit) == 'number',
  'nodes/rt/config.lua muss safety.max_temperature fuehren')
assert_true(type(sequencer.DEFAULT_SCRAM_TEMPERATURE) == 'number',
  'master/startup_sequencer.lua muss seinen Rueckfallwert benennen, nicht verstecken')

assert_eq(sequencer.DEFAULT_SCRAM_TEMPERATURE, rt_limit,
  'MASTERs Rueckfall-Schwelle und RTs eigene Trip-Grenze muessen dieselbe Zahl sein')

-- Und die Folge daraus, an der es wehtut: bei einer Temperatur, die die
-- Anlage selbst noch als normal ansieht, darf MASTER keinen Notfall sehen.
local normal_operating_temp = rt_limit - 400
assert_eq(safety.should_scram({
  temperature = normal_operating_temp,
  max_temperature = sequencer.DEFAULT_SCRAM_TEMPERATURE,
}), false, ('bei %d Grad faehrt die Anlage normal -- das darf kein EMERGENCY sein')
  :format(normal_operating_temp))

-- Oberhalb der Anlagengrenze aber sehr wohl.
assert_true(safety.should_scram({
  temperature = rt_limit + 50,
  max_temperature = sequencer.DEFAULT_SCRAM_TEMPERATURE,
}), 'oberhalb der Anlagengrenze muss MASTER ausloesen')

-- Der Rueckfall greift wirklich: das Feld wird nirgends im Projekt gesetzt.
do
  local hits = 0
  local function scan(path)
    local f = io.open(path, 'r')
    if not f then return end
    local src = f:read('*a'); f:close()
    for _ in src:gmatch('scram_temperature') do hits = hits + 1 end
  end
  scan('xreactor/master/config.lua')
  scan('xreactor/master/context.lua')
  assert_eq(hits, 0,
    'scram_temperature wird jetzt doch konfiguriert -- dann gehoert dieser Test'
      .. ' erweitert, statt nur den Rueckfallwert zu pruefen')
end

print('master_scram_threshold_matches_rt_limit_test.lua: ok')
