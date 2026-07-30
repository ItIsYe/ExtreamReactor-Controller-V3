-- tests/log_collector_reclaim_cache_invalidation_test.lua
--
-- Pflicht-Test fuer LOG-P0 (siehe docs/CODING_AI_OTHER_NODES_PERFORMANCE_
-- 2026-07-12.md, Abschnitt 22 "KRITISCH OFFEN"). nodes/log_collector/
-- main.lua's free_space() cached ihren Rueckgabewert pro Mount fuer
-- FREE_SPACE_CACHE_TTL (2 echte Sekunden, per os.clock()).
-- reclaim_oldest() prueft vor JEDER Loeschung denselben gecachten Wert,
-- ohne ihn danach zu invalidieren. Da mehrere aufeinanderfolgende
-- Loeschungen innerhalb eines einzigen Reclaim-Laufs praktisch keine echte
-- Zeit verbrauchen, blieb der Cache-Eintrag ueber den GESAMTEN Lauf
-- "frisch" (aus os.clock()'s Sicht) -- die Schleife sah bei jeder Iteration
-- weiterhin den ALTEN, niedrigen Free-Space-Wert und loeschte munter
-- weiter, obwohl nach der ersten Loeschung bereits genug Platz frei war.
--
-- main.lua hat schwere Boot-Zeit-Seiteneffekte und kann nicht per
-- require() instanziiert werden -- reclaim_oldest()/free_space() werden
-- daher per Marker-Extraktion + load() aus dem echten Quelltext isoliert
-- (wie an anderer Stelle in dieser Suite etabliert, siehe z.B.
-- tests/log_collector_no_blanket_wipe_test.lua).

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local SRC = read("xreactor/nodes/log_collector/main.lua")

local START_MARKER = "local function safe_delete(path)"
local END_MARKER = "local function discover_disks()"

local start_pos = SRC:find(START_MARKER, 1, true)
assert(start_pos, "start marker not found")
local end_pos = SRC:find(END_MARKER, start_pos, true)
assert(end_pos, "end marker not found")
local block = SRC:sub(start_pos, end_pos - 1)

local chunk_src = "local MIN_FREE_BYTES = 8192\n"
  .. "local stats = { wiped = 0 }\n"
  .. block
  .. "\nreturn { reclaim_oldest = reclaim_oldest }\n"

-- Simulates a disk holding three files of equal size (oldest-to-newest:
-- c, b, a). Deleting exactly ONE file is enough to cross the requested
-- free-space target -- deleting a second would prove the cache-staleness
-- bug is still present.
local function make_fake_fs()
  local files = {
    ["/disk1/xreactor_logs/RT/c.log"] = { content = string.rep("c", 100), mtime = 10 },
    ["/disk1/xreactor_logs/RT/b.log"] = { content = string.rep("b", 100), mtime = 20 },
    ["/disk1/xreactor_logs/RT/a.log"] = { content = string.rep("a", 100), mtime = 30 },
  }
  local dirs = {
    ["/"] = true, ["/disk1"] = true, ["/disk1/xreactor_logs"] = true, ["/disk1/xreactor_logs/RT"] = true,
  }
  local get_free_space_calls = 0

  local fake = {}
  fake.exists = function(p) return files[p] ~= nil or dirs[p] == true end
  fake.isDir = function(p) return dirs[p] == true end
  fake.combine = function(a, b) return a .. "/" .. b end
  fake.delete = function(p) files[p] = nil end
  fake.attributes = function(p)
    if files[p] then return { modified = files[p].mtime } end
    return nil
  end
  fake.list = function(p)
    local out = {}
    local prefix = p .. "/"
    for k in pairs(files) do
      if k:sub(1, #prefix) == prefix then out[#out + 1] = k:sub(#prefix + 1) end
    end
    return out
  end
  -- Before any deletion: 2 of 3 files remain (200 bytes "used") -> free
  -- space is reported as LOW (below the 250-byte target). After exactly
  -- one deletion, only... this function recomputes from whatever is left
  -- in `files`, so it reflects reality -- the point of this test is
  -- whether reclaim_oldest() actually RE-QUERIES it after each delete
  -- instead of trusting a stale cached value.
  local CAPACITY = 300
  fake.getFreeSpace = function()
    get_free_space_calls = get_free_space_calls + 1
    local used = 0
    for _, f in pairs(files) do used = used + #f.content end
    return CAPACITY - used
  end

  return fake, files, function() return get_free_space_calls end
end

local function load_module(fake_fs)
  -- os.clock() NEVER advances across the whole test -- this is the exact
  -- real-world condition the bug depended on: synchronous deletions
  -- inside one reclaim_oldest() call consume no measurable wall-clock
  -- time, so a naive 2s TTL cache never sees itself as stale unless the
  -- code explicitly invalidates it after each deletion.
  local env = setmetatable({
    fs = fake_fs,
    os = { clock = function() return 1000 end, epoch = function() return 0 end },
  }, { __index = _G })
  local fn = assert(load(chunk_src, "=log_collector_reclaim_cache_test", "t", env))
  return fn()
end

do
  local fake_fs, files, get_calls = make_fake_fs()
  local mod = load_module(fake_fs)

  -- capacity(300) - used(300, all 3 files present) = 0 free, below the
  -- 100-byte target. Deleting exactly the single oldest file (c.log, 100
  -- bytes) brings free space to capacity(300) - used(200) = 100, which
  -- already satisfies the target -- a correct re-measurement must stop
  -- right there. A stale-cache bug would keep seeing "0 free" forever
  -- (os.clock() never advances in this test) and delete all three files.
  local removed = mod.reclaim_oldest("/disk1/xreactor_logs", "/disk1", 100)

  assert(removed == 1,
    "exactly one file must be removed once free space rises above the target after the first deletion -- " ..
    "removing more proves free_space() served a stale cached value instead of re-measuring: removed=" .. tostring(removed))
  assert(files["/disk1/xreactor_logs/RT/c.log"] == nil, "the oldest file (c.log) must be the one removed")
  assert(files["/disk1/xreactor_logs/RT/b.log"] ~= nil, "b.log must survive -- one deletion was already enough")
  assert(files["/disk1/xreactor_logs/RT/a.log"] ~= nil, "a.log must survive -- one deletion was already enough")
  assert(get_calls() >= 2, "free_space() must be re-queried (not served from a stale cache) after the deletion")
end

print("log_collector_reclaim_cache_invalidation_test.lua: ok")
