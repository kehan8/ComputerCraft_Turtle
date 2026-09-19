-- fuel.lua: inventory refuel, and the two-chest refuel station trip used
-- when both the tank and inventory are empty. See README.md "Fuel & the
-- refuel station" for the physical chest layout this depends on.

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

  -- Drops inventory into the chest in front (the station's drop-off
  -- chest), keeping up to cfg.FUEL_RESERVE_ITEMS fuel items aboard as
  -- reserve so refuelIfNeeded() can burn one mid-field later. Reports if
  -- the chest couldn't take everything -- turtle.drop() fails silently
  -- (no error) when the target chest is full.
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

  -- Sucks items from the chest in front (the station's fuel chest) and
  -- burns whatever's usable. Burns first on every iteration -- so fuel
  -- gets a real chance to rise before the reserve-count check reads it --
  -- then stops sucking once fuel clears the threshold AND at least
  -- FUEL_RESERVE_ITEMS usable items are aboard. Bounded to 16 iterations.
  -- Returns true if at least one item was turned into fuel.
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

  -- Walk home, climb up to drop off inventory, climb down to refuel, and
  -- (if that left enough fuel for the trip back out) resume mining
  -- exactly where it paused. Returns false if the station had nothing
  -- usable -- the turtle is left AT HOME rather than stranded in the field.
  local function refuelAtStation()
    state.refuelStation.inProgress = true

    -- Captured BEFORE walkHome() changes pos -- also exactly the fuel
    -- cost of the walk back out afterward, since the station sits at the
    -- same (0,0,0) walkHome() always targets.
    local tripDistance = movement.distanceHome()
    local savedX, savedY, savedZ, savedHeading = pos.x, pos.y, pos.z, state.heading

    logging.logEvent(string.format(
      "Fuel low at x=%d y=%d z=%d and nothing usable in inventory -- heading to the refuel station instead of stopping.",
      savedX, savedY, savedZ))

    movement.walkHome()

    -- walkHome() usually lands exactly on (0,0,0), but not guaranteed
    -- (e.g. the very first column got cut short by a fuel halt). Every
    -- chest interaction below hard-assumes (0,0,0) -- check once, here,
    -- so a wrong assumption becomes one clear log line instead of
    -- confusing "no peripheral access" symptoms further down.
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
    if backOk then
      logging.logEvent(string.format("Refueled at the station (fuel now %s) -- resuming at x=%d y=%d z=%d.",
        tostring(turtle.getFuelLevel()), savedX, savedY, savedZ))
    else
      logging.logEvent(string.format(
        "Refueled at the station, but got stuck heading back out (now at x=%d y=%d z=%d, wanted x=%d y=%d z=%d) -- mining resumes from here instead.",
        pos.x, pos.y, pos.z, savedX, savedY, savedZ))
    end
    return true
  end

  -- Tries the cheap inventory refuel first, then escalates to a full
  -- station trip if that's not enough -- only if the station is enabled,
  -- not already mid-trip, and hasn't already been confirmed empty.
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

  -- Registers the hook movement.lua's forward()/down() call through, so
  -- a low-fuel move can try refueling before halting without movement.lua
  -- depending on this module directly.
  state.tryRefuelBeforeHalt = tryRefuelBeforeHalt

  return {
    refuelIfNeeded = refuelIfNeeded,
    inventoryFull = inventoryFull,
    tryRefuelBeforeHalt = tryRefuelBeforeHalt,
  }
end
