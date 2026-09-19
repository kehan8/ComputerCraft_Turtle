-- startup.lua (CC:Tweaked)
--
-- Auto-runs on every turtle boot. ONLY job: if end_miner.lua left a saved
-- position behind, walk back to (0,0,0)/heading 0. Never starts mining,
-- even if called with arguments -- that's always a manual
-- `end_miner <width> <height> <depth>` command.
--
-- Standalone on purpose (not sharing modules with end_miner.lua). There is
-- no GPS in this setup -- the saved position is pure dead reckoning, only
-- ever as good as end_miner.lua's last checkpoint before whatever
-- interrupted it (a real reboot, a tick-freeze, a manual restart). A
-- turtle that already destroyed a player's own chests and a fuel machine
-- by digging "home" through what turned out to be their actual base, on a
-- run where the saved position had gone stale, is why this defaults to
-- NEVER digging ordinary terrain on the walk home (SKIP_BLOCKS is always
-- routed around instead of dug, same as everywhere else in this project --
-- never a trust question, obsidian etc. is just never breakable).
-- Detouring around a SKIP_BLOCKS obstacle through space that's already
-- open is always safe regardless -- it only ever walks air, and undoes
-- itself cleanly if no already-open path exists -- so that part is always
-- on. Horizontal (x, then z, re-corrected in rounds) before vertical --
-- the only shaft guaranteed clear the whole way is the one at x=0,z=0.
-- Gets stuck -> logs where (both to screen and LOG_FILE, since nobody's
-- usually watching right after a server restart) and stops; run `startup`
-- again by hand to retry once refueled and/or the obstacle is cleared by
-- hand. If you're SURE the saved position is accurate -- e.g. you were
-- standing right there when it ran dry and just refueled it, no reboot
-- happened -- run `startup force` instead to also dig through ordinary
-- (non-SKIP_BLOCKS) terrain on this one walk, same as end_miner.lua's own
-- live-run home walk does.
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
local MAX_DIG_ATTEMPTS = 8 -- give up retrying a block after this many tries

-- Standalone fallback: end_miner.lua's own detour caps its width to the
-- run's actual footprint (min(width, depth)), but startup.lua doesn't know
-- the run's dimensions -- this is just generous enough for a normal
-- obsidian vein without risking a very long, pointless probe.
local DETOUR_MAX_WIDTH = 16

local pos = { x = 0, y = 0, z = 0 }
local heading = 0

-- Set from the "force" command-line argument in main() -- see the file
-- header comment. false (default): ordinary terrain blocks the walk
-- outright instead of being dug, same as the hardened Round-35 behavior.
-- true: dig ordinary terrain too, same rules as end_miner.lua's live-run
-- home walk. SKIP_BLOCKS is never dug either way.
local allowDig = false

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

-- Returns true (clear), or false + "skip"/"blocked"/"stuck" + block name.
-- SKIP_BLOCKS is never dug (returned as "skip" for the caller to detour
-- around, same as everywhere else). Anything else: if `allowDig` is false
-- (the default -- see file header and the `force` argument in main()),
-- blocks the move outright ("blocked"), no digging attempted at all. If
-- `allowDig` is true, dug through same as movement.lua's safeClear().
local function safeClear(inspectFn, digFn, detectFn)
  local isBlock, data = inspectFn()
  if not isBlock then return true end
  if SKIP_BLOCKS[data.name] then return false, "skip", data.name end
  if not allowDig then return false, "blocked", data.name end

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

-- Swings out `sideHeading`, tries to cross back to `originalHeading`. Same
-- shape as detour.lua's tryDetourSide (see that file for the full
-- reasoning) but inlined here since this script is standalone. Undoes its
-- own steps on failure so pos/heading always match the turtle's real
-- position. `fuelHalt` lets the caller stop trying sides instead of
-- burning more fuel on a second probe once the tank's actually empty.
local function tryDetourSide(sideHeading, originalHeading)
  turnTo(sideHeading)
  local moveLog = {}
  local success = false
  local fuelHalt = false

  for _ = 1, DETOUR_MAX_WIDTH do
    local ok, reason = forward()
    if reason == "no_fuel" then fuelHalt = true; break end
    if not ok then break end -- dead end this way
    table.insert(moveLog, sideHeading)

    turnTo(originalHeading)
    local okF, reasonF = forward()
    if reasonF == "no_fuel" then fuelHalt = true; break end
    if okF then
      table.insert(moveLog, originalHeading)
      success = true
      break
    end
    turnTo(sideHeading) -- still blocked straight ahead -- widen one more
  end

  if success then return true, fuelHalt end

  for i = #moveLog, 1, -1 do
    turnTo((moveLog[i] + 2) % 4)
    local ok = forward()
    if not ok then
      logEvent(string.format("Detour undo stuck at x=%d y=%d z=%d -- leaving turtle here.", pos.x, pos.y, pos.z))
      break
    end
  end
  turnTo(originalHeading)

  return false, fuelHalt
