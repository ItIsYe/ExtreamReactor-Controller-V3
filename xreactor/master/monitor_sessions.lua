local M = {}

local PRIMARY_ROLE_MAP = { "overview", "rt", "energy" }

local function default_view(index, view_order)
  local role = PRIMARY_ROLE_MAP[index]
  if role then return role end
  return (view_order and view_order[1]) or "overview"
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    sessions = {},
    order = {},
    view_order = opts.view_order or { "overview", "rt", "energy" }
  }, { __index = M })
end

function M:bind_or_update(monitors, desired_scale, view_order)
  self.view_order = view_order or self.view_order
  local next_sessions, next_order = {}, {}
  for i, mon in ipairs(monitors or {}) do
    local id = mon.id or mon.name
    local prior = self.sessions[id] or {}
    local role = (i <= 3) and PRIMARY_ROLE_MAP[i] or "aux"
    local locked = i <= 3
    local view_key = locked and role or (prior.view_key or default_view(i, self.view_order))
    local size_key = tostring(mon.width or 0) .. "x" .. tostring(mon.height or 0)
    local layout_key = tostring(mon.layout_class or "compact")
    local session = {
      id = id,
      name = mon.name,
      mon = mon.mon,
      role = role,
      view_key = view_key,
      locked = locked,
      text_scale = mon.text_scale or desired_scale,
      last_applied_scale = mon.last_applied_scale or prior.last_applied_scale,
      last_size_key = prior.last_size_key or size_key,
      last_layout_key = prior.last_layout_key or layout_key,
      last_render_hash = prior.last_render_hash,
      dirty = prior.dirty == nil and true or prior.dirty,
      first_draw_done = prior.first_draw_done == true,
      hitboxes = prior.hitboxes or {},
      last_input = prior.last_input,
      last_error = prior.last_error,
      width = mon.width,
      height = mon.height,
      size_tag = mon.size_tag,
      layout_class = mon.layout_class,
      size_key = size_key,
      layout_key = layout_key
    }
    if prior.mon ~= nil and prior.mon ~= session.mon then
      session.dirty = true
      session.first_draw_done = false
      session.last_error = "monitor-rebound"
    end
    if session.last_size_key ~= size_key or session.last_layout_key ~= layout_key then
      session.dirty = true
      session.last_size_key = size_key
      session.last_layout_key = layout_key
    end
    next_sessions[id] = session
    next_order[#next_order + 1] = id
  end
  self.sessions, self.order = next_sessions, next_order
  return self:get_primary_sessions()
end


function M:get_sessions()
  local out = {}
  for _, id in ipairs(self.order) do
    out[#out + 1] = self.sessions[id]
  end
  return out
end

function M:get_primary_sessions()
  local out = {}
  for i = 1, math.min(3, #self.order) do
    out[#out + 1] = self.sessions[self.order[i]]
  end
  return out
end

function M:get_session_by_name(name)
  for _, id in ipairs(self.order) do
    local s = self.sessions[id]
    if s and (s.name == name or s.id == name or tostring(s.mon) == tostring(name)) then return s end
  end
end

function M:mark_dirty(session, reason)
  if not session then return end
  session.dirty = true
  if reason then session.last_error = tostring(reason) end
end

function M:needs_full_clear(session)
  if not session then return true end
  return (not session.first_draw_done) or session.dirty
end

return M
