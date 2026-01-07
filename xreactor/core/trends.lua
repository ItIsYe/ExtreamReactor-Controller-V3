local trends = {}

local EPSILON = {
  power = 0.01,
  energy = 0.005,
  water = 0.005
}

local RingBuffer = {}
RingBuffer.__index = RingBuffer

function RingBuffer.new(size)
  return setmetatable({ size = size, data = {}, index = 0, count = 0 }, RingBuffer)
end

function RingBuffer:push(value)
  self.index = (self.index % self.size) + 1
  self.data[self.index] = value
  self.count = math.min(self.count + 1, self.size)
end

function RingBuffer:last()
  if self.count == 0 then return nil end
  return self.data[self.index]
end

function RingBuffer:values()
  local out = {}
  if self.count == 0 then return out end
  for i = 1, self.count do
    local pos = self.index - self.count + i
    if pos <= 0 then pos = pos + self.size end
    out[#out + 1] = self.data[pos]
  end
  return out
end

function trends.new(sample_size)
  local size = sample_size or 600
  local self = {
    buffers = {
      power = RingBuffer.new(size),
      energy = RingBuffer.new(size),
      water = RingBuffer.new(size)
    },
    last = {},
    dirty = {}
  }

  function self:push(name, value)
    local buffer = self.buffers[name]
    if not buffer then return false end
    local last_value = self.last[name]
    local epsilon = EPSILON[name] or 0
    if last_value == nil or math.abs(value - last_value) >= epsilon then
      buffer:push(value)
      self.last[name] = value
      self.dirty[name] = true
      return true
    end
    return false
  end

  function self:values(name)
    local buffer = self.buffers[name]
    if not buffer then return {} end
    return buffer:values()
  end

  function self:is_dirty(name)
    return self.dirty[name] == true
  end

  function self:clear_dirty(name)
    self.dirty[name] = false
  end

  return self
end

trends.RingBuffer = RingBuffer

return trends
