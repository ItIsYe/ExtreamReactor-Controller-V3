from pathlib import Path
import re, zlib

ROOT = Path('.')

def read(path): return (ROOT/path).read_text(encoding='utf-8')
def write(path, text): (ROOT/path).write_text(text, encoding='utf-8')
def replace_once(path, old, new):
    text=read(path); count=text.count(old)
    if count != 1: raise SystemExit(f'{path}: anchor count={count}: {old[:100]!r}')
    write(path, text.replace(old,new,1))
def regex_once(path, pattern, replacement, flags=0):
    text=read(path); new,count=re.subn(pattern,lambda _m:replacement,text,count=1,flags=flags)
    if count != 1: raise SystemExit(f'{path}: regex count={count}: {pattern[:120]!r}')
    write(path,new)
def crc(data): return f'{zlib.crc32(data)&0xffffffff:08x}'

router='xreactor/nodes/fuel/redstone_router.lua'
replace_once(router,
'''      tree_configured = false,
      refresh_deferred = false,
''',
'''      tree_configured = false,
      refresh_deferred = false,
      transaction_seq = 0,
      last_transaction = nil,
      safety_latch = nil,
      quiesce = nil,
''')
replace_once(router,
'''  if self._state.transaction then
    self._state.refresh_deferred = true
    self.log("DEBUG", "RedstoneRouter: refresh deferred while transaction is active")''',
'''  if self._state.transaction or self._state.quiesce then
    self._state.refresh_deferred = true
    self.log("DEBUG", "RedstoneRouter: refresh deferred while transaction/quiesce is active")''')

helper_anchor='''function M:begin_transaction(target_id, action_fn, valve_open_ms, opts)
'''
helpers='''local SAFETY_CONFIRM_TIMEOUT_MS = 15000
local SAFETY_RETRY_MS = 1000

local function phase_for_state(state)
  local map = {
    WAIT_BLOCK_ACKS = "BLOCKING",
    WAIT_OPEN_ACKS = "OPENING",
    WAIT_SETTLE = "SETTLING",
    HOLD_OPEN = "HOLDING",
    WAIT_FINAL_ACKS = "FINAL_BLOCK",
  }
  return map[state] or state
end

function M:_next_transaction_id(target_id)
  self._state.transaction_seq = (self._state.transaction_seq or 0) + 1
  local now = os.epoch and os.epoch("utc") or 0
  return table.concat({ tostring(self.source_node_id or "ROUTER"), tostring(now),
    tostring(self._state.transaction_seq), tostring(target_id or "?") }, ":")
end

function M:_all_block_entries()
  local entries = {}
  for _, v in ipairs(self._state.all_valves or {}) do
    entries[#entries + 1] = { integrator = v.integrator, side = v.side, high = true }
  end
  return entries
end

function M:_record_terminal(tx, state_name, reason, notify_complete)
  if not tx then return end
  local now = os.epoch and os.epoch("utc") or 0
  local info = {
    id = tx.id,
    transaction_id = tx.id,
    target_id = tx.target_id,
    state = state_name,
    phase = state_name,
    reason = reason,
    started_ts = tx.started_ts,
    finished_ts = now,
  }
  self._state.last_transaction = info
  if notify_complete and tx.on_complete then
    local ok, err = pcall(tx.on_complete, info)
    if not ok then
      self.warn_once("tx_on_complete_failed:" .. tostring(tx.target_id),
        "RedstoneRouter: on_complete-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
    end
  end
end

function M:_start_final_block(tx, now_ms)
  tx.pending = self:_request_valve_batch(self:_all_block_entries())
  tx.state = "WAIT_FINAL_ACKS"
  tx.phase = "FINAL_BLOCK"
  tx.phase_started_ms = now_ms
end

function M:_set_safety_latch(tx, reason, now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  local latch = {
    state = "FINAL_BLOCK_UNCONFIRMED",
    transaction_id = tx and tx.id or nil,
    target_id = tx and tx.target_id or nil,
    reason = reason,
    since = now_ms,
    phase_started_ms = now_ms,
    attempts = 1,
  }
  if #self._state.all_valves > 0 then
    latch.pending = self:_request_valve_batch(self:_all_block_entries())
  end
  self._state.safety_latch = latch
  self.log("ERROR", "RedstoneRouter: Safety-Latch gesetzt -- neue Lieferungen gesperrt bis BLOCKED erneut bestaetigt ist (" .. tostring(reason) .. ")")
end

function M:_tick_safety_latch(now_ms)
  local latch = self._state.safety_latch
  if not latch then return true end
  if #self._state.all_valves == 0 then return false end
  if not latch.pending then
    latch.pending = self:_request_valve_batch(self:_all_block_entries())
    latch.phase_started_ms = now_ms
    latch.attempts = (latch.attempts or 0) + 1
    return false
  end
  local status = self:_check_valve_batch(latch.pending)
  if status == "ok" then
    self.log("INFO", "RedstoneRouter: Safety-Latch aufgehoben -- alle Ventile erneut BLOCKED bestaetigt")
    self._state.safety_latch = nil
    return true
  end
  if status == "waiting" and now_ms - (latch.phase_started_ms or now_ms) < SAFETY_CONFIRM_TIMEOUT_MS then
    return false
  end
  if now_ms - (latch.phase_started_ms or 0) >= SAFETY_RETRY_MS then
    latch.pending = self:_request_valve_batch(self:_all_block_entries())
    latch.phase_started_ms = now_ms
    latch.attempts = (latch.attempts or 0) + 1
  end
  return false
end

function M:get_safety_latch()
  local latch = self._state.safety_latch
  if not latch then return nil end
  return {
    state = latch.state, transaction_id = latch.transaction_id, target_id = latch.target_id,
    reason = latch.reason, since = latch.since, attempts = latch.attempts,
  }
end

function M:get_last_transaction()
  return self._state.last_transaction
end

-- Update-Quiesce has a stricter contract than shutdown_now(): runtime may only
-- stop after every currently known wireless/local valve is confirmed BLOCKED.
function M:begin_quiesce(reason)
  if self._state.quiesce then return self._state.quiesce.state == "CONFIRMED" end
  if self._state.transaction then
    self:shutdown_now(reason or "UPDATE_QUIESCE", { skip_latch = true })
  end
  local q = {
    reason = reason or "UPDATE_QUIESCE", state = "BLOCKING",
    started_ts = os.epoch and os.epoch("utc") or 0,
    phase_started_ms = os.epoch and os.epoch("utc") or 0,
    attempts = 1,
  }
  self._state.quiesce = q
  if not self._state.tree_configured then
    q.state = "CONFIRMED"
    return true
  end
  if #self._state.all_valves == 0 then
    q.state = "UNCONFIRMED_NO_VALVES"
    self.log("ERROR", "RedstoneRouter: Quiesce kann Routing-Sicherheit nicht bestaetigen -- Baum konfiguriert, aber keine Ventile bekannt")
    return false
  end
  q.pending = self:_request_valve_batch(self:_all_block_entries())
  return false
end

function M:poll_quiesce(now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  if not self._state.quiesce then
    local ready = self:begin_quiesce("UPDATE_QUIESCE")
    if ready then return true end
  end
  local q = self._state.quiesce
  if q.state == "CONFIRMED" then return true end
  if #self._state.all_valves == 0 then return false end
  if not q.pending then
    q.pending = self:_request_valve_batch(self:_all_block_entries())
    q.phase_started_ms = now_ms
    q.attempts = (q.attempts or 0) + 1
    return false
  end
  local status = self:_check_valve_batch(q.pending)
  if status == "ok" then
    q.state = "CONFIRMED"
    self._state.safety_latch = nil
    self.log("INFO", "RedstoneRouter: Update-Quiesce bestaetigt -- alle Ventile BLOCKED")
    return true
  end
  if status == "waiting" and now_ms - (q.phase_started_ms or now_ms) < SAFETY_CONFIRM_TIMEOUT_MS then
    return false
  end
  q.pending = self:_request_valve_batch(self:_all_block_entries())
  q.phase_started_ms = now_ms
  q.attempts = (q.attempts or 0) + 1
  self.log("WARN", "RedstoneRouter: Quiesce-BLOCKED noch nicht bestaetigt -- sichere Anforderung wird erneut gesendet")
  return false
end

'''
replace_once(router, helper_anchor, helpers+helper_anchor)

