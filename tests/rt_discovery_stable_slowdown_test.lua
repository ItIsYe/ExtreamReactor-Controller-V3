-- Funktionaler Verifikationstest fuer RT-P0 "Discovery-Slowdown funktioniert
-- nicht wie dokumentiert" (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md Abschnitt 4). Extrahiert die exakten should_discover()/
-- discover_with_stability_tracking()-Funktionen aus nodes/rt/main.lua und
-- treibt sie ueber eine Fake-Clock mit einem 100ms-Scheduler-Tick, GENAU
-- wie das echte services/discovery_service.lua's tick() (due-Berechnung
-- und last_scan-nur-bei-echtem-Scan-Update) -- nicht nur ueber direkte
-- should_discover(..., due=true)-Aufrufe wie der fruehere (vom Audit als
-- Testluecke identifizierte) Test. Damit wird die tatsaechliche
-- Zeitinteraktion zwischen RT's Slowdown-Logik und dem geteilten Discovery-
-- Service abgedeckt, nicht nur ein Aufruf-Zaehler.

local REPO = os.getenv("REPO_ROOT") or "."

local function read_file(p)
  local f = assert(io.open(p, "r"))
  local c = f:read("*a")
  f:close()
  return c
end

local function extract(s, start_marker, end_marker)
  local a = s:find(start_marker, 1, true)
  assert(a, "start marker not found: " .. start_marker)
  local b = s:find(end_marker, a, true)
  assert(b, "end marker not found: " .. end_marker)
  return s:sub(a, b + #end_marker - 1)
end

local fail = 0
local function check(cond, msg)
  if not cond then print("FAIL: " .. msg); fail = fail + 1 end
end

local src = read_file(REPO .. "/xreactor/nodes/rt/main.lua")
local block_src = extract(src,
  "local DISCOVERY_STABLE_STREAK    = 3",
  "discovery_next_slow_scan_at = 0\n  end\nend")
assert(block_src:find("discover_with_stability_tracking", 1, true), "extraction missed discover_with_stability_tracking")

-- Baut eine FRISCHE Instanz von should_discover()/discover_with_stability_
-- tracking() mit eigenen, unabhaengigen Upvalues (discovery_stable_count/
-- discovery_next_slow_scan_at) -- jede Sektion dieses Tests braucht ihren
-- eigenen, sauberen Zustand statt sich einen geteilten Modul-Zustand ueber
-- mehrere Simulationslaeufe hinweg zu teilen.
local function make_module(make_discover)
  local env = {
    devices = { binding_signature = "stable-signature" },
    tonumber = tonumber,
  }
  env.discover = make_discover(env)
  env._ENV = env
  local chunk = assert(load(block_src .. "\nreturn { should_discover = should_discover, discover_with_stability_tracking = discover_with_stability_tracking }",
    "=discovery_stability", "t", env))
  return chunk(), env
end

local discover_calls = 0
local M = make_module(function()
  return function() discover_calls = discover_calls + 1 end
end)

-- Treibt die echte discovery_service.lua-Semantik nach: due wird aus
-- last_scan berechnet, last_scan wird NUR bei einem tatsaechlich
-- ausgefuehrten Scan aktualisiert -- exakt der Mechanismus, der den
-- urspruenglichen Bug (last_scan blieb bei einem uebersprungenen Scan
-- stehen, "due" blieb ab dann bei JEDEM 100ms-Tick wahr) ausgeloest hat.
local function make_fake_service(interval_s)
  return { interval = interval_s, last_scan = 0 }
end

local function fake_tick(service, ts)
  local due = ts - service.last_scan >= service.interval * 1000
  local should_scan = M.should_discover(service, ts, nil, due)
  if should_scan then
    service.last_scan = ts
    M.discover_with_stability_tracking()
    return true
  end
  return false
end

------------------------------------------------------------------------------
-- 180+ Sekunden Fake-Clock, 100ms-Scheduler-Tick, stabile Hardware
-- (binding_signature aendert sich nie): Scanabstaende sollen nach der
-- Boot-Phase tatsaechlich ungefaehr 60s betragen, kein Burst.
------------------------------------------------------------------------------

local service = make_fake_service(10)
local scan_ts_list = {}
local TICK_MS = 100
local TOTAL_MS = 190000

for ts = 0, TOTAL_MS, TICK_MS do
  if fake_tick(service, ts) then
    table.insert(scan_ts_list, ts)
  end
end

check(#scan_ts_list >= 5, "expected at least 5 scans over 190s (boot streak + several slow-mode scans), got " .. #scan_ts_list)

-- Boot-Phase: erste 3 Scans laufen auf normaler 10s-Kadenz.
check(scan_ts_list[1] == 10000, "first scan should run at the first due tick (10s), got " .. tostring(scan_ts_list[1]))
check(scan_ts_list[2] == 20000, "second boot-phase scan should run ~10s later, got " .. tostring(scan_ts_list[2]))
check(scan_ts_list[3] == 30000, "third boot-phase scan (reaches stability streak) should run ~10s later, got " .. tostring(scan_ts_list[3]))

-- Ab dem 5. Scan (nach dem ersten "Uebergangs"-Scan bei erreichter
-- Stabilitaet) muessen alle folgenden Abstaende ungefaehr 60s betragen --
-- NICHT ~0.6s wie beim urspruenglichen Bug, und kein Scanburst (mehrere
-- Scans dicht hintereinander).
for i = 5, #scan_ts_list do
  local gap = scan_ts_list[i] - scan_ts_list[i - 1]
  check(gap >= 59000 and gap <= 61000,
    string.format("scan %d gap should be ~60s once in slow mode, got %dms (scan_ts=%d)", i, gap, scan_ts_list[i]))
end

-- Kein Scan-Burst: es darf NIE zwei Scans innerhalb weniger als ~9s geben
-- (die kuerzeste legitime Kadenz ist die normale 10s-Basisrate).
for i = 2, #scan_ts_list do
  local gap = scan_ts_list[i] - scan_ts_list[i - 1]
  check(gap >= 9000, string.format("no scan burst allowed: gap between scan %d and %d was only %dms", i - 1, i, gap))
end

------------------------------------------------------------------------------
-- Eine echte Bindungsaenderung wird beim naechsten faelligen Scan erkannt
-- und setzt sofort auf die normale 10s-Kadenz zurueck (dokumentierte
-- maximale Erkennungszeit: bis zu einem Scanintervall im aktuellen Modus).
------------------------------------------------------------------------------

do
  local service2 = make_fake_service(10)
  local change_applied = false
  local discover_calls2 = 0
  local M2, env2 = make_module(function(env_ref)
    return function()
      discover_calls2 = discover_calls2 + 1
      if change_applied then
        env_ref.devices.binding_signature = "changed-signature"
      end
    end
  end)

  local function fake_tick2(service, ts)
    local due = ts - service.last_scan >= service.interval * 1000
    local should_scan = M2.should_discover(service, ts, nil, due)
    if should_scan then
      service.last_scan = ts
      M2.discover_with_stability_tracking()
      return true
    end
    return false
  end

  local scans2 = {}
  local change_injected_at = nil
  for ts = 0, 130000, TICK_MS do
    if ts == 45000 then
      -- Aenderung kurz nach einem Scan injizieren (Scans liegen bei
      -- 10s/20s/30s dann alle 60s -- 40s ist der naechste, danach 100s).
      change_applied = true
      change_injected_at = ts
    end
    if fake_tick2(service2, ts) then
      table.insert(scans2, ts)
    end
  end

  -- Scans bei 10s/20s/30s (Boot), 40s (Uebergang in Slow-Mode). Aenderung
  -- wird bei 45s injiziert -- muss beim naechsten faelligen Scan (100s,
  -- 60s nach dem 40s-Scan) erkannt werden, NICHT beim urspruenglich fuer
  -- den alten Bug typischen ~0.6s-Fenster.
  check(#scans2 >= 6, "expected at least 6 scans (4 pre-change + at least 2 post-detection), got " .. #scans2)
  local detection_ts = nil
  for _, ts in ipairs(scans2) do
    if ts > change_injected_at then detection_ts = ts; break end
  end
  check(detection_ts ~= nil, "the changed binding must eventually be detected by a scan")
  check(detection_ts - change_injected_at <= 60000,
    "detection latency must not exceed the documented slow-mode interval (~60s), got " ..
    tostring(detection_ts and (detection_ts - change_injected_at)))

  -- Nach der Erkennung: naechster Scan folgt wieder auf normaler 10s-Kadenz
  -- (Ruecksetzung des Stability-Streaks), nicht weiterhin im 60s-Rhythmus.
  local detection_index = nil
  for i, ts in ipairs(scans2) do
    if ts == detection_ts then detection_index = i; break end
  end
  if detection_index and scans2[detection_index + 1] then
    local post_gap = scans2[detection_index + 1] - scans2[detection_index]
    check(post_gap <= 11000,
      "the scan right after detecting a real change must return to the fast ~10s cadence, got gap=" .. post_gap)
  end
end

if fail == 0 then
  print("ALL CHECKS PASSED")
  os.exit(0)
else
  print(fail .. " CHECK(S) FAILED")
  os.exit(1)
end
