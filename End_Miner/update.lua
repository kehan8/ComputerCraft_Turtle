-- update.lua: redownloads the code files, leaves config.lua alone.

local REPO_URL = "https://raw.githubusercontent.com/kehan8/ComputerCraft_Turtle/refs/heads/main/End_Miner/"

local FILES = {
    "end_miner.lua", "state.lua", "logging.lua", "movement.lua", "detour.lua", "fuel.lua",
    "startup.lua", "update.lua", "update_full.lua", "install.lua", "uninstall.lua",
}

local function downloadFile(name)
    -- cache-busting
    local request = http.get(REPO_URL .. name .. "?t=" .. os.epoch("utc"))
    if not request then
        print("Failed to download " .. name)
        return false
    end
    local contents = request.readAll()
    request.close()

    local file = fs.open(name, "w")
    file.write(contents)
    file.close()
    return true
end

for _, name in ipairs(FILES) do
    print("Updating " .. name .. "...")
    downloadFile(name)
end

print("Done. Run 'startup' (or reboot) to play with the new version.")