begin_pattern=r'''function M:begin_transaction\(target_id, action_fn, valve_open_ms, opts\)\n.*?\nend\n\nfunction M:_fail_transaction'''
begin_new='''function M:begin_transaction(target_id, action_fn, valve_open_ms, opts)
  opts = opts or {}
  if self._state.quiesce then return false, "quiescing" end
  if self._state.safety_latch then return false, "safety_latched" end
  if self._state.transaction then return false, "busy" end

  local tx_id = opts.transaction_id or self:_next_transaction_id(target_id)
  local now_ms = os.epoch and os.epoch("utc") or 0
  if #self._state.all_valves == 0 then
    if not self._state.tree_configured then
      local pseudo = { id = tx_id, target_id = target_id, started_ts = now_ms, on_complete = opts.on_complete }
      local ok, result, detail = true, nil, nil
      if action_fn then ok, result, detail = pcall(action_fn) end
      if not ok or result == false then
        local reason = not ok and tostring(result) or tostring(detail or "action returned false")
        self:_record_terminal(pseudo, "EXPORT_FAILED", reason, true)
        return false, "action_failed", tx_id
      end
      self:_record_terminal(pseudo, "COMPLETE_SAFE", nil, true)
      return true, "direct_export", tx_id
    end
    self.log("ERROR", "RedstoneRouter: begin_transaction() verweigert -- Routing war konfiguriert, aber 0 Ventile bekannt. Kein ungeschuetzter Direkt-Export.")
    self:block_all()
    return false, "invalid_tree", tx_id
  end

  local path = find_path(self._state.routes, target_id)
  if not path then
    self.log("WARN", "RedstoneRouter: no path found for target: " .. tostring(target_id))
    self:block_all()
    self._state.active_target = nil
    self._state.active_path = nil
    return false, "no_path", tx_id
  end

  self._state.transaction = {
    id = tx_id,
    target_id = target_id,
    action_fn = action_fn,
    on_error = opts.on_error,
    on_complete = opts.on_complete,
    valve_open_ms = tonumber(valve_open_ms) or 2000,
    state = "WAIT_BLOCK_ACKS",
    phase = "BLOCKING",
    pending = self:_request_valve_batch(self:_all_block_entries()),
    path = path,
    phase_started_ms = now_ms,
    settle_until = nil,
    hold_until = nil,
    started_ts = now_ms,
  }
  return true, "started", tx_id
end

function M:_fail_transaction'''
regex_once(router,begin_pattern,begin_new,re.S)

