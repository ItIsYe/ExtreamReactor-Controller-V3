package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Das Einlernen, Betreibervorgabe vom 2026-09-28:
--
--   "im learning modus muessen 80% der turbinen im ziel rpm bereich sein
--    +-15 rpm. das heisst die turbinen muessen auch unabhaengig vom master
--    waehrend des lernens -- aber auch nur waehrend des lernens -- auf 900
--    rpm gebracht werden. sobald das abgeschlossen ist geht dann wieder
--    ganz normale regelung."
--
-- Warum es das ueberhaupt braucht: MASTER und Knoten lesen denselben
-- Prozentsatz verschieden.
--
--   MASTER (master/rt_sync.lua):  assigned_power = capacity * pct / 100
--                                 -- Anteil der LEISTUNG
--   Knoten (rt2_turbine.lua):     running_count  = pct / 100 * turbine_count
--                                 -- Anteil der TURBINEN
--
-- Das geht nur auf, wenn capacity_max beschreibt, was die Flotte liefert,
-- wenn ALLE Turbinen laufen. Genau diese Zahl entsteht im Einlernen -- und
-- nur dort, weil nur dort die ganze Flotte faehrt.

local orchestrator = require('nodes.rt.rt2_orchestrator')

local function assert_eq(a, e, m) if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- n Turbinen, davon stehen die ersten `in_band` im Zielband und gekuppelt.
local function fleet(n, in_band, band_rpm)
  local t = {}
  for i = 1, n do
    local ok = i <= in_band
    t[i] = {
      name = 'T' .. i,
      rpm = ok and (band_rpm or 900) or 400,
      energy = ok and 100 or 20,
      coil_engaged = ok,
      current_flow = 1200,
    }
  end
  return t
end

-- ══ 1. Waehrend des Einlernens gilt MASTER nicht ═══════════════════════

do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local r = o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 20,
    turbines = fleet(50, 0), reactor = {} })

  assert_true(r.capacity.learning, 'der Knoten lernt ein')
  assert_eq(r.capacity.reason, 'LEARNING')
  assert_eq(r.effective_percent, 100, 'die MASTER-Vorgabe von 20 % ist uebersteuert')
  for _, t in ipairs(r.turbines) do
    assert_eq(t.target_rpm, 900, 'die GANZE Flotte faehrt auf Zieldrehzahl')
  end
  assert_true(not r.capacity.ready, 'MASTER bekommt dabei keine Zahl -- eine aus dem Hochlauf waere beliebig')
  assert_eq(r.capacity.required_at_target, 40, '80 % von 50 Turbinen sind 40')
end

-- ══ 2. Die Schwelle ist 80 %, das Band +/- 15 RPM ══════════════════════

do
  local o = orchestrator.new()
  o.note_master_seen(0)
  o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 20, turbines = fleet(50, 0), reactor = {} })

  -- 39 von 50 = 78 % -- noch nicht genug.
  local r = o.tick({ now_ms = 2000, hardware_ready = true, master_percent = 20,
    turbines = fleet(50, 39), reactor = {} })
  assert_true(r.capacity.learning, '78 % reichen nicht')
  assert_eq(r.capacity.at_target, 39)

  -- 40 von 50 = 80 % -- der Messpunkt.
  r = o.tick({ now_ms = 3000, hardware_ready = true, master_percent = 20,
    turbines = fleet(50, 40), reactor = {} })
  assert_true(not r.capacity.learning, 'bei 80 % ist das Einlernen durch')
  assert_eq(r.capacity.reason, 'MEASURED')
  assert_eq(r.capacity.max_output, 5000,
    'aus 40 Turbinen zu je 100 RF/t wird auf die Flotte von 50 hochgerechnet')
  assert_true(r.capacity.ready, 'und jetzt darf MASTER damit rechnen')
end

do
  -- Das Band ist eng: 16 RPM daneben zaehlt nicht mehr.
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(10, 0), reactor = {} })
  local r = o.tick({ now_ms = 2000, hardware_ready = true,
    turbines = fleet(10, 10, 900 - orchestrator.LEARN_TOLERANCE_RPM - 1), reactor = {} })
  assert_true(r.capacity.learning, '884 RPM liegt ausserhalb von 900 +/- 15')

  r = o.tick({ now_ms = 3000, hardware_ready = true,
    turbines = fleet(10, 10, 900 - orchestrator.LEARN_TOLERANCE_RPM), reactor = {} })
  assert_true(not r.capacity.learning, '885 RPM liegt gerade noch drin')
end

-- ══ 3. Danach wieder ganz normale Regelung ═════════════════════════════

