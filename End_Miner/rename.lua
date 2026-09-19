-- rename.lua: change this computer's label.

local current = os.getComputerLabel() or "(none set)"
print("Current label: " .. current)
io.write("New label (Enter or SKIP = keep it): ")
local input = read() or ""

if input == "" or input:lower() == "skip" then
    print("Kept: " .. current)
else
    os.setComputerLabel(input)
    print("Label set to: " .. input)
end