fail_pattern=r'''function M:_fail_transaction\(reason\)\n.*?\nend\n\n-- Maximale Wartezeit'''
fail_new='''function M:_fail_transaction(reason)
  local tx = self._state.transaction
  self.log("ERROR", string.format(
    "RedstoneRouter: Transaktion %s zu %s abgebrochen (%s) -- sichere BLOCKED-Bestaetigung wird gelatcht",
    tostring(tx and tx.id), tostring(tx and tx.target_id), tostring(reason)))
  self._state.active_target = nil
  self._state.active_path = nil
  self._state.transaction = nil
  if tx then
    self:_record_terminal(tx, "CANCELLED", reason, false)
    if #self._state.all_valves > 0 then self:_set_safety_latch(tx, "cancelled:" .. tostring(reason)) else self:block_all() end
  else
    self:block_all()
  end
  if tx and tx.on_error then
    local ok, err = pcall(tx.on_error, reason)
    if not ok then
      self.warn_once("tx_on_error_failed:" .. tostring(tx.target_id),
        "RedstoneRouter: on_error-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
    end
  end
end

-- Maximale Wartezeit'''
regex_once(router,fail_pattern,fail_new,re.S)

# Replace only the tick state machine. Keep surrounding comments and later APIs.
tick_pattern=r'''function M:tick\(now_ms\)\n.*?\nend\n\n-- Sofortiger Shutdown-Pfad'''
tick_new='''function M:tick(now_ms)
  now_ms = now_ms or (os.epoch and os.epoch("utc") or 0)
  local tx = self._state.transaction
  if not tx then
    if self._state.safety_latch then self:_tick_safety_latch(now_ms) end
    if self._state.refresh_deferred and not self._state.quiesce and not self._state.safety_latch then
      self._state.refresh_deferred = false
      self:refresh()
    end
    return
  end

  if tx.state == "WAIT_BLOCK_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    if status == "failed" then self:_fail_transaction("block_ack_failed:" .. tostring(failed_key)); return end
    if status == "waiting" then
      if now_ms - tx.phase_started_ms >= VALVE_PHASE_TIMEOUT_MS then self:_fail_transaction("block_ack_timeout") end
      return
    end
    local uses_network, open_entries = false, {}
    for _, v in ipairs(tx.path) do
      open_entries[#open_entries + 1] = { integrator = v.integrator, side = v.side, high = false }
      local w = v.integrator and self._state.integrators[v.integrator]
      if w and w.network then uses_network = true end
    end
    tx.pending = self:_request_valve_batch(open_entries)
    tx.uses_network = uses_network
    tx.state = "WAIT_OPEN_ACKS"
    tx.phase = "OPENING"
    tx.phase_started_ms = now_ms
    return
  end

  if tx.state == "WAIT_OPEN_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    if status == "failed" then self:_fail_transaction("open_ack_failed:" .. tostring(failed_key)); return end
    if status == "waiting" then
      if now_ms - tx.phase_started_ms >= VALVE_PHASE_TIMEOUT_MS then self:_fail_transaction("open_ack_timeout") end
      return
    end
    local sides = {}
    for _, v in ipairs(tx.path) do sides[#sides + 1] = v.side end
    self._state.active_target = tx.target_id
    self._state.active_path = sides
    self._state.last_target = tx.target_id
    self._state.last_path = sides
    self._state.last_active_ts = now_ms
    local settle_s = tx.uses_network and 0.4 or 0.05
    tx.settle_until = now_ms + math.floor(settle_s * 1000)
    tx.state = "WAIT_SETTLE"
    tx.phase = "SETTLING"
    return
  end

  if tx.state == "WAIT_SETTLE" then
    if now_ms < tx.settle_until then return end
    local ready, readiness_error = self:_path_runtime_ready(tx.path)
    if not ready then self:_fail_transaction("path_not_ready:" .. tostring(readiness_error)); return end

    tx.phase = "EXPORTING"
    local action_ok, result, detail = true, nil, nil
    if tx.action_fn then action_ok, result, detail = pcall(tx.action_fn) end
    if not action_ok or result == false then
      local reason = not action_ok and tostring(result) or tostring(detail or "action returned false")
      tx.terminal_after_block = "EXPORT_FAILED"
      tx.terminal_reason = reason
      self.warn_once("transaction_action_error:" .. tostring(tx.target_id),
        "RedstoneRouter: Export/Aktions-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. reason)
      self:_start_final_block(tx, now_ms)
      return
    end

    tx.state = "HOLD_OPEN"
    tx.phase = "HOLDING"
    tx.hold_until = now_ms + tx.valve_open_ms
    return
  end

  if tx.state == "HOLD_OPEN" then
    if now_ms >= tx.hold_until then
      tx.terminal_after_block = tx.terminal_after_block or "COMPLETE_SAFE"
      self:_start_final_block(tx, now_ms)
    end
    return
  end

  if tx.state == "WAIT_FINAL_ACKS" then
    local status, failed_key = self:_check_valve_batch(tx.pending)
    local timed_out = (now_ms - tx.phase_started_ms) >= VALVE_PHASE_TIMEOUT_MS
    if status == "waiting" and not timed_out then return end

    self._state.active_target = nil
    self._state.active_path = nil
    self._state.transaction = nil
    if status == "ok" then
      local terminal = tx.terminal_after_block or "COMPLETE_SAFE"
      self:_record_terminal(tx, terminal, tx.terminal_reason, true)
      return
    end

    local reason = status == "failed"
      and ("final_block_failed:" .. tostring(failed_key)) or "final_block_timeout"
    self:_set_safety_latch(tx, reason, now_ms)
    self:_record_terminal(tx, "FINAL_BLOCK_UNCONFIRMED", reason, true)
    return
  end
end

-- Sofortiger Shutdown-Pfad'''
regex_once(router,tick_pattern,tick_new,re.S)

