-- stats.disk_index wurde bei Boot auf 1 initialisiert und danach nirgends
-- mehr aktualisiert. disk_for_role() nutzt es als Fallback fuer Disks mit
-- unbekannter Rolle (stats.disks[stats.disk_index] or stats.disks[1]) --
-- ohne Rotation landeten alle Logs unbekannter Rollen dauerhaft auf Disk 1,
-- selbst wenn mehrere Disks verfuegbar waren. disk_for_role() muss
-- stats.disk_index nach jeder Zuweisung weiterdrehen.
--
-- main.lua hat schwere Boot-Zeit-Seiteneffekte und kann nicht per require()
-- instanziiert werden -- disk_for_role/role_index/free_space werden daher
-- per Marker-Extraktion + load() isoliert, wie bereits in
-- tests/log_collector_no_blanket_wipe_test.lua etabliert.

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local SRC = read("xreactor/nodes/log_collector/main.lua")

local ROLE_ORDER_SRC = SRC:match("ROLE_ORDER%s*=%s*(%b{})")
assert(ROLE_ORDER_SRC, "could not extract ROLE_ORDER from main.lua")

local START_MARKER = "local function free_space(path)"
local END_MARKER = "-- Lesbares Datum"

local start_pos = SRC:find(START_MARKER, 1, true)
assert(start_pos, "start marker not found")
local end_pos = SRC:find(END_MARKER, start_pos, true)
assert(end_pos, "end marker not found")
local block = SRC:sub(start_pos, end_pos - 1)

local chunk_src = "local ROLE_ORDER = " .. ROLE_ORDER_SRC .. "\n"
  .. "local free_space_cache = {}\n"
  .. "local FREE_SPACE_CACHE_TTL = 2\n"
  .. "local MIN_FREE_BYTES = 8192\n"
  .. "local stats\n"
  .. block
  .. "\nreturn { disk_for_role = disk_for_role, set_stats = function(s) stats = s end }\n"

local chunk = assert(load(chunk_src, "=log_collector_disk_rotation_slice"))
local mod = chunk()

local function make_disk(id, role, mount)
  return { id = id, mount = mount, role = role, role_group = nil, slot = 1 }
end

local stats = {
  disks = { make_disk(1, "UNKNOWN", "disk1"), make_disk(2, "UNKNOWN", "disk2"), make_disk(3, "UNKNOWN", "disk3") },
  disk_index = 1,
}
mod.set_stats(stats)

-- fs.getFreeSpace ist in dieser Sandbox nicht vorhanden -- free_space()
-- faellt dann auf 0 zurueck, was fuer den unbekannte-Rolle-Zweig (der
-- free_space gar nicht aufruft) irrelevant ist.

local seen = {}
for i = 1, 6 do
  local disk = mod.disk_for_role("SOME-UNKNOWN-ROLE")
  assert(disk, "expected a disk to be returned for an unknown role")
  seen[#seen + 1] = disk.mount
end

-- Erwartung: die Zuweisungen rotieren rundlaufend ueber alle 3 Disks statt
-- immer "disk1" zurueckzugeben.
local distinct = {}
for _, m in ipairs(seen) do distinct[m] = true end
local distinct_count = 0
for _ in pairs(distinct) do distinct_count = distinct_count + 1 end

if distinct_count < 3 then
  error("expected disk_for_role to rotate across all 3 disks for an unknown role, got only: " ..
    table.concat(seen, ","))
end

if seen[1] ~= "disk1" or seen[2] ~= "disk2" or seen[3] ~= "disk3" or seen[4] ~= "disk1" then
  error("expected strict round-robin disk1,disk2,disk3,disk1,... got: " .. table.concat(seen, ","))
end

print('log_collector_unknown_role_disk_rotation_test.lua: ok')
