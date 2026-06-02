if type(package) == "table" and type(package.path) == "string" then
  local extra = ";/xreactor/?.lua;/xreactor/?/init.lua;/xreactor/?/main.lua"
  if not package.path:find("/xreactor/%?%.lua", 1, false) then
    package.path = package.path .. extra
  end
end

local ok_constants, constants = pcall(require, "shared.constants")
if not ok_constants or type(constants) ~= "table" then
  constants = { channels = { LOG = 6502 } }
end

local CHANNEL = constants.channels and constants.channels.LOG or 6502
local DEFAULT_ROOTS = { "/disk", "/disk1", "/disk2", "/xreactor_collected_logs" }

local stats = {
  received = 0,
  written = 0,
  dropped = 0,
  last_node = "-",
  last_level = "-",
  last_error = nil,
  log_root = nil,
  modem = nil
}

local function safe_print(text)
  pcall(print, tostring(text))
end

local function ensure_dir(path)
  if fs.exists(path) then return fs.isDir(path) end
  local ok = pcall(fs.makeDir, path)
  return ok and fs.exists(path) and fs.isDir(path)
end

local function free_space(path)
  if not fs.getFreeSpace then return math.huge end
  local ok, value = pcall(fs.getFreeSpace, path or "/")
  if not ok then return 0 end
  if type(value) == "string" then
    if value == "unlimited" then return math.huge end
    value = tonumber(value) or 0
  end
  return tonumber(value) or 0
end

local function disk_roots()
  local roots, seen = {}, {}
  local function add(path)
    if type(path) ~= "string" or path == "" or seen[path] then return end
    seen[path] = true
    roots[#roots + 1] = path
  end
  if peripheral and disk and type(peripheral.getNames) == "function" and type(disk.getMountPath) == "function" then
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then
      for _, name in ipairs(names) do
        local is_drive = false
        if peripheral.hasType then
          local ok_type, result = pcall(peripheral.hasType, name, "drive")
          is_drive = ok_type and result == true
        else
          local ok_type, ptype = pcall(peripheral.getType, name)
          is_drive = ok_type and ptype == "drive"
        end
        if is_drive then
          local ok_mount, mount = pcall(disk.getMountPath, name)
          if ok_mount then add(mount) end
        end
      end
    end
  end
  if fs and fs.list then
    local ok, entries = pcall(fs.list, "/")
    if ok and type(entries) == "table" then
      for _, entry in ipairs(entries) do
        if type(entry) == "string" and entry:match("^disk%d*$") then add("/" .. entry) end
      end
    end
  end
  for _, root in ipairs(DEFAULT_ROOTS) do add(root) end
  return roots
end

local function write_probe(root)
  local dir = root .. "/xreactor_logs"
  if not ensure_dir(dir) then return false end
  local path = dir .. "/.collector_probe"
  local ok = pcall(function()
    local h = fs.open(path, "w")
    if not h then error("open failed") end
    h.write("probe")
    h.close()
    fs.delete(path)
  end)
  return ok
end

local function choose_log_root()
  local best, best_free = nil, -1
  for _, root in ipairs(disk_roots()) do
    if ensure_dir(root) and write_probe(root) then
      local free = free_space(root)
      if free > best_free then
        best, best_free = root .. "/xreactor_logs", free
      end
    end
  end
  if best and ensure_dir(best) then return best end
  local fallback = "/xreactor_collected_logs"
  ensure_dir(fallback)
  return fallback
end

local function sanitize(value)
  local text = tostring(value or "unknown"):lower()
  text = text:gsub("[^a-z0-9_%-]+", "_")
  text = text:gsub("^_+", ""):gsub("_+$", "")
  if text == "" then return "unknown" end
  return text
end

local function format_line(payload)
  local ts = payload.ts or (os.epoch and os.epoch("utc")) or "?"
  return string.format("[%s] %s | %s | %s | %s", tostring(ts), tostring(payload.role or "?"), tostring(payload.prefix or "LOG"), tostring(payload.level or "INFO"), tostring(payload.message or payload.line or ""))
end

local function write_log(payload)
  local root = stats.log_root or choose_log_root()
  stats.log_root = root
  local role = sanitize(payload.role or "unknown")
  local node_id = sanitize(payload.node_id or "unknown")
  local dir = root .. "/" .. role
  if not ensure_dir(dir) then return false, "mkdir failed" end
  local path = dir .. "/" .. node_id .. ".log"
  if free_space(root) < 256 then return false, "disk full" end
  local h = fs.open(path, "a")
  if not h then return false, "open failed" end
  h.write(format_line(payload) .. "\n")
  h.close()
  return true
end

local function find_modem()
  if not peripheral or not peripheral.getNames then return nil, nil end
  local names = peripheral.getNames()
  local fallback_name, fallback_modem = nil, nil
  for _, name in ipairs(names) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem then
        local wireless = false
        if type(modem.isWireless) == "function" then
          local ok, result = pcall(modem.isWireless)
          wireless = ok and result == true
        end
        if wireless then return name, modem end
        fallback_name, fallback_modem = fallback_name or name, fallback_modem or modem
      end
    end
  end
  return fallback_name, fallback_modem
end

local function draw()
  term.clear()
  term.setCursorPos(1, 1)
  print("XReactor LOG COLLECTOR")
  print("Channel: " .. tostring(CHANNEL))
  print("Modem:   " .. tostring(stats.modem or "none"))
  print("Root:    " .. tostring(stats.log_root or "n/a"))
  print("Recv:    " .. tostring(stats.received))
  print("Written: " .. tostring(stats.written))
  print("Dropped: " .. tostring(stats.dropped))
  print("Last:    " .. tostring(stats.last_node) .. " " .. tostring(stats.last_level))
  if stats.last_error then print("Error:   " .. tostring(stats.last_error)) end
end

local function run()
  stats.log_root = choose_log_root()
  local modem_name, modem = find_modem()
  stats.modem = modem_name
  if not modem then error("No modem found for LOG collector", 0) end
  modem.open(CHANNEL)
  draw()
  while true do
    local _, _, channel, _, message = os.pullEvent("modem_message")
    if channel == CHANNEL and type(message) == "table" and message.type == "LOG_EVENT" then
      stats.received = stats.received + 1
      stats.last_node = message.node_id or "?"
      stats.last_level = message.level or "?"
      local ok, err = write_log(message)
      if ok then stats.written = stats.written + 1 else stats.dropped = stats.dropped + 1; stats.last_error = err end
      if stats.received % 5 == 0 or not ok then draw() end
    end
  end
end

run()
