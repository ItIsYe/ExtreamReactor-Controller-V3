local machine = {}

function machine.new(states, initial)
  assert(states[initial], "invalid initial state")
  local current = initial
  local handlers = {}
  for name, def in pairs(states) do
    handlers[name] = {
      on_enter = def.on_enter or function() end,
      on_tick = def.on_tick or function() end,
      on_exit = def.on_exit or function() end
    }
  end

  return {
    state = function()
      return current
    end,
    transition = function(_, target, context)
      if not handlers[target] then
        error("invalid state: " .. tostring(target))
      end
      if target == current then return end
      handlers[current].on_exit(context)
      current = target
      handlers[current].on_enter(context)
    end,
    tick = function(_, context)
      handlers[current].on_tick(context)
    end
  }
end

return machine