shutdown_pattern=r'''function M:shutdown_now\(reason\)\n.*?\nend\n\n-- Sichtbarkeit fuer UI/Diagnose: aktive Transaktion und ihr Zustand\.\nfunction M:get_active_transaction\(\)\n.*?\nend'''
shutdown_new='''function M:shutdown_now(reason, opts)
  opts = opts or {}
  local tx = self._state.transaction
  self._state.transaction = nil
  self._state.active_target = nil
  self._state.active_path = nil
  if tx then
    self.log("WARN", string.format(
      "RedstoneRouter: Transaktion %s zu %s durch shutdown_now() abgebrochen (%s)",
      tostring(tx.id), tostring(tx.target_id), tostring(reason or "shutdown")))
    self:_record_terminal(tx, "CANCELLED", reason or "shutdown", false)
    if not opts.skip_latch and #self._state.all_valves > 0 then
      self:_set_safety_latch(tx, "shutdown:" .. tostring(reason or "shutdown"))
    else
      self:block_all()
    end
    if tx.on_error then
      local ok, err = pcall(tx.on_error, reason or "shutdown")
      if not ok then
        self.warn_once("tx_on_error_failed:" .. tostring(tx.target_id),
          "RedstoneRouter: on_error-Callback fuer " .. tostring(tx.target_id) .. " fehlgeschlagen: " .. tostring(err))
      end
    end
  else
    self:block_all()
  end
end

-- Sichtbarkeit fuer UI/Diagnose: aktive Transaktion und ihr Zustand.
function M:get_active_transaction()
  local tx = self._state.transaction
  if not tx then return nil end
  return {
    id = tx.id, transaction_id = tx.id, target_id = tx.target_id,
    state = tx.state, phase = tx.phase or phase_for_state(tx.state), started_ts = tx.started_ts,
  }
end'''
regex_once(router,shutdown_pattern,shutdown_new,re.S)

# FUEL and REPROCESSOR update quiesce must wait for confirmed wireless BLOCKED.
fuel='xreactor/nodes/fuel/main.lua'
replace_once(fuel,
'''end, quiesce_handshake and { handshake = quiesce_handshake, on_quiesce = function()
  local rs_router = get_rs_router()
  rs_router:shutdown_now("UPDATE_QUIESCE")
  return rs_router:get_active_transaction() == nil
end } or nil)''',
'''end, quiesce_handshake and { handshake = quiesce_handshake, on_quiesce = function()
  local rs_router = get_rs_router()
  rs_router:begin_quiesce("UPDATE_QUIESCE")
  return rs_router:poll_quiesce()
end } or nil)''')

reproc='xreactor/nodes/reprocessor/main.lua'
replace_once(reproc,
'''end, quiesce_handshake and { handshake = quiesce_handshake, on_quiesce = function()
  enter_standby("UPDATE_QUIESCE")
  return standby == true
end } or nil)''',
'''end, quiesce_handshake and { handshake = quiesce_handshake, on_quiesce = function()
  enter_standby("UPDATE_QUIESCE")
  local rs_router = get_rs_router()
  rs_router:begin_quiesce("UPDATE_QUIESCE")
  return standby == true and rs_router:poll_quiesce()
end } or nil)''')

