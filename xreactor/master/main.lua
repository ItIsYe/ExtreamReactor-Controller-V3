local bootstrap = dofile('/xreactor/core/bootstrap.lua')
bootstrap.setup({
  role = 'master',
  log_enabled = false,
  log_path = nil
})

local require = bootstrap.require
local runtime_loop  = require('master.runtime_loop')
runtime_loop.run()
