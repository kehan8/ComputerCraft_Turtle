-- End Area Miner (CC:Tweaked)
-- Mines width x height x depth in the End, zigzag column by column.
-- Skips SKIP_BLOCKS, detours around other obstacles, returns home after.
--
-- USAGE: end_miner <width> <height> <depth>
-- Settings: config.lua. Full history: PROGRESS.md.

local configOk, rawConfig = pcall(dofile, "config.lua")
if not configOk or type(rawConfig) ~= "table" then
  rawConfig = {}
end

-- Emergency fallback if config.lua fails to load. Add new blocks in
-- config.lua, not here.
local DEFAULT_SKIP_BLOCKS = {
  ["minecraft:obsidian"]         = true,
  ["minecraft:crying_obsidian"]  = true,
  ["minecraft:bedrock"]          = true,
  ["minecraft:end_portal_frame"] = true,
  ["minecraft:end_gateway"]      = true,
  ["minecraft:end_portal"]       = true,
  ["minecraft:dragon_egg"]       = true,
}

-- Shared by reference across modules. Booleans use `== nil`, not `or`,
-- so an explicit `false` isn't silently overridden by the default.
local cfg = {
  SKIP_BLOCKS         = rawConfig.SKIP_BLOCKS or DEFAULT_SKIP_BLOCKS,
  FUEL_THRESHOLD      = rawConfig.FUEL_THRESHOLD or 200,
  FUEL_SAFETY_MARGIN  = rawConfig.FUEL_SAFETY_MARGIN or 20,
  FUEL_RESERVE_ITEMS  = rawConfig.FUEL_RESERVE_ITEMS or 3,
  ATTACK_MOBS         = rawConfig.ATTACK_MOBS,
  COLLECT_ITEMS       = rawConfig.COLLECT_ITEMS,
  DETOUR_ENABLED      = rawConfig.DETOUR_ENABLED,
  DETOUR_MAX_WIDTH    = rawConfig.DETOUR_MAX_WIDTH or 4,
  DETOUR_USE_MEMORY   = rawConfig.DETOUR_USE_MEMORY,
  AUTO_REFUEL_STATION = rawConfig.AUTO_REFUEL_STATION,
}
if cfg.ATTACK_MOBS == nil then cfg.ATTACK_MOBS = false end
if cfg.COLLECT_ITEMS == nil then cfg.COLLECT_ITEMS = false end
if cfg.DETOUR_ENABLED == nil then cfg.DETOUR_ENABLED = true end
if cfg.DETOUR_USE_MEMORY == nil then cfg.DETOUR_USE_MEMORY = true end
if cfg.AUTO_REFUEL_STATION == nil then cfg.AUTO_REFUEL_STATION = true end

local state    = dofile("state.lua")
local logging  = dofile("logging.lua")(state, cfg)
local movement = dofile("movement.lua")(state, cfg, logging)
local detour   = dofile("detour.lua")(state, cfg, logging, movement)
local fuel     = dofile("fuel.lua")(state, cfg, logging, movement)

local log, logEvent = logging.log, logging.logEvent
local up, down, turnLeft, turnRight, turnTo = movement.up, movement.down, movement.turnLeft, movement.turnRight, movement.turnTo
local stepForward = detour.stepForward

------------------------------------------------------------
-- Mining pattern
------------------------------------------------------------

-- Digs one direction only (zigzag, halves vertical travel). A partial
-- column (obstacle) is undone so pos.y always ends at 0 or -height.
local function mineColumn(height)
  local goingDown = (state.pos.y == 0)
  local mover   = goingDown and down or up
  local unmover = goingDown and up or down

  local moved = 0
  for _ = 1, height do
    if state.fatalFuel then break end
    local ok, reason, name = mover()
    if not ok then
      local blockY = goingDown and (state.pos.y - 1) or (state.pos.y + 1)
      if reason == "skip" then
        log(string.format("Skip %s at x=%d y=%d z=%d row=%d col=%d", name, state.pos.x, blockY, state.pos.z, state.currentRow, state.currentCol))
      elseif reason ~= "no_fuel" and reason ~= "low_fuel" then
        log(string.format("Stuck %s at x=%d y=%d z=%d row=%d col=%d (%s)",
          goingDown and "down" or "up", state.pos.x, blockY, state.pos.z, state.currentRow, state.currentCol, tostring(name)))
      end
      break
    end
    moved = moved + 1
    state.save() -- checkpoint every block -- a crash mid-column must not lose more than one block of real position
  end

  if moved < height and not state.fatalFuel then
    for _ = 1, moved do
      local ok = unmover()
      if not ok then
        logEvent(string.format("Could not undo partial column at x=%d y=%d z=%d -- leaving turtle here.", state.pos.x, state.pos.y, state.pos.z))
        break
      end
      state.save() -- same per-block checkpoint as the dig loop above
    end
  end
