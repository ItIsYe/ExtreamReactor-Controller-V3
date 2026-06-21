local M = {}

local PRIMARY_ROLE_MAP = { "overview", "rt", "energy" }

local function is_primary_index(index)
  return type(index) == "number" and index >= 1 and index <= #PRIMARY_ROLE_MAP
end

local function resolve_role(index)
  return is_primary_index(index) and PRIMARY_ROLE_MAP[index] or "aux"
end

-- Fix: aux-Monitore (4.+) sollen ein fest dediziertes Error/Warning-Display
-- sein, nicht durch Touch umschaltbar — daher ebenfalls "locked" wie die
-- 3 primären Monitore, nur eben auf AUX_DEFAULT_VIEW statt einer der
-- primären Rollen.
local function resolve_locked(index)
  return true
end

-- TEMPORÄR/dauerhaft: 4. physischer Monitor (und jeder weitere "aux"-Monitor)
-- wird automatisch fest auf die Fehler/Warnungs-Anzeige ("alarms") gepinnt,
-- statt die normale Default-View (Overview) zu zeigen. Dient ausschließlich
-- als dediziertes Error/Warning-Display, unabhängig von den 3 primären
-- Monitoren (overview/rt/energy), die davon NICHT betroffen sind.
local AUX_DEFAULT_VIEW = "alarms"

local function default_view(index, view_order)
  local role = resolve_role(index)
  if role ~= "aux" then return role end
  return AUX_DEFAULT_VIEW
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

function M:is_primary(session)
  return session and session.role and session.role ~= "aux" and session.locked == true or false
end

function M:bind_primary_role(session, index)
  if not session then return end
  session.role = resolve_role(index)
  session.locked = resolve_locked(index)
  -- Fix: dieselbe Korrektur wie in resolve_binding() — "aux" ist kein
  -- gültiger view_key, muss über default_view() aufgelöst werden.
  if session.locked then
    session.view_key = (session.role ~= "aux") and session.role or default_view(index, self.view_order)
  end
end

function M:resolve_view_key(session, index)
  if not session then return default_view(index, self.view_order) end
  if self:is_primary(session) then return session.role or default_view(index, self.view_order) end
  return session.view_key or default_view(index, self.view_order)
end

function M:resolve_binding(index, prior)
  local prior_session = prior or {}
  local role = resolve_role(index)
  local locked = resolve_locked(index)
  -- Fix: "locked and role" setzte den view_key für aux-Monitore fälschlich
  -- auf den ROLLENNAMEN "aux" — eine View mit diesem Namen existiert nicht
  -- ("view-missing-or-no-render"). Nur PRIMÄRE Rollen (overview/rt/energy)
  -- haben einen view_key, der direkt dem Rollennamen entspricht; aux-Monitore
  -- müssen immer über default_view() aufgelöst werden (das liefert
  -- AUX_DEFAULT_VIEW = "alarms").
  local view_key
  if locked and role ~= "aux" then
    view_key = role
  else
    view_key = default_view(index, self.view_order)
  end
  return role, locked, view_key
end

function M:bind_or_update(monitors, desired_scale, view_order)
  self.view_order = view_order or self.view_order
  local next_sessions, next_order = {}, {}
  for i, mon in ipairs(monitors or {}) do
    local id = mon.id or mon.name
    local prior = self.sessions[id] or {}
    local size_key = tostring(mon.width or 0) .. "x" .. tostring(mon.height or 0)
    local layout_key = tostring(mon.layout_class or "compact")
    local rebound = prior.mon ~= nil and prior.mon ~= mon.mon
    local size_changed = prior.last_size_key ~= nil and prior.last_size_key ~= size_key
    local layout_changed = prior.last_layout_key ~= nil and prior.last_layout_key ~= layout_key

    local session = {
      id = id,
      name = mon.name,
      mon = mon.mon,
      role = prior.role,
      view_key = prior.view_key,
      locked = prior.locked == true,
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

    local role, locked, view_key = self:resolve_binding(i, prior)
    session.role = role
    session.locked = locked
    session.view_key = view_key

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
