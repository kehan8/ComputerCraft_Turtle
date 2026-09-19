-- startup.lua (CC:Tweaked)
--
-- Auto-runs on every turtle boot. ONLY job: if end_miner.lua left a saved
-- position behind, walk back to (0,0,0)/heading 0. Never starts mining,
-- even if called with arguments -- that's always a manual
-- `end_miner <width> <height> <depth>` command.
--
-- Standalone on purpose (not sharing modules with end_miner.lua): never
-- digs (SKIP_BLOCKS or anything else -- stop and log instead, see
-- safeClear()), horizontal (x, then z) before vertical -- the only shaft
-- guaranteed clear the whole way is the one at x=0,z=0. Gets stuck ->
-- logs where (both to screen and LOG_FILE, since nobody's usually
-- watching right after a server restart) and stops; run `startup` again
-- by hand to retry once the obstacle's cleared or it's refueled.
--
-- STATE_FILE format must stay in sync with end_miner.lua's saveState() --
-- both are plain { x, y, z, heading } tables via textutils.serialize.

local STATE_FILE = "end_miner_state.txt"
local LOG_FILE = "startup_home.log"

-- Same list as end_miner.lua's SKIP_BLOCKS -- never dug, even on the walk
-- home; a reboot doesn't change what's actually breakable.
local SKIP_BLOCKS = {
  ["minecraft:obsidian"]         = true,
  ["minecraft:crying_obsidian"]  = true,
  ["minecraft:bedrock"]          = true,
  ["minecraft:end_portal_frame"] = true,
  ["minecraft:end_gateway"]      = true,
  ["minecraft:end_portal"]       = true,
  ["minecraft:dragon_egg"]       = true,
}

local MAX_MOVE_ATTEMPTS = 8

local pos = { x = 0, y = 0, z = 0 }
local heading = 0

local HEADING_DELTA = {
  [0] = { x = 1,  z = 0  },
  [1] = { x = 0,  z = 1  },
  [2] = { x = -1, z = 0  },
  [3] = { x = 0,  z = -1 },
}

local function log(msg)
  print(msg)
end

-- Like log(), but also appended to LOG_FILE. A stuck home-walk usually
-- happens unattended right after a server restart -- the turtle's own
-- screen has no scrollback, so without this the reason is gone the
-- moment it scrolls off. Never lets a write failure stop the walk.
local function logEvent(msg)
  log(msg)
  local f = fs.open(LOG_FILE, "a")
  if not f then return end
  local ok, ts = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  f.write((ok and ts and ("[" .. ts .. "] ") or "") .. msg .. "\n")
  f.close()
end

-- Same reasoning as end_miner.lua's saveState() -- keeps STATE_FILE in sync
-- as this walk progresses, so a second interruption (another reboot mid-walk)
-- resumes from wherever THIS walk got to, not from the original mining
-- position. Cheap here -- a home walk is short, nowhere near a full mining
-- run's move count.
local function saveState()
  local f = fs.open(STATE_FILE, "w")
  if not f then return end
  f.write(textutils.serialize({ x = pos.x, y = pos.y, z = pos.z, heading = heading }))
  f.close()
end

-- Never digs, period -- not just SKIP_BLOCKS. Anything in the path home
-- means the saved position is wrong (reboot mid-run, desync, etc.), not
-- that there's rubble to clear -- digging through it could just as easily
-- be a player's own chests/machines at the home base. `digFn` is kept as
-- a parameter for signature symmetry with end_miner.lua's safeClear() but
-- is never called.
local function safeClear(inspectFn, digFn, detectFn)
  local isBlock, data = inspectFn()
  if not isBlock then return true end
  if SKIP_BLOCKS[data.name] then return false, "skip", data.name end
  return false, "blocked", data.name
end

-- Same as end_miner.lua's tryMove() -- bounded retries, hard stop the
-- instant fuel is actually at 0 (no point retrying a move with no fuel).
local function tryMove(moveFn)
  local fuel = turtle.getFuelLevel()
  if fuel ~= "unlimited" and fuel <= 0 then return false, "no_fuel" end

  local attempts = 0
  local moved = moveFn()
  while not moved and attempts < MAX_MOVE_ATTEMPTS do
    os.sleep(0.3)
    moved = moveFn()
    attempts = attempts + 1
  end
  if not moved then return false, "stuck" end
  return true
end

local function forward()
  local ok, reason, name = safeClear(turtle.inspect, turtle.dig, turtle.detect)
  if not ok then return false, reason, name end
  local moved, reason = tryMove(turtle.forward)
  if not moved then return false, reason end
  local d = HEADING_DELTA[heading]
  pos.x = pos.x + d.x
  pos.z = pos.z + d.z
  saveState()
  return true
