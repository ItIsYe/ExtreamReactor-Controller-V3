local M = {}

local PRIMARY_ROLE_MAP = { "overview", "rt", "energy" }

local function default_view(index, view_order)
  local role = PRIMARY_ROLE_MAP[index]
  if role then return role end
  return (view_order and view_order[1]) or "overview"
end

local function copy_hit(hit)
  if type(hit) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(hit) do out[k] = v end
  return out
end

local function normalize_payload(payload)
  if type(payload) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(payload) do out[k] = v end
  if payload.hit then out.hit = copy_hit(payload.hit) end
  return out
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
    local rebound = prior.mon ~= nil and prior.mon ~= mon.mon
    local size_changed = prior.last_size_key ~= nil and prior.last_size_key ~= size_key
    local layout_changed = prior.last_layout_key ~= nil and prior.last_layout_key ~= layout_key

    local session = {
      id = id,
      name = mon.name,
      mon = mon.mon,
      role = role,
      view_key = view_key,
      locked = locked,
      text_scale = mon.text_scale or desired_scale,
      last_applied_scale = mon.last_applied_scale or prior.last_applied_scale,
      last_size_key = size_key,
      last_layout_key = layout_key,
      dirty = prior.dirty == nil and true or prior.dirty,
      dirty_reason = prior.dirty_reason,
      first_draw_done = prior.first_draw_done == true,
      hitboxes = prior.hitboxes or {},
      last_input = prior.last_input,
      last_error = prior.last_error,
      width = mon.width,
      height = mon.height,
      size_tag = mon.size_tag,
      layout_class = mon.layout_class,
      size_key = size_key,
      layout_key = layout_key,
      rebind_pending = rebound
    }

    if rebound then
      session.dirty = true
      session.first_draw_done = false
      session.dirty_reason = "rebind"
      session.last_error = "monitor-rebound"
      session.hitboxes = {}
    elseif size_changed or layout_changed then
      session.dirty = true
      session.dirty_reason = size_changed and "size-changed" or "layout-changed"
    end

    next_sessions[id] = session
    next_order[#next_order + 1] = id
  end
  self.sessions, self.order = next_sessions, next_order
  return self:get_primary_sessions()
end

function M:get_sessions()
  local out = {}
  for _, id in ipairs(self.order) do out[#out + 1] = self.sessions[id] end
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
  session.dirty_reason = reason and tostring(reason) or session.dirty_reason
end

function M:needs_full_clear(session)
  if not session then return true end
  return (not session.first_draw_done) or session.dirty
end

function M:note_render_success(session)
  if not session then return end
  session.first_draw_done = true
  session.dirty = false
  session.dirty_reason = nil
  session.last_error = nil
  session.rebind_pending = false
end

function M:note_render_failure(session, err)
  if not session then return end
  session.last_error = tostring(err)
  session.dirty = true
  session.dirty_reason = "render-failed"
end

function M:note_input(session, payload)
  if not session then return end
  session.last_input = normalize_payload(payload)
  local hit = payload and payload.hit
  if hit then
    session.hitboxes = { copy_hit(hit) }
  elseif payload and payload.clears_hitboxes then
    session.hitboxes = {}
  end
end

return M
