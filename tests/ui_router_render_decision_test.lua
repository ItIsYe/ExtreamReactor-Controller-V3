package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.ui_router'] = nil
package.loaded['core.ui'] = {
  begin_frame = function() end,
  getSize = function(mon) return mon.getSize() end,
  rightText = function() end,
  clear = function() end,
  text = function() end,
}
package.loaded['shared.colors'] = { get = function() return 1 end }
_G.textutils = {
  serialize = function(payload)
    return tostring(payload.page) .. ':' .. tostring(payload.snapshot or payload.model)
  end,
}

local ui_router = require('core.ui_router')
local renders = 0
local router = ui_router.new({
  pages = {
    {
      name = 'A',
      render = function(_, _, should_clear)
        renders = renders + 1
        assert(should_clear == true)
        return { left = { x1 = 2, x2 = 5, y = 10 }, right = { x1 = 25, x2 = 29, y = 10 } }
      end,
    },
    {
      name = 'B',
      render = function()
        renders = renders + 1
        return { left = { x1 = 2, x2 = 5, y = 10 }, right = { x1 = 25, x2 = 29, y = 10 } }
      end,
    },
  },
})

local width, height = 30, 10
local mon = {
  getSize = function() return width, height end,
  getTextScale = function() return 0.5 end,
}
local model = { snapshot = 'same' }

assert(router:needs_render(mon, model) == true, 'initial frame must be rendered')
assert(router:render(mon, model) == true and renders == 1)
assert(router:needs_render(mon, model) == false, 'unchanged content and layout must be skipped')
assert(router:render(mon, model) == false and renders == 1, 'skipped frames must report false')

router:set(2)
assert(router:needs_render(mon, model) == true, 'page changes must invalidate the frame')
assert(router:render(mon, model) == true and renders == 2)

width = 32
assert(router:needs_render(mon, model) == true, 'geometry changes must invalidate the frame')
assert(router:render(mon, model) == true and renders == 3)

router:invalidate_layout()
assert(router:needs_render(mon, model) == true, 'explicit layout invalidation must force one frame')
assert(router:render(mon, model) == true and renders == 4)
assert(router:needs_render(mon, model) == false)

router.footer.prev = nil
assert(router:needs_render(mon, model) == true, 'missing navigation zones must be rebuilt with the frame')

_G.textutils = nil
print('ui_router_render_decision_test.lua: ok')
