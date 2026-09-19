-- state.lua: shared mutable run state, no GPS -- pos/heading are a pure
-- counter, not ground truth. Loaded once by end_miner.lua and passed by
-- reference into every other module, so a change made in one file (e.g.
-- pos during a move) is visible everywhere else immediately.

local STATE_FILE = "end_miner_state.txt"

local state = {
  STATE_FILE = STATE_FILE,

  -- Position/heading relative to start. heading: 0=start dir, 1=right,
  -- 2=back, 3=left.
  pos = { x = 0, y = 0, z = 0 },
  heading = 0,

  fatalFuel = false, -- true once mining halts for fuel; every loop stops
  haltReason = nil,  -- "low_fuel" (preemptive) or "no_fuel" (hard 0)

  -- Set by fuel.lua once constructed. movement.lua calls through this
  -- hook so a low-fuel forward()/down() can try refueling before halting,
  -- without movement.lua depending on fuel.lua directly.
  tryRefuelBeforeHalt = nil,

  -- Set by detour.lua once constructed. movement.lua's home walk
  -- (walkHome()/walkBackTo()) calls through this hook so a real obstacle
  -- (SKIP_BLOCKS or stuck) blocking the straight-line path can be routed
  -- around exactly like any other sideways step during mining, without
  -- movement.lua depending on detour.lua directly (detour.lua already
  -- depends on movement.lua, so the reverse import would be circular).
  detourStepForward = nil,

  -- Current row/column, diagnostics only -- pos.x/y/z stay the only
  -- source of truth for movement/fuel decisions. -1/-1 = not mining right
  -- now (e.g. during the walk home).
  currentRow = -1,
  currentCol = -1,

  -- Collected for the end-of-run summary (see logging.lua).
  skipped = {},
  detours = {},
  runLog = {},

  -- Per-(x,y) memory of which side/width a detour needed last time.
  detourMemory = {},

  -- Re-entrancy/exhaustion guard for the refuel station trip (fuel.lua).
  refuelStation = { inProgress = false, exhausted = false },
}

-- Persists pos/heading so startup.lua can walk the turtle home after a
-- reboot. Called at safe checkpoints, not every move. Write failure is
-- silently ignored -- this is a convenience feature, never allowed to
-- interrupt a run.
function state.save()
  local f = fs.open(STATE_FILE, "w")
  if not f then return end
  f.write(textutils.serialize({ x = state.pos.x, y = state.pos.y, z = state.pos.z, heading = state.heading }))
  f.close()
end

-- Reads STATE_FILE if present and well-formed; nil otherwise (missing,
-- unreadable, or corrupt are treated the same -- "nothing to trust").
function state.readSaved()
  local f = fs.open(STATE_FILE, "r")
  if not f then return nil end
  local raw = f.readAll()
  f.close()
  local ok, saved = pcall(textutils.unserialize, raw)
  if not ok or type(saved) ~= "table" or not saved.x or not saved.y or not saved.z or not saved.heading then
    return nil
  end
  return saved
end

return state
