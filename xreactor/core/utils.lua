local utils = {}

function utils.ensure_dir(path)
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

function utils.read_config(path, defaults)
  if not fs.exists(path) then
    return defaults or {}
  end
  local file = fs.open(path, "r")
  if not file then
    return defaults or {}
  end
  local content = file.readAll()
  file.close()
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return defaults or {}
end

function utils.write_config(path, tbl)
  utils.ensure_dir(fs.getDir(path))
  local file = fs.open(path, "w")
  if not file then
    error("Unable to write config at " .. path)
  end
  file.write(textutils.serialize(tbl))
  file.close()
end

function utils.log(prefix, message)
  local stamp = textutils.formatTime(os.epoch("utc") / 1000, true)
  print(string.format("[%s] %s | %s", stamp, prefix, message))
end

function utils.safe_peripheral_call(name, method, ...)
  if not name or not peripheral.isPresent(name) then
    return nil, "peripheral missing"
  end
  local ok, result = pcall(peripheral.call, name, method, ...)
  if not ok then
    return nil, result
  end
  return result
end

function utils.cache_peripherals(names)
  local cache = {}
  for _, name in ipairs(names) do
    if peripheral.isPresent(name) then
      cache[name] = peripheral.wrap(name)
    end
  end
  return cache
end

function utils.merge(a, b)
  local merged = {}
  for k, v in pairs(a or {}) do merged[k] = v end
  for k, v in pairs(b or {}) do merged[k] = v end
  return merged
end

return utils
