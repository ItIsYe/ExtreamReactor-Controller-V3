package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')
package.loaded['nodes.fuel.half_overview'] = nil
local overlay = require('nodes.fuel.half_overview')
assert(overlay.DISABLED_FIXED_SCALE_1 == true)
assert(overlay.render({}, {}) == false)
print('fuel_half_overview_test.lua: ok')
