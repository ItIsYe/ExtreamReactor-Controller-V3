local M = {}
local Surface = {}
Surface.__index = Surface

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return false end
  return pcall(obj[method], ...)
end

local function geometry(parent)
  local ok, width, height = safe_call(parent, "getSize")
  if not ok or type(width) ~= "number" or type(height) ~= "number"
      or width < 1 or height < 1 then
    return nil, nil
  end
  return width, height
end

local function text_scale(parent)
  local ok, scale = safe_call(parent, "getTextScale")
  if ok then return scale end
  return nil
end

local function same_binding(frame, parent, name, width, height, scale)
  return frame
    and frame.parent == parent
    and frame.name == name
    and frame.width == width
    and frame.height == height
    and frame.scale == scale
end

local function hide(frame)
  if frame and frame.buffered then
    safe_call(frame.target, "setVisible", false)
  end
end

local function show(frame)
  if frame and frame.buffered then
    safe_call(frame.target, "setVisible", true)
  end
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    window_api = opts.window_api,
    active = nil,
    pending = nil,
  }, Surface)
end

function Surface:_window_api()
  if self.window_api ~= nil then return self.window_api end
  return window
end

function Surface:bind(parent, name)
  if not parent then
    local changed = self.active ~= nil or self.pending ~= nil
    hide(self.pending)
    hide(self.active)
    self.pending = nil
    self.active = nil
    return nil, changed
  end

  local width, height = geometry(parent)
  local scale = text_scale(parent)
  if not self.pending and same_binding(self.active, parent, name, width, height, scale) then
    return self.active.target, false
  end
  if same_binding(self.pending, parent, name, width, height, scale) then
    return self.pending.target, true
  end

  hide(self.pending)
  self.pending = nil

  local target = parent
  local buffered = false
  local window_api = self:_window_api()
  if width and height and type(window_api) == "table" and type(window_api.create) == "function" then
    local ok, candidate = pcall(window_api.create, parent, 1, 1, width, height, false)
    if ok and candidate and type(candidate.setVisible) == "function" then
      target = candidate
      buffered = true
    end
  end

  self.pending = {
    parent = parent,
    name = name,
    width = width,
    height = height,
    scale = scale,
    target = target,
    buffered = buffered,
  }
  return target, true
end

function Surface:render(callback)
  if type(callback) ~= "function" then error("render callback required", 2) end
  local candidate = self.pending or self.active
  if not candidate then return nil end

  local previous = self.active
  local is_replacement = self.pending ~= nil
  if candidate.buffered and not is_replacement then
    hide(candidate)
  elseif not candidate.buffered and previous and previous ~= candidate then
    -- Direct rendering cannot be staged. Hide an old window first so writes
    -- reach the physical monitor, and restore it if the callback fails.
    hide(previous)
  end

  local ok, result = xpcall(function()
    return callback(candidate.target)
  end, function(err)
    if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
    return tostring(err)
  end)

  if not ok then
    if is_replacement then
      hide(candidate)
      self.pending = nil
    end
    show(previous)
    error(result, 0)
  end

  if previous and previous ~= candidate then hide(previous) end
  show(candidate)
  self.active = candidate
  self.pending = nil
  return result
end

return M
