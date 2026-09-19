# End Area Miner (CC:Tweaked)

Mines a `width x depth` area, `height` blocks deep, in the End. Skips
obsidian/bedrock/portal blocks via `inspect()` before ever calling `dig()` --
it never retries forever and pillars stay intact.

## Usage

```
end_miner <width> <height> <depth>
```

Argument order matches Minecraft's own X, Y, Z axis order: `width` = X
(East/West), `height` = Y (Up/Down), `depth` = Z (North/South). Start the
turtle at the top corner, facing the direction it should mine `width`
blocks across; it snakes `depth` rows deep, digging `height` blocks down
each column.

## Configuration (`config.lua`)

Fuel thresholds, the fuel reserve kept aboard, mob/item handling, and the
detour behavior (on/off, max width, memory shortcut) all live in
`config.lua`, not `end_miner.lua` -- edit that file to tune a run without
touching the main script. Each setting has a short 1-2 line comment
explaining what it does.

`config.lua` is optional at runtime: if it's missing, unreadable, or
missing a field (e.g. an old copy from before a setting existed),
`end_miner.lua` falls back to the same defaults shown in `config.lua`
itself, rather than crashing the run.

`SKIP_BLOCKS`, retry limits, and the state/log file names are **not**
in `config.lua` on purpose -- those are internal/safety details, not
things a player tunes per run.

## Code structure

`end_miner.lua` is split into small, single-purpose files instead of one
big script:

- `state.lua` -- shared mutable run state (position, heading, fuel/halt
  flags, skip/detour logs) plus save/load of `end_miner_state.txt`.
- `logging.lua` -- console output and the saved `end_miner_skips.log`.
- `movement.lua` -- safe dig/move primitives (forward/up/down/turn) and
  the home walk.
- `detour.lua` -- routes around a pillar blocking a sideways step.
- `fuel.lua` -- inventory refuel and the two-chest refuel station trip.
- `end_miner.lua` -- the mining pattern (rows/columns) and `main()`.

Each of the above (except `state.lua`) is a factory function returning a
table of the module's functions, wired together at the top of
`end_miner.lua`. `startup.lua` stays fully standalone on purpose -- it
must keep working even if these modules are missing or broken.

## Installing & updating (from GitHub)

The turtle side of this project can be deployed straight from the
`kehan8/ComputerCraft_Turtle` repo instead of copy-pasting files by hand:

- `install.lua` -- first-time setup. Downloads everything (`end_miner.lua`
  and its modules, `config.lua`, `startup.lua`, `update.lua`,
  `update_full.lua`, `uninstall.lua`). If `config.lua` already exists on
  the turtle, it's left alone instead of overwritten, so a re-run of
  `install` never wipes settings you've already tuned. Also offers to
  label the computer.
- `update.lua` -- redownloads the code files only. Leaves your
  `config.lua` untouched.
- `update_full.lua` -- redownloads everything, `config.lua` included --
  use this to reset settings back to the repo defaults.
- `uninstall.lua` -- removes the installed files; asks separately before
  also removing `config.lua`.

Run `install` once per turtle, `update` (or `update_full` to also reset
settings) whenever the repo changes.

## Known quirks

### "Pillar" behaviour at End Portal height

If the turtle's start position (the surface it walks on) is at the **same
Y-height** as an End Portal, the turtle treats the portal like it treats any
other obstacle it can't dig through (bedrock, obsidian frame, etc.): it skips
that single column and keeps going. Because an End Portal is a 3x3 block of
`minecraft:end_portal` sitting inside the obstacle field, and the turtle is
walking *at* that height, it ends up skipping the entire row it's currently
digging along that height -- visually it looks like it "thinks the whole row
is a pillar," even though the portal itself is just one flat plane, not a
solid pillar all the way up/down.