end

-- Keeps the turtle on its canonical (x,z), undoing detour drift.
-- Bounded with cycle detection so a pillar corner can't loop forever.
local MAX_CORRECTION_ROUNDS = 4

local function correctZ(targetZ, row, bounds)
  while state.pos.z < targetZ and not state.fatalFuel do
    turnTo(1)
    local moved, reason = stepForward(bounds)
    if not moved then
      if reason ~= "no_fuel" and reason ~= "low_fuel" then
        logEvent(string.format(
          "Could not correct to depth z=%d for row %d (stuck at z=%d) -- mining continues at the wrong depth.",
          targetZ, row, state.pos.z))
      end
      return false
    end
  end
  while state.pos.z > targetZ and not state.fatalFuel do
    turnTo(3)
    local moved, reason = stepForward(bounds)
    if not moved then
      if reason ~= "no_fuel" and reason ~= "low_fuel" then
        logEvent(string.format(
          "Could not correct to depth z=%d for row %d (stuck at z=%d) -- mining continues at the wrong depth.",
          targetZ, row, state.pos.z))
      end
      return false
    end
  end
  return true
end

local function correctX(targetX, row, bounds)
  while state.pos.x < targetX and not state.fatalFuel do
    turnTo(0)
    local moved, reason = stepForward(bounds)
    if not moved then
      if reason ~= "no_fuel" and reason ~= "low_fuel" then
        logEvent(string.format(
          "Could not correct to column x=%d for row %d (stuck at x=%d) -- mining continues at the wrong column.",
          targetX, row, state.pos.x))
      end
      return false
    end
  end
  while state.pos.x > targetX and not state.fatalFuel do
    turnTo(2)
    local moved, reason = stepForward(bounds)
    if not moved then
      if reason ~= "no_fuel" and reason ~= "low_fuel" then
        logEvent(string.format(
          "Could not correct to column x=%d for row %d (stuck at x=%d) -- mining continues at the wrong column.",
          targetX, row, state.pos.x))
      end
      return false
    end
  end
  return true
end

-- Corrects Z then X, looping until both match or rounds run out.
-- Stops early if a position repeats (cycle = stuck at a corner).
local function correctPosition(targetX, targetZ, row, mineHeading, bounds)
  local seenPositions = { [state.pos.x .. ":" .. state.pos.z] = true }
  local cycleDetected = false

  for _ = 1, MAX_CORRECTION_ROUNDS do
    if state.fatalFuel then break end
    if state.pos.x == targetX and state.pos.z == targetZ then break end
    if not correctZ(targetZ, row, bounds) then break end
    if state.fatalFuel then break end
    if state.pos.x == targetX and state.pos.z == targetZ then break end
    if not correctX(targetX, row, bounds) then break end
    if state.fatalFuel then break end
    if state.pos.x == targetX and state.pos.z == targetZ then break end

    local key = state.pos.x .. ":" .. state.pos.z
    if seenPositions[key] then
      cycleDetected = true
      break
    end
    seenPositions[key] = true
  end

  if not state.fatalFuel and (state.pos.x ~= targetX or state.pos.z ~= targetZ) then
    if cycleDetected then
      logEvent(string.format(
        "Position correction for row %d is oscillating near an obstacle corner (back at x=%d z=%d, wanted x=%d z=%d) -- stopping early, mining continues here.",
        row, state.pos.x, state.pos.z, targetX, targetZ))
    else
      logEvent(string.format(
        "Could not fully correct position for row %d after %d round(s) (at x=%d z=%d, wanted x=%d z=%d) -- mining continues here.",
        row, MAX_CORRECTION_ROUNDS, state.pos.x, state.pos.z, targetX, targetZ))
    end
  end
  turnTo(mineHeading)
