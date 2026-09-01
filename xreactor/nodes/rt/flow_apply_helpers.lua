local M = {}

-- reuse_flow: caller already has a flow reading from this exact tick with
-- no write/actuation in between (nothing physically could have changed) --
-- reuse it instead of a guaranteed-identical fresh read, and skip the
-- retry loop too (a reread would return the same value). Any tick with an
-- actual write or brake actuation still gets the full fresh readback.
function M.capture_turbine_flow_readback(turbine, caps, ctrl, requested_flow, rail_cfg, read_turbine_flow, clamp_turbine_flow, reuse_flow)
  local flow_tolerance = rail_cfg.confirm_tolerance or 1
  local observed_flow
  if reuse_flow ~= nil then
    observed_flow = reuse_flow
  else
    observed_flow = read_turbine_flow(turbine, caps)
    local fast_rereads = math.max(0, rail_cfg.readback_fast_rereads or 2)
    local attempt = 0
    while type(observed_flow) == "number"
        and math.abs(requested_flow - observed_flow) > flow_tolerance
        and attempt < fast_rereads do
      local retry_flow = read_turbine_flow(turbine, caps)
      if type(retry_flow) == "number" then
        observed_flow = retry_flow
      end
      attempt = attempt + 1
    end
  end
  if type(observed_flow) == "number" then
    ctrl.confirmed_flow = clamp_turbine_flow(observed_flow)
    if not ctrl.startup_synced then
      ctrl.startup_synced = true
    end
  end
  return flow_tolerance
end

function M.update_turbine_flow_tracking(ctrl, requested_flow, confirmed_flow, flow_tolerance, rail_cfg, now_ts, decision, write_state, turbine_regulator)
  local previous_requested = ctrl.pending_expected_flow
  if type(previous_requested) ~= "number" then
    previous_requested = ctrl.last_requested_flow
  end
  local write_accepted = write_state == "WRITE_ACCEPTED"
  local new_write = write_accepted and previous_requested ~= requested_flow
  if new_write then
    -- Neuer Zielwert: Tracking reset, pending_settled gegen neuen Zielwert prüfen
    ctrl.pending_flow_since   = now_ts
    ctrl.pending_expected_flow = requested_flow
    ctrl.pending_retries      = 0
    ctrl.pending_retry_stage  = 0
  end
  -- pending_settled nach möglichem Reset berechnen
  local pending_settled = turbine_regulator.flows_match(ctrl.pending_expected_flow, confirmed_flow, flow_tolerance)
  if pending_settled and not new_write then
    -- Zielwert bestätigt: Tracking bereinigen
    ctrl.pending_retries      = 0
    ctrl.pending_retry_stage  = 0
    ctrl.pending_flow_since   = 0
    ctrl.pending_expected_flow = requested_flow
  elseif not pending_settled and not new_write then
    -- Noch ausstehend: Timeout-Stages hochzählen
    local settle_timeout_s = tonumber(rail_cfg and rail_cfg.settle_timeout_s) or 0
    local pending_since    = tonumber(ctrl.pending_flow_since) or now_ts
    local pending_age      = math.max(0, now_ts - pending_since)
    if settle_timeout_s > 0 then
      local retry_stage = math.floor(pending_age / settle_timeout_s)
      ctrl.pending_retry_stage = retry_stage
      ctrl.pending_retries     = retry_stage
    elseif write_accepted then
      ctrl.pending_retries     = (ctrl.pending_retries or 0) + 1
      ctrl.pending_retry_stage = ctrl.pending_retries
    end
  end

  local effective_min_samples = rail_cfg.effective_min_samples or 3
  turbine_regulator.update_effective_min(
    ctrl,
    requested_flow,
    confirmed_flow,
    effective_min_samples
  )
  if decision and decision.overspeed_brake and requested_flow == 0 and type(confirmed_flow) == "number" and confirmed_flow > flow_tolerance then
    ctrl.overspeed_floor_hits = (ctrl.overspeed_floor_hits or 0) + 1
  else
    ctrl.overspeed_floor_hits = 0
  end
  local readback_state, readback_detail = turbine_regulator.classify_confirmation({
    requested_flow = requested_flow,
    confirmed_flow = confirmed_flow,
    pending_expected_flow = ctrl.pending_expected_flow,
    tolerance = flow_tolerance,
    pending_retries = ctrl.pending_retries,
    readback_retry_cap = rail_cfg.readback_retry_cap or 0,
    settle_timeout_s = rail_cfg.settle_timeout_s or 0,
    pending_since = ctrl.pending_flow_since,
    now_ts = now_ts,
    floor_hint = (ctrl.overspeed_floor_hits or 0) >= effective_min_samples,
    write_state = write_state
  })
  return pending_settled, readback_state, readback_detail
end

return M
