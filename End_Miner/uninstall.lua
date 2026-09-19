-- uninstall.lua: removes the files installed by install.lua/update.lua.

local FILES = {
    "end_miner.lua", "state.lua", "logging.lua", "movement.lua", "detour.lua", "fuel.lua",
    "rename.lua", "startup.lua", "update.lua", "update_full.lua", "install.lua",
}

print("This will remove: " .. table.concat(FILES, ", "))
io.write("Also remove config.lua (your miner settings)? (y/N): ")
local removeConfig = (read() or ""):lower() == "y"
if removeConfig then
    table.insert(FILES, "config.lua")
end

for _, name in ipairs(FILES) do
    if fs.exists(name) then
        fs.delete(name)
        print("Removed " .. name)
    end
end

print("Done. Run install.lua again for a clean reinstall.")
