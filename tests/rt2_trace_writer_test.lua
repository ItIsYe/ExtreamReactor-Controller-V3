package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Die Datei-Seite der Aufzeichnung. Sie hat eine einzige harte Pflicht:
-- die Regelung NIE stoeren. Eine volle oder kaputte Platte darf hoechstens
-- die Aufzeichnung kosten, nie einen Regeltakt.
--
-- Und sie muss ihren Platzbedarf deckeln. Eine vollgelaufene Platte hat auf
-- diesem Knoten schon einmal ein Update verhindert (siehe
-- installer/auto_update.lua's ensure_temp_space()), also darf ein
-- vergessenes Trace das nicht wiederholen.

local writer_lib = require('nodes.rt.rt2_trace_writer')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

-- Ein Dateisystem im Speicher, das sich wie CC:Tweaked's fs verhaelt.
local function fake_fs()
  local files = {}
  local dirs = {}
  return files, dirs, {
    exists = function(p) return files[p] ~= nil or dirs[p] == true end,
    makeDir = function(p) dirs[p] = true end,
    isDir = function(p) return dirs[p] == true end,
    getSize = function(p) return #(files[p] or '') end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    open = function(p, mode)
      if mode == 'w' then files[p] = '' end
      if mode == 'a' then files[p] = files[p] or '' end
      return {
        write = function(text) files[p] = (files[p] or '') .. text end,
        close = function() end,
      }
    end,
  }
end

-- ── 1. Erste Datei bekommt den Kopf, danach wird angehaengt ──────────────

do
  local files, _, fs = fake_fs()
  local w = writer_lib.new({ fs_impl = fs, dir = '/logs', node_id = 'node-101', flush_ms = 0 })
  assert_eq(w.path(), '/logs/rt_trace_node-101.csv', 'Dateiname')

  w.append({ 'T,1000,1,LEARNING' }, 1000)
  local content = files[w.path()]
  assert_true(content ~= nil, 'nichts geschrieben')
  assert_true(content:find('# xreactor rt trace', 1, true) == 1,
    'die erste Datei muss die Spaltenkoepfe tragen -- sonst ist sie ohne den Quelltext unlesbar')
  assert_true(content:find('T,1000,1,LEARNING', 1, true) ~= nil, 'die Zeile fehlt')

  w.append({ 'T,2000,2,AUTONOM' }, 2000)
  content = files[w.path()]
  assert_eq(select(2, content:gsub('# xreactor rt trace', '')), 1,
    'der Kopf darf nur einmal drinstehen')
  assert_true(content:find('T,2000,2,AUTONOM', 1, true) ~= nil, 'die zweite Zeile fehlt')
end

-- ── 2. Der Flush-Takt haelt: nicht jeder Takt fasst die Platte an ────────
--
-- Bei 10 Hz waeren das 10 fs.open/close je Sekunde, je Knoten. Das ist
-- Last ohne Nutzen -- gepuffert wird trotzdem, damit nichts verlorengeht.

do
  local files, _, fs = fake_fs()
  local opens = 0
  local real_open = fs.open
  fs.open = function(...) opens = opens + 1; return real_open(...) end

  local w = writer_lib.new({ fs_impl = fs, dir = '/logs', flush_ms = 2000 })
  w.append({ 'T,0' }, 0)          -- erster Aufruf schreibt sofort
  assert_eq(opens, 1, 'der erste Takt darf schreiben')
  w.append({ 'T,500' }, 500)
  w.append({ 'T,1000' }, 1000)
  assert_eq(opens, 1, 'innerhalb des Flush-Takts darf die Platte nicht angefasst werden')
  w.append({ 'T,2500' }, 2500)
  assert_eq(opens, 2, 'nach dem Flush-Takt schon')

  -- Verloren ist dabei nichts.
  local content = files[w.path()]
  for _, line in ipairs({ 'T,0', 'T,500', 'T,1000', 'T,2500' }) do
    assert_true(content:find(line, 1, true) ~= nil, 'gepufferte Zeile verloren: ' .. line)
  end
end

-- ── 3. Rotation deckelt den Platzbedarf ──────────────────────────────────

do
  local files, _, fs = fake_fs()
  local MAX, KEEP = 2000, 3
  local w = writer_lib.new({
    fs_impl = fs, dir = '/logs', flush_ms = 0, max_bytes = MAX, keep = KEEP,
  })
  local rt2_trace = require('nodes.rt.rt2_trace')
  local long = string.rep('x', 180)
  for i = 1, 60 do w.append({ 'T,' .. i .. ',' .. long }, i * 1000) end

  assert_true(files[w.path()] ~= nil, 'die aktuelle Datei fehlt')
  assert_true(files[w.rotated_path(1)] ~= nil, 'es muss rotiert worden sein')

  -- Die Zusicherung, auf die es ankommt: mehr als keep+1 Dateien gibt es
  -- nie, und keine einzelne wird unbegrenzt gross. Der Kopf und die eine
  -- gerade geschriebene Portion kommen als Zugabe oben drauf -- eine Datei
  -- wird geschlossen, NACHDEM sie die Grenze reisst, nicht davor.
  local count, biggest = 0, 0
  for path, content in pairs(files) do
    count = count + 1
    if #content > biggest then biggest = #content end
    assert_true(path == w.path() or path:find(w.path(), 1, true) == 1,
      'fremde Datei im Log-Verzeichnis: ' .. path)
  end
  assert_true(count <= KEEP + 1,
    ('es darf hoechstens keep+1 = %d Dateien geben, es sind %d'):format(KEEP + 1, count))

  local slack = #rt2_trace.HEADER + 512
  assert_true(biggest <= MAX + slack,
    ('keine Datei darf ueber max_bytes+Zugabe wachsen: %d > %d'):format(biggest, MAX + slack))

  -- Der juengste Stand steht in der aktuellen Datei, nicht in einer alten.
  assert_true(files[w.path()]:find('T,60,', 1, true) ~= nil,
    'die letzte Zeile muss in der aktuellen Datei stehen')
end

-- ── 4. Eine kaputte Platte kostet die Zeile, nicht den Takt ──────────────

do
  local _, _, fs = fake_fs()
  fs.open = function() error('disk full', 0) end
  local w = writer_lib.new({ fs_impl = fs, dir = '/logs', flush_ms = 0 })
  local ok = pcall(function() w.append({ 'T,1' }, 1) end)
  assert_true(ok, 'ein Schreibfehler darf NICHT nach oben durchschlagen')
  assert_true(w.dropped_writes >= 1, 'er muss aber gezaehlt werden')

  -- Auch ohne fs ueberhaupt (Umgebung ohne Dateisystem).
  local w2 = writer_lib.new({ fs_impl = nil, dir = '/logs', flush_ms = 0 })
  w2.fs = nil
  assert_true(pcall(function() w2.append({ 'T,1' }, 1) end),
    'ohne Dateisystem darf es genauso still fehlschlagen')
end

-- ── 5. Die Takte: Sammelzeile und voller Durchgang ───────────────────────

do
  local _, _, fs = fake_fs()
  local w = writer_lib.new({
    fs_impl = fs, dir = '/logs', interval_ms = 1000, full_sweep_ms = 30000,
    methods_ms = 30000, flush_ms = 0,
  })
  assert_true(w.due(0), 'der erste Takt ist immer faellig')
  w.append({ 'T,0' }, 0)
  assert_eq(w.due(500), false, 'innerhalb des Intervalls nicht')
  assert_true(w.due(1000), 'nach dem Intervall schon')

  assert_true(w.sweep_due(0), 'der erste volle Durchgang ist faellig')
  w.note_sweep(0)
  assert_eq(w.sweep_due(29000), false, 'dann Ruhe bis zum Takt')
  assert_true(w.sweep_due(30000), 'danach wieder')

  -- Die Methodenzeilen laufen auf einem EIGENEN, langsameren Takt: sie
  -- aendern sich im Betrieb nicht, und 50 Zeilen je Durchgang waeren
  -- reine Last.
  local w2 = writer_lib.new({
    fs_impl = fs, dir = '/logs', full_sweep_ms = 5000, methods_ms = 60000, flush_ms = 0,
  })
  assert_true(w2.methods_due(0), 'der erste Methoden-Durchgang ist faellig')
  w2.note_methods(0)
  assert_eq(w2.methods_due(30000), false, 'danach lange Ruhe')
  assert_true(w2.methods_due(60000), 'erst nach methods_ms wieder')
  assert_true(w2.sweep_due(5000), 'der Turbinen-Durchgang laeuft unabhaengig weiter')
end

-- ── 6. Die Freiplatz-Bremse ─────────────────────────────────────────────
--
-- Die eigentliche Absicherung. Die Installation belegt allein rund 730 KB,
-- und installer/auto_update.lua's ensure_temp_space() LOESCHT
-- /xreactor_logs, wenn ein Update Platz braucht. Eine Aufzeichnung, die
-- den letzten freien Platz verbraucht, verhindert damit genau das Update,
-- mit dem man den Fehler beheben wollte. Im Feld gemeldet: 968 Bytes frei.

do
  local files, _, fs = fake_fs()
  local free = 1024 * 1024
  fs.getFreeSpace = function() return free end

  local w = writer_lib.new({
    fs_impl = fs, dir = '/logs', flush_ms = 0, min_free_bytes = 256 * 1024,
  })

  w.append({ 'T,1' }, 1)
  assert_true(files[w.path()] ~= nil, 'bei viel Platz wird geschrieben')
  local before = #files[w.path()]

  -- Jetzt wird es eng.
  free = 100 * 1024
  w.append({ 'T,2,sollte-nicht-erscheinen' }, 2)
  assert_eq(#files[w.path()], before,
    'unterhalb der Reserve darf NICHTS mehr geschrieben werden')
  assert_true(w.paused_for_space, 'und der Halt muss vermerkt sein')

  -- Der Puffer darf dabei nicht anwachsen -- sonst wandert das
  -- Platzproblem nur in den Hauptspeicher.
  assert_eq(#w.buffer, 0, 'der Puffer muss verworfen werden, nicht wachsen')

  -- Und sie gibt ihren eigenen Platz her: die Vorgaengerdateien zuerst.
  assert_eq(files[w.rotated_path(1)], nil, 'alte Trace-Dateien muessen weichen')

  -- Ist wieder Platz da, laeuft sie weiter.
  free = 1024 * 1024
  w.append({ 'T,3,wieder-da' }, 3)
  assert_true(files[w.path()]:find('wieder-da', 1, true) ~= nil,
    'mit wieder freiem Platz muss sie weiterschreiben')
  assert_eq(w.paused_for_space, false, 'und den Halt aufheben')
end

-- ── 7. Ohne getFreeSpace bleibt es beim bisherigen Verhalten ─────────────

do
  local files, _, fs = fake_fs()
  fs.getFreeSpace = nil
  local w = writer_lib.new({ fs_impl = fs, dir = '/logs', flush_ms = 0 })
  w.append({ 'T,1' }, 1)
  assert_true(files[w.path()] ~= nil,
    'ist der freie Platz nicht feststellbar, wird wie bisher geschrieben')
end

-- ── 8. "unlimited" ist kein Platzmangel ──────────────────────────────────

do
  local files, _, fs = fake_fs()
  fs.getFreeSpace = function() return 'unlimited' end
  local w = writer_lib.new({ fs_impl = fs, dir = '/logs', flush_ms = 0 })
  w.append({ 'T,1' }, 1)
  assert_true(files[w.path()] ~= nil,
    'ein unbegrenztes Laufwerk darf die Aufzeichnung nicht anhalten')
end

print('rt2_trace_writer_test.lua: ok')