do
  local o = orchestrator.new()
  o.note_master_seen(0)
  o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 20, turbines = fleet(50, 0), reactor = {} })
  o.tick({ now_ms = 2000, hardware_ready = true, master_percent = 20, turbines = fleet(50, 40), reactor = {} })

  local r = o.tick({ now_ms = 3000, hardware_ready = true, master_percent = 20,
    turbines = fleet(50, 40), reactor = {} })
  assert_eq(r.effective_percent, 20, 'jetzt gilt die MASTER-Vorgabe wieder')
  local running = 0
  for _, t in ipairs(r.turbines) do
    if t.target_rpm > 0 then running = running + 1 end
  end
  assert_eq(running, 10, '20 % von 50 Turbinen sind 10 -- der Rest steht')
end

-- ══ 4. Gesummt wird NUR ueber die Turbinen im Band ═════════════════════
--
-- Die uebrigen bis zu 20 % haengen noch im Hochlauf. Ihren kleineren
-- Ausstoss mitzumitteln zoege die Zahl nach unten, und MASTER teilte dem
-- Knoten dauerhaft zu wenig zu.
do
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(10, 0), reactor = {} })
  -- 8 im Band zu je 100, 2 im Hochlauf zu je 20.
  local r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet(10, 8), reactor = {} })
  assert_eq(r.capacity.at_target, 8)
  assert_eq(r.capacity.max_output, 1000,
    '(800/8) * 10 = 1000 -- nicht (840/10) * 10 = 840')
end

-- ══ 5. Die Notbremse: das Einlernen endet IMMER ════════════════════════
--
-- Eine dampfarme Anlage bringt vielleicht nie 80 % ins Band. Ohne Grenze
-- liefe das Einlernen ewig und der Knoten wuerde MASTER dauerhaft
-- uebersteuern -- das ist die Sackgasse, in der die alte Lernphase stecken
-- blieb.
do
  local o = orchestrator.new()
  o.note_master_seen(0)
  local starved = fleet(10, 3)   -- nur 30 % schaffen das Band, nie mehr
  o.tick({ now_ms = 1000, hardware_ready = true, master_percent = 40, turbines = starved, reactor = {} })

  local r = o.tick({ now_ms = 1000 + orchestrator.LEARN_TIMEOUT_MS - 1, hardware_ready = true,
    master_percent = 40, turbines = starved, reactor = {} })
  assert_true(r.capacity.learning, 'kurz vor der Grenze laeuft es noch')

  r = o.tick({ now_ms = 1000 + orchestrator.LEARN_TIMEOUT_MS + 1, hardware_ready = true,
    master_percent = 40, turbines = starved, reactor = {} })
  assert_true(not r.capacity.learning, 'nach der Grenze endet das Einlernen in jedem Fall')
  assert_eq(r.capacity.reason, 'OBSERVED', 'und sagt, dass die Zahl nur geschaetzt ist')
  assert_true(r.capacity.max_output > 0, 'es gilt der hoechste geflossene Ausstoss')
  assert_true(r.capacity.ready, 'MASTER bekommt eine Zahl, statt den Knoten nie zuzuteilen')

  r = o.tick({ now_ms = 1000 + orchestrator.LEARN_TIMEOUT_MS + 2000, hardware_ready = true,
    master_percent = 40, turbines = starved, reactor = {} })
  assert_eq(r.effective_percent, 40, 'und die normale Regelung laeuft wieder')
end

-- ══ 6. Eine geaenderte Turbinenzahl ist eine andere Anlage ═════════════

do
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(10, 0), reactor = {} })
  local r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet(10, 10), reactor = {} })
  assert_eq(r.capacity.max_output, 1000)
  assert_true(not r.capacity.learning)

  -- Eine Turbine abgebaut: die alte Zahl darf nicht weiterleben.
  r = o.tick({ now_ms = 3000, hardware_ready = true, turbines = fleet(9, 0), reactor = {} })
  assert_true(r.capacity.learning, 'eine geaenderte Flotte wird neu eingelernt')
  assert_eq(r.capacity.total_turbines, 9)
  assert_eq(r.capacity.required_at_target, 8, '80 % von 9 aufgerundet sind 8')
end

-- ══ 7. Im SAFE wird nicht gemessen ═════════════════════════════════════

do
  local o = orchestrator.new()
  o.tick({ now_ms = 1000, hardware_ready = true, turbines = fleet(10, 0), reactor = {} })
  local r = o.tick({ now_ms = 2000, hardware_ready = true, turbines = fleet(10, 10), reactor = {} })
  assert_eq(r.capacity.max_output, 1000)

  r = o.tick({ now_ms = 3000, hardware_ready = true, safety_tripped = true,
    turbines = fleet(10, 0), reactor = {} })
  assert_eq(r.capacity.max_output, 1000, 'eine Ausloesung wirft die Messung nicht weg')
end

print('rt2_learning_test.lua: ok')
