package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Zwei P1-Befunde aus dem ATM10-8.1-Audit, beide vorher mit eigenen
-- Gegenproben reproduziert:
--
-- P01  Ein fest konfigurierter REPROCESSOR-Sorter, der gerade fehlt, wurde
--      durch einen BELIEBIGEN anderen ersetzt -- ohne Meldung.
-- W02  WATER nahm nach einem Neustart an, seine Ausgaenge seien aus, und
--      glich einen bereits aktiven externen Ausgang nie ab.

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end
local function assert_eq(a, e, m)
  if a ~= e then error((m or 'assert_eq') .. ': erwartet=' .. tostring(e) .. ' ist=' .. tostring(a), 2) end
end

-- ── P01: eine ausdrueckliche Bindung ist verbindlich ─────────────────────
--
-- Vorher startete die allgemeine Methodensuche auch dann, wenn ein
-- konkreter Name konfiguriert, aber gerade nicht verfuegbar war. Der
-- Sorter verstellt seine Default-Farbe und damit sein Routing -- auf einem
-- gemeinsamen Peripherie-Netz mit FUEL gehoert der naechste gefundene
-- Sorter oft einem ganz anderen Zweig der Anlage. Gegenprobe vorher:
-- konfiguriert "sorter_mine", vorhanden nur "sorter_fremd" -> gebunden
-- wurde "sorter_fremd", und zwar ohne jede Warnung.
do
  local devices = {}
  local SORTER_METHODS = { 'setDefaultColor', 'getDefaultColor', 'setAutoMode' }
  _G.peripheral = {
    getNames = function()
      local out = {}
      for n in pairs(devices) do out[#out + 1] = n end
      table.sort(out); return out
    end,
    isPresent = function(n) return devices[n] ~= nil end,
    getType = function(n) return devices[n] and 'logisticalSorter' or nil end,
    getMethods = function(n) return devices[n] and SORTER_METHODS or {} end,
    wrap = function(n)
      if not devices[n] then return nil end
      return setmetatable({}, { __index = function() return function() return true end end })
    end,
    call = function() return true end,
  }
  os.epoch = function() return 1000000 end
  local feed_router = require('nodes.reprocessor.feed_router')

  local function bind(configured, present)
    devices = {}
    for _, n in ipairs(present) do devices[n] = true end
    local warns = {}
    local r = feed_router.new({
      config = { feed = { sorter = configured } },
      log = function() end,
      warn_once = function(_, m) warns[#warns + 1] = m end,
    })
    r:refresh_peripherals()
    return r._state.sorter_name, warns, r._state.sorter
  end

  local name = bind('sorter_mine', { 'sorter_mine', 'sorter_fremd' })
  assert_eq(name, 'sorter_mine', 'der konfigurierte Sorter wird gebunden, wenn er da ist')

  local name2, warns2, adapter2 = bind('sorter_mine', { 'sorter_fremd' })
  assert_true(name2 ~= 'sorter_fremd',
    'ein fehlender GEBUNDENER Sorter darf nicht durch einen fremden ersetzt werden')
  assert_eq(adapter2, nil, 'und es darf gar kein Sorter gebunden sein')
  local said_so = false
  for _, w in ipairs(warns2) do if w:find('sorter_mine', 1, true) then said_so = true end end
  assert_true(said_so, 'das fehlende gebundene Geraet muss beim Namen genannt werden')

  local name3 = bind('sorter_mine', {})
  assert_eq(name3, nil, 'ohne jeden Sorter bleibt es ungebunden')

  -- Ohne Konfiguration darf die Methodensuche weiterhin entscheiden --
  -- das ist der bewusst ungebundene Fall.
  local name4 = bind(nil, { 'sorter_fremd' })
  assert_eq(name4, 'sorter_fremd', 'ohne konfigurierten Namen bleibt die automatische Suche erlaubt')
end

-- ── W02: WATER gleicht seine Ausgaenge beim Start ab ─────────────────────
--
-- manage_clusters() ist eine lokale Funktion im Boot-Skript und nicht
-- require()-bar -- dieselbe Marker-Extraktion wie in
-- tests/water_rt_persistence_ack_honesty_test.lua.
--
-- Der Fehler: ein frischer Softwarezustand begann mit filling=false,
-- draining=false, und der Im-Band-Zweig schreibt nur, wenn eines dieser
-- Flags vorher gesetzt war. Ein externer Fuellausgang, der beim Neustart
-- bereits an war, blieb damit an, waehrend die Software "nicht fuellend"
-- meldete. Einen Readback des Istzustands gibt es in der Datei nicht.
do
  local function read(path)
    local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
    local c = f:read('*a'); f:close(); return c
  end
  local source = read('xreactor/nodes/water/main.lua')
  local start_pos = source:find('local function manage_clusters()', 1, true)
  assert(start_pos, 'manage_clusters nicht gefunden')
  local end_pos = source:find('\n::continue::', start_pos, true)
    or source:find('\nlocal function ', start_pos + 10, true)
  assert(end_pos, 'Ende von manage_clusters nicht gefunden')
  -- Bis zum Ende der Funktion: die naechste Zeile, die auf Spaltenanfang
  -- "end" enthaelt und auf den goto-Block folgt.
  local tail = source:find('\nend\n', end_pos, true)
  assert(tail, 'Funktionsende nicht gefunden')
  local block = source:sub(start_pos, tail + 4)

  local function load_manage(clusters, level, outputs)
    local writes = {}
    local env = setmetatable({
      config = { clusters = clusters },
      cluster_states = {},
      read_tank_level = function() return level end,
      set_rs_output = function(side, value)
        writes[#writes + 1] = tostring(side) .. '=' .. tostring(value)
        outputs[side] = value and true or false
        return true
      end,
      warn_once = function() end,
      utils = { log = function() end },
    }, { __index = _G })
    local chunk = block .. '\nreturn { manage_clusters = manage_clusters, states = cluster_states }\n'
    local fn = assert(load(chunk, '=water_manage_clusters_test', 't', env))
    local mod = fn()
    return mod, writes, env
  end

  local CLUSTER = { { name = 'A', tank = 'tank_0', min_volume = 10, max_volume = 20,
                      fill_side = 'left', drain_side = 'right' } }

  -- 1. Der eigentliche Fehler: Tank im Band, externer Fuellausgang bereits AN.
  do
    local outputs = { left = true, right = false }
    local mod, writes = load_manage(CLUSTER, 15, outputs)
    mod.manage_clusters()
    assert_eq(outputs.left, false,
      'ein bereits aktiver Fuellausgang MUSS beim Start abgeglichen werden -- das war der Fehler')
    assert_eq(outputs.right, false)
    assert_true(#writes >= 2, 'beim unbekannten Istzustand muessen beide Ausgaenge geschrieben werden')
    assert_eq(mod.states['A'].known, true, 'danach gilt der Zustand als bekannt')
    assert_eq(mod.states['A'].filling, false)
  end

  -- 2. Danach wird nicht mehr unnoetig geschrieben.
  do
    local outputs = { left = true, right = false }
    local mod = load_manage(CLUSTER, 15, outputs)
    mod.manage_clusters()
    local before = outputs.left
    local count_before = 0
    for _ in pairs(mod.states) do count_before = count_before + 1 end
    mod.manage_clusters()
    mod.manage_clusters()
    assert_eq(outputs.left, before, 'der Zustand bleibt stabil')
    assert_eq(count_before, 1)
  end

  -- 3. Unter dem Minimum wird gefuellt -- auch beim allerersten Durchlauf.
  do
    local outputs = { left = false, right = true }
    local mod = load_manage(CLUSTER, 5, outputs)
    mod.manage_clusters()
    assert_eq(outputs.left, true, 'unter dem Minimum muss gefuellt werden')
    assert_eq(outputs.right, false, 'und der Ablauf muss zu sein -- auch wenn er extern offen war')
    assert_eq(mod.states['A'].filling, true)
  end

  -- 4. Ueber dem Maximum wird abgelassen, analog.
  do
    local outputs = { left = true, right = false }
    local mod = load_manage(CLUSTER, 25, outputs)
    mod.manage_clusters()
    assert_eq(outputs.right, true, 'ueber dem Maximum muss abgelassen werden')
    assert_eq(outputs.left, false, 'und der Zulauf muss zu sein')
  end

  -- 5. Unbekannter Tankstand bleibt wie bisher BLOCK_ALL.
  do
    local outputs = { left = true, right = true }
    local mod = load_manage(CLUSTER, nil, outputs)
    mod.manage_clusters()
    assert_eq(outputs.left, false); assert_eq(outputs.right, false)
    assert_eq(mod.states['A'].read_failed, true)
  end
end

print('audit_bindings_and_outputs_test.lua: ok')
