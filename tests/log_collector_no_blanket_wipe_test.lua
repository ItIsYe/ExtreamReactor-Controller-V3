-- tests/log_collector_no_blanket_wipe_test.lua
--
-- INSTALL/LOG-P0 (docs/CODING_AI_OTHER_NODES_PERFORMANCE_2026-07-12.md,
-- Abschnitt 16): nodes/log_collector/main.lua's probe_disk() loeschte
-- bisher bei EINEM fehlgeschlagenen Schreibversuch den GESAMTEN Rollen-
-- Logordner der Disk, und die Platzmangel-Behandlung (vor jedem Log-Write
-- und beim Out-of-Space-Retry) loeschte ebenfalls den kompletten Ordner
-- in einem Schritt, statt gezielt nur die aeltesten Dateien zu entfernen.
--
-- main.lua selbst hat schwere Boot-Zeit-Seiteneffekte (Modem-/Disk-
-- Discovery, UI-Loop) und kann nicht per require() instanziiert werden --
-- die betroffenen Funktionen (probe_disk, reclaim_oldest,
-- list_files_recursive) werden daher per Marker-Extraktion + load() aus
-- dem echten Quelltext isoliert, wie an anderer Stelle in dieser Suite
-- etabliert (siehe z.B. tests/valve_failed_write_retry_test.lua).

local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local c = f:read("*a")
  f:close()
  return c
end

local SRC = read("xreactor/nodes/log_collector/main.lua")

local MIN_FREE_BYTES = tonumber(SRC:match("MIN_FREE_BYTES%s*=%s*(%d+)"))
assert(MIN_FREE_BYTES, "could not extract MIN_FREE_BYTES from main.lua")

local START_MARKER = "local function safe_delete(path)"
local END_MARKER = "local function discover_disks()"

local start_pos = SRC:find(START_MARKER, 1, true)
assert(start_pos, "start marker not found")
local end_pos = SRC:find(END_MARKER, start_pos, true)
assert(end_pos, "end marker not found")
local block = SRC:sub(start_pos, end_pos - 1)

local chunk_src = "local MIN_FREE_BYTES = " .. MIN_FREE_BYTES .. "\n"
  .. "local stats = { wiped = 0 }\n"
  .. block
  .. "\nreturn { probe_disk = probe_disk, reclaim_oldest = reclaim_oldest, "
  .. "list_files_recursive = list_files_recursive, RECLAIM_TARGET_BYTES = RECLAIM_TARGET_BYTES }\n"

