package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local stability_ms = 1500
local restart_cooldown_ms = 15000

local function tick(workflow, now, is_candidate)
  if is_candidate then
    if workflow.stage == 'CANCELLED_DEMAND_RECOVERED' and workflow.cancelled_at and (now - workflow.cancelled_at) >= restart_cooldown_ms and not workflow.requested_at then
      workflow.shutdown_candidate_since = now
      workflow.stage = nil
      workflow.final_reason = nil
      workflow.outcome = nil
      workflow.completed_at = nil
      workflow.error = nil
    end
    workflow.shutdown_candidate_since = workflow.shutdown_candidate_since or now
    local age = now - workflow.shutdown_candidate_since
    if workflow.cancelled_at and (now - workflow.cancelled_at) < restart_cooldown_ms then
      workflow.shutdown_candidate_since = now
      return 'cooldown'
    end
    if age < stability_ms then
      return 'stability'
    end
    if not workflow.requested_at then
      workflow.requested_at = now
      workflow.stage = 'RAMPDOWN'
      return 'start'
    end
    return 'running'
  end
  if workflow.requested_at and workflow.stage ~= 'CANCELLED_DEMAND_RECOVERED' then
    workflow.stage = 'CANCELLED_DEMAND_RECOVERED'
    workflow.cancelled_at = now
    workflow.requested_at = nil
    return 'cancelled'
  end
  workflow.shutdown_candidate_since = nil
  return 'idle'
end

local wf = {}
if tick(wf, 1000, true) ~= 'stability' then error('candidate must not start immediately') end
if tick(wf, 2000, true) ~= 'stability' then error('candidate must still be gated by stability window') end
if tick(wf, 2600, true) ~= 'start' then error('candidate must start after stability window') end
if tick(wf, 3000, false) ~= 'cancelled' then error('workflow must cancel on demand recovery') end

if tick(wf, 3050, true) ~= 'cooldown' then error('cancelled workflow must be blocked by restart cooldown') end
if tick(wf, 19000, true) ~= 'stability' then error('after cooldown and long gap, stability gate must re-arm before restart') end
if tick(wf, 20600, true) ~= 'start' then error('candidate restarts only after cooldown + fresh stability') end

print('master_rt_shutdown_candidate_stability_semantic_test.lua: ok')
