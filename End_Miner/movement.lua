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
    -- NOTE: homing used to also refuse to dig ANYTHING here (see
    -- state.homingNoDig), on the theory that a home path should already
    -- be open air. In practice the mining pattern only connects columns
    -- at y=0/y=-height, so a mid-depth home walk routinely needs to dig
    -- through ordinary terrain -- exactly like normal mining always has.
    -- The old monolithic end_miner.lua never distinguished homing from
    -- mining here, and blocking it stranded the turtle on the first
    -- un-dug block. Restored to match: SKIP_BLOCKS is still respected,
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

  -- Used only while homing (state.homingNoDig true): plain forward()
  -- (which still digs ordinary terrain via safeClear(), same as normal
  -- mining), never a detour -- a home path needing a detour means `pos`
  -- itself has drifted from reality (no GPS to check against), so stop
  -- and log instead of trying to route around it.
  local function walkStraight(count, axisLabel)
    for _ = 1, count do
      local moved, reason, name = forward()
      if not moved then
        logging.logEvent(string.format("Stuck walking home (%s, at x=%d y=%d z=%d): %s%s",
          axisLabel, pos.x, pos.y, pos.z, tostring(reason), name and (" (" .. name .. ")") or ""))
        return false
      end
    end
    return true
  end

  -- Walks straight back to (0,0,0)/heading 0. Horizontal (x, then z)
  -- first, vertical last -- through the guaranteed-clear column at
  -- x=0,z=0 from the very first row of the run, not a shaft that might
  -- have a naturally-occurring pillar directly overhead partway along.
  local function walkHome()
    state.homingNoDig = true
    local ok = true

    if pos.x > 0 then
      turnTo(2); ok = walkStraight(pos.x, "x")
    elseif pos.x < 0 then
      turnTo(0); ok = walkStraight(-pos.x, "x")
    end

    if ok and pos.z > 0 then
      turnTo(3); ok = walkStraight(pos.z, "z")
    elseif ok and pos.z < 0 then
      turnTo(1); ok = walkStraight(-pos.z, "z")
    end

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
    state.homingNoDig = false
    return ok
  end

  -- Reverse trip: from (0,0,0)/heading 0 back out to a saved position --
  -- used after a station refuel to resume mining where it paused. Same
  -- no-dig/stop-on-obstruction treatment as walkHome().
  local function walkBackTo(targetX, targetY, targetZ, targetHeading)
    state.homingNoDig = true
    local ok = true

    if targetX > pos.x then
      turnTo(0); ok = walkStraight(targetX - pos.x, "x")
    elseif targetX < pos.x then
      turnTo(2); ok = walkStraight(pos.x - targetX, "x")
    end

    if ok and targetZ > pos.z then
      turnTo(1); ok = walkStraight(targetZ - pos.z, "z")
    elseif ok and targetZ < pos.z then
      turnTo(3); ok = walkStraight(pos.z - targetZ, "z")
    end

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
    state.homingNoDig = false
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
