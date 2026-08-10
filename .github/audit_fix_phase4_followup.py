from pathlib import Path

ROOT = Path('.')

def read(path): return (ROOT / path).read_text(encoding='utf-8')
def write(path, text): (ROOT / path).write_text(text, encoding='utf-8')
def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{path}: expected one anchor, got {count}: {old[:100]!r}')
    write(path, text.replace(old, new, 1))

wiring = 'tests/install_p0_2_quiesce_wiring_test.lua'
replace_once(wiring,
'''--   FUEL:         redstone_router:shutdown_now()    + get_active_transaction()
--   REPROCESSOR:  enter_standby()                    (bereits idempotent)
''',
'''--   FUEL:         redstone_router:begin_quiesce() + poll_quiesce() bis alle
--                 aktuellen Netzwerk-/lokalen Ventile BLOCKED bestaetigen
--   REPROCESSOR:  enter_standby() + derselbe bestaetigte Router-Quiesce
''')
replace_once(wiring,
'''-- ── FUEL: shutdown_now() + get_active_transaction()-Bestaetigung ───────────
do
  local src = read("nodes/fuel/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "fuel/main.lua")
  assert_contains(src, 'rs_router:shutdown_now("UPDATE_QUIESCE")', "fuel/main.lua")
  assert_contains(src, "rs_router:get_active_transaction() == nil", "fuel/main.lua")
end

-- ── REPROCESSOR: enter_standby() ist bereits idempotent, wiederverwendet ───
do
  local src = read("nodes/reprocessor/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "reprocessor/main.lua")
  assert_contains(src, 'enter_standby("UPDATE_QUIESCE")', "reprocessor/main.lua")
  assert_contains(src, "return standby == true", "reprocessor/main.lua")
end
''',
'''-- ── FUEL: Runtime darf erst nach bestaetigtem all-BLOCKED stoppen ─────────
do
  local src = read("nodes/fuel/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "fuel/main.lua")
  assert_contains(src, 'rs_router:begin_quiesce("UPDATE_QUIESCE")', "fuel/main.lua")
  assert_contains(src, "return rs_router:poll_quiesce()", "fuel/main.lua")
end

-- ── REPROCESSOR: Standby plus bestaetigter all-BLOCKED Router-Quiesce ──────
do
  local src = read("nodes/reprocessor/main.lua")
  assert_contains(src, "_G.__xreactor_update_handshake", "reprocessor/main.lua")
  assert_contains(src, 'enter_standby("UPDATE_QUIESCE")', "reprocessor/main.lua")
  assert_contains(src, 'rs_router:begin_quiesce("UPDATE_QUIESCE")', "reprocessor/main.lua")
  assert_contains(src, "return standby == true and rs_router:poll_quiesce()", "reprocessor/main.lua")
end
''')

race = 'tests/redstone_router_refresh_transaction_race_test.lua'
replace_once(race,
'''-- Next idle tick applies the deferred discovery refresh safely.
router:tick(clock + 1)
assert(router._state.refresh_deferred == false, 'deferred refresh must be consumed after transaction')

print('redstone_router_refresh_transaction_race_test.lua: ok')
''',
'''-- Abbruch allein ist noch KEIN sicher bestaetigter Endzustand. Der neue
-- Safety-Latch muss sowohl neue Lieferungen ALS AUCH den deferred refresh
-- sperren, bis ein frisches BLOCKED-Kommando wirklich bestaetigt wurde.
router:tick(clock + 1)
assert(router:get_safety_latch() ~= nil, 'aborted route must stay safety-latched until fresh BLOCKED confirmation')
assert(router._state.refresh_deferred == true, 'deferred refresh must not rebuild bindings while final safety is unconfirmed')
local ok_new, why_new = router:begin_transaction('R1', function() end, 500)
assert(ok_new == false and why_new == 'safety_latched', 'new delivery must stay blocked while latch is unresolved')

-- Peer kommt wieder und bestaetigt das aktuell vom Latch angeforderte BLOCKED.
peers['VALVE-A'] = { down = false, stale = false }
ack_current(true)
router:tick(clock + 2)
assert(router:get_safety_latch() == nil, 'fresh BLOCKED confirmation should clear safety latch')
-- Der Refresh wird im selben Tick erst nach erfolgreicher Latch-Aufhebung
-- konsumiert; damit existiert kein Fenster mit unbestaetigter Safety.
assert(router._state.refresh_deferred == false, 'deferred refresh must be consumed only after safety latch clears')

print('redstone_router_refresh_transaction_race_test.lua: ok')
''')

print('phase4 followup regressions updated')
