-- logging.lua: console + saved-log output. Records skips/detours/events
-- in `state` so saveSkipLog() can write a full end-of-run summary.

return function(state, cfg)
  local LOG_FILE = "end_miner_skips.log"

  local function log(msg)
    print(msg)
  end

  -- Like log(), but also persisted for the "why did this run stop early"
  -- section of the saved log. Not for routine progress lines.
  local function logEvent(msg)
    log(msg)
    table.insert(state.runLog, msg)
  end

  -- Uses the block's position (not the turtle's) plus row/col, so a
  -- repeat on a new row reads differently from a same-row rerun.
  local function recordSkip(bx, by, bz, blockName)
    table.insert(state.skipped, { x = bx, y = by, z = bz, block = blockName, row = state.currentRow, col = state.currentCol })
  end

  -- Records a detour's outcome -- the only evidence of whether the
  -- memory shortcut actually fired.
  local function recordDetour(bx, by, bz, outcome, width)
    table.insert(state.detours, { x = bx, y = by, z = bz, row = state.currentRow, col = state.currentCol, outcome = outcome, width = width })
  end

  -- Optional peek into whatever chest is directly in front, purely
  -- diagnostic -- wrapped so it can never throw or affect any decision.
  local function peekChestInFront(label)
    local wrapOk, inv = pcall(peripheral.wrap, "front")
    if not wrapOk or not inv or not inv.list then
      logEvent(string.format("%s: could not inspect chest contents (no peripheral access) -- continuing anyway.", label))
      return
    end
    local listOk, items = pcall(inv.list)
    if not listOk or not items then
      logEvent(string.format("%s: could not read chest contents -- continuing anyway.", label))
      return
    end
    local parts = {}
    for _, item in pairs(items) do
      table.insert(parts, string.format("%s x%d", item.name, item.count))
    end
    if #parts == 0 then
      logEvent(string.format("%s: chest is empty.", label))
    else
      logEvent(string.format("%s: contains %s.", label, table.concat(parts, ", ")))
    end
  end

  -- Writes a full run summary. lastRow/lastCol must be snapshotted by
  -- the caller before returnHome() resets them to -1,-1.
  local function saveSkipLog(width, height, depth, lastRow, lastCol)
    local f = fs.open(LOG_FILE, "w")
    if not f then
      log("Warning: could not open " .. LOG_FILE)
      return
    end

    local pos = state.pos
    f.write(string.format("Requested area: %d wide x %d down x %d deep\n", width, height, depth))
    f.write(string.format("Detour: %s (max %d block(s) wide), memory shortcut: %s\n",
      cfg.DETOUR_ENABLED and "on" or "off", cfg.DETOUR_MAX_WIDTH, cfg.DETOUR_USE_MEMORY and "on" or "off"))
    f.write(string.format("Last row/col mined: row=%d col=%d\n", lastRow, lastCol))
    f.write(string.format("Final position: x=%d y=%d z=%d (target 0,0,0)%s\n",
      pos.x, pos.y, pos.z, (pos.x == 0 and pos.y == 0 and pos.z == 0) and " -- home" or " -- DID NOT MAKE IT HOME"))

    f.write("\nSkipped blocks (relative to start):\n")
    if #state.skipped == 0 then
      f.write("  none\n")
    end
    for _, e in ipairs(state.skipped) do
      f.write(string.format("  x=%d y=%d z=%d  row=%d col=%d  %s\n", e.x, e.y, e.z, e.row, e.col, e.block))
    end

    f.write("\nDetours taken (relative to start):\n")
    if #state.detours == 0 then
      f.write("  none\n")
    end
    for _, d in ipairs(state.detours) do
      f.write(string.format("  x=%d y=%d z=%d  row=%d col=%d  %-20s width=%d\n",
        d.x, d.y, d.z, d.row, d.col, d.outcome, d.width))
    end

    if #state.runLog > 0 then
      f.write("\nEvents (why the run may have stopped early):\n")
      for _, e in ipairs(state.runLog) do
        f.write("  " .. e .. "\n")
      end
    end

    f.close()
    log(string.format("Saved run summary (%d skipped, %d detour(s), %d event(s)) to %s",
      #state.skipped, #state.detours, #state.runLog, LOG_FILE))
  end

  return {
    log = log,
    logEvent = logEvent,
    recordSkip = recordSkip,
    recordDetour = recordDetour,
    peekChestInFront = peekChestInFront,
    saveSkipLog = saveSkipLog,
  }
end