local function make_fake_fs(capacity)
  local files = {}
  local dirs = { ["/"] = true }
  local fail_probe_write = false

  local function total_used()
    local sum = 0
    for _, f in pairs(files) do sum = sum + #f.content end
    return sum
  end

  local fake = {}
  fake.exists = function(p) return files[p] ~= nil or dirs[p] == true end
  fake.isDir = function(p) return dirs[p] == true end
  fake.makeDir = function(p) dirs[p] = true end
  fake.combine = function(a, b) return a .. "/" .. b end
  fake.delete = function(p) files[p] = nil; dirs[p] = nil end
  fake.attributes = function(p)
    if files[p] then return { modified = files[p].mtime } end
    return nil
  end
  fake.getFreeSpace = function() return capacity - total_used() end
  fake.list = function(p)
    local out = {}
    local prefix = p .. "/"
    for k in pairs(files) do
      if k:sub(1, #prefix) == prefix and not k:sub(#prefix + 1):find("/", 1, true) then
        out[#out + 1] = k:sub(#prefix + 1)
      end
    end
    for k in pairs(dirs) do
      if k ~= p and k:sub(1, #prefix) == prefix and not k:sub(#prefix + 1):find("/", 1, true) then
        out[#out + 1] = k:sub(#prefix + 1)
      end
    end
    return out
  end
  fake.open = function(p, mode)
    if mode == "w" then
      if fail_probe_write and p:match("%.probe$") then return nil end
      local buf = {}
      return {
        write = function(s) buf[#buf + 1] = s end,
        close = function() files[p] = { content = table.concat(buf), mtime = 0 } end,
      }
    elseif mode == "r" then
      if not files[p] then return nil end
      local content = files[p].content
      return { readAll = function() return content end, close = function() end }
    end
  end

  local function put_file(path, content, mtime)
    files[path] = { content = content, mtime = mtime }
    -- Register every intermediate directory so fake.list()/fake.isDir()
    -- can see this file the same way real CC:Tweaked fs would.
    local accum = ""
    for segment in path:gmatch("[^/]+") do
      accum = accum .. "/" .. segment
      if accum ~= path then dirs[accum] = true end
    end
  end
  local function set_fail_probe(v) fail_probe_write = v end
  return fake, files, put_file, set_fail_probe
end

local function load_module(fake_fs)
  local clock_counter = 0
  local env = setmetatable({
    fs = fake_fs,
    os = {
      clock = function() clock_counter = clock_counter + 10; return clock_counter end,
      epoch = function() return 0 end,
    },
  }, { __index = _G })
  local fn = assert(load(chunk_src, "=log_collector_disk_test", "t", env))
  return fn()
end

-- ---------------------------------------------------------------------
-- 1) probe_disk(): a failing write-probe must NOT touch pre-existing log
--    files -- only its own ".probe" artifact may ever be involved.
-- ---------------------------------------------------------------------
do
  local fake_fs, files, put_file, set_fail_probe = make_fake_fs(1000000)
  put_file("/disk1/xreactor_logs/RT/node-a.log", "important log line 1\n", 100)
  put_file("/disk1/xreactor_logs/RT/node-b.log", "important log line 2\n", 200)
  local mod = load_module(fake_fs)

  set_fail_probe(true)
  local ok = mod.probe_disk("/disk1")
  assert(ok == false, "probe_disk() must report failure when the write-probe fails")
  assert(files["/disk1/xreactor_logs/RT/node-a.log"] ~= nil,
    "a failed probe must not delete pre-existing log files (node-a.log)")
  assert(files["/disk1/xreactor_logs/RT/node-b.log"] ~= nil,
    "a failed probe must not delete pre-existing log files (node-b.log)")

  set_fail_probe(false)
  local ok2 = mod.probe_disk("/disk1")
  assert(ok2 == true, "probe_disk() must succeed once the write-probe stops failing")
  assert(files["/disk1/xreactor_logs/RT/node-a.log"] ~= nil,
    "a successful probe must still leave pre-existing log files untouched")
end

-- ---------------------------------------------------------------------
-- 2) reclaim_oldest(): removes the OLDEST files first, stops as soon as
--    enough space is free, and never wipes everything in one shot.
-- ---------------------------------------------------------------------
do
  local fake_fs, files, put_file = make_fake_fs(1200)
  -- Oldest-to-newest: c (mtime=10), b (mtime=20), a (mtime=30). Each file
  -- is 300 bytes; capacity 1200 bytes total means only ~900 bytes are
  -- "used" by these three files, so free space already looks fine until
  -- we shrink capacity via a 4th, bigger, most-recent file.
  put_file("/disk1/xreactor_logs/RT/c.log", string.rep("c", 300), 10)
  put_file("/disk1/xreactor_logs/RT/b.log", string.rep("b", 300), 20)
  put_file("/disk1/xreactor_logs/RT/a.log", string.rep("a", 300), 30)
  put_file("/disk1/xreactor_logs/RT/newest.log", string.rep("n", 500), 40)

  local mod = load_module(fake_fs)
  -- capacity(1200) - used(1400) = negative free space right now.
  local removed = mod.reclaim_oldest("/disk1/xreactor_logs", "/disk1", 200)

  assert(removed >= 1 and removed < 4,
    "reclaim_oldest() must remove only as many files as needed, never the whole directory at once: removed=" .. tostring(removed))
  assert(files["/disk1/xreactor_logs/RT/c.log"] == nil,
    "the oldest file (c.log, mtime=10) must be removed first")
  assert(files["/disk1/xreactor_logs/RT/newest.log"] ~= nil,
    "the most recently modified file must survive a partial reclaim")
end

print("log_collector_no_blanket_wipe_test.lua: ok")
