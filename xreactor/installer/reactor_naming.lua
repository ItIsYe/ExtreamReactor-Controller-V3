-- One-time reactor naming step for manual RT installations.

local M = {}

M.CONFIG_PATH = "/xreactor/config/reactor_names.lua"
M.MAX_LABEL_LENGTH = 32

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function read_all(fs_api, path)
  if not fs_api or not fs_api.exists or not fs_api.exists(path) then return nil end
  local handle = fs_api.open(path, "r")
  if not handle then return nil end
  local content = handle.readAll()
  handle.close()
  return content
end

function M.load(fs_api, path)
  local content = read_all(fs_api, path or M.CONFIG_PATH)
  if type(content) ~= "string" or content == "" then return nil end
  local loader = load(content, "=reactor_names", "t", {})
  if not loader then return nil end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" or data.completed ~= true or type(data.aliases) ~= "table" then
    return nil
  end
  local aliases = {}
  for peripheral_name, label in pairs(data.aliases) do
    local normalized = trim(label)
    if type(peripheral_name) == "string" and peripheral_name ~= ""
        and normalized ~= "" and #normalized <= M.MAX_LABEL_LENGTH then
      aliases[peripheral_name] = normalized
    end
  end
  return { version = 1, completed = true, aliases = aliases }
end

local function method_set(peripheral_api, name)
  local ok, methods = pcall(peripheral_api.getMethods, name)
  if not ok or type(methods) ~= "table" then return nil end
  local set = {}
  for _, method in ipairs(methods) do set[method] = true end
  return set
end

local function is_reactor(peripheral_api, name)
  local ok_type, type_name = pcall(peripheral_api.getType, name)
  type_name = ok_type and tostring(type_name or ""):lower() or ""
  if type_name:find("turbine", 1, true) then return false end
  if type_name:find("reactor", 1, true) then return true end
  local methods = method_set(peripheral_api, name)
  if not methods then return false end
  return methods.getControlRodLevel or methods.getControlRodLevels
    or methods.getControlRodsLevels or methods.getControlRods
    or methods.setAllControlRodLevels or methods.setControlRodLevel
    or methods.getFuelAmount or false
end

function M.detect(peripheral_api)
  local found = {}
  if not peripheral_api or type(peripheral_api.getNames) ~= "function"
      or type(peripheral_api.getMethods) ~= "function"
      or type(peripheral_api.getType) ~= "function" then
    return found
  end
  local ok, names = pcall(peripheral_api.getNames)
  if not ok or type(names) ~= "table" then return found end
  table.sort(names)
  for _, name in ipairs(names) do
    if type(name) == "string" and name ~= "" and is_reactor(peripheral_api, name) then
      found[#found + 1] = name
    end
  end
  return found
end

function M.serialize(aliases)
  local parts = {
    "-- RT reactor display names -- generated once by the installer\n",
    "return {\n  version = 1,\n  completed = true,\n  aliases = {\n",
  }
  local names = {}
  for name in pairs(aliases or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    parts[#parts + 1] = "    [" .. string.format("%q", name) .. "] = "
      .. string.format("%q", aliases[name]) .. ",\n"
  end
  parts[#parts + 1] = "  },\n}\n"
  return table.concat(parts)
end

function M.run(opts)
  opts = opts or {}
  local path = opts.path or M.CONFIG_PATH
  local existing = M.load(opts.fs or fs, path)
  if existing then return true, "already_completed", existing end
  if opts.remote_update == true then return true, "remote_update_skipped" end

  local reactors = M.detect(opts.peripheral or peripheral)
  if #reactors == 0 then return true, "no_reactors_detected" end

  local output = opts.output or function(message) print(message) end
  local input = opts.input or function() return read() end
  output("")
  output("=== Reaktoren benennen ===")
  output("Diese Namen werden einmal gespeichert und spaeter im FUEL-Routen-Editor angezeigt.")

  local aliases, used = {}, {}
  for index, peripheral_name in ipairs(reactors) do
    local default = "Reaktor " .. tostring(index)
    while true do
      output(string.format("  %s [%s]:", peripheral_name, default))
      local label = trim(input())
      if label == "" then label = default end
      local key = label:lower()
      if #label > M.MAX_LABEL_LENGTH then
        output("  Name ist zu lang (maximal " .. M.MAX_LABEL_LENGTH .. " Zeichen).")
      elseif used[key] then
        output("  Name ist bereits vergeben. Bitte einen eindeutigen Namen eingeben.")
      else
        aliases[peripheral_name] = label
        used[key] = true
        break
      end
    end
  end

  local write = opts.write
  if type(write) ~= "function" then return false, "write_function_missing" end
  local ok, err = write(path, M.serialize(aliases))
  if ok ~= true then return false, err or "write_failed" end
  return true, "saved", { version = 1, completed = true, aliases = aliases }
end

return M