# logistics_router: stable delivery ID/phase and no asynchronous mutation of a
# later last_cycle object.
logi='xreactor/nodes/fuel/logistics_router.lua'
replace_once(logi,
'''      current_request = nil,  -- { reactor_id, label, state="requesting"|"delivering"|nil }
''',
'''      current_request = nil,  -- { transaction_id, reactor_id, label, state, phase }
      last_delivery = nil,
      delivery_seq = 0,
''')
constructor_anchor='''-- ---- peripheral discovery --------------------------------------------------
'''
logi_helpers='''local function next_delivery_id(self, label)
  self._state.delivery_seq = (self._state.delivery_seq or 0) + 1
  local now = os.epoch and os.epoch("utc") or 0
  return table.concat({ "FUEL", tostring(now), tostring(self._state.delivery_seq), tostring(label or "?") }, ":")
end

local function finish_delivery(self, request, phase, terminal_state, err)
  if not request then return end
  request.phase = phase
  request.terminal_state = terminal_state
  request.error = err or request.error
  request.finished_ts = os.epoch and os.epoch("utc") or 0
  self._state.last_delivery = {
    transaction_id = request.transaction_id,
    reactor_id = request.reactor_id,
    label = request.label,
    phase = request.phase,
    terminal_state = request.terminal_state,
    moved = request.moved or 0,
    error = request.error,
    started_ts = request.started_ts,
    finished_ts = request.finished_ts,
  }
  if self._state.current_request == request then self._state.current_request = nil end
end

'''
replace_once(logi,constructor_anchor,logi_helpers+constructor_anchor)
replace_once(logi,
'''    self._state.current_request = {
      reactor_id = r.reactor_id, label = r.label, state = "requesting",
    }''',
'''    self._state.current_request = {
      reactor_id = r.reactor_id, label = r.label, state = "requesting", phase = "REQUESTING",
      started_ts = os.epoch and os.epoch("utc") or 0,
    }''')
replace_once(logi,
'''      local valve_ms = tonumber(cfg_l.valve_open_ms) or 2000
      local pct_str = fuel_pct and string.format(" (%.0f%%)", fuel_pct * 100) or ""

      if routed then''',
'''      local valve_ms = tonumber(cfg_l.valve_open_ms) or 2000
      local pct_str = fuel_pct and string.format(" (%.0f%%)", fuel_pct * 100) or ""
      local request = self._state.current_request
      request.transaction_id = request.transaction_id or next_delivery_id(self, r.label)

      if routed then''')

routed_pattern=r'''      if routed then\n.*?        return exported, errors\n      end\n\n      -- No redstone routing configured:'''
routed_new='''      if routed then
        local function do_export()
          request.phase = "EXPORTING"
          request.state = "delivering"
          local ok, result = pcall(bridge.wrapped.exportItemToPeripheral,
            { name = r.item, count = push }, r.inlet.name)
          if not ok then
            local err = tostring(result)
            self.warn_once("exp_err:" .. r.inlet.name,
              "exportItemToPeripheral → " .. r.inlet.name .. ": " .. err)
            self._state.total_errors = self._state.total_errors + 1
            request.error_counted = true
            request.error = err
            return false, err
          end
          local moved = type(result) == "number" and result or 0
          request.moved = moved
          request.exported_at = os.epoch and os.epoch("utc") or 0
          if moved > 0 then
            self._state.total_exported = self._state.total_exported + moved
            self.log("INFO", string.format("ME→[%s]%s %s x%d via %s [tx=%s]",
              r.label, pct_str, r.item, moved, r.inlet.name, tostring(request.transaction_id)))
          end
          return true, moved
        end

        local function on_transaction_error(reason)
          self.warn_once("routing_failed:" .. tostring(r.label),
            "Logistics: Routing-Transaktion fuer " .. r.label .. " abgebrochen (" .. tostring(reason) .. ")")
          if not request.error_counted then
            self._state.total_errors = self._state.total_errors + 1
            request.error_counted = true
          end
          finish_delivery(self, request, "ERROR", "CANCELLED", tostring(reason))
        end

        local function on_transaction_complete(info)
          local terminal = type(info) == "table" and info.state or "ERROR"
          if terminal == "COMPLETE_SAFE" then
            finish_delivery(self, request, "COMPLETE", terminal, nil)
          else
            if not request.error_counted then
              self._state.total_errors = self._state.total_errors + 1
              request.error_counted = true
            end
            finish_delivery(self, request, "ERROR", terminal,
              type(info) == "table" and info.reason or "transaction failed")
          end
        end

        local started, reason, router_tx_id = rs:begin_transaction(r.label, do_export, valve_ms, {
          on_error = on_transaction_error,
          on_complete = on_transaction_complete,
          transaction_id = request.transaction_id,
        })
        if not started then
          self._state.current_request = nil
          if reason == "busy" then
            self.log("DEBUG", "Logistics: Router beschaeftigt (aktive Transaktion) — restliche Kandidaten diesen Zyklus uebersprungen")
            return exported, errors
          end
          if reason == "safety_latched" or reason == "quiescing" then
            self.log("WARN", "Logistics: Router sicherheitsgesperrt (" .. tostring(reason) .. ") — keine weitere Lieferung")
            return exported, errors
          end
          self.log("DEBUG", "Logistics: " .. r.label .. ": Routing nicht moeglich (" .. tostring(reason) .. ") — naechster Kandidat")
          goto continue
        end
        request.transaction_id = router_tx_id or request.transaction_id
        request.state = "delivering"
        local active = type(rs.get_active_transaction) == "function" and rs:get_active_transaction() or nil
        request.phase = active and active.phase or "BLOCKING"
        return exported, errors
      end

      -- No redstone routing configured:'''
regex_once(logi,routed_pattern,routed_new,re.S)

