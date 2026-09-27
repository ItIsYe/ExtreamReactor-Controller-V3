package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- MASTERs Startup-Sequencer lief bei jeder RT-Node in einen Timeout.
--
-- Im Feld gemessen: `Timeout stage=WAITING_ACK elapsed=60.2s`, Warteschlange
-- 51 von 52. Die Node hatte das Kommando angenommen -- MASTER hat die
-- Quittung nur nicht zuordnen koennen.
--
-- Die Zuordnung laeuft ueber genau ein Feld
-- (master/message_handlers.lua -> master/startup_sequencer.lua):
--     sequencer:notify_ack(id, result.module_id)
--     ... if self.active.module_id == module_id then -> WAITING_STABLE
--
-- v1s command_handler.lua gab `module_id` mit. Beim Umstieg auf den
-- rt2-Regler ging das Feld verloren: rt2_command_handler kannte nur
-- ok/error/reason_code. MASTER verglich gegen nil, blieb in WAITING_ACK und
-- lief nach 60 s in handle_timeout() -- und das ist kein reines Logging: es
-- verwirft die GANZE Warteschlange, schickt MODE=LIMITED (bzw. EMERGENCY)
-- und meldet einen Alarm.
--
-- Dieser Test verdrahtet BEIDE echten Seiten gegeneinander: den echten
-- Sequencer und den echten RT-Kommandopfad. Kein Nachbau der Quittung --
-- genau der Nachbau hatte die Luecke ja nicht.

local sequencer_lib = require('master.startup_sequencer')
local rt2_command_handler = require('nodes.rt.rt2_command_handler')
local rt2_state = require('nodes.rt.rt2_state')
local constants = require('shared.constants')

local function assert_eq(a, e, m)
  if a ~= e then error((m or 'eq') .. ': expected=' .. tostring(e) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local MODULE_IDS = { 'turbine:Turbine_1', 'turbine:Turbine_2', 'reactor:Reactor_7' }

local function build_node()
  local modules = {}
  for _, id in ipairs(MODULE_IDS) do
    modules[id] = {
      state = 'STABLE',
      type = id:find('turbine', 1, true) and 'turbine' or 'reactor',
      name = id,
    }
  end
  return {
    id = 'node-101',
    mode = 'MASTER',
    status = constants.status_levels.OK,
    state = constants.node_states.RUNNING,
    modules = modules,
  }
end

-- Der Kommandopfad der RT-Node, so wie main.lua ihn baut: der Handler
-- entscheidet, main.lua's handle_command_rt2() formt die Quittung.
local function rt_node_ack(command)
  local result = rt2_command_handler.handle(command, { state = rt2_state.states.MASTER })
  return {
    ok = result.ok,
    error = result.error,
    reason_code = result.reason_code,
    module_id = result.module_id,
  }
end

-- ── 1. Die Quittung traegt die module_id, die MASTER geschickt hat ───────

do
  local ack = rt_node_ack({
    target = constants.command_targets.STARTUP_STAGE,
    value = { module_id = 'turbine:Turbine_1', module_type = 'turbine', ramp_profile = 'NORMAL' },
  })
  assert_eq(ack.ok, true, 'die Node muss das Startup-Kommando annehmen')
  assert_eq(ack.module_id, 'turbine:Turbine_1',
    'ohne dieses Feld kann MASTER die Quittung nicht zuordnen -- das war der Fehler')
end

-- Auch ohne value darf nichts krachen (aeltere/fremde Absender).
do
  local ack = rt_node_ack({ target = constants.command_targets.STARTUP_STAGE })
  assert_eq(ack.ok, true, 'ein Startup-Kommando ohne value bleibt angenommen')
  assert_eq(ack.module_id, nil, 'und erfindet keine module_id')
end

-- ── 2. Der echte Sequencer kommt damit durch alle Module ────────────────

do
  local sent = {}
  local comms = {
    send_command = function(_, node_id, payload) sent[#sent + 1] = { node_id = node_id, payload = payload } end,
  }
  -- send_command wird als comms:send_command(...) aufgerufen -> self zuerst.
  comms.send_command = function(self, node_id, payload)
    if type(self) ~= 'table' then node_id, payload = self, node_id end
    sent[#sent + 1] = { node_id = node_id, payload = payload }
  end

  local seq = sequencer_lib.new(comms, 'NORMAL', { timeout_s = 60 })
  local node = build_node()
  local nodes = { ['node-101'] = node }

  seq:enqueue('node-101', 'TEST')
  seq.build_steps(nodes)
  assert_eq(#seq.queue, #MODULE_IDS, 'der Plan muss jedes Modul enthalten')

  local completed = 0
  for step = 1, #MODULE_IDS do
    seq:tick(nodes)   -- IDLE -> Kommando raus -> WAITING_ACK
    assert_eq(seq.state, 'WAITING_ACK', 'Schritt ' .. step .. ': kein Kommando gesendet')

    local command = sent[#sent].payload
    local ack = rt_node_ack(command)
    assert_eq(ack.ok, true, 'Schritt ' .. step .. ': die Node lehnt ab')

    seq:notify_ack('node-101', ack.module_id)
    assert_eq(seq.state, 'WAITING_STABLE',
      'Schritt ' .. step .. ': MASTER konnte die Quittung nicht zuordnen und'
        .. ' bleibt in WAITING_ACK -- genau der 60s-Timeout aus dem Feld')

    -- Der Modulzustand kommt aus rt2_projection.lua und ist STABLE.
    seq:notify_stable('node-101', seq.active.module_id, 'STABLE')
    assert_eq(seq.state, 'IDLE', 'Schritt ' .. step .. ': der Schritt wird nicht abgeschlossen')
    completed = completed + 1
  end

  assert_eq(completed, #MODULE_IDS, 'nicht alle Module durchlaufen')
  assert_eq(#seq.queue, 0, 'die Warteschlange muss leer sein')
  assert_eq(seq.active, nil, 'kein Schritt darf offen bleiben')
end

-- ── 3. Eine falsche id darf NICHT zufaellig passen ──────────────────────
--
-- Die Zuordnung ist der Sinn der Sache. Ein Sequencer, der jedes ACK
-- akzeptiert, waere genauso kaputt -- nur in die andere Richtung.

do
  local sent = {}
  local comms = { send_command = function(self, node_id, payload)
    if type(self) ~= 'table' then node_id, payload = self, node_id end
    sent[#sent + 1] = { node_id = node_id, payload = payload }
  end }
  local seq = sequencer_lib.new(comms, 'NORMAL', { timeout_s = 60 })
  local nodes = { ['node-101'] = build_node() }
  seq:enqueue('node-101', 'TEST')
  seq.build_steps(nodes)
  seq:tick(nodes)
  assert_eq(seq.state, 'WAITING_ACK', 'kein Kommando gesendet')
  seq:notify_ack('node-101', 'turbine:GIBT_ES_NICHT')
  assert_eq(seq.state, 'WAITING_ACK', 'ein fremdes ACK darf den Schritt nicht abschliessen')
  seq:notify_ack('node-101', nil)
  assert_eq(seq.state, 'WAITING_ACK', 'und ein ACK ohne id erst recht nicht')
end

print('master_rt_startup_ack_correlation_test.lua: ok')
