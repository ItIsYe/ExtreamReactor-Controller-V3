package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local handle = assert(io.open('xreactor/master/main.lua', 'r'))
local main_src = handle:read('*a')
handle:close()

local stability_ms = tonumber(main_src:match('rt_shutdown_candidate_stability_ms%s*=%s*(%d+)'))
local restart_cooldown_ms = tonumber(main_src:match('shutdown_restart_cooldown_ms%)%s*or%s*(%d+)'))
if stability_ms ~= 1500 then
  error('unexpected rt_shutdown_candidate_stability_ms constant drift: ' .. tostring(stability_ms))
end
if restart_cooldown_ms ~= 15000 then
  error('unexpected shutdown_restart_cooldown_ms constant drift: ' .. tostring(restart_cooldown_ms))
end

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
if wf.stage ~= 'CANCELLED_DEMAND_RECOVERED' then error('cancelled stage must be retained for restart gating') end

if tick(wf, 3050, true) ~= 'cooldown' then error('cancelled workflow must be blocked by restart cooldown') end
if tick(wf, 19000, true) ~= 'stability' then error('after cooldown and long gap, stability gate must re-arm before restart') end
if tick(wf, 20600, true) ~= 'start' then error('candidate restarts only after cooldown + fresh stability') end


if tick(wf, 20601, true) ~= 'running' then error('immediate next tick after restart must not restart again') end
if wf.stage ~= 'RAMPDOWN' then error('workflow stage must stay rampdown after restart') end

wf.requested_at = nil
wf.stage = 'CANCELLED_DEMAND_RECOVERED'
wf.cancelled_at = 30000
if tick(wf, 45000, true) ~= 'stability' then error('cooldown boundary at exactly restart window must still pass through stability first') end
if tick(wf, 46600, true) ~= 'start' then error('restart after boundary still requires fresh stability age') end

-- Flap guard: rapid candidate loss/recovery must not re-enter start without cooldown+stability.
if tick(wf, 47000, false) ~= 'cancelled' then error('second cancellation after restart must transition to CANCELLED_DEMAND_RECOVERED') end
if tick(wf, 47010, true) ~= 'cooldown' then error('immediate re-candidate after second cancel must remain cooldown-gated') end
if tick(wf, 62000, true) ~= 'stability' then error('post-cooldown re-candidate must re-arm stability, not start instantly') end
if tick(wf, 63650, true) ~= 'start' then error('post-cooldown restart must only happen after renewed stability window') end

print('master_rt_shutdown_candidate_stability_semantic_test.lua: ok')
