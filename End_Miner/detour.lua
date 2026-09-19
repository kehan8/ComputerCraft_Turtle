-- detour.lua: routes around a pillar blocking a sideways step, bounded by
-- cfg.DETOUR_MAX_WIDTH on each side -- never loops forever, and undoes
-- its own steps on failure so pos always matches the turtle's real
-- position. Used both while actively mining (bounded to the requested
-- footprint) and by the home walk (movement.lua's walkHome()/
-- walkBackTo(), via the state.detourStepForward hook below -- unbounded,
-- since the way home may need to pass back through ground a mining-time
-- detour left outside the footprint).

return function(state, cfg, logging, movement)
  local pos = state.pos
  local forward = movement.forward
  local turnTo = movement.turnTo
  local stepWouldLeaveFootprint = movement.stepWouldLeaveFootprint

  -- Swings out `sideHeading`, tries to cross back to `originalHeading`.
  -- On failure, undoes exactly the moves it made, in reverse -- each one
  -- guaranteed clear since it was just physically walked. On success, the
  -- turtle is left wherever forward() actually confirmed it could go --
  -- never forced back onto the original (provably blocked) line.
  local function tryDetourSide(sideHeading, originalHeading, bounds)
    turnTo(sideHeading)
    local moveLog = {}
    local success = false
    local fuelHalt = false
    local width = 0

    for _ = 1, cfg.DETOUR_MAX_WIDTH do
      if stepWouldLeaveFootprint(bounds) then
        break -- widening further would leave the requested area
      end
      local ok, reason = forward()
      if reason == "low_fuel" or reason == "no_fuel" then
        fuelHalt = true
        break
      end
      if not ok then
        break -- dead end this way
      end
      table.insert(moveLog, sideHeading)
      width = width + 1

      turnTo(originalHeading)
      if stepWouldLeaveFootprint(bounds) then
        turnTo(sideHeading) -- crossing here would leave the area -- keep widening
      else
        local okF, reasonF = forward()
        if reasonF == "low_fuel" or reasonF == "no_fuel" then
          fuelHalt = true
          break
        end
        if okF then
          table.insert(moveLog, originalHeading)
          success = true
          break
        end
        turnTo(sideHeading) -- still blocked straight ahead -- widen one more
      end
    end

    if success then
      return true, fuelHalt, width
    end

    for i = #moveLog, 1, -1 do
      turnTo((moveLog[i] + 2) % 4)
      local ok = forward()
      if not ok then
        logging.log(string.format("Detour undo stuck at x=%d y=%d z=%d -- leaving turtle here.", pos.x, pos.y, pos.z))
        break
      end
    end
    turnTo(originalHeading)

    return false, fuelHalt
  end

  -- Fast path for a REMEMBERED (side, width): jumps straight to the known
  -- offset instead of probing 1, 2, 3... from scratch. A stale/wrong
  -- memory entry just fails and falls back to tryDetourSide -- never a
  -- correctness risk, at most one wasted probe.
  local function tryDetourExact(sideHeading, originalHeading, width, bounds)
    turnTo(sideHeading)
    local moveLog = {}
    local success = false
    local fuelHalt = false

    for _ = 1, width do
      if stepWouldLeaveFootprint(bounds) then
        break
      end
      local ok, reason = forward()
      if reason == "low_fuel" or reason == "no_fuel" then
        fuelHalt = true
        break
      end
      if not ok then
        break
      end
      table.insert(moveLog, sideHeading)
    end

    if not fuelHalt and #moveLog == width then
      turnTo(originalHeading)
      if not stepWouldLeaveFootprint(bounds) then
        local okF, reasonF = forward()
        if reasonF == "low_fuel" or reasonF == "no_fuel" then
          fuelHalt = true
        elseif okF then
          table.insert(moveLog, originalHeading)
          success = true
        end
      end
    end

    if success then
      return true, fuelHalt
    end

    for i = #moveLog, 1, -1 do
      turnTo((moveLog[i] + 2) % 4)
      local ok = forward()
      if not ok then
        logging.log(string.format("Detour undo stuck at x=%d y=%d z=%d -- leaving turtle here.", pos.x, pos.y, pos.z))
        break
      end
    end
    turnTo(originalHeading)

    return false, fuelHalt
  end

  -- Keyed by x,y only (not z): the same obstacle's cross-section
  -- reappears across every row, since z is what changes row to row.
  local function detourKey(x, y)
    return x .. ":" .. y
  end

  -- Tries the remembered side/width first (if any and enabled), then
  -- falls back to a full right-then-left expanding search.
  local function detourAround(originalHeading, bounds)
    if not cfg.DETOUR_ENABLED then return false end

    local blockedX, blockedY, blockedZ = pos.x, pos.y, pos.z
    local rightHeading = (originalHeading + 1) % 4
    local leftHeading  = (originalHeading - 1) % 4
    local key = detourKey(blockedX, blockedY)
    local remembered = cfg.DETOUR_USE_MEMORY and state.detourMemory[key] or nil

    if remembered then
      local rememberedHeading = (remembered.side == "left") and leftHeading or rightHeading
      local ok, fuelHalt = tryDetourExact(rememberedHeading, originalHeading, remembered.width, bounds)
      if ok then
        logging.log(string.format("Detour: routed around obstacle at x=%d y=%d z=%d row=%d col=%d via %s (known).",
          blockedX, blockedY, blockedZ, state.currentRow, state.currentCol, remembered.side))
        logging.recordDetour(blockedX, blockedY, blockedZ, "via " .. remembered.side .. " (known)", remembered.width)
        return true
      end
      if fuelHalt or state.fatalFuel then
        return false
      end
      -- Remembered path no longer works -- fall through to a full search.
    end

    local ok, fuelHalt, width = tryDetourSide(rightHeading, originalHeading, bounds)
    if ok then
      state.detourMemory[key] = { side = "right", width = width }
      logging.log(string.format("Detour: routed around obstacle at x=%d y=%d z=%d row=%d col=%d via right.",
        blockedX, blockedY, blockedZ, state.currentRow, state.currentCol))
      logging.recordDetour(blockedX, blockedY, blockedZ, "via right", width)
      return true
    end
    if fuelHalt or state.fatalFuel then
      return false
    end

    ok, fuelHalt, width = tryDetourSide(leftHeading, originalHeading, bounds)
    if ok then
      state.detourMemory[key] = { side = "left", width = width }
      logging.log(string.format("Detour: routed around obstacle at x=%d y=%d z=%d row=%d col=%d via left.",
        blockedX, blockedY, blockedZ, state.currentRow, state.currentCol))
      logging.recordDetour(blockedX, blockedY, blockedZ, "via left", width)
      return true
    end

    logging.log(string.format(
      "Detour failed at x=%d y=%d z=%d row=%d col=%d -- obstacle wider than %d block(s) (or fuel). Giving up on this step.",
      blockedX, blockedY, blockedZ, state.currentRow, state.currentCol, cfg.DETOUR_MAX_WIDTH))
    logging.recordDetour(blockedX, blockedY, blockedZ, "FAILED (gave up)", 0)
    return false
  end

  -- Drop-in replacement for forward() at every sideways step while
  -- mining, AND for the horizontal legs of the home walk (movement.lua
  -- calls this via state.detourStepForward, unbounded): tries a detour on
  -- a real obstacle ("skip"/"stuck") before reporting failure. Fuel
  -- reasons pass straight through untouched. Re-checks fatalFuel after a
  -- failed detour so the caller reports the real halt reason instead of a
  -- stale pre-detour one, in case fuel went fatal mid-detour.
  local function stepForward(bounds)
    local originalHeading = state.heading
    local moved, reason, name = forward()
    if moved then return true end
    if reason == "low_fuel" or reason == "no_fuel" then
      return false, reason, name
    end
    if detourAround(originalHeading, bounds) then
      return true
    end
    if state.fatalFuel then
      return false, state.haltReason or "low_fuel", name
    end
    return false, reason, name
  end

  -- Registers the hook movement.lua's walkHome()/walkBackTo() call
  -- through, so the home walk can detour around a real obstacle exactly
  -- like every other sideways step during mining, without movement.lua
  -- depending on this module directly (this module already depends on
  -- movement.lua, so the reverse import would be circular).
  state.detourStepForward = stepForward

  return {
    detourAround = detourAround,
    stepForward = stepForward,
  }
end
