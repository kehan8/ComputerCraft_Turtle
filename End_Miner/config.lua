-- config.lua: player-tunable settings. Missing/corrupt file is not
-- fatal -- callers fall back to hardcoded defaults per field.

return {

  -- Blocks never dug. Add new ones here ONLY -- end_miner.lua/startup.lua
  -- keep emergency fallback copies that are NOT meant to be edited.
  SKIP_BLOCKS = {
    ["minecraft:obsidian"]         = true,
    ["minecraft:crying_obsidian"]  = true,
    ["minecraft:bedrock"]          = true,
    ["minecraft:end_portal_frame"] = true,
    ["minecraft:end_gateway"]      = true,
    ["minecraft:end_portal"]       = true,
    ["minecraft:dragon_egg"]       = true,
  },

  -- Refuel when fuel drops below this.
  FUEL_THRESHOLD = 200,

  -- Extra fuel buffer kept on top of the calculated trip home.
  FUEL_SAFETY_MARGIN = 20,

  -- Spare fuel items kept aboard so refuelIfNeeded() can burn one
  -- mid-field instead of a full station trip. 0 disables.
  FUEL_RESERVE_ITEMS = 3,

  -- true = punch whatever blocks a cleared space. false = wait/retry only.
  ATTACK_MOBS = false,

  -- false = ignore a full inventory and keep mining (drops on the ground).
  COLLECT_ITEMS = false,

  -- Route around a pillar instead of giving up on that one step.
  -- false = old behavior (log and stop).
  DETOUR_ENABLED = true,

  -- Fallback max detour width; main() caps it to min(width, depth) once
  -- the run's dimensions are known.
  DETOUR_MAX_WIDTH = 4,

  -- Remember which side/width worked at an obstacle and reuse it next
  -- time. false = re-probe from scratch every time.
  DETOUR_USE_MEMORY = true,

  -- Walk to the two-chest refuel station instead of halting when fuel
  -- runs low. Requires the station built at the start position -- see
  -- README.md "Fuel & the refuel station".
  AUTO_REFUEL_STATION = true,

}