end

-- Mines one row, column by column. Verifies pos matches each column's
-- canonical (x,z) first, so drift never silently mines the wrong spot.
local function mineRow(width, height, bounds)
  local mineHeading = state.heading
  local targetZ = state.currentRow - 1
  local startX = (mineHeading == 0) and 0 or (width - 1)
  local dirX = (mineHeading == 0) and 1 or -1

  for col = 1, width do
    if state.fatalFuel then break end
    state.currentCol = col
    local expectedX = startX + (col - 1) * dirX
    if state.pos.x == expectedX and state.pos.z == targetZ then
      mineColumn(height)
    else
      logEvent(string.format(
        "Column skipped: row=%d col=%d intended x=%d z=%d could not be reached (turtle at x=%d z=%d) -- no shaft mined here.",
        state.currentRow, col, expectedX, targetZ, state.pos.x, state.pos.z))
    end
    state.save() -- per-column checkpoint
    if state.fatalFuel then break end
    if col < width then
      local moved, reason, name = stepForward(bounds)
      if not moved then
        -- stepForward() already tried a detour on both sides and gave up
        -- -- stop this row here instead of re-digging the same column
        -- forever (pos never advances if this loop kept going).
        if reason ~= "no_fuel" and reason ~= "low_fuel" then
          logEvent(string.format(
            "Could not step at x=%d y=%d z=%d row=%d col=%d (%s) -- stopping this row early.",
            state.pos.x, state.pos.y, state.pos.z, state.currentRow, state.currentCol, tostring(reason or name)))
        end
        break
      end
      local targetX = startX + col * dirX
      correctPosition(targetX, targetZ, state.currentRow, mineHeading, bounds)
    end
  end
end

-- Walks back onto the row's start cell -- never trusts wherever the
-- previous row's detours left the turtle.
local function goToRowStart(row, width, bounds)
  local mineHeading = state.heading
  local targetZ = row - 1
  local targetX = (mineHeading == 0) and 0 or (width - 1)
  correctPosition(targetX, targetZ, row, mineHeading, bounds)
end

-- The mining footprint, computed once -- lets a detour refuse a step that
-- would leave the requested area instead of digging past its edges.
local function mineArea(width, height, depth)
  local bounds = { minX = 0, maxX = width - 1, minZ = 0, maxZ = depth - 1 }
  for row = 1, depth do
    if state.fatalFuel then break end
    state.currentRow = row

    if not fuel.refuelIfNeeded() then
      movement.haltOnNoFuel()
      break
    end
    if cfg.COLLECT_ITEMS and fuel.inventoryFull() then
      log("Inventory full! Returning home.")
      return
    end

    state.currentCol = 0 -- correcting position before this row starts, not mining a column yet
    goToRowStart(row, width, bounds)
    if state.fatalFuel then break end

    log(string.format("Row %d/%d (z=%d)", row, depth, state.pos.z))
    mineRow(width, height, bounds)
    if state.fatalFuel then break end

    if row < depth then
      -- snake: step sideways, flip to face back
      local moved
      if state.heading == 0 then
        turnRight(); moved = stepForward(bounds); turnRight()
      else
        turnLeft(); moved = stepForward(bounds); turnLeft()
      end
      if not moved then
        if not state.fatalFuel then
          logEvent(string.format("Could not advance to next row at x=%d y=%d z=%d row=%d -- stopping.", state.pos.x, state.pos.y, state.pos.z, state.currentRow))
        end
        break
      end
    end
  end
end

-- Final walk home. Marks row/col -1 so skips here aren't logged as
-- mining skips (unlike a mid-run refuel trip, which stays mining).
local function returnHome()
  state.currentRow, state.currentCol = -1, -1
  movement.walkHome()
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

