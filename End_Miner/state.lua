-- state.lua: shared mutable run state (pos/heading are a dead-reckoning
-- counter, no GPS). Passed by reference into every module.

local STATE_FILE = "end_miner_state.txt"

local state = {
  STATE_FILE = STATE_FILE,

  -- Position/heading relative to start. heading: 0=start dir, 1=right,
  -- 2=back, 3=left.
  pos = { x = 0, y = 0, z = 0 },
  heading = 0,

  fatalFuel = false, -- true once mining halts for fuel; every loop stops
  haltReason = nil,  -- "low_fuel" (preemptive) or "no_fuel" (hard 0)

  -- Set by fuel.lua. movement.lua calls through this hook to try
  -- refueling before halting, without depending on fuel.lua directly.
  tryRefuelBeforeHalt = nil,

  -- Set by detour.lua. The home walk calls through this hook to detour
  -- around obstacles, avoiding a circular movement.lua<->detour.lua import.
  detourStepForward = nil,

  -- Current row/column, diagnostics only (pos.x/y/z is the real source
  -- of truth). -1/-1 = not mining right now.
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

-- Persists pos/heading so startup.lua can walk home after a reboot.
-- Called at checkpoints, not every move. Write failure never interrupts a run.
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
