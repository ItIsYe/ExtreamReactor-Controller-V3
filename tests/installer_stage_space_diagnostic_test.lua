-- tests/installer_stage_space_diagnostic_test.lua
--
-- Regression test for installer/stage.lua's space-shortage handling.
--
-- History: this used to auto-delete /xreactor_logs unconditionally on low
-- space (pre-2026-07-16), then stopped doing that entirely and only
-- reported a diagnostic for the user to act on manually (2026-07-16 /
-- 2026-08-12 first pass). Per explicit user request (2026-08-12, after
-- repeated "out of space" aborts on MASTER, whose role file set leaves
-- little headroom on tightly-quota'd computers once logs re-accumulate
-- between install attempts), /xreactor_logs deletion is now back as a
-- LAST-RESORT fallback inside reclaim() -- but deliberately narrower than
-- the old unconditional behavior: only /xreactor_logs specifically, only
-- after the installer's own harmless intermediate dirs weren't enough,
-- and every actual deletion is announced via print(), never silent.
--
-- Two scenarios: (1) clearing /xreactor_logs frees enough space and the
-- write succeeds; (2) it still isn't enough and the write fails with a
-- diagnostic reflecting that logs were already tried.

local function make_fs(total_quota, log_bytes)
  local files = {}
  local dirs = { ["/xreactor_logs"] = true }

  local function used_space()
    local total = 0
    for _, content in pairs(files) do total = total + #content end
    return total
  end

  local mock = {
    getDir = function(p) return (p:match("^(.*)/[^/]+$")) or "" end,
    exists = function(p) return files[p] ~= nil or dirs[p] == true end,
    isDir = function(p) return dirs[p] == true end,
    makeDir = function(p) dirs[p] = true end,
    getFreeSpace = function() return total_quota - used_space() end,
    getSize = function(p) return files[p] and #files[p] or 0 end,
    list = function(p)
      if p ~= "/xreactor_logs" then return {} end
      local names = {}
      for path in pairs(files) do
        local prefix = "/xreactor_logs/"
        if path:sub(1, #prefix) == prefix then
          names[#names + 1] = path:sub(#prefix + 1)
        end
      end
      return names
    end,
    open = function(p, mode)
      if mode == "w" then
        local buf = {}
        return {
          write = function(content) buf[#buf + 1] = content end,
          close = function() files[p] = table.concat(buf) end,
        }
      elseif mode == "r" then
        if not files[p] then return nil end
        return { readAll = function() return files[p] end, close = function() end }
      end
      return nil
    end,
    delete = function(p)
      if dirs[p] then
        dirs[p] = nil
        local prefix = p .. "/"
        for path in pairs(files) do
          if path:sub(1, #prefix) == prefix then files[path] = nil end
        end
      end
      files[p] = nil
    end,
    move = function(src, dst) files[dst] = files[src]; files[src] = nil end,
  }
  files["/xreactor_logs/master.log"] = string.rep("x", log_bytes)
  return mock, files, dirs
end

package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")
package.loaded["installer.stage"] = nil
local stage = require("installer.stage")

-- Scenario 1: deleting /xreactor_logs frees enough space -- write must
-- succeed, the log directory must actually be gone, and the deletion must
-- be announced via print().
do
  _G.fs, _, dirs = make_fs(2000, 1500)
  local printed = {}
  local real_print = print
  _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
  local ok, err = stage.write("/xreactor/config/role.lua", string.rep("y", 100))
  _G.print = real_print

  if not ok then error("expected write to succeed after auto-clearing /xreactor_logs, got err: " .. tostring(err)) end
  if fs.exists("/xreactor_logs") then error("CRITICAL: /xreactor_logs must actually be deleted when used as the last-resort reclaim") end
  local announced = false
  for _, line in ipairs(printed) do
    if line:find("xreactor_logs", 1, true) and line:find("1500", 1, true) then announced = true end
  end
  if not announced then error("expected the /xreactor_logs deletion to be announced via print(), got: " .. table.concat(printed, " | ")) end
end

-- Scenario 2: even clearing /xreactor_logs isn't enough -- write must
-- still fail, with a diagnostic that no longer suggests deleting logs
-- manually (they were already tried).
do
  _G.fs = make_fs(500, 400)
  local ok, err = stage.write("/xreactor/config/role.lua", string.rep("y", 100))
  if ok then error("expected write to still fail when even /xreactor_logs isn't enough, got ok=true") end
  local msg = tostring(err)
  if not msg:find("not enough space", 1, true) then
    error("expected 'not enough space' in error, got: " .. msg)
  end
  if not msg:find("already cleared", 1, true) then
    error("expected diagnostic to note /xreactor_logs was already cleared and still not enough, got: " .. msg)
  end
end

print("installer_stage_space_diagnostic_test.lua: ok")
