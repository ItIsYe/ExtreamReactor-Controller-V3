package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

-- End-to-end regression for the real router lifecycle: render a page, use
-- its returned footer hitboxes, render the transition, and immediately
-- navigate again in either direction.  This is the sequence used by the
-- FUEL monitor's four pages.
package.loaded['core.ui_router'] = nil
package.loaded['core.ui'] = {
  begin_frame = function() end,
  getSize = function(mon) return mon.getSize() end,
  rightText = function() end,
  clear = function() end,
  text = function() end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }
_G.window = nil
_G.textutils = {
  serialize = function(value)
    return tostring(value.page) .. ':' .. tostring(value.snapshot or value.model)
  end,
}

local ui_router = require('core.ui_router')
local rendered = {}
local function page(name)
  return {
    name = name,
    render = function(mon)
      rendered[#rendered + 1] = name
      local w, h = mon.getSize()
      return {
        left = { x1 = 2, x2 = 10, y = h },
        right = { x1 = w - 9, x2 = w - 1, y = h },
      }
    end,
  }
end

local mon = {
  getSize = function() return 60, 20 end,
  getTextScale = function() return 0.5 end,
}
local router = ui_router.new({
  monitor_name = 'monitor_0',
  pages = { page('Overview'), page('Details'), page('Diagnostics'), page('Router') },
})
local model = { snapshot = 'stable' }

local function render_and_assert(index, name)
  router:render(mon, model)
  assert(router.index == index, 'expected page index ' .. index .. ', got ' .. tostring(router.index))
  assert(rendered[#rendered] == name, 'expected rendered page ' .. name)
  assert(router.footer.prev and router.footer.next, 'rendered page must publish both footer hitboxes')
end

local function touch(button)
  local hitbox = assert(router.footer[button], 'missing footer button ' .. button)
  local consumed = router:handle_input({ 'monitor_touch', 'monitor_0', hitbox.x1, hitbox.y })
  assert(consumed == true, 'footer touch must be consumed')
end

render_and_assert(1, 'Overview')
touch('next'); render_and_assert(2, 'Details')
touch('next'); render_and_assert(3, 'Diagnostics')
touch('next'); render_and_assert(4, 'Router')
touch('prev'); render_and_assert(3, 'Diagnostics')
touch('prev'); render_and_assert(2, 'Details')
touch('next'); render_and_assert(3, 'Diagnostics')

_G.textutils = nil
print('ui_router_navigation_roundtrip_test.lua: ok')
