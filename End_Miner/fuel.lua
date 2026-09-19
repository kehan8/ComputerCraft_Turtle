-- fuel.lua: inventory refuel, plus the two-chest station trip when both
-- tank and inventory are empty. Chest layout: README.md.

return function(state, cfg, logging, movement)
  local pos = state.pos

  local function refuelIfNeeded()
    if turtle.getFuelLevel() == "unlimited" then return true end
    if turtle.getFuelLevel() > cfg.FUEL_THRESHOLD then return true end

    for slot = 1, 16 do
      turtle.select(slot)
      if turtle.getItemCount(slot) > 0 and turtle.refuel(0) then
        turtle.refuel()
        if turtle.getFuelLevel() > cfg.FUEL_THRESHOLD then
          turtle.select(1)
          return true
        end
      end
    end
    turtle.select(1)
    return turtle.getFuelLevel() > 0
  end

  local function inventoryFull()
    for slot = 1, 16 do
      if turtle.getItemCount(slot) == 0 then
        return false
      end
    end
    return true
  end

  -- Drops inventory into the chest in front, keeping up to
  -- FUEL_RESERVE_ITEMS fuel items as reserve. Reports if the chest is full.
  local function dropOffAtStation()
    local reserved = 0
    for slot = 1, 16 do
      turtle.select(slot)
      if turtle.getItemCount(slot) > 0 then
        if reserved < cfg.FUEL_RESERVE_ITEMS and turtle.refuel(0) then
          reserved = reserved + 1
        else
          turtle.drop()
        end
      end
    end
    turtle.select(1)

    if reserved > 0 then
      logging.logEvent(string.format("Kept %d fuel item(s) on board as reserve (not dropped off).", reserved))
    end

    local stillHeld = 0
    for slot = 1, 16 do
      if turtle.getItemCount(slot) > 0 then
        stillHeld = stillHeld + 1
      end
    end
    stillHeld = stillHeld - reserved
    if stillHeld > 0 then
      logging.logEvent(string.format(
        "Drop-off chest could not take everything -- %d inventory slot(s) still full after trying to empty out (the drop-off chest is probably full -- empty it by hand).",
        stillHeld))
    end
  end

  -- Sucks from the chest in front, burning whatever's usable. Stops once
  -- fuel clears the threshold AND FUEL_RESERVE_ITEMS items are aboard.
  -- Returns true if anything got burned.
  local function refuelFromChestInFront()
    local gotAny = false

    for _ = 1, 16 do
      local fuel = turtle.getFuelLevel()
      local haveEnoughFuel = fuel == "unlimited" or fuel > cfg.FUEL_THRESHOLD

      if not haveEnoughFuel then
        for slot = 1, 16 do
          turtle.select(slot)
          if turtle.getItemCount(slot) > 0 and turtle.refuel(0) then
            turtle.refuel()
            gotAny = true
            fuel = turtle.getFuelLevel()
            haveEnoughFuel = fuel == "unlimited" or fuel > cfg.FUEL_THRESHOLD
            if haveEnoughFuel then break end
          end
        end
        turtle.select(1)
      end

      if haveEnoughFuel then
        local fuelItems = 0
        for slot = 1, 16 do
          if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if turtle.refuel(0) then
              fuelItems = fuelItems + 1
            end
          end
        end
        turtle.select(1)
        if fuelItems >= cfg.FUEL_RESERVE_ITEMS then
          break
        end
      end

      if not turtle.suck() then
        break
      end
    end

    -- Safety net for the rare case the loop above hits its bound right
    -- after a suck() that added a new item, before it got a burn attempt.
    for slot = 1, 16 do
      local fuel = turtle.getFuelLevel()
      if fuel ~= "unlimited" and fuel > cfg.FUEL_THRESHOLD then
        break
      end
      turtle.select(slot)
      if turtle.getItemCount(slot) > 0 and turtle.refuel(0) then
        turtle.refuel()
        gotAny = true
      end
    end
    turtle.select(1)

    return gotAny
  end

  -- Walk home, drop off, refuel, then resume where mining paused.
  -- Returns false if the station had nothing, or the walk back missed
  -- the paused spot -- never lets the caller wrongly assume it's fixed.
  local function refuelAtStation()
    state.refuelStation.inProgress = true

    -- Captured before walkHome() changes pos -- also the fuel cost of
    -- the trip back out, since the station is always at (0,0,0).
    local tripDistance = movement.distanceHome()
    local savedX, savedY, savedZ, savedHeading = pos.x, pos.y, pos.z, state.heading

    logging.logEvent(string.format(
      "Fuel low at x=%d y=%d z=%d and nothing usable in inventory -- heading to the refuel station instead of stopping.",
      savedX, savedY, savedZ))

    movement.walkHome()

    -- walkHome() usually lands exactly on (0,0,0) but isn't guaranteed --
    -- check once here so a miss is one clear log line, not confusing errors below.
    if pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0 then
      logging.logEvent(string.format(
        "Could not fully return to the station (stuck at x=%d y=%d z=%d, not 0,0,0) -- treating the station as unreachable this trip.",
        pos.x, pos.y, pos.z))
      state.refuelStation.inProgress = false
      return false
    end

    movement.turnTo(2) -- face the station chests, directly behind the start position

    -- Drop-off is the UPPER chest (y=+1), fuel is the GROUND chest (y=0).
    local grabbedAny = false
    local okUp = movement.up()
    if okUp then
      logging.peekChestInFront("Drop-off chest (upper, before dropping items)")
      dropOffAtStation()
      local okDown = movement.down()
      if okDown then
        logging.peekChestInFront("Fuel chest (ground level, before refueling)")
        grabbedAny = refuelFromChestInFront()
      else
        logging.logEvent(string.format("Could not descend back to the fuel chest at x=%d y=%d z=%d -- leaving turtle here.", pos.x, pos.y, pos.z))
      end
    else
      logging.logEvent("Could not reach the drop-off chest (blocked climbing up) -- treating the station as empty this trip.")
    end

    local fuelNow = turtle.getFuelLevel()
    local enough = grabbedAny and (fuelNow == "unlimited" or fuelNow > tripDistance + 1 + cfg.FUEL_SAFETY_MARGIN)

    if not enough then
      state.refuelStation.exhausted = true
      logging.logEvent(string.format(
        "Refuel station had nothing usable (or not enough for the %d block(s) back out) -- stopping here instead of risking getting stranded.",
        tripDistance))
      state.refuelStation.inProgress = false
      return false
    end

    local backOk = movement.walkBackTo(savedX, savedY, savedZ, savedHeading)
    state.refuelStation.inProgress = false
    state.save() -- checkpoint right after resuming, don't wait for the next column

    -- walkBackTo() can fall short without erroring -- check position too,
    -- not just backOk, before reporting the fuel problem as solved.
    if not backOk or pos.x ~= savedX or pos.y ~= savedY or pos.z ~= savedZ then
      logging.logEvent(string.format(
        "Could not walk back to the exact paused spot after refueling (wanted x=%d y=%d z=%d, at x=%d y=%d z=%d) -- stopping here instead of mining from the wrong column.",
        savedX, savedY, savedZ, pos.x, pos.y, pos.z))
      state.refuelStation.exhausted = true
      return false
    end

    logging.logEvent(string.format("Refueled at the station (fuel now %s) -- resuming at x=%d y=%d z=%d.",
      tostring(turtle.getFuelLevel()), savedX, savedY, savedZ))
    return true
  end

  -- Tries the cheap inventory refuel first, escalates to a station trip
  -- if enabled, not already mid-trip, and not already confirmed empty.
  local function tryRefuelBeforeHalt()
    refuelIfNeeded()
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" or fuel > movement.distanceHome() + 1 + cfg.FUEL_SAFETY_MARGIN then
      return true
    end

    if cfg.AUTO_REFUEL_STATION and not state.refuelStation.inProgress and not state.refuelStation.exhausted then
      return refuelAtStation()
    end

    return false
  end

  -- Hook so movement.lua can try refueling before halting, without
  -- depending on this module directly.
  state.tryRefuelBeforeHalt = tryRefuelBeforeHalt

  return {
    refuelIfNeeded = refuelIfNeeded,
    inventoryFull = inventoryFull,
    tryRefuelBeforeHalt = tryRefuelBeforeHalt,
  }
end
