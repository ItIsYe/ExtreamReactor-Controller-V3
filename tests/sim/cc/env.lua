-- tests/sim/cc/env.lua  Phase 4.5
-- Stellt alle CC:Tweaked Globals bereit die von Node-Code genutzt werden.
-- Verwendung: local env = dofile(...); setfenv(fn, env) oder direkt nutzen.

local function make(opts)
  opts = opts or {}
  local sim_path = opts.sim_path or "tests/sim/cc"

  local kernel   = opts.kernel   or dofile(sim_path.."/kernel.lua")
  local eq_cls   = opts.eq_cls   or dofile(sim_path.."/event_queue.lua")
  local fs_mod   = opts.fs_mod   or dofile(sim_path.."/fs.lua")
  local http_mod = opts.http_mod or dofile(sim_path.."/http.lua")
  local term_mod = opts.term_mod or dofile(sim_path.."/term.lua")
  local tim_mod  = opts.tim_mod  or dofile(sim_path.."/timers.lua")

  if opts.seed then kernel.reset(opts.seed) end

  local eq      = opts.queue   or eq_cls.new()
  local timers  = opts.timers  or tim_mod.new(kernel)
  local vfs     = fs_mod.new(opts.files or {})
  local http    = http_mod.new(eq)
  local term    = opts.term or term_mod.new(opts.term_opts)

  local computer_id    = opts.computer_id    or 1
  local computer_label = opts.computer_label or "SIM"

  local function _os_epoch() return kernel.epoch_ms() end

  local env = {
    -- Lua stdlib (wichtige Teile)
    pairs     = pairs, ipairs  = ipairs, next    = next,
    type      = type,  tostring= tostring, tonumber= tonumber,
    select    = select, unpack = table.unpack or unpack,
    error     = error, pcall   = pcall,  xpcall = xpcall,
    assert    = assert, print  = print,
    math      = math,  string  = string, table   = table,
    setmetatable = setmetatable, getmetatable = getmetatable,
    rawget    = rawget, rawset = rawset, rawequal = rawequal,
    require   = require,  -- echtes require für Xreactor-Module
    dofile    = dofile,
    io        = io,
    coroutine = coroutine,
    load      = load, loadstring = loadstring,

    -- CC:Tweaked globals
    os = {
      epoch       = function(tz) return _os_epoch() end,
      time        = function(tz) return kernel.now_s() end,
      clock       = function()   return kernel.now_s() end,
      sleep       = function(s)  kernel.advance_s(s)   end,
      startTimer  = function(s)  return timers:start(s) end,
      cancelTimer = function(id) timers:cancel(id) end,
      pullEvent   = function(f)  timers:fired(eq); return eq:pull(f) end,
      pullEventRaw= function(f)  timers:fired(eq); return eq:pull_raw(f) end,
      queueEvent  = function(...) eq:push(...) end,
      reboot      = function() error("SIM:reboot", 0) end,
      shutdown    = function() error("SIM:shutdown", 0) end,
      getComputerID    = function() return computer_id end,
      getComputerLabel = function() return computer_label end,
      setComputerLabel = function(l) computer_label = l end,
    },

    fs   = vfs,
    http = http,
    term = term,

    -- textutils subset
    textutils = {
      serialize   = function(v) return tostring(v) end,
      unserialize = function(s) return load("return "..s)() end,
      serializeJSON = function(v)
        if type(v)=="string" then return '"'..v:gsub('"','\\"')..'"' end
        if type(v)=="number" or type(v)=="boolean" then return tostring(v) end
        if type(v)=="table" then
          local parts={}
          for k,val in pairs(v) do
            parts[#parts+1]='"'..tostring(k)..'": '..(
              type(val)=="string" and '"'..tostring(val)..'"' or tostring(val))
          end
          return "{"..table.concat(parts,", ").."}"
        end
        return "null"
      end,
    },

    -- colors/colours
    colors  = { white=1,orange=2,magenta=4,lightBlue=8,yellow=16,lime=32,
                pink=64,gray=128,lightGray=256,cyan=512,purple=1024,blue=2048,
                brown=4096,green=8192,red=16384,black=32768 },
    colours = { white=1,orange=2,magenta=4,lightBlue=8,yellow=16,lime=32,
                pink=64,gray=128,lightGray=256,cyan=512,purple=1024,blue=2048,
                brown=4096,green=8192,red=16384,black=32768 },

    -- Interner Zugriff für Tests
    _sim = {
      kernel  = kernel,
      queue   = eq,
      timers  = timers,
      vfs     = vfs,
      http    = http,
      term    = term,
    },
  }

  -- _G zeigt auf sich selbst
  env._G = env
  return env
end

return { make = make }
