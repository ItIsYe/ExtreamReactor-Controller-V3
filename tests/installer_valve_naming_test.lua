-- tests/installer_valve_naming_test.lua
--
-- Regression test: VALVE nodes should get a clear, automatically-assigned
-- display name (unlike RT's reactor naming, no operator interaction is
-- possible or needed -- a VALVE node is exactly one computer, already
-- unambiguous via os.getComputerID()). The name is persisted once to
-- CONFIG_PATH (outside /xreactor, survives reinstalls) and applied as the
-- computer's own OS label via os.setComputerLabel().

local root = os.getenv("REPO_ROOT") or "."
local naming = assert(loadfile(root .. "/xreactor/installer/valve_naming.lua"))()

local function make_fs(files)
  files = files or {}
  return files, {
    exists = function(path) return files[path] ~= nil end,
    open = function(path, mode)
      if mode == "r" then
        if files[path] == nil then return nil end
        return { readAll = function() return files[path] end, close = function() end }
      end
      return nil
    end,
  }
end

-- Fall 1: fresh node -- generates "VALVE-<computer id>", persists it, and
-- applies it as the OS label.
do
  local files, fake_fs = make_fs()
  local labels_set = {}
  local fake_os = {
    getComputerID = function() return 42 end,
    setComputerLabel = function(label) labels_set[#labels_set + 1] = label end,
  }
  local ok, state, name = naming.run({
    fs = fake_fs,
    os = fake_os,
    write = function(path, content) files[path] = content; return true end,
  })
  if not (ok == true and state == "saved" and name == "VALVE-42") then
    error("expected a fresh VALVE node to be auto-named VALVE-42, got: "
      .. tostring(ok) .. " " .. tostring(state) .. " " .. tostring(name))
  end
  if files[naming.CONFIG_PATH] == nil then
    error("expected the generated name to be persisted to " .. naming.CONFIG_PATH)
  end
  if #labels_set ~= 1 or labels_set[1] ~= "VALVE-42" then
    error("expected os.setComputerLabel('VALVE-42') exactly once, got: " .. table.concat(labels_set, ","))
  end
  local loaded = naming.load(fake_fs, naming.CONFIG_PATH)
  if loaded ~= "VALVE-42" then
    error("expected the persisted name to load back as VALVE-42, got: " .. tostring(loaded))
  end
end

-- Fall 2: already named (e.g. a reinstall/update) -- no-op besides
-- re-applying the label; the name is never regenerated or overwritten.
do
  local files, fake_fs = make_fs({ [naming.CONFIG_PATH] = naming.serialize("VALVE-7") })
  local labels_set = {}
  local write_calls = 0
  local fake_os = {
    getComputerID = function() return 999 end,
    setComputerLabel = function(label) labels_set[#labels_set + 1] = label end,
  }
  local ok, state, name = naming.run({
    fs = fake_fs,
    os = fake_os,
    write = function(path, content) write_calls = write_calls + 1; files[path] = content; return true end,
  })
  if not (ok == true and state == "already_named" and name == "VALVE-7") then
    error("expected an already-named VALVE node to be a no-op, got: "
      .. tostring(ok) .. " " .. tostring(state) .. " " .. tostring(name))
  end
  if write_calls ~= 0 then
    error("expected zero writes for an already-named node, got " .. write_calls)
  end
  if #labels_set ~= 1 or labels_set[1] ~= "VALVE-7" then
    error("expected the existing name to still be (re-)applied as the OS label, got: " .. table.concat(labels_set, ","))
  end
end

-- Fall 3: unattended auto-update on an already-named node -- must still
-- re-apply the label (cheap, idempotent) without treating it as a fresh
-- naming attempt.
do
  local _, fake_fs = make_fs({ [naming.CONFIG_PATH] = naming.serialize("VALVE-3") })
  local ok, state, name = naming.run({
    fs = fake_fs,
    os = { getComputerID = function() return 3 end, setComputerLabel = function() end },
    remote_update = true,
    write = function() error("must not write during an unattended update with an existing name") end,
  })
  if not (ok == true and state == "already_named" and name == "VALVE-3") then
    error("expected remote_update on an already-named node to be a no-op, got: "
      .. tostring(ok) .. " " .. tostring(state) .. " " .. tostring(name))
  end
end

-- Fall 4: unattended auto-update on a genuinely unnamed node -- must never
-- attempt to write (mirrors reactor_naming's own remote_update_skipped
-- behaviour), rather than risk a name being (re-)assigned outside of a
-- foreground installer run.
do
  local _, fake_fs = make_fs()
  local ok, state = naming.run({
    fs = fake_fs,
    os = { getComputerID = function() return 5 end, setComputerLabel = function() end },
    remote_update = true,
    write = function() error("must not write during an unattended update") end,
  })
  if not (ok == true and state == "remote_update_skipped") then
    error("expected remote_update on an unnamed node to skip naming, got: "
      .. tostring(ok) .. " " .. tostring(state))
  end
end

-- Fall 5: write failure must be reported, not silently swallowed.
do
  local _, fake_fs = make_fs()
  local ok, err = naming.run({
    fs = fake_fs,
    os = { getComputerID = function() return 8 end, setComputerLabel = function() end },
    write = function() return false, "disk full" end,
  })
  if ok then error("CRITICAL: a failed persist must not report success") end
  if err ~= "disk full" then error("expected the write error to be surfaced, got: " .. tostring(err)) end
end

print("installer_valve_naming_test.lua: ok")
