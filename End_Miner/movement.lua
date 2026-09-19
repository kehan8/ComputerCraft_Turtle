-- movement.lua: safe dig/move primitives. Every retry is bounded --
-- never an infinite loop. forward()/down() also check fuel before moving
-- and try to refuel (via state.tryRefuelBeforeHalt, wired up by fuel.lua)
-- before halting the run.

return function(state, cfg, logging)
  local MAX_DIG_ATTEMPTS  = 8 -- give up retrying a block after this many tries
  local MAX_MOVE_ATTEMPTS = 8 -- give up retrying a blocked move after this many tries

  -- Never mined -- checked via inspect() before dig().
  local SKIP_BLOCKS = {
    ["minecraft:obsidian"]         = true,
    ["minecraft:crying_obsidian"]  = true,
    ["minecraft:bedrock"]          = true,
    ["minecraft:end_portal_frame"] = true,
    ["minecraft:end_gateway"]      = true,
    ["minecraft:end_portal"]       = true,
    ["minecraft:dragon_egg"]       = true,
  }

  local HEADING_DELTA = {
    [0] = { x = 1,  z = 0  },
    [1] = { x = 0,  z = 1  },
    [2] = { x = -1, z = 0  },
    [3] = { x = 0,  z = -1 },
  }

  local pos = state.pos

  -- Steps needed to walk straight back to (0,0,0).
  local function distanceHome()
    return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z)
  end

  -- Returns true (clear), or false + "skip"/"blocked"/"stuck" + block name.
  local function safeClear(inspectFn, digFn, detectFn)
    local isBlock, data = inspectFn()
    if not isBlock then
      return true
    end
    if SKIP_BLOCKS[data.name] then
      return false, "skip", data.name
    end
    -- No homing/mining distinction here on purpose. The mining pattern
    -- only connects columns at y=0/y=-height, so a mid-depth home walk
    -- routinely needs to dig through ordinary terrain -- exactly like
    -- normal mining always has. The old monolithic end_miner.lua never
    -- distinguished homing from mining here either: SKIP_BLOCKS is
    -- respected (returned as "skip" for the caller to detour around),
    -- everything else gets dug through same as always.

    local attempts = 0
    while detectFn() and attempts < MAX_DIG_ATTEMPTS do
      digFn()
      attempts = attempts + 1
      if detectFn() then
        os.sleep(0.3) -- let falling sand/gravel settle
      end
    end

    if detectFn() then
      -- gravel/sand may reveal a skip-block underneath -- recheck
      local stillBlock, stillData = inspectFn()
      if stillBlock and SKIP_BLOCKS[stillData.name] then
        return false, "skip", stillData.name
      end
      return false, "stuck", (stillData and stillData.name) or "unknown"
    end

    return true
  end

  -- Retries a move; only attacks if ATTACK_MOBS is on. Checks fuel first
  -- -- no point retrying 8x if the tank is just empty.
  local function tryMove(moveFn, attackFn)
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and fuel <= 0 then
      return false, "no_fuel"
    end

    local attempts = 0
    local moved = moveFn()
    while not moved and attempts < MAX_MOVE_ATTEMPTS do
      if attackFn and cfg.ATTACK_MOBS then attackFn() end
      os.sleep(0.3)
      moved = moveFn()
      attempts = attempts + 1
    end
    if not moved then
      return false, "stuck"
    end
    return true
  end

  -- Last-resort net: fuel actually hit 0 and a move failed because of it.
  local function haltOnNoFuel()
    if not state.fatalFuel then
      state.fatalFuel = true
      state.haltReason = "no_fuel"
      logging.logEvent("FATAL: Out of fuel, cannot move. Needs manual refuel.")
    end
  end

  -- Normal path: fuel is getting low, stop mining and head home while
  -- there's still enough left to make the trip.
  local function haltOnLowFuel()
    if not state.fatalFuel then
      state.fatalFuel = true
      state.haltReason = "low_fuel"
      logging.logEvent("Fuel low -- heading home now instead of risking it.")
    end
  end

  local function forward()
    if not state.fatalFuel and not state.refuelStation.inProgress then
      local fuel = turtle.getFuelLevel()
      if fuel ~= "unlimited" and fuel <= distanceHome() + 1 + cfg.FUEL_SAFETY_MARGIN then
        if not (state.tryRefuelBeforeHalt and state.tryRefuelBeforeHalt()) then
          haltOnLowFuel()
          return false, "low_fuel"
        end
      end
    end
    local ok, reason, name = safeClear(turtle.inspect, turtle.dig, turtle.detect)
    if not ok then
      if reason == "skip" then
        local d = HEADING_DELTA[state.heading]
        logging.recordSkip(pos.x + d.x, pos.y, pos.z + d.z, name)
      end
      return false, reason, name
    end
    local moved, moveReason = tryMove(turtle.forward, turtle.attack)
    if not moved then
      if moveReason == "no_fuel" then haltOnNoFuel() end
      return false, moveReason, "path blocked after clearing"
    end
    local d = HEADING_DELTA[state.heading]
    pos.x = pos.x + d.x
    pos.z = pos.z + d.z
    return true
  end

  local function up()
    -- Same soft low-fuel check as forward()/down() -- mineColumn() also
    -- uses up() to dig the ascending half of a zigzag column, so this is
    -- NOT always a move toward home; skipping the check let fuel run to
    -- literal 0 on every other column instead of heading home early.
    if not state.fatalFuel and not state.refuelStation.inProgress then
      local fuel = turtle.getFuelLevel()
      if fuel ~= "unlimited" and fuel <= distanceHome() + 1 + cfg.FUEL_SAFETY_MARGIN then
        if not (state.tryRefuelBeforeHalt and state.tryRefuelBeforeHalt()) then
          haltOnLowFuel()
          return false, "low_fuel"
        end
      end
    end
    local ok, reason, name = safeClear(turtle.inspectUp, turtle.digUp, turtle.detectUp)
    if not ok then
      if reason == "skip" then logging.recordSkip(pos.x, pos.y + 1, pos.z, name) end
      return false, reason, name
    end
    local moved, moveReason = tryMove(turtle.up, turtle.attackUp)
    if not moved then
      if moveReason == "no_fuel" then haltOnNoFuel() end
      return false, moveReason, "path blocked after clearing"
    end
    pos.y = pos.y + 1
    return true
  end

  local function down()
    -- Skips the soft fuel-threshold check (but never the hard fuel==0
    -- check in tryMove()) while a station trip is already in progress --
    -- otherwise every step of that trip re-sees low fuel, tries to start
    -- a second nested trip, gets correctly refused, and halts the run one
    -- block from the fuel chest that would have fixed everything.
    if not state.fatalFuel and not state.refuelStation.inProgress then
      local fuel = turtle.getFuelLevel()
      if fuel ~= "unlimited" and fuel <= distanceHome() + 1 + cfg.FUEL_SAFETY_MARGIN then
        if not (state.tryRefuelBeforeHalt and state.tryRefuelBeforeHalt()) then
          haltOnLowFuel()
          return false, "low_fuel"
        end
      end
    end
    local ok, reason, name = safeClear(turtle.inspectDown, turtle.digDown, turtle.detectDown)
    if not ok then
      if reason == "skip" then logging.recordSkip(pos.x, pos.y - 1, pos.z, name) end
      return false, reason, name
    end
    local moved, moveReason = tryMove(turtle.down, turtle.attackDown)
    if not moved then
      if moveReason == "no_fuel" then haltOnNoFuel() end
      return false, moveReason, "path blocked after clearing"
    end
    pos.y = pos.y - 1
    return true
  end

  local function turnLeft()
    turtle.turnLeft()
    state.heading = (state.heading - 1) % 4
  end

  local function turnRight()
    turtle.turnRight()
    state.heading = (state.heading + 1) % 4
  end

  -- Max 2 turns, never loops forever.
  local function turnTo(target)
    while state.heading ~= target do
      turnRight()
    end
  end

  -- Pure check, no movement: would one step in the CURRENT heading leave
  -- the requested footprint? `bounds` is { minX, maxX, minZ, maxZ } or
  -- nil (no limit, used by the home walk). Lets a detour refuse a step
  -- before taking it instead of undoing it afterward.
  local function stepWouldLeaveFootprint(bounds)
    if not bounds then return false end
    local d = HEADING_DELTA[state.heading]
    local nx, nz = pos.x + d.x, pos.z + d.z
    return nx < bounds.minX or nx > bounds.maxX or nz < bounds.minZ or nz > bounds.maxZ
  end

  -- Used for the horizontal legs of the home walk. Routes through
  -- state.detourStepForward (== detour.lua's stepForward, wired up once
  -- detour.lua is constructed -- same hook pattern as
  -- state.tryRefuelBeforeHalt above) so a real obstacle (SKIP_BLOCKS or
  -- "stuck") blocking the straight-line path home gets swung around
  -- exactly like any other sideways step during mining, instead of just
  -- halting on the first one. No bounds passed (unbounded detour) -- the
  -- home walk must stay free to pass back through a position a
  -- mining-time detour deliberately left outside the requested footprint
  -- earlier in the run. Falls back to plain forward() only if detour.lua
  -- hasn't registered the hook yet (shouldn't happen in normal startup
  -- order, but keeps this safe rather than erroring).
  local function walkStraight(count, axisLabel)
    local step = state.detourStepForward or forward
    for _ = 1, count do
      local moved, reason, name = step()
      if not moved then
        logging.logEvent(string.format("Stuck walking home (%s, at x=%d y=%d z=%d): %s%s",
          axisLabel, pos.x, pos.y, pos.z, tostring(reason), name and (" (" .. name .. ")") or ""))
        return false
      end
    end
    return true
  end

  -- Horizontal (x, then z) leg of a home/resume walk, re-corrected in
  -- rounds. A detour taken on the X leg only ever side-steps along Z, and
  -- the Z leg that follows recomputes its step count from wherever Z
  -- actually ended up -- so that drift self-corrects for free. But a
  -- detour taken on the Z leg side-steps along X (detour.lua's
  -- tryDetourSide deliberately never undoes that side-step -- the turtle
  -- is left wherever forward() actually confirmed it could go), and
  -- nothing came after the Z leg to notice or fix it. A single X-then-Z
  -- pass can therefore land off-target by exactly the width of whatever
  -- got detoured on the Z leg. Loop X->Z->X... like mineArea's
  -- correctPosition() does for mining columns, with the same
  -- seen-position cycle check, so a pillar corner can't loop forever.
  local MAX_HOME_CORRECTION_ROUNDS = 6

  local function walkHorizontal(targetX, targetZ, label)
    local seen = { [pos.x .. ":" .. pos.z] = true }

    for _ = 1, MAX_HOME_CORRECTION_ROUNDS do
      if pos.x == targetX and pos.z == targetZ then return true end

      local ok = true
      if pos.x > targetX then
        turnTo(2); ok = walkStraight(pos.x - targetX, label .. " x")
      elseif pos.x < targetX then
        turnTo(0); ok = walkStraight(targetX - pos.x, label .. " x")
      end
      if not ok then return false end
      if pos.x == targetX and pos.z == targetZ then return true end

      if pos.z > targetZ then
        turnTo(3); ok = walkStraight(pos.z - targetZ, label .. " z")
      elseif pos.z < targetZ then
        turnTo(1); ok = walkStraight(targetZ - pos.z, label .. " z")
      end
      if not ok then return false end
      if pos.x == targetX and pos.z == targetZ then return true end

      local key = pos.x .. ":" .. pos.z
      if seen[key] then
        logging.logEvent(string.format(
          "Home walk (%s) is oscillating near an obstacle corner (back at x=%d z=%d, wanted x=%d z=%d) -- stopping horizontal correction here.",
          label, pos.x, pos.z, targetX, targetZ))
        return false
      end
      seen[key] = true
    end

    logging.logEvent(string.format(
      "Could not fully correct home walk (%s) after %d round(s) (at x=%d z=%d, wanted x=%d z=%d).",
      label, MAX_HOME_CORRECTION_ROUNDS, pos.x, pos.z, targetX, targetZ))
    return false
  end

  -- Walks straight back to (0,0,0)/heading 0. Horizontal first (see
  -- walkHorizontal() above for why that's a re-corrected loop, not a
  -- single X-then-Z pass), vertical last -- through the guaranteed-clear
  -- column at x=0,z=0 from the very first row of the run, not a shaft that
  -- might have a naturally-occurring pillar directly overhead partway
  -- along.
  local function walkHome()
    local ok = walkHorizontal(0, 0, "home")

    if ok then
      while pos.y < 0 do
        local moved, reason = up()
        if not moved then
          logging.logEvent(string.format("Cannot climb back to surface (y=%d): %s", pos.y, tostring(reason)))
          ok = false
          break
        end
      end
    end
    if ok then
      while pos.y > 0 do
        local moved, reason = down()
        if not moved then
          logging.logEvent(string.format("Cannot descend back to surface (y=%d): %s", pos.y, tostring(reason)))
          ok = false
          break
        end
      end
    end

    turnTo(0)
    return ok
  end

  -- Reverse trip: from (0,0,0)/heading 0 back out to a saved position --
  -- used after a station refuel to resume mining where it paused. Same
  -- re-corrected horizontal walk as walkHome() (see walkHorizontal()
  -- above) -- this is exactly the leg where the drift bug showed up in
  -- practice: refuelAtStation() checks the landing spot is exact before
  -- trusting the resume, so an uncorrected detour drift here silently
  -- aborted the whole run instead of just missing a checkpoint.
  local function walkBackTo(targetX, targetY, targetZ, targetHeading)
    local ok = walkHorizontal(targetX, targetZ, "resume")

    if ok then
      while pos.y > targetY do
        local moved, reason = down()
        if not moved then
          logging.logEvent(string.format("Could not descend back to y=%d after refueling (stuck at y=%d): %s", targetY, pos.y, tostring(reason)))
          ok = false
          break
        end
      end
    end
    if ok then
      while pos.y < targetY do
        local moved, reason = up()
        if not moved then
          logging.logEvent(string.format("Could not climb back to y=%d after refueling (stuck at y=%d): %s", targetY, pos.y, tostring(reason)))
          ok = false
          break
        end
      end
    end

    turnTo(targetHeading)
    return ok
  end

  return {
    distanceHome = distanceHome,
    haltOnNoFuel = haltOnNoFuel,
    haltOnLowFuel = haltOnLowFuel,
    forward = forward,
    up = up,
    down = down,
    turnLeft = turnLeft,
    turnRight = turnRight,
    turnTo = turnTo,
    stepWouldLeaveFootprint = stepWouldLeaveFootprint,
    walkHome = walkHome,
    walkBackTo = walkBackTo,
  }
end