# Replace direct-export block so it receives the same transaction identity and
# an explicit terminal result, while remaining synchronous.
direct_pattern=r'''      -- No redstone routing configured: export directly, weiter zum\n      -- naechsten Kandidaten \(unveraendertes Verhalten, keine Blockierung\)\.\n      self\._state\.current_request\.state = "delivering"\n      local ok, result = pcall\(bridge\.wrapped\.exportItemToPeripheral,\n        \{ name = r\.item, count = push \}, r\.inlet\.name\)\n      if not ok then\n.*?      end\n    end'''
direct_new='''      -- No redstone routing configured: synchronous export with the same
      -- stable transaction identity/terminal semantics.
      request.state = "delivering"
      request.phase = "EXPORTING"
      local ok, result = pcall(bridge.wrapped.exportItemToPeripheral,
        { name = r.item, count = push }, r.inlet.name)
      if not ok then
        local err = tostring(result)
        self.warn_once("exp_err:" .. r.inlet.name,
          "exportItemToPeripheral → " .. r.inlet.name .. ": " .. err)
        errors = errors + 1
        request.error_counted = true
        finish_delivery(self, request, "ERROR", "EXPORT_FAILED", err)
      else
        local moved = type(result) == "number" and result or 0
        request.moved = moved
        if moved > 0 then
          exported = exported + moved
          cycle_log[#cycle_log + 1] = string.format(
            "ME→[%s]%s %s x%d via %s", r.label, pct_str, r.item, moved, r.inlet.name)
        end
        finish_delivery(self, request, "COMPLETE", "COMPLETE_SAFE", nil)
      end
    end'''
regex_once(logi,direct_pattern,direct_new,re.S)

# Summary keeps the current request phase synchronized to the router state and
# exposes terminal delivery + safety latch without claiming them as current.
replace_once(logi,
'''  return {
    enabled        = cfg.enabled == true,''',
'''  local active_tx = s.rs_router and type(s.rs_router.get_active_transaction) == "function"
    and s.rs_router:get_active_transaction() or nil
  if s.current_request and active_tx
      and (not s.current_request.transaction_id or s.current_request.transaction_id == active_tx.transaction_id) then
    s.current_request.transaction_id = active_tx.transaction_id or s.current_request.transaction_id
    s.current_request.phase = active_tx.phase or s.current_request.phase
  end
  local safety_latch = s.rs_router and type(s.rs_router.get_safety_latch) == "function"
    and s.rs_router:get_safety_latch() or nil
  return {
    enabled        = cfg.enabled == true,''')
replace_once(logi,
'''    current_request = s.current_request,
    total_exported = s.total_exported,''',
'''    current_request = s.current_request,
    last_delivery  = s.last_delivery,
    router_safety_latch = safety_latch,
    total_exported = s.total_exported,''')

# Update async lifecycle regression to the new truthful final-block semantics.
test='tests/fuel_logistics_async_delivery_lifecycle_test.lua'
replace_once(test,
'''  local fake = { calls = {}, next_started = true, next_reason = 'started' }
''',
'''  local fake = { calls = {}, next_started = true, next_reason = 'started', active_phase = 'BLOCKING' }
''')
replace_once(test,
'''  function fake:begin_transaction(target_id, action_fn, valve_open_ms, opts)
    table.insert(self.calls, { target_id = target_id, action_fn = action_fn, valve_open_ms = valve_open_ms, opts = opts })
    return self.next_started, self.next_reason
  end''',
'''  function fake:begin_transaction(target_id, action_fn, valve_open_ms, opts)
    local id = opts and opts.transaction_id or 'tx-missing'
    table.insert(self.calls, { target_id = target_id, action_fn = action_fn, valve_open_ms = valve_open_ms, opts = opts, id = id })
    return self.next_started, self.next_reason, id
  end
  function fake:get_active_transaction()
    if #self.calls == 0 then return nil end
    return { transaction_id = self.calls[#self.calls].id, phase = self.active_phase, state = 'WAIT_BLOCK_ACKS' }
  end
  function fake:get_safety_latch() return nil end''')
