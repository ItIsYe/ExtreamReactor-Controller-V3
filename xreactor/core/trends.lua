local trends = {}

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
  return {
    power = RingBuffer.new(size),
    energy = RingBuffer.new(size),
    water = RingBuffer.new(size)
  }
end

trends.RingBuffer = RingBuffer

return trends
