local function selectSeed()
    for i = 1, 16 do
        local item = turtle.getItemDetail(i)
        if item and item.name == "minecraft:wheat_seeds" then
            turtle.select(i)
            return true
        end
    end
    return false
end

local SEED_BUFFER_SLOT = 2

local function inventoryIsFull()
    for i = 1, 16 do
        if turtle.getItemCount(i) == 0 then
            return false
        end
    end
    return true
end

local function isContainer(data)
    return data.name == "minecraft:chest"
        or data.name == "minecraft:trapped_chest"
        or data.name == "minecraft:barrel"
end

local function dumpOverflowBack()
    turtle.turnLeft()
    turtle.turnLeft()

    local turns = 0
    local is_block, blockdata = turtle.inspect()
    local found = is_block and isContainer(blockdata)
    while not found and turns < 3 do
        turtle.turnLeft()
        turns = turns + 1
        is_block, blockdata = turtle.inspect()
        found = is_block and isContainer(blockdata)
    end

    if found then
        for i = 1, 16 do
            if i ~= SEED_BUFFER_SLOT and turtle.getItemCount(i) > 0 then
                turtle.select(i)
                turtle.drop()
            end
        end
    else
        print("warning: no chest/barrel found around turtle - overflow dump skipped")
    end

    for _ = 1, turns do
        turtle.turnRight()
    end
    turtle.select(1)
    turtle.turnLeft()
    turtle.turnLeft()
end

turtle.select(1)
homing = false
start = false

while not homing do
    local is_block, blockdata = turtle.inspect()
    if is_block then
        if blockdata.name == "minecraft:wheat" then
            turtle.turnLeft()
            local is_block2, blockdata2 = turtle.inspect()
            if is_block2 then
                if blockdata2.name == "minecraft:wheat" then
                    turtle.turnRight()
                    homing = true
                end
            else
                turtle.turnRight()
                turtle.turnRight()
                homing = true
            end
        else
            print("not found")
            turtle.turnLeft()
        end
    else
        print("not found")
        turtle.turnLeft()
    end
end

while true do
    sleep(0.1)
    local is_top, top_data = turtle.inspectUp()
    local top_present = is_top and isContainer(top_data)
    local is_bottom, bottom_data = turtle.inspectDown()
    local bottom_present = is_bottom and isContainer(bottom_data)
    local chest_above_full = not top_present
    local chest_below_full = not bottom_present

    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then
            turtle.select(i)
            local item = turtle.getItemDetail()
            if item then
                if item.name == "minecraft:wheat" then
                    if top_present and not turtle.dropUp() then
                        chest_above_full = true
                    end
                elseif item.name == "minecraft:wheat_seeds" then
                    if i ~= SEED_BUFFER_SLOT then
                        turtle.transferTo(SEED_BUFFER_SLOT)
                        if turtle.getItemCount(i) > 0 then
                            if bottom_present and not turtle.dropDown() then
                                chest_below_full = true
                            end
                        end
                    end
                else
                    if bottom_present and not turtle.dropDown() then
                        chest_below_full = true
                    end
                end
            end
        end
    end
    turtle.select(1)

    if inventoryIsFull() then
        dumpOverflowBack()
    end

    local chest_is_full = chest_above_full and chest_below_full

    if chest_is_full then
        term.clear()
        term.setCursorPos(1,1)
        print("chest is full - waiting...")
        sleep(2)
    else
        term.clear()
        term.setCursorPos(1,1)
        print("chest has space - farming")

        for side = 1, 4 do
            local is_block, blockdata = turtle.inspect()
            if is_block then
                if blockdata.state.age == 7 then
                    turtle.dig()
                    if selectSeed() then
                        turtle.place()
                    end
                end
            end
            turtle.turnRight()
        end
    end
end
