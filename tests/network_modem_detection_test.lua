package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

_G.fs = _G.fs or {
  exists = function() return false end,
  open = function() return nil end,
  getDir = function() return '' end,
  makeDir = function() end,
}
_G.textutils = _G.textutils or {
  serialize = function(value)
    if type(value) ~= 'table' then return tostring(value) end
    return 'table'
  end,
  unserialize = function() return nil end,
}
_G.os = _G.os or {}
if not os.getComputerID then
  os.getComputerID = function() return 1 end
end
if not os.getComputerLabel then
  os.getComputerLabel = function() return 'CC' end
end

local function reset_network()
  package.loaded['core.network'] = nil
  return require('core.network')
end

local function install_peripheral(stub)
  _G.peripheral = {
    getNames = function() return stub.names end,
    isPresent = function(name) return stub.entries[name] ~= nil end,
    getType = function(name)
      local entry = stub.entries[name]
      return entry and entry.type or nil
    end,
    wrap = function(name)
      local entry = stub.entries[name]
      return entry and entry.wrap or nil
    end,
  }
end

local function build_modem(opts)
  opts = opts or {}
  local opened = opts.opened
  return {
    open = function(channel, extra)
      if extra ~= nil then
        error('wrapped modem open must not receive implicit self argument')
      end
      if opened then table.insert(opened, channel) end
    end,
    transmit = function(channel, reply_channel, payload, extra)
      if extra ~= nil then
        error('wrapped modem transmit must not receive implicit self argument')
      end
      if channel == nil or reply_channel == nil or payload == nil then
        error('wrapped modem transmit missing arguments')
      end
    end,
    isWireless = opts.isWireless and function(extra)
      if extra ~= nil then
        error('wrapped modem isWireless must not receive implicit self argument')
      end
      return opts.isWireless
    end or nil,
    callRemote = opts.callRemote and function(device_name, method_name, ...)
      if device_name == nil or method_name == nil then
        error('wrapped modem callRemote missing target args')
      end
      return true
    end or nil,
    isPresentRemote = opts.callRemote and function(device_name, extra)
      if extra ~= nil then
        error('wrapped modem isPresentRemote must not receive implicit self argument')
      end
      return device_name ~= nil
    end or nil,
  }
end

local function test_autodetect_wireless_and_wired()
  local opened = {}
  install_peripheral({
    names = { 'back', 'top' },
    entries = {
      top = { type = 'modem', wrap = build_modem({ isWireless = true, opened = opened }) },
      back = { type = 'modem', wrap = build_modem({ isWireless = false, callRemote = true }) },
    },
  })
  local network = reset_network()
  local net = network.init({ role = 'MASTER', channels = { control = 6500, status = 6501 } })
  if not net.modem then error('expected wireless modem to be autodetected') end
  if not net.wired then error('expected wired modem to be autodetected') end
  if net.selected_modems.wireless.name ~= 'top' then
    error('expected wireless modem top, got ' .. tostring(net.selected_modems.wireless.name))
  end
  if net.selected_modems.wired.name ~= 'back' then
    error('expected wired modem back, got ' .. tostring(net.selected_modems.wired.name))
  end
  if #opened ~= 2 then
    error('expected 2 modem.open calls for channels')
  end
end

local function test_invalid_override_falls_back()
  install_peripheral({
    names = { 'left', 'right' },
    entries = {
      left = { type = 'modem', wrap = build_modem({ isWireless = true }) },
      right = { type = 'modem', wrap = build_modem({ isWireless = false, callRemote = true }) },
    },
  })
  local network = reset_network()
  local net = network.init({
    role = 'MASTER',
    wireless_modem = 'missing',
    wired_modem = 'left',
  })
  if net.selected_modems.wireless.name ~= 'left' then
    error('invalid wireless override should fall back to autodetect wireless candidate')
  end
  if net.selected_modems.wired.name ~= 'right' then
    error('invalid wired override should fall back to wired candidate')
  end
end

local function test_override_wins_over_autodetect()
  install_peripheral({
    names = { 'a', 'z' },
    entries = {
      a = { type = 'modem', wrap = build_modem({ isWireless = true }) },
      z = { type = 'modem', wrap = build_modem({ isWireless = true }) },
    },
  })
  local network = reset_network()
  local net = network.init({
    role = 'MASTER',
    wireless_modem = 'z',
  })
  if net.selected_modems.wireless.name ~= 'z' then
    error('explicit override must win over deterministic autodetect order')
  end
  if net.selected_modems.wireless_source ~= 'config override' then
    error('expected wireless source to report config override')
  end
end

local function test_legacy_modem_alias_maps_to_wireless_override()
  install_peripheral({
    names = { 'a', 'z' },
    entries = {
      a = { type = 'modem', wrap = build_modem({ isWireless = true }) },
      z = { type = 'modem', wrap = build_modem({ isWireless = true }) },
    },
  })
  local network = reset_network()
  local net = network.init({
    role = 'MASTER',
    modem = 'z',
  })
  if net.selected_modems.wireless.name ~= 'z' then
    error('legacy modem field should alias to wireless override')
  end
  if net.selected_modems.wireless_source ~= 'config override' then
    error('legacy modem alias should report config override source')
  end
end

local function test_wireless_override_wins_over_legacy_modem_alias()
  install_peripheral({
    names = { 'a', 'z' },
    entries = {
      a = { type = 'modem', wrap = build_modem({ isWireless = true }) },
      z = { type = 'modem', wrap = build_modem({ isWireless = true }) },
    },
  })
  local network = reset_network()
  local net = network.init({
    role = 'MASTER',
    modem = 'a',
    wireless_modem = 'z',
  })
  if net.selected_modems.wireless.name ~= 'z' then
    error('wireless_modem must take precedence over legacy modem field')
  end
end

local function test_no_hard_left_right_required()
  install_peripheral({
    names = { 'bottom', 'top' },
    entries = {
      top = { type = 'modem', wrap = build_modem({ isWireless = true }) },
      bottom = { type = 'peripheral_hub', wrap = build_modem({ callRemote = true }) },
    },
  })
  local network = reset_network()
  local net = network.init({ role = 'RT-NODE' })
  if not net.modem then
    error('expected startup without hard-coded left/right modem sides')
  end
  if net.selected_modems.wireless.name ~= 'top' then
    error('expected top as wireless modem')
  end
  if net.selected_modems.wired.name ~= 'bottom' then
    error('expected bottom as wired peripheral hub')
  end
end

test_autodetect_wireless_and_wired()
test_invalid_override_falls_back()
test_override_wins_over_autodetect()
test_legacy_modem_alias_maps_to_wireless_override()
test_wireless_override_wins_over_legacy_modem_alias()
test_no_hard_left_right_required()

print('network_modem_detection_test.lua: ok')
