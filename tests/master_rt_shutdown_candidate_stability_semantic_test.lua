package.path = table.concat({ './xreactor/?.lua', './xreactor/?/init.lua', package.path }, ';')

local coalescer = require('master.rt_sync_coalescer')

local stability_ms = coalescer.DEFAULT_SHUTDOWN_CANDIDATE_STABILITY_MS
local restart_cooldown_ms = coalescer.DEFAULT_SHUTDOWN_RESTART_COOLDOWN_MS

local function tick(workflow, now, is_candidate)
  local step = coalescer.advance_shutdown_candidate({
    workflow = workflow,
    now = now,
    is_candidate = is_candidate,
    restart_cooldown_ms = restart_cooldown_ms,
    stability_ms = stability_ms
  })
  if step.action == 'start_requested' then
    workflow.requested_at = now
    workflow.stage = 'RAMPDOWN'
    return 'start'
  elseif step.action == 'debounce_stability' then
    return 'stability'
  elseif step.action == 'debounce_cooldown' then
    return 'cooldown'
  elseif step.action == 'cancelled' then
    return 'cancelled'
  elseif step.action == 'candidate_active' then
    return 'running'
  end
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

if tick(wf, 47000, false) ~= 'cancelled' then error('second cancellation after restart must transition to CANCELLED_DEMAND_RECOVERED') end
if tick(wf, 47010, true) ~= 'cooldown' then error('immediate re-candidate after second cancel must remain cooldown-gated') end
if tick(wf, 62000, true) ~= 'stability' then error('post-cooldown re-candidate must re-arm stability, not start instantly') end
if tick(wf, 63650, true) ~= 'start' then error('post-cooldown restart must only happen after renewed stability window') end

print('master_rt_shutdown_candidate_stability_semantic_test.lua: ok')