# Replace the four scenario body region wholesale to avoid retaining the old
# unsafe assumption that action_fn alone is terminal.
scenario_pattern=r'''-- 1\. Erfolgreicher Async-Export:.*?print\('fuel_logistics_async_delivery_lifecycle_test\.lua: ok'\)'''
scenario_new='''-- 1. Erfolgreicher Async-Export: action_fn bewegt Material, aber die
-- Transaktion bleibt bis zur bestaetigten FINAL_BLOCK-Completion sichtbar.
do
  local fake_rs = make_fake_rs_router()
  local router = make_router(fake_rs, function() return 64 end)
  local result = router:run_cycle()
  assert_eq(result.exported, 0, 'async cycle must not claim export synchronously')
  local req = router._state.current_request
  assert_true(req ~= nil and req.transaction_id ~= nil, 'in-flight request needs a stable transaction id')
  assert_eq(req.phase, 'BLOCKING', 'initial router phase must be exposed')
  assert_eq(#fake_rs.calls, 1)
  assert_eq(fake_rs.calls[1].opts.transaction_id, req.transaction_id, 'router and logistics must share the same transaction id')

  fake_rs.active_phase = 'OPENING'
  assert_eq(router:get_summary().current_request.phase, 'OPENING', 'summary must track router phase for same transaction')
  local action_ok = fake_rs.calls[1].action_fn()
  assert_true(action_ok == true, 'export callback should report success explicitly')
  assert_true(router._state.current_request ~= nil, 'export is not terminal until final block is confirmed')
  assert_eq(router._state.total_exported, 64)
  assert_eq(result.exported, 0, 'async callback must not mutate a potentially replaced last_cycle')
  assert_eq(#result.moves, 0, 'async callback must not append into cycle-owned moves table')

  fake_rs.calls[1].opts.on_complete({ state='COMPLETE_SAFE', transaction_id=req.transaction_id })
  assert_eq(router._state.current_request, nil, 'request clears only at terminal router completion')
  assert_eq(router._state.last_delivery.transaction_id, req.transaction_id)
  assert_eq(router._state.last_delivery.terminal_state, 'COMPLETE_SAFE')
end

-- 2. Exportfehler bleibt bis zur sicheren finalen Blockierung sichtbar.
do
  local fake_rs = make_fake_rs_router()
  local router = make_router(fake_rs, function() error('bridge offline') end)
  router:run_cycle()
  local call = fake_rs.calls[1]
  local ok, err = call.action_fn()
  assert_eq(ok, false, 'callback must report hardware/export failure to router')
  assert_true(router._state.current_request ~= nil, 'failed export still needs final-block completion')
  assert_eq(router._state.total_errors, 1)
  call.opts.on_complete({ state='EXPORT_FAILED', reason=err, transaction_id=call.id })
  assert_eq(router._state.current_request, nil)
  assert_eq(router._state.last_delivery.terminal_state, 'EXPORT_FAILED')
  assert_eq(router._state.total_errors, 1, 'same export failure must not be double-counted')
end

-- 3. Abbruch VOR Export uses on_error and terminates the request immediately.
do
  local fake_rs = make_fake_rs_router()
  local export_called = false
  local router = make_router(fake_rs, function() export_called=true; return 64 end)
  router:run_cycle()
  local call = fake_rs.calls[1]
  call.opts.on_error('ack_timeout:VALVE-A|top')
  assert_true(not export_called)
  assert_eq(router._state.current_request, nil)
  assert_eq(router._state.last_delivery.terminal_state, 'CANCELLED')
  assert_eq(router._state.total_errors, 1)
end

-- 4. Busy: no transaction started and no hanging request.
do
  local fake_rs = make_fake_rs_router(); fake_rs.next_started=false; fake_rs.next_reason='busy'
  local router = make_router(fake_rs, function() return 64 end)
  local result = router:run_cycle()
  assert_eq(router._state.current_request, nil)
  assert_eq(result.exported, 0)
end

print('fuel_logistics_async_delivery_lifecycle_test.lua: ok')'''
regex_once(test,scenario_pattern,scenario_new,re.S)

# New quiesce ACK gate regression.
quiesce_test='''package.path = table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path}, ';')
local clock=1000000; os.epoch=function() return clock end
local rr=require('nodes.fuel.redstone_router')
local sent={}
local modem={isWireless=function() return true end,open=function() end,transmit=function(_,_,m) sent[#sent+1]=m; return true end}
_G.peripheral={find=function(k) if k=='modem' then return modem end end,isPresent=function() return false end,wrap=function() return nil end}
local function make()
  local r=rr.new({config={logistics={redstone_tree={
    {side='top',integrator='V1',reactor='R1'},{side='bottom',integrator='V2',reactor='R2'} }}},
    comms={get_peers=function() return {V1={down=false,stale=false},V2={down=false,stale=false}} end},log=function() end,warn_once=function() end})
  r:refresh(); return r
end
local function ack(r,id,side)
  local key=id..'|'..side; local e=assert(r._state.pending_valve_acks[key], 'pending '..key)
  r:handle_valve_ack({type='VALVE_ACK',command_id=e.command_id,src=e.dst,dst=e.src,applied=true,high=true})
end
local r=make()
assert(r:begin_quiesce('UPDATE_QUIESCE') == false, 'wireless quiesce cannot be confirmed before ACKs')
assert(r:poll_quiesce(clock) == false)
ack(r,'V1','top'); assert(r:poll_quiesce(clock) == false, 'one missing valve ACK must keep runtime quiescing')
ack(r,'V2','bottom'); assert(r:poll_quiesce(clock) == true, 'all current BLOCKED ACKs should confirm quiesce')
assert(r._state.quiesce.state == 'CONFIRMED')

local direct=rr.new({config={logistics={redstone_tree={}}},log=function() end,warn_once=function() end})
direct:refresh(); assert(direct:begin_quiesce('UPDATE_QUIESCE') == true, 'no configured routing has no valve ACK obligation')
print('redstone_router_quiesce_ack_gate_test.lua: ok')
'''
write('tests/redstone_router_quiesce_ack_gate_test.lua',quiesce_test)

