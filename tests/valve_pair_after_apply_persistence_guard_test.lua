local function read(p) local f=assert(io.open(p,'r'));local s=f:read('*a');f:close();return s end
local root=os.getenv('REPO_ROOT') or '.'
local s=read(root..'/xreactor/nodes/valve/main.lua')
local validate=s:find('if type(message.high) ~= "boolean" then',1,true)
local apply=s:find('local applied = apply_valve(message.high',validate or 1,true)
local pair=s:find('config.trusted_source = message.src',apply or 1,true)
local persist=s:find('utils.write_config(CONFIG.CONFIG_PATH, config)',pair or 1,true)
assert(validate and apply and pair and persist and validate < apply and apply < pair and pair < persist,
  'VALVE pairing must happen only after full validation and successful physical apply')
assert(s:find('config.trusted_source = nil',persist,true),'pair persistence failure must undo RAM trust')
assert(s:find('local blocked_ok = apply_valve(true, true)',persist,true),
  'pair persistence failure must force a fresh physical BLOCKED write')
assert(s:find('PAIRING_PERSIST_FAILED',persist,true),'ACK must surface pairing persistence failure')
print('valve_pair_after_apply_persistence_guard_test.lua: ok')
