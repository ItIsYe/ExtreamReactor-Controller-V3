-- One-time automatic naming for VALVE nodes.
--
-- Unlike RT (several physical reactors can sit behind one computer, so
-- naming them needs manual, in-person identification -- see
-- reactor_naming.lua), a VALVE node IS one computer: its identity is
-- already unambiguous via os.getComputerID(), so it can be named fully
-- automatically, with no operator interaction. Runs once per node --
-- the result is written to CONFIG_PATH, which lives outside /xreactor
-- (see installer/init.lua's CONFIG_DIR comment) and therefore survives
-- every reinstall/update, so this never re-runs after the first success.
-- Also sets the computer's own OS-level label, so the name is visible in
-- CraftOS itself (e.g. "run label get"), not just inside XReactor.

local M = {}

M.CONFIG_PATH = "/xreactor_config/valve_name.lua"

local function read_all(fs_api, path)
  if not fs_api or type(fs_api.exists) ~= "function" or not fs_api.exists(path) then
    return nil, "missing"
  end
  local handle = fs_api.open(path, "r")
  if not handle then return nil, "unreadable" end
  local content = handle.readAll()
  handle.close()
  if type(content) ~= "string" or content == "" then return nil, "empty" end
  return content
end

function M.load(fs_api, path)
  local content, read_err = read_all(fs_api, path or M.CONFIG_PATH)
  if not content then return nil, read_err end
  local loader, load_err = load(content, "=valve_name", "t", {})
  if not loader then return nil, "syntax:" .. tostring(load_err) end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" or type(data.name) ~= "string" or data.name == "" then
    return nil, "invalid"
  end
  return data.name
end

function M.serialize(name)
  return "-- VALVE display name -- generated once by the installer\n"
    .. "return {\n  name = " .. string.format("%q", name) .. ",\n}\n"
end

function M.run(opts)
  opts = opts or {}
  local fs_api = opts.fs or fs
  local os_api = opts.os or os
  local path = opts.path or M.CONFIG_PATH

  local function apply_label(name)
    if os_api and type(os_api.setComputerLabel) == "function" then
      pcall(os_api.setComputerLabel, name)
    end
  end

  local existing = M.load(fs_api, path)
  if existing then
    apply_label(existing)
    return true, "already_named", existing
  end
  if opts.remote_update == true then return true, "remote_update_skipped" end

  if not os_api or type(os_api.getComputerID) ~= "function" then
    return false, "computer_id_unavailable"
  end
  local name = "VALVE-" .. tostring(os_api.getComputerID())

  if type(opts.write) ~= "function" then return false, "write_function_missing" end
  local ok, err = opts.write(path, M.serialize(name))
  if ok ~= true then return false, err or "write_failed" end

  apply_label(name)
  return true, "saved", name
end

return M
