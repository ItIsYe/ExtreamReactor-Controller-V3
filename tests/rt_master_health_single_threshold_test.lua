package.path = table.concat({ './tests/?.lua', './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Der Health-Check und die Zustandsmaschine muessen DIESELBE Aussage ueber
-- den MASTER treffen.
--
-- Vorgeschichte: der Knoten zeigte "MASTER DOWN", waehrend er im Zustand
-- MASTER regelte. Es gab drei Schwellen fuer dieselbe Tatsache --
-- comms.peer_timeout_s (20 s), rt2_master_link.TIMEOUT_MS (20 s) und hier
-- heartbeat_interval * 5 (10 s) -- und zwei Rueckfallwege, die sich
-- widersprachen.

local health_payload = require('nodes.rt.health_payload')

local function assert_true(v, m) if not v then error(m or 'assert_true failed', 2) end end

local CONSTANTS = { roles = { MASTER = 'MASTER' } }

local function ctx_with(opts)
  return {
    constants = CONSTANTS,
    comms = opts.peers and { get_peers = function() return opts.peers end } or nil,
    master_seen = opts.master_seen,
    hb = opts.hb or 2,
    peer_timeout_s = opts.peer_timeout_s,
  }
end

-- ── 1. Nie gesehener MASTER ist NICHT verbunden ──────────────────────────
--
-- Der Kern des Fehlers: main.lua uebergab (master_seen_ts or os.epoch),
-- ein nie gesehener MASTER kam also mit Alter 0 an.
do
  local connected = health_payload.is_master_connected(ctx_with({ master_seen = nil }))
  assert_true(connected == false,
    'ohne je eine MASTER-Nachricht darf die Verbindung nicht als gesund gelten')
end

-- ── 2. Der Rueckfallweg benutzt peer_timeout_s, nicht hb * 5 ─────────────
do
  local now = os.epoch("utc")

  -- 15 s alt: unter 20 s (peer_timeout_s), aber ueber 10 s (hb * 5).
  -- Vorher kam hier "nicht verbunden" heraus, waehrend rt2_master_link mit
  -- denselben 15 s "verbunden" sagte.
  local c15, age15 = health_payload.is_master_connected(ctx_with({
    master_seen = now - 15000, hb = 2, peer_timeout_s = 20.0 }))
  assert_true(c15 == true, string.format(
    '15 s alt muss bei peer_timeout_s = 20 verbunden sein (Alter %.1f s)', age15 or -1))

  local c25 = health_payload.is_master_connected(ctx_with({
    master_seen = now - 25000, hb = 2, peer_timeout_s = 20.0 }))
  assert_true(c25 == false, '25 s alt ist bei peer_timeout_s = 20 nicht mehr verbunden')

  -- Ohne Angabe gilt derselbe Default wie in rt2_master_link.
  local rt2_master_link = require('nodes.rt.rt2_master_link')
  assert_true(health_payload.DEFAULT_PEER_TIMEOUT_S * 1000 == rt2_master_link.TIMEOUT_MS,
    'der Default des Health-Checks muss dem der Zustandsmaschine entsprechen')

  local c_def = health_payload.is_master_connected(ctx_with({
    master_seen = now - 15000, hb = 2 }))
  assert_true(c_def == true, 'ohne peer_timeout_s gilt der gemeinsame Default von 20 s')
end

-- ── 3. Uhr-Ruecksprung gilt nicht als "ganz frisch" ──────────────────────
do
  local now = os.epoch("utc")
  local connected = health_payload.is_master_connected(ctx_with({
    master_seen = now + 3600000, peer_timeout_s = 20.0 }))
  assert_true(connected == false,
    'ein Zeitstempel aus der Zukunft ist wertlos, nicht frisch')
end

-- ── 4. Der FRISCHESTE MASTER-Peer gewinnt, nicht ein beliebiger ──────────
--
-- Die Peer-Tabelle kann mehrere MASTER-Eintraege tragen (ein abgemeldeter
-- unter alter Kennung, der laufende). pairs() hat keine festgelegte
-- Reihenfolge -- erwischte der Durchlauf den alten, stand "MASTER DOWN" auf
-- dem Schirm, obwohl der MASTER lief.
do
  local peers = {
    ['MASTER-alt']  = { role = 'MASTER', down = true,  age = 900 },
    ['MASTER-live'] = { role = 'MASTER', down = false, age = 1 },
    ['FUEL-1']      = { role = 'FUEL',   down = false, age = 1 },
  }
  -- Mehrfach pruefen: bei einem Reihenfolgefehler waere das Ergebnis
  -- nicht reproduzierbar.
  for attempt = 1, 20 do
    local peer = health_payload.master_peer_state(ctx_with({ peers = peers }))
    assert_true(peer ~= nil and peer.age == 1, string.format(
      'Versuch %d: es muss der frischeste MASTER-Eintrag gewaehlt werden', attempt))
    local connected = health_payload.is_master_connected(ctx_with({ peers = peers }))
    assert_true(connected == true, string.format(
      'Versuch %d: mit einem lebenden MASTER-Peer gilt die Verbindung', attempt))
  end

  -- Umgekehrt: ist der frischeste Eintrag down, ist er auch das Ergebnis.
  local all_down = {
    ['MASTER-a'] = { role = 'MASTER', down = true, age = 40 },
    ['MASTER-b'] = { role = 'MASTER', down = true, age = 25 },
  }
  local connected = health_payload.is_master_connected(ctx_with({ peers = all_down }))
  assert_true(connected == false, 'sind alle MASTER-Eintraege down, ist die Verbindung weg')
end

print('ok rt_master_health_single_threshold_test')
