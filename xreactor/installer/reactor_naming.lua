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

local function call_method(peripheral_api, name, method)
  if type(peripheral_api.call) == "function" then
    local ok, value = pcall(peripheral_api.call, name, method)
    if ok then return value end
  end
  if type(peripheral_api.wrap) == "function" then
    local ok_wrap, wrapped = pcall(peripheral_api.wrap, name)
    if ok_wrap and wrapped and type(wrapped[method]) == "function" then
      local ok, value = pcall(wrapped[method])
      if ok then return value end
    end
  end
  return nil
end

function M.read_active(peripheral_api, name)
  local methods = method_set(peripheral_api, name)
  if not methods then return nil end
  local value
  if methods.getActive then
    value = call_method(peripheral_api, name, "getActive")
  elseif methods.getStatus then
    value = call_method(peripheral_api, name, "getStatus")
  end
  if type(value) == "boolean" then return value end
  if type(value) == "string" then
    local normalized = value:lower()
    if normalized == "online" or normalized == "active" or normalized == "running" then return true end
    if normalized == "offline" or normalized == "inactive" or normalized == "stopped" then return false end
  end
  return nil
end

local function capture_active(peripheral_api, reactors)
  local snapshot = {}
  for _, name in ipairs(reactors or {}) do snapshot[name] = M.read_active(peripheral_api, name) end
  return snapshot
end

local function active_label(value)
  if value == true then return "AN" end
  if value == false then return "AUS" end
  return "UNBEKANNT"
end

local function wait_for_restore(peripheral_api, reactors, baseline, output, input)
  while true do
    local current = capture_active(peripheral_api, reactors)
    local pending = {}
    for _, name in ipairs(reactors) do
      if type(baseline[name]) == "boolean" and current[name] ~= baseline[name] then
        pending[#pending + 1] = name
      end
    end
    if #pending == 0 then return end
    output("  Bitte " .. table.concat(pending, ", ") .. " wieder auf den Ausgangszustand schalten und ENTER druecken.")
    input()
  end
end

local function identify_next(peripheral_api, reactors, output, input)
  if #reactors == 1 then
    output("  Letzter verbleibender Reaktor: " .. reactors[1])
    return reactors[1]
  end

  local baseline = capture_active(peripheral_api, reactors)
  local readable = 0
  output("")
  output("Live-Erkennung der angeschlossenen Reaktoren:")
  for index, name in ipairs(reactors) do
    if type(baseline[name]) == "boolean" then readable = readable + 1 end
    output(string.format("  %d) %s  Status=%s", index, name, active_label(baseline[name])))
  end

  while true do
    if readable > 0 then
      output("Genau EINEN noch unbenannten Reaktor manuell AN/AUS schalten, dann ENTER druecken.")
    else
      output("Aktivzustand nicht lesbar. Reaktor anhand der Liste waehlen [1-" .. #reactors .. "].")
    end
    output("Alternativ kann jederzeit die Nummer aus der Liste eingegeben werden.")
    local answer = trim(input())
    local manual_index = tonumber(answer)
    if manual_index and manual_index == math.floor(manual_index)
        and manual_index >= 1 and manual_index <= #reactors then
      local current = capture_active(peripheral_api, reactors)
      local changed = {}
      for _, name in ipairs(reactors) do
        if type(baseline[name]) == "boolean" and current[name] ~= baseline[name] then
          changed[#changed + 1] = name
        end
      end
      if #changed > 0 then wait_for_restore(peripheral_api, changed, baseline, output, input) end
      output("  Manuell gewaehlt: " .. reactors[manual_index])
      return reactors[manual_index]
    end

    local current = capture_active(peripheral_api, reactors)
    local changed = {}
    for _, name in ipairs(reactors) do
      if type(baseline[name]) == "boolean" and type(current[name]) == "boolean"
          and baseline[name] ~= current[name] then
        changed[#changed + 1] = name
      end
    end
    if #changed == 1 then
      local identified = changed[1]
      output("  Erkannt: " .. identified .. " (" .. active_label(baseline[identified])
        .. " -> " .. active_label(current[identified]) .. ")")
      wait_for_restore(peripheral_api, { identified }, baseline, output, input)
      output("  Ausgangszustand wiederhergestellt.")
      return identified
    end

    if #changed > 1 then
      output("  Mehrere Reaktoren wurden geaendert; Zuordnung ist nicht eindeutig.")
      wait_for_restore(peripheral_api, changed, baseline, output, input)
    else
      output("  Keine eindeutige Zustandsaenderung erkannt. Bitte erneut versuchen.")
    end
  end
end

local function ask_label(peripheral_name, default, used, output, input)
  while true do
    output(string.format("  Name fuer %s [%s]:", peripheral_name, default))
    local label = trim(input())
    if label == "" then label = default end
    local key = label:lower()
    if #label > M.MAX_LABEL_LENGTH then
      output("  Name ist zu lang (maximal " .. M.MAX_LABEL_LENGTH .. " Zeichen).")
    elseif used[key] then
      output("  Name ist bereits vergeben. Bitte einen eindeutigen Namen eingeben.")
    else
      used[key] = true
      return label
    end
  end
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

  local aliases, used, remaining = {}, {}, {}
  for _, name in ipairs(reactors) do remaining[#remaining + 1] = name end
  local assigned = 0
  while #remaining > 0 do
    local peripheral_name = identify_next(opts.peripheral or peripheral, remaining, output, input)
    assigned = assigned + 1
    aliases[peripheral_name] = ask_label(peripheral_name, "Reaktor " .. tostring(assigned), used, output, input)
    for index, name in ipairs(remaining) do
      if name == peripheral_name then table.remove(remaining, index); break end
    end
  end

  local write = opts.write
  if type(write) ~= "function" then return false, "write_function_missing" end
  local ok, err = write(path, M.serialize(aliases))
  if ok ~= true then return false, err or "write_failed" end
  return true, "saved", { version = 1, completed = true, aliases = aliases }
end

return M
