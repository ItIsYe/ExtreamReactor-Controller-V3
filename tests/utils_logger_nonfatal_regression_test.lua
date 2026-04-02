package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

package.loaded['core.logger'] = {
  log = function()
    error('forced logger failure')
  end
}
package.loaded['core.utils'] = nil
local utils = require('core.utils')

local ok, err = pcall(function()
  utils.log('RT', 'must stay non-fatal', 'INFO')
end)
if not ok then
  error('utils.log must never throw on logger backend errors: ' .. tostring(err))
end

print('utils_logger_nonfatal_regression_test.lua: ok')
