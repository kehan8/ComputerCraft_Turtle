-- movement.lua: safe dig/move primitives, retries always bounded.
-- forward()/down() check fuel and try refueling before halting.

return function(state, cfg, logging)
  local MAX_DIG_ATTEMPTS  = 8 -- give up retrying a block after this many tries
  local MAX_MOVE_ATTEMPTS = 8 -- give up retrying a blocked move after this many tries

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
    if cfg.SKIP_BLOCKS[data.name] then
      return false, "skip", data.name
    end
    -- Same rule for mining or homing: SKIP_BLOCKS routed around, rest dug.

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
      if stillBlock and cfg.SKIP_BLOCKS[stillData.name] then
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
    -- Same soft fuel check as forward()/down() -- up() isn't always
    -- toward home (zigzag ascent), so it needs this check too.
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
    -- Skips the soft fuel check (never the hard fuel==0 one) mid-station-
    -- trip -- otherwise every step re-triggers a nested trip and halts early.
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

  -- Pure check: would one step leave the footprint (bounds =
  -- {minX,maxX,minZ,maxZ}, nil = no limit)? Lets a detour refuse early.
  local function stepWouldLeaveFootprint(bounds)
    if not bounds then return false end
    local d = HEADING_DELTA[state.heading]
    local nx, nz = pos.x + d.x, pos.z + d.z
    return nx < bounds.minX or nx > bounds.maxX or nz < bounds.minZ or nz > bounds.maxZ
  end

  -- Horizontal leg of the home walk. Routes through detour.lua's hook
  -- (unbounded, unlike mining) so obstacles get swung around, not halted
  -- on. Falls back to plain forward() if that hook isn't registered.
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

  -- x then z, re-corrected in rounds (a z-leg detour drifts x with
  -- nothing after to fix it). Cycle check so a corner can't loop forever.
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

  -- Walks back to (0,0,0)/heading 0: horizontal first, then vertical
  -- through the guaranteed-clear x=0,z=0 column.
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

  -- Reverse trip: (0,0,0) back to a saved position, resuming mining
  -- after a station refuel. Same re-corrected walk as walkHorizontal().
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