local function main(...)
  local args = { ... }
  local width  = tonumber(args[1]) or 16
  local height = tonumber(args[2]) or 5
  local depth  = tonumber(args[3]) or 16

  -- Bad dimensions make Lua's `for` loops silently run zero times --
  -- fail loud instead of looking like a successful empty run.
  if width < 1 or height < 1 or depth < 1
      or width ~= math.floor(width) or height ~= math.floor(height) or depth ~= math.floor(depth) then
    log(string.format(
      "Invalid dimensions: width=%s height=%s depth=%s -- all must be whole numbers >= 1. Aborting.",
      tostring(width), tostring(height), tostring(depth)))
    return
  end

  -- No GPS -- always assumes it starts at (0,0,0). A leftover non-home
  -- saved position is the only sign of an unfinished run -- confirm first.
  local saved = state.readSaved()
  if saved and (saved.x ~= 0 or saved.y ~= 0 or saved.z ~= 0) then
    log(string.format(
      "Warning: last saved position was x=%d y=%d z=%d (not home) -- an earlier run may not have finished.",
      saved.x, saved.y, saved.z))
    log("If this turtle is NOT physically on its start pad right now, Ctrl+T to cancel and run 'startup' by hand first to walk it home. Press Enter to mine anyway (here becomes the new start).")
    read()
  end

  -- A detour wider than the mining area itself is pointless.
  cfg.DETOUR_MAX_WIDTH = math.min(width, depth)

  log(string.format("Starting mine: %d wide x %d down x %d deep", width, height, depth))
  log("Obsidian/bedrock/portal blocks: skipped, never broken.")
  if cfg.DETOUR_ENABLED then
    log(string.format("Detour around obstacles: on (max %d block(s) wide).", cfg.DETOUR_MAX_WIDTH))
    log(string.format("Detour memory shortcut: %s -- %s.",
      cfg.DETOUR_USE_MEMORY and "on" or "off",
      cfg.DETOUR_USE_MEMORY and "known spots are jumped to directly"
        or "every obstacle is fully re-probed every time, even repeats"))
  end
  log(string.format("Refuel station: %s%s.",
    cfg.AUTO_REFUEL_STATION and "on" or "off",
    cfg.AUTO_REFUEL_STATION
      and " -- if fuel runs low with nothing usable in inventory, the turtle will detour home to the chests behind the start position before giving up"
      or ""))

  local currentFuel = turtle.getFuelLevel()
  if currentFuel ~= "unlimited" then
    -- height+1 per column, not 2*height+1: mineColumn() zigzags instead
    -- of always descending then climbing back.
    local estNeeded = width * depth * (height + 1) + depth
    if currentFuel < estNeeded then
      log(string.format("Warning: ~%d fuel needed, have %d. May run out mid-mine.", estNeeded, currentFuel))
    end
  end

  state.save() -- baseline checkpoint: reboot before any move still reads as "home"

  mineArea(width, height, depth)

  -- Snapshot before returnHome(), which unconditionally resets
  -- currentRow/currentCol to -1,-1.
  local lastRow, lastCol = state.currentRow, state.currentCol

  if state.fatalFuel and state.haltReason == "low_fuel" then
    log("Fuel getting low -- stopped mining early, heading home now.")
  elseif state.fatalFuel then
    log("Mining stopped early: out of fuel. Attempting return with what's left...")
  else
    log("Mining pass complete. Returning home...")
  end
  returnHome()
  state.save() -- final checkpoint: home, or (fatal-fuel run) stuck partway

  if state.pos.x ~= 0 or state.pos.y ~= 0 or state.pos.z ~= 0 then
    logEvent(string.format("Could not fully return home -- stuck at x=%d y=%d z=%d (fuel=%s).",
      state.pos.x, state.pos.y, state.pos.z, tostring(turtle.getFuelLevel())))
  elseif state.fatalFuel and state.haltReason == "low_fuel" then
    log("Back home safely (stopped early to conserve fuel).")
  else
    log("Back home.")
  end
  logging.saveSkipLog(width, height, depth, lastRow, lastCol)
  log("Done.")
end

main(...)