end

local function up()
  local ok, reason, name = safeClear(turtle.inspectUp, turtle.digUp, turtle.detectUp)
  if not ok then return false, reason, name end
  local moved, reason = tryMove(turtle.up)
  if not moved then return false, reason end
  pos.y = pos.y + 1
  saveState()
  return true
end

local function down()
  local ok, reason, name = safeClear(turtle.inspectDown, turtle.digDown, turtle.detectDown)
  if not ok then return false, reason, name end
  local moved, reason = tryMove(turtle.down)
  if not moved then return false, reason end
  pos.y = pos.y - 1
  saveState()
  return true
end

local function turnRight()
  turtle.turnRight()
  heading = (heading + 1) % 4
end

local function turnTo(target)
  while heading ~= target do turnRight() end
end

-- Horizontal (x then z) first, vertical last -- see the file header
-- comment for why. Returns true if it made it all the way to
-- (0,0,0)/heading 0.
local function walkHome()
  if pos.x > 0 then
    turnTo(2)
    for _ = 1, pos.x do
      local ok, reason = forward()
      if not ok then
        logEvent(string.format("Stuck walking home (x, at x=%d y=%d z=%d): %s", pos.x, pos.y, pos.z, tostring(reason)))
        return false
      end
    end
  elseif pos.x < 0 then
    turnTo(0)
    for _ = 1, -pos.x do
      local ok, reason = forward()
      if not ok then
        logEvent(string.format("Stuck walking home (x, at x=%d y=%d z=%d): %s", pos.x, pos.y, pos.z, tostring(reason)))
        return false
      end
    end
  end

  if pos.z > 0 then
    turnTo(3)
    for _ = 1, pos.z do
      local ok, reason = forward()
      if not ok then
        logEvent(string.format("Stuck walking home (z, at x=%d y=%d z=%d): %s", pos.x, pos.y, pos.z, tostring(reason)))
        return false
      end
    end
  elseif pos.z < 0 then
    turnTo(1)
    for _ = 1, -pos.z do
      local ok, reason = forward()
      if not ok then
        logEvent(string.format("Stuck walking home (z, at x=%d y=%d z=%d): %s", pos.x, pos.y, pos.z, tostring(reason)))
        return false
      end
    end
  end

  while pos.y < 0 do
    local ok, reason = up()
    if not ok then
      logEvent(string.format("Stuck walking home (y, at x=%d y=%d z=%d): %s", pos.x, pos.y, pos.z, tostring(reason)))
      return false
    end
  end
  while pos.y > 0 do
    local ok, reason = down()
    if not ok then
      logEvent(string.format("Stuck walking home (y, at x=%d y=%d z=%d): %s", pos.x, pos.y, pos.z, tostring(reason)))
      return false
    end
  end

  turnTo(0)
  return true
end

local function main(...)
  local args = { ... }
  if #args > 0 then
    log("startup.lua: got argument(s) (" .. table.concat(args, " ") ..
      ") but this script never auto-starts mining, on purpose -- ignoring them and just walking home instead. Run 'end_miner <width> <height> <depth>' by hand to start a job.")
  end

  local f = fs.open(STATE_FILE, "r")
  if not f then
    log("startup.lua: no saved position (" .. STATE_FILE .. " not found) -- nothing to do. Either this turtle has never run end_miner.lua, or it's already home.")
    return
  end
  local raw = f.readAll()
  f.close()

  local ok, saved = pcall(textutils.unserialize, raw)
  if not ok or type(saved) ~= "table" or not saved.x or not saved.y or not saved.z or not saved.heading then
    logEvent("startup.lua: " .. STATE_FILE .. " is unreadable or corrupt -- not moving, to avoid walking in a wrong/random direction. Check the turtle by hand.")
    return
  end

  pos.x, pos.y, pos.z, heading = saved.x, saved.y, saved.z, saved.heading

  if pos.x == 0 and pos.y == 0 and pos.z == 0 then
    log("startup.lua: already home (0,0,0). Nothing to do.")
    return
  end

  logEvent(string.format("startup.lua: last known position x=%d y=%d z=%d heading=%d -- walking home.",
    pos.x, pos.y, pos.z, heading))

  if walkHome() then
    logEvent("startup.lua: back home.")
  else
    logEvent(string.format(
      "startup.lua: could not make it all the way home -- stuck at x=%d y=%d z=%d (fuel=%s). Refuel and/or clear the obstacle, then run 'startup' again by hand to retry from here.",
      pos.x, pos.y, pos.z, tostring(turtle.getFuelLevel())))
  end
end

main(...)
