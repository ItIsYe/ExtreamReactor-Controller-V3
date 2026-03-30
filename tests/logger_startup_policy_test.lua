local package_path = package.path
package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local original_fs = _G.fs
local original_settings = _G.settings
local original_os = _G.os
local original_print = _G.print
local original_peripheral = _G.peripheral
local original_disk = _G.disk

local files = {}
local dirs = {
  ["/"] = true,
  ["/xreactor_logs"] = true
}
local moves = {}
local print_lines = {}
local disk_writable = true
local disk_present = true
local disk_roots = {
  disk = true
}
local peripheral_drives = {}
local free_space_by_path = {
  ["/disk"] = 800000
}

local function write_file(path, content)
  files[path] = content or ""
end

local function ensure_dir(path)
  dirs[path] = true
end

local function parent_dir(path)
  return (path:match("^(.*)/[^/]+$")) or "/"
end

_G.fs = {
  exists = function(path)
    if path:match("^/disk%d*$") then
      return disk_present and disk_roots[path:sub(2)] == true
    end
    return files[path] ~= nil or dirs[path] == true
  end,
  isDir = function(path)
    if path:match("^/disk%d*$") then
      return disk_present and disk_roots[path:sub(2)] == true
    end
    return dirs[path] == true
  end,
  list = function(path)
    if path == "/" then
      local out = {}
      for name in pairs(disk_roots) do
        out[#out + 1] = name
      end
      return out
    end
    local out = {}
    local seen = {}
    local prefix = path == "/" and "/" or (path .. "/")
    for file_path in pairs(files) do
      if file_path:sub(1, #prefix) == prefix then
        local rest = file_path:sub(#prefix + 1)
        local first = rest:match("^([^/]+)")
        if first and not seen[first] then
          seen[first] = true
          out[#out + 1] = first
        end
      end
    end
    for dir_path in pairs(dirs) do
      if dir_path:sub(1, #prefix) == prefix then
        local rest = dir_path:sub(#prefix + 1)
        local first = rest:match("^([^/]+)")
        if first and not seen[first] then
          seen[first] = true
          out[#out + 1] = first
        end
      end
    end
    return out
  end,
  getFreeSpace = function(path)
    if free_space_by_path[path] ~= nil then
      return free_space_by_path[path]
    end
    return 800000
  end,
  makeDir = function(path)
    ensure_dir(path)
  end,
  getSize = function(path)
    return #(files[path] or "")
  end,
  delete = function(path)
    local dir = parent_dir(path)
    local reclaimed = #(files[path] or "")
    if reclaimed > 0 and free_space_by_path[dir] ~= nil then
      free_space_by_path[dir] = free_space_by_path[dir] + reclaimed
    end
    files[path] = nil
    dirs[path] = nil
  end,
  move = function(src, dst)
    moves[#moves + 1] = { src = src, dst = dst }
    files[dst] = files[src]
    files[src] = nil
  end,
  open = function(path, mode)
    local dir = parent_dir(path)
    if not (dirs[dir] or dir == "/") then
      return nil
    end
    if path:sub(1, 5) == "/disk" and (not disk_present or not disk_writable) then
      return nil
    end
    if mode == "w" then
      files[path] = ""
      return {
        write = function(self, text) files[path] = files[path] .. tostring(text or "") end,
        close = function() end
      }
    end
    if mode == "a" then
      files[path] = files[path] or ""
      return {
        write = function(self, text) files[path] = files[path] .. tostring(text or "") end,
        close = function() end
      }
    end
    return nil
  end
}

_G.settings = { get = function() return false end }
_G.os = _G.os or {}
os.date = function() return "00:00:00" end
local clock_tick = 0
os.clock = function()
  clock_tick = clock_tick + 1
  return clock_tick
end
_G.print = function(message)
  print_lines[#print_lines + 1] = tostring(message)
end
_G.peripheral = {
  getNames = function()
    local out = {}
    for name in pairs(peripheral_drives) do
      out[#out + 1] = name
    end
    return out
  end,
  hasType = function(name, wanted)
    return wanted == "drive" and peripheral_drives[name] ~= nil
  end
}
_G.disk = {
  getMountPath = function(name)
    return peripheral_drives[name]
  end
}

package.loaded["core.logger"] = nil
local logger = require("core.logger")

ensure_dir("/disk")
write_file("/disk/xreactor_logs/rt.log.1", "old-1")
write_file("/disk/xreactor_logs/rt.log.2", "old-2")
write_file("/disk/xreactor_logs/rt.log.preboot", "old-preboot")
write_file("/disk/xreactor_logs/.xreactor_log_probe", "stale-probe")
local status = logger.init({ log_name = "rt", enabled = true, truncate = true })
if status.log_dir ~= "/disk/xreactor_logs" then
  error("expected auto disk log_dir when disk is suitable")
end
if not tostring(status.log_source):find("auto%-disk:/disk", 1, false) then
  error("expected auto-disk source with disk root")
end
if files["/disk/xreactor_logs/rt.log.1"] or files["/disk/xreactor_logs/rt.log.2"] or files["/disk/xreactor_logs/rt.log.preboot"] then
  error("expected startup cleanup to delete stale disk log rotations")
end
if files["/disk/xreactor_logs/.xreactor_log_probe"] then
  error("expected startup cleanup to remove stale probe file")
end
if tostring(status.startup_action):find("non%-disk", 1, false) then
  error("disk log target must not be classified as non-disk during cleanup")
end
if not tostring(status.startup_action):find("disk=true", 1, true) then
  error("expected startup action diagnostics to expose disk classification")
end
if not tostring(status.startup_action):find("executed=true", 1, true) then
  error("expected startup action diagnostics to expose cleanup execution")
end
if not tostring(status.startup_action):find("removed=4", 1, true) then
  error("expected startup action to expose disk cleanup result")
end
if not tostring(status.startup_action):find("rt.log.preboot", 1, true) then
  error("expected startup action to include removed filenames for diagnostics")
end
if not tostring(status.startup_action):find("startup_min_required=", 1, true) then
  error("expected startup diagnostics to include startup minimum threshold")
end
if not tostring(status.startup_action):find("startup_required_now=1", 1, true) then
  error("expected startup diagnostics to include immediate startup space requirement")
end
if not tostring(status.startup_action):find("target_budget=", 1, true) then
  error("expected startup diagnostics to include target budget threshold")
end
if not tostring(status.startup_action):find("startup_budget_ok=", 1, true) then
  error("expected startup diagnostics to include startup budget decision")
end

logger.log("RT", "disk-write", "INFO")
logger.flush()
if not files["/disk/xreactor_logs/rt.log"] then
  error("expected disk log file")
end

-- Simulate mounted network disk with real free space while /disk is nearly full.
disk_roots.disk = true
disk_roots.disk2 = true
ensure_dir("/disk2")
free_space_by_path["/disk"] = 13
free_space_by_path["/disk2"] = 120000
local network_status = logger.init({ log_name = "net", enabled = true, truncate = true })
if network_status.log_dir ~= "/disk2/xreactor_logs" then
  error("expected network disk mount to be selected when /disk is full")
end
if not tostring(network_status.log_source):find("auto%-disk:/disk2", 1, false) then
  error("expected auto-disk source for /disk2")
end
if tostring(network_status.startup_action):find("non%-disk", 1, false) then
  error("disk2 log target must not be classified as non-disk during cleanup")
end
if not tostring(network_status.startup_action):find("disk=true", 1, true) then
  error("expected startup action diagnostics to expose disk classification for /disk2")
end

-- Disk startup should remain on disk when there is enough room to start but less than target budget.
free_space_by_path["/disk2/xreactor_logs"] = 1724
local startup_tight_ok = logger.init({ log_name = "startup_tight_ok", enabled = true, truncate = true, log_dir = "/disk2/xreactor_logs" })
if startup_tight_ok.log_dir ~= "/disk2/xreactor_logs" then
  error("expected disk startup to stay on disk when startup minimum is satisfied")
end
if tostring(startup_tight_ok.startup_action):find("startup_space_reject", 1, true) then
  error("startup should not reject disk when startup minimum is satisfied")
end

-- Disk target must allow bigger budget than local.
write_file("/disk2/xreactor_logs/net.log", string.rep("d", 250000))
logger.log("RT", "disk-rotation-threshold-check", "INFO")
logger.flush()
if files["/disk2/xreactor_logs/net.log.1"] then
  error("disk logs should not rotate at local budget limit")
end


-- Disk preflight must reject writes when immediate space is exhausted and fallback before open fails.
free_space_by_path["/disk2/xreactor_logs"] = 80
logger.init({ log_name = "runtime_small_flush", enabled = true, truncate = true, log_dir = "/disk2/xreactor_logs" })
logger.log("RT", "tiny", "INFO")
logger.flush()
if not files["/disk2/xreactor_logs/runtime_small_flush.log"] then
  error("expected runtime small flush to stay on disk with realistic preflight requirement")
end
if files["/xreactor_logs/runtime_small_flush.log"] then
  error("small runtime flush must not fallback to local when disk has enough bytes for the pending write")
end

free_space_by_path["/disk2/xreactor_logs"] = 0
logger.init({ log_name = "runtime_preflight", enabled = true, truncate = true, log_dir = "/disk2/xreactor_logs" })
logger.log("RT", string.rep("runtime-preflight-check", 12), "INFO")
logger.flush()
if not files["/xreactor_logs/runtime_preflight.log"] then
  error("expected runtime preflight fallback to local for low disk space")
end
local saw_preflight_reason = false
for _, line in ipairs(print_lines) do
  if line:find("preflight%-space%-failed", 1, false) then
    saw_preflight_reason = true
    break
  end
end
if not saw_preflight_reason then
  error("expected runtime fallback warning to include preflight-space-failed diagnostics")
end

-- Runtime cleanup should recover space and avoid fallback when stale files can be removed.
free_space_by_path["/disk2/xreactor_logs"] = 8
write_file("/disk2/xreactor_logs/runtime_recover.log.1", string.rep("x", 256))
logger.init({ log_name = "runtime_recover", enabled = true, truncate = true, log_dir = "/disk2/xreactor_logs" })
logger.log("RT", "recoverable", "INFO")
logger.flush()
if not files["/disk2/xreactor_logs/runtime_recover.log"] then
  error("expected runtime cleanup recovery to keep log on disk")
end
if files["/xreactor_logs/runtime_recover.log"] then
  error("runtime cleanup recovery should not fallback to local")
end

-- Simulate disk disappearing after startup and require fallback.
disk_present = false
logger.log("RT", "fallback-local", "INFO")
logger.flush()
if not files["/xreactor_logs/rt.log"] then
  error("expected fallback to local log path")
end

write_file("/xreactor_logs/energy.log", string.rep("a", 200001))
logger.init({ log_name = "energy", enabled = true, truncate = false, log_dir = "/xreactor_logs" })
logger.log("ENERGY", "rotation-check", "INFO")
logger.flush()
if not files["/xreactor_logs/energy.log.1"] then
  error("expected size-based rotation backup file")
end
if #moves == 0 then
  error("expected fs.move to be called for rotation")
end

logger.init({ log_name = "override", enabled = true, truncate = true, log_dir = "/xreactor_logs/manual_logs" })
logger.log("OVERRIDE", "manual-path", "INFO")
logger.flush()
if not files["/xreactor_logs/manual_logs/override.log"] then
  error("expected explicit log_dir override to be honored")
end

-- Explicit disk targets with insufficient space should fallback to local.
disk_present = true
free_space_by_path["/disk/tight_logs"] = 10
local explicit_fallback = logger.init({ log_name = "tight", enabled = true, truncate = true, log_dir = "/disk/tight_logs" })
if explicit_fallback.log_dir ~= "/xreactor_logs" then
  error("expected explicit disk path fallback to local when space is insufficient")
end
if not tostring(explicit_fallback.log_source):find("fallback%-local%(explicit%-disk:space:", 1, false) then
  error("expected explicit disk fallback reason to include space diagnostics")
end

free_space_by_path["/disk/tiny_logs"] = 12
local startup_space_reject = logger.init({ log_name = "tiny", enabled = true, truncate = true, log_dir = "/disk/tiny_logs" })
if startup_space_reject.log_dir ~= "/xreactor_logs" then
  error("expected explicit tiny disk path to fallback to local")
end

-- Peripheral network drive mount path should also be considered.
disk_roots.disk2 = nil
free_space_by_path["/disk2"] = nil
peripheral_drives["drive_remote_0"] = "/disk_remote"
ensure_dir("/disk_remote")
free_space_by_path["/disk_remote/xreactor_logs"] = 128000
local remote_status = logger.init({ log_name = "remote", enabled = true, truncate = true })
if remote_status.log_dir ~= "/disk_remote/xreactor_logs" then
  error("expected peripheral drive mount path to be selected")
end
if not tostring(remote_status.log_source):find("auto%-disk:/disk_remote", 1, false) then
  error("expected auto-disk source for remote mount")
end

_G.fs = original_fs
_G.settings = original_settings
_G.os = original_os
_G.print = original_print
_G.peripheral = original_peripheral
_G.disk = original_disk
package.path = package_path

print("logger_startup_policy_test.lua: ok")
