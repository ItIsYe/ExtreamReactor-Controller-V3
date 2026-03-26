local package_path = package.path
package.path = table.concat({ "./xreactor/?.lua", "./xreactor/?/init.lua", package.path }, ";")

local original_term = _G.term
local original_os = _G.os
local original_fs = _G.fs

local redirected = false
local current_terminal = { id = "orig" }

_G.term = {
  current = function()
    return current_terminal
  end,
  redirect = function(target)
    local old = current_terminal
    current_terminal = target
    redirected = target ~= nil and target ~= old
    return old
  end,
  setBackgroundColor = function() end,
  setTextColor = function() end,
  clear = function() end,
  setCursorPos = function() end,
  write = function() end
}

_G.os = _G.os or {}
os.date = function() return "00:00:00" end
os.clock = function() return 0 end

_G.fs = {
  exists = function() return true end,
  makeDir = function() end,
  getSize = function() return 0 end,
  open = function()
    return {
      write = function() end,
      close = function() end
    }
  end
}

package.loaded["core.logger"] = nil
package.loaded["core.ui"] = nil
local ui = require("core.ui")

local monitor = {
  getSize = function() return 4, 4 end
}

-- Force an error in render callback by making monitor text color setter fail.
_G.term.setTextColor = function()
  error("simulated render error")
end

ui.clear(monitor)

if current_terminal == monitor then
  error("term.redirect should have been restored to old terminal")
end
if not redirected then
  error("expected redirect to be used during render")
end

_G.term = original_term
_G.os = original_os
_G.fs = original_fs
package.path = package_path

print("ui_redirect_guard_test.lua: ok")