latch_test='''package.path = table.concat({'./xreactor/?.lua','./xreactor/?/init.lua',package.path}, ';')
local clock=2000000; os.epoch=function() return clock end
local rr=require('nodes.fuel.redstone_router')
local modem={isWireless=function() return true end,open=function() end,transmit=function() return true end}
_G.peripheral={find=function(k) if k=='modem' then return modem end end,isPresent=function() return false end,wrap=function() return nil end}
local peers={V1={down=false,stale=false},V2={down=false,stale=false}}
local r=rr.new({config={logistics={redstone_tree={{side='top',integrator='V1',reactor='R1'},{side='bottom',integrator='V2',reactor='R2'}}}},
  comms={get_peers=function() return peers end},log=function() end,warn_once=function() end})
r:refresh()
local function ack(id,side,applied,high)
  local key=id..'|'..side; local e=assert(r._state.pending_valve_acks[key], 'pending '..key)
  r:handle_valve_ack({type='VALVE_ACK',command_id=e.command_id,src=e.dst,dst=e.src,applied=applied~=false,high=high==nil and e.high or high})
end
local completed
local ok,reason,txid=r:begin_transaction('R1',function() return true end,100,{on_complete=function(i) completed=i end})
assert(ok and txid, reason)
ack('V1','top',true,true); ack('V2','bottom',true,true); r:tick(clock)
ack('V1','top',true,false); r:tick(clock); clock=clock+500; r:tick(clock)
assert(r:get_active_transaction().phase=='HOLDING')
clock=clock+200; r:tick(clock); assert(r:get_active_transaction().phase=='FINAL_BLOCK')
ack('V1','top',false,true); ack('V2','bottom',true,true); r:tick(clock)
assert(r:get_active_transaction()==nil, 'failed final ACK ends active tx but must latch safety')
assert(r:get_safety_latch() and r:get_safety_latch().state=='FINAL_BLOCK_UNCONFIRMED')
assert(completed and completed.state=='FINAL_BLOCK_UNCONFIRMED')
local ok2,reason2=r:begin_transaction('R1',function() end,100)
assert(not ok2 and reason2=='safety_latched', 'new delivery must be blocked by unresolved final safety fault')
ack('V1','top',true,true); ack('V2','bottom',true,true); r:tick(clock)
assert(r:get_safety_latch()==nil, 'fresh all-BLOCKED confirmation should clear latch')
local ok3=r:begin_transaction('R1',function() end,100)
assert(ok3, 'new delivery may start only after latch clears')
print('redstone_router_final_block_latch_test.lua: ok')
'''
write('tests/redstone_router_final_block_latch_test.lua',latch_test)

# Source contract: both routed roles must use confirmed quiesce API.
role_test='''local function read(p) local f=assert(io.open(p,'r')); local s=f:read('*a');f:close();return s end
local root=os.getenv('REPO_ROOT') or '.'
for _,p in ipairs({'xreactor/nodes/fuel/main.lua','xreactor/nodes/reprocessor/main.lua'}) do
  local s=read(root..'/'..p)
  assert(s:find(':begin_quiesce("UPDATE_QUIESCE")',1,true), p..' must begin confirmed valve quiesce')
  assert(s:find(':poll_quiesce()',1,true), p..' must wait for current BLOCKED acknowledgements')
end
print('fuel_reprocessor_quiesce_ack_wiring_test.lua: ok')
'''
write('tests/fuel_reprocessor_quiesce_ack_wiring_test.lua',role_test)

# Release v516 + manifest preserving all semantic flags.
release=read('xreactor/release.lua')
for old,new in [('beta-v515','beta-v516'),('manifest-v515','manifest-v516'),('manifest_version = 515','manifest_version = 516')]:
    if release.count(old)!=1: raise SystemExit('release anchor '+old)
    release=release.replace(old,new,1)
write('xreactor/release.lua',release)

manifest=read('xreactor/manifest.lua')
manifest=manifest.replace('-- xreactor/manifest.lua -- manifest-v515','-- xreactor/manifest.lua -- manifest-v516',1)
manifest=manifest.replace('manifest_version = 515','manifest_version = 516',1)
manifest=manifest.replace('manifest_id = "manifest-v515"','manifest_id = "manifest-v516"',1)
for rel in ['nodes/fuel/redstone_router.lua','nodes/fuel/logistics_router.lua','nodes/fuel/main.lua','nodes/reprocessor/main.lua','release.lua']:
    data=(ROOT/'xreactor'/rel).read_bytes(); size=len(data); h=crc(data)
    lines=manifest.splitlines(True); idx=[i for i,l in enumerate(lines) if f'path = "{rel}"' in l]
    if len(idx)!=1: raise SystemExit(f'manifest entry {rel} count {len(idx)}')
    i=idx[0]; line=lines[i]
    line,n1=re.subn(r'size_bytes\s*=\s*\d+',f'size_bytes = {size}',line,count=1)
    line,n2=re.subn(r'hash\s*=\s*"[0-9a-f]+"',f'hash = "{h}"',line,count=1)
    if n1!=1 or n2!=1: raise SystemExit('manifest entry shape '+rel)
    lines[i]=line; manifest=''.join(lines)
write('xreactor/manifest.lua',manifest)
print('phase4 patch applied')
