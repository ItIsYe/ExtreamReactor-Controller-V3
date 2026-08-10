package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- Regression test for the visible Router footer contract: the wrapper page
-- must return router_ui:render()'s footer coordinates to core/ui_router.lua.

local function read_file(path)
  local f = assert(io.open(path, 'r'))
  local content = f:read('*a')
  f:close()
  return content
end

local function extract(content, start_marker, end_marker)
  local s = content:find(start_marker, 1, true)
  assert(s, 'start marker not found: ' .. start_marker)
  local e = content:find(end_marker, s, true)
  assert(e, 'end marker not found: ' .. end_marker)
  return content:sub(s, e + #end_marker - 1)
end

local function assert_true(value, message)
  if not value then error(message or 'assert_true failed') end
end

-- FUEL uses `current_model` only to avoid shadowing the outer model; the
-- semantic signature remains (target, model, should_clear).
do
  local source = read_file('xreactor/nodes/fuel/monitor_ui.lua')
  local entry_src = extract(source,
    '{ name = "Router", render = function(target, current_model, should_clear)',
    'ctx.get_router_ui():handle_touch(x, y) end }')

  local mock_footer = { left = { x1 = 2, x2 = 10, y = 20 }, right = { x1 = 50, x2 = 60, y = 20 } }
  local mock_router_ui = {
    render = function(_self, _target, _ui, _colors, _should_clear) return mock_footer end,
    handle_touch = function(_self, _x, _y) return true end,
  }

  local chunk = [[
local ctx = { get_router_ui = function() return ROUTER_UI_MOCK end }
return ]] .. entry_src
  local env = { ROUTER_UI_MOCK = mock_router_ui }
  env._G = env
  local fn = assert(load(chunk, 'fuel_router_page_entry_chunk', 't', env))
  local entry = fn()

  assert_true(type(entry.render) == 'function', 'the Router page entry must have a render field')
  local result = entry.render('MON', 'MODEL', true)
  assert_true(result == mock_footer,
    'nodes/fuel/monitor_ui.lua: Router render() must return visible footer coordinates')
end

-- REPROCESSOR keeps its existing wrapper contract.
do
  local source = read_file('xreactor/nodes/reprocessor/main.lua')
  local entry_src = extract(source,
    '{ name = "Router", render = function(target, m, should_clear)',
    'get_router_ui():handle_touch(x, y) end }')

  local mock_footer = { left = { x1 = 2, x2 = 10, y = 20 }, right = { x1 = 50, x2 = 60, y = 20 } }
  local mock_router_ui = {
    render = function(_self, _target, _ui, _colors, _should_clear) return mock_footer end,
    handle_touch = function(_self, _x, _y) return true end,
  }

  local chunk = [[
local get_router_ui = function() return ROUTER_UI_MOCK end
local ui, colors = nil, nil
return ]] .. entry_src
  local env = { ROUTER_UI_MOCK = mock_router_ui }
  env._G = env
  local fn = assert(load(chunk, 'reprocessor_router_page_entry_chunk', 't', env))
  local entry = fn()

  assert_true(type(entry.render) == 'function', 'the Router page entry must have a render field')
  local result = entry.render('MON', 'MODEL', true)
  assert_true(result == mock_footer,
    'nodes/reprocessor/main.lua: Router render() must return visible footer coordinates')
end

print('router_page_footer_nav_return_test.lua: ok')
