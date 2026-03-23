package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local files = {
  'xreactor/services/alert_service.lua',
  'xreactor/master/ui/alerts.lua'
}

for _, path in ipairs(files) do
  local handle, open_err = io.open(path, 'r')
  if not handle then
    error(string.format('failed to open %s: %s', path, tostring(open_err)))
  end
  local source = handle:read('*a')
  handle:close()
  local chunk, load_err = load(source, '=' .. path, 't', {})
  if not chunk then
    error(string.format('lua parse failed for %s: %s', path, tostring(load_err)))
  end
end

print('lua_parse_guard_test.lua: ok')