This is **not fixed in code on purpose**. Trying to special-case "is this
obstacle actually a thin plane vs. a real pillar" from inside a turtle with
only `inspect()`/`detect()` is fragile and easy to get wrong in ways that are
much worse (e.g. digging into an End Portal by accident, or getting the
turtle stuck). The cheap, reliable fix is positional instead of algorithmic:

**Start the turtle at a Y-height that does not match any End Portal in the
mining area.** Above or below the portal's height is both fine -- just not
the same height. Do that and the whole run goes through cleanly, portal
included (it gets skipped as a normal unbreakable block, one column, no
side effects).

## Auto-return home on reboot (`startup.lua`)

`startup.lua` auto-runs on every turtle boot (CC:Tweaked's reserved
filename). Its only job: if `end_miner.lua` was interrupted mid-run
(server/turtle restart, crash, `/reboot`), walk the turtle back to its
start position `(0,0,0)` using the last position `end_miner.lua` saved
to `end_miner_state.txt`.

**It never starts mining on its own -- not even if called with
arguments.** Starting a mining job is always the explicit
`end_miner <width> <height> <depth>` command, typed by hand. This is
intentional, not a missing feature.

If it gets stuck walking home (obstacle or empty fuel), it logs exactly
where, the exact block name if one's in the way, and stops -- clear the
obstacle or refuel, then run `startup` again by hand to retry from that
same spot. That message is also appended to `startup_home.log` (with a
timestamp), not just printed -- a reboot-triggered walk usually happens
with nobody watching the turtle's screen, so the live `print()` output
alone would otherwise be gone the moment it scrolls off. Check that file
after a restart if the turtle didn't end up back home.

**`startup.lua`'s homing never digs ordinary terrain by default -- only
`end_miner.lua`'s own live-run home walk does.** There is no GPS in this
setup, so a saved position `startup.lua` reads from disk after a reboot is
only ever a best guess (the reboot/tick-freeze itself is exactly the kind
of event that can make it wrong, and nobody's there afterward to check).
On real hardware, digging through "whatever's actually there" while that
guess was wrong meant digging through the player's own chests and a fuel
machine at the home base. `end_miner.lua`'s own walk-home (used at the end
of a run and during a station refuel trip) is different: it always runs
inside the same continuous, never-rebooted execution where the position
is live-tracked, not read cold off disk, and any run that starts with a
suspicious saved position already stopped for the confirmation described
below -- so it's safe for it to dig ordinary terrain and detour around
`SKIP_BLOCKS` obstacles same as normal mining. `startup.lua` can't tell
whether it's trustworthy the same way, so by default it only detours
around a `SKIP_BLOCKS` obstacle through space that's already open (never
digs to make room) and stops on anything else. If you're certain the
saved position is accurate -- e.g. you were standing right there when it
ran dry and just refueled it, no reboot happened -- run `startup force`
instead to let that one walk dig through ordinary terrain too, the same
trust call `end_miner.lua`'s own prompt below asks for, just as an
explicit flag instead of an Enter press, since `startup.lua` usually runs
unattended. Either way: a stuck turtle is recoverable by hand; a destroyed
base is not.

**Manually retyping `end_miner <w> <h> <d>` on a turtle that's mid-run
(after `Ctrl+T`, a crash, etc.) is risky** -- the script has no way to
check it's physically back on its start pad, so "here" silently becomes
the new `(0,0,0)`. If `end_miner_state.txt` still has a non-home position
saved when `end_miner` is started, it now warns and waits for Enter before
continuing -- read that warning; if the turtle isn't actually on its start
pad, run `startup` by hand first instead of pressing Enter.

## Fuel & the refuel station

The station uses two chests at different heights: one for fuel (lava
buckets), one for dropping off mined items. Which one is "up" and which is
"down" is just a fixed convention in the script -- it doesn't need to be
configurable per-run. If your build ever forces the two chests to swap
positions, that's a one-line change in the station-visit code rather than a
setting worth exposing, so it's being left as-is unless that actually comes
up.