end

-- Tries right first, then left. No memory (unlike detour.lua) -- a home
-- walk is a one-shot trip, not worth persisting an offset for.
local function detourAround(originalHeading)
  local blockedX, blockedY, blockedZ = pos.x, pos.y, pos.z
  local rightHeading = (originalHeading + 1) % 4
  local leftHeading  = (originalHeading - 1) % 4

  local ok, fuelHalt = tryDetourSide(rightHeading, originalHeading)
  if ok then
    logEvent(string.format("Detour: routed around obstacle at x=%d y=%d z=%d via right.", blockedX, blockedY, blockedZ))
    return true
  end
  if fuelHalt then return false end

  ok, fuelHalt = tryDetourSide(leftHeading, originalHeading)
  if ok then
    logEvent(string.format("Detour: routed around obstacle at x=%d y=%d z=%d via left.", blockedX, blockedY, blockedZ))
    return true
  end

  return false
end

-- Drop-in replacement for forward() at every step of the horizontal home
-- walk: tries a detour on a real obstacle ("skip"/"stuck") before
-- reporting failure. Fuel reasons pass straight through untouched.
local function stepForward()
  local originalHeading = heading
  local moved, reason, name = forward()
  if moved then return true end
  if reason == "no_fuel" then return false, reason, name end
  if detourAround(originalHeading) then return true end
  return false, reason, name
end

local function walkStraight(count, axisLabel)
  for _ = 1, count do
    local moved, reason, name = stepForward()
    if not moved then
      logEvent(string.format("Stuck walking home (%s, at x=%d y=%d z=%d): %s%s",
        axisLabel, pos.x, pos.y, pos.z, tostring(reason), name and (" (" .. name .. ")") or ""))
      return false
    end
  end
  return true
end

-- Horizontal (x, then z) leg of the home walk, re-corrected in rounds --
-- same reasoning as movement.lua's walkHorizontal(): a detour taken on the
-- x leg only ever side-steps along z (self-correcting, since the z leg
-- that follows recomputes its step count from wherever z actually ended
-- up), but a detour taken on the z leg side-steps along x with nothing
-- after it to notice or fix that drift. Loop x->z->x... with a
-- seen-position cycle check so a pillar corner can't loop forever.
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
      logEvent(string.format(
        "Home walk (%s) is oscillating near an obstacle corner (back at x=%d z=%d, wanted x=%d z=%d) -- stopping horizontal correction here.",
        label, pos.x, pos.z, targetX, targetZ))
      return false
    end
    seen[key] = true
  end

  logEvent(string.format(
    "Could not fully correct home walk (%s) after %d round(s) (at x=%d z=%d, wanted x=%d z=%d).",
    label, MAX_HOME_CORRECTION_ROUNDS, pos.x, pos.z, targetX, targetZ))
  return false
end

-- Horizontal (x then z, re-corrected) first, vertical last -- see the file
-- header comment for why. Returns true if it made it all the way to
-- (0,0,0)/heading 0.
local function walkHome()
  local ok = walkHorizontal(0, 0, "home")

  if ok then
    while pos.y < 0 do
      local moved, reason, name = up()
      if not moved then
        logEvent(string.format("Stuck walking home (y, at x=%d y=%d z=%d): %s%s",
          pos.x, pos.y, pos.z, tostring(reason), name and (" (" .. name .. ")") or ""))
        ok = false
        break
      end
    end
  end
  if ok then
    while pos.y > 0 do
      local moved, reason, name = down()
      if not moved then
        logEvent(string.format("Stuck walking home (y, at x=%d y=%d z=%d): %s%s",
          pos.x, pos.y, pos.z, tostring(reason), name and (" (" .. name .. ")") or ""))
        ok = false
        break
      end
    end
  end

  turnTo(0)
  return ok
end

local function main(...)
  local args = { ... }
  local extra = {}
  for _, a in ipairs(args) do
    if a == "force" then
      allowDig = true
    else
      table.insert(extra, a)
    end
  end
  if allowDig then
    log("startup.lua: 'force' given -- will also dig through ordinary (non-SKIP_BLOCKS) terrain on this walk home, trusting the saved position.")
  end
  if #extra > 0 then
    log("startup.lua: got argument(s) (" .. table.concat(extra, " ") ..
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
      "startup.lua: could not make it all the way home -- stuck at x=%d y=%d z=%d (fuel=%s). Refuel and/or clear the obstacle by hand, then run 'startup' again to retry from here -- or, if you're sure this saved position is accurate (e.g. you just refueled it right here, no reboot happened), run 'startup force' instead to let it dig through ordinary terrain too.",
      pos.x, pos.y, pos.z, tostring(turtle.getFuelLevel())))
  end
end

main(...)
