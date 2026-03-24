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
    open = function(_, channel)
      if opened then table.insert(opened, channel) end
    end,
    transmit = function() end,
    isWireless = opts.isWireless and function() return opts.isWireless end or nil,
    callRemote = opts.callRemote and function() return true end or nil,
    isPresentRemote = opts.callRemote and function() return true end or nil,
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
test_no_hard_left_right_required()

print('network_modem_detection_test.lua: ok')
