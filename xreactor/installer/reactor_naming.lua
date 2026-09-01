-- One-time reactor naming for manual RT installations.
--
-- The installer never changes reactor state. With multiple reactors the
-- operator toggles one reactor manually; this module only observes getActive
-- or getStatus and asks for the original state to be restored before it
-- accepts the identification.

local M = {}

M.CONFIG_PATH = "/xreactor/config/reactor_names.lua"
M.MAX_LABEL_LENGTH = 32
M.MAX_INPUT_ATTEMPTS = 20
M.MAX_RESTORE_ATTEMPTS = 10

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

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
  local loader, load_err = load(content, "=reactor_names", "t", {})
  if not loader then return nil, "syntax:" .. tostring(load_err) end
  local ok, data = pcall(loader)
  if not ok or type(data) ~= "table" then return nil, "invalid_table" end
  if data.completed ~= true or type(data.aliases) ~= "table" then
    return nil, "incomplete"
  end

  local aliases, used = {}, {}
  for peripheral_name, label in pairs(data.aliases) do
    local normalized = trim(label)
    if type(peripheral_name) ~= "string" or peripheral_name == "" then
      return nil, "invalid_peripheral_name"
    end
    if normalized == "" or #normalized > M.MAX_LABEL_LENGTH then
      return nil, "invalid_label"
    end
    local key = normalized:lower()
    if used[key] then return nil, "duplicate_label" end
    aliases[peripheral_name] = normalized
    used[key] = true
  end

  local reactors, reactor_seen = {}, {}
  if type(data.reactors) == "table" then
    for _, name in ipairs(data.reactors) do
      if type(name) ~= "string" or name == "" or reactor_seen[name] then
        return nil, "invalid_reactor_list"
      end
      reactors[#reactors + 1] = name
      reactor_seen[name] = true
    end
  else
    for name in pairs(aliases) do reactors[#reactors + 1] = name end
  end
  table.sort(reactors)

  for name in pairs(aliases) do
    if not reactor_seen[name] and type(data.reactors) == "table" then
      return nil, "alias_not_in_reactor_list"
    end
  end
  for _, name in ipairs(reactors) do
    if not aliases[name] then return nil, "reactor_without_alias" end
  end

  return {
    version = tonumber(data.version) or 1,
    completed = true,
    aliases = aliases,
    reactors = reactors,
    topology_fingerprint = table.concat(reactors, "|"),
  }
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
    or methods.getFuelAmount or methods.getFuelStats or false
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
  for _ = 1, M.MAX_RESTORE_ATTEMPTS do
    local current = capture_active(peripheral_api, reactors)
    local pending = {}
    for _, name in ipairs(reactors) do
      if type(baseline[name]) == "boolean" and current[name] ~= baseline[name] then
        pending[#pending + 1] = name
      end
    end
    if #pending == 0 then return true end
    output("  Bitte " .. table.concat(pending, ", ")
      .. " wieder auf den Ausgangszustand schalten und ENTER druecken.")
    input()
  end
  return false, "reactor_restore_timeout"
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

  for _ = 1, M.MAX_INPUT_ATTEMPTS do
    if readable > 0 then
      output("Genau EINEN noch unbenannten Reaktor manuell AN/AUS schalten, dann ENTER druecken")
      output("(oder direkt die Nummer aus der Liste oben eingeben und ENTER druecken).")
    else
      output("Aktivzustand nicht lesbar. Reaktor anhand der Liste waehlen [1-" .. #reactors .. "].")
    end
    output("'Q' bricht die gesamte Installation ohne Speichern ab.")
    local answer = trim(input())
    if answer:upper() == "Q" or answer:upper() == "ABBRUCH" then
      return nil, "operator_aborted"
    end

    local current = capture_active(peripheral_api, reactors)
    local changed = {}
    for _, name in ipairs(reactors) do
      if type(baseline[name]) == "boolean" and type(current[name]) == "boolean"
          and baseline[name] ~= current[name] then
        changed[#changed + 1] = name
      end
    end

    local manual_index = tonumber(answer)
    if manual_index and manual_index == math.floor(manual_index)
        and manual_index >= 1 and manual_index <= #reactors then
      if #changed > 0 then
        local restored, restore_err = wait_for_restore(peripheral_api, changed, baseline, output, input)
        if not restored then return nil, restore_err end
      end
      output("  Manuell gewaehlt: " .. reactors[manual_index])
      return reactors[manual_index]
    end

    if #changed == 1 then
      local identified = changed[1]
      output("  Erkannt: " .. identified .. " (" .. active_label(baseline[identified])
        .. " -> " .. active_label(current[identified]) .. ")")
      local restored, restore_err = wait_for_restore(
        peripheral_api, { identified }, baseline, output, input)
      if not restored then return nil, restore_err end
      output("  Ausgangszustand wiederhergestellt.")
      return identified
    end

    if #changed > 1 then
      output("  Mehrere Reaktoren wurden geaendert; Zuordnung ist nicht eindeutig.")
      local restored, restore_err = wait_for_restore(peripheral_api, changed, baseline, output, input)
      if not restored then return nil, restore_err end
    else
      output("  Keine eindeutige Zustandsaenderung erkannt. Bitte erneut versuchen.")
    end
  end
  return nil, "reactor_identification_attempts_exhausted"
end

-- "input(default)" pre-fills the CC:Tweaked edit line with the suggested
-- name (read()'s 4th parameter) so the operator can tweak it in place --
-- arrow/backspace like any other line -- instead of only being able to
-- accept it blindly (Enter) or retype the whole name from scratch.
-- 'Z' discards the CURRENT reactor's identification (nothing has been
-- committed to aliases/used yet at this point) and lets the caller redo
-- identify_next() for it, so a wrongly-identified reactor can be corrected
-- without aborting the entire naming step.
local function ask_label(peripheral_name, default, used, output, input)
  for _ = 1, M.MAX_INPUT_ATTEMPTS do
    output(string.format(
      "  Name fuer %s (Vorschlag '%s' ist editierbar, Enter uebernimmt; 'Z'=diesen Reaktor neu erkennen, 'Q'=abbrechen):",
      peripheral_name, default))
    local label = trim(input(default))
    if label:upper() == "Q" or label:upper() == "ABBRUCH" then
      return nil, "operator_aborted"
    end
    if label:upper() == "Z" then
      return nil, "operator_redo"
    end
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
  return nil, "reactor_label_attempts_exhausted"
end

function M.serialize(aliases, reactors)
  local parts = {
    "-- RT reactor display names -- generated once by the installer\n",
    "return {\n  version = 2,\n  completed = true,\n  aliases = {\n",
  }
  local names = {}
  for name in pairs(aliases or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    parts[#parts + 1] = "    [" .. string.format("%q", name) .. "] = "
      .. string.format("%q", aliases[name]) .. ",\n"
  end
  parts[#parts + 1] = "  },\n  reactors = {\n"
  for _, name in ipairs(reactors or names) do
    parts[#parts + 1] = "    " .. string.format("%q", name) .. ",\n"
  end
  parts[#parts + 1] = "  },\n}\n"
  return table.concat(parts)
end

function M.run(opts)
  opts = opts or {}
  local fs_api = opts.fs or fs
  local peripheral_api = opts.peripheral or peripheral
  local path = opts.path or M.CONFIG_PATH
  local exists = fs_api and type(fs_api.exists) == "function" and fs_api.exists(path)
  if exists then
    local existing, load_err = M.load(fs_api, path)
    if not existing then return false, "invalid_existing_config:" .. tostring(load_err) end
    if opts.force ~= true then
      local current = M.detect(peripheral_api)
      if table.concat(current, "|") ~= existing.topology_fingerprint then
        existing.current_reactors = current
        existing.topology_changed = true
        return true, "already_completed_topology_changed", existing
      end
      return true, "already_completed", existing
    end
  end
  if opts.remote_update == true then return true, "remote_update_skipped" end

  local reactors = M.detect(peripheral_api)
  if #reactors == 0 then return true, "no_reactors_detected" end

  local output = opts.output or function(message) print(message) end
  -- "default" (used only by ask_label()) is forwarded to CC:Tweaked's
  -- read()'s 4th parameter, which pre-fills the edit line with that text
  -- instead of just showing it as a bracketed hint the operator has to
  -- either accept blindly or retype from scratch.
  local input = opts.input or function(default) return read and read(nil, nil, nil, default) or "" end
  output("")
  output("=== Reaktoren benennen ===")
  output("Die Namen werden einmal gespeichert und im FUEL-Routen-Editor angezeigt.")

  local aliases, used, remaining = {}, {}, {}
  for _, name in ipairs(reactors) do remaining[#remaining + 1] = name end
  local assigned = 0
  while #remaining > 0 do
    local peripheral_name, identify_err = identify_next(peripheral_api, remaining, output, input)
    if not peripheral_name then return false, identify_err end
    assigned = assigned + 1
    local label, label_err = ask_label(
      peripheral_name, "Reaktor " .. tostring(assigned), used, output, input)
    if not label then
      if label_err ~= "operator_redo" then return false, label_err end
      -- Nothing was committed for this reactor (identify_next() only
      -- returns a peripheral name, ask_label() only wrote into a LOCAL
      -- attempt) -- undo just the "Reaktor N" default counter and loop
      -- back to re-identify the SAME still-remaining reactor.
      assigned = assigned - 1
      output("  Erkennung fuer " .. peripheral_name .. " wird wiederholt.")
    else
      aliases[peripheral_name] = label
      for index, name in ipairs(remaining) do
        if name == peripheral_name then table.remove(remaining, index); break end
      end
    end
  end

  if type(opts.write) ~= "function" then return false, "write_function_missing" end
  local ok, err = opts.write(path, M.serialize(aliases, reactors))
  if ok ~= true then return false, err or "write_failed" end
  return true, "saved", {
    version = 2,
    completed = true,
    aliases = aliases,
    reactors = reactors,
    topology_fingerprint = table.concat(reactors, "|"),
  }
end

return M
