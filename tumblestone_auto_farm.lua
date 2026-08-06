-- item replant
local TUMBLESTONE_ITEM = {
	["cobblemon:tumblestone"] = true,
	["cobblemon:black_tumblestone"] = true,
	["cobblemon:sky_tumblestone"] = true,
}

-- all growth phases for homing-check
local TUMBLESTONE_STAGES = {
	["cobblemon:small_budding_tumblestone"]			= true,
	["cobblemon:medium_budding_tumblestone"]		= true,
	["cobblemon:large_budding_tumblestone"]			= true,
	["cobblemon:tumblestone_cluster"]				= true,
	["cobblemon:small_budding_black_tumblestone"]	= true,
	["cobblemon:medium_budding_black_tumblestone"]	= true,
	["cobblemon:large_budding_black_tumblestone"]	= true,
	["cobblemon:black_tumblestone_cluster"]			= true,
	["cobblemon:small_budding_sky_tumblestone"]		= true,
	["cobblemon:medium_budding_sky_tumblestone"]	= true,
	["cobblemon:large_budding_sky_tumblestone"]		= true,
	["cobblemon:sky_tumblestone_cluster"]			= true,
}

-- fullgrown tumblestone
local TUMBLESTONE_FULLGROWN = {
	["cobblemon:tumblestone_cluster"] = true,
	["cobblemon:black_tumblestone_cluster"] = true,
	["cobblemon:sky_tumblestone_cluster"] = true,
}

local function selectTumblestone()
	for i = 1, 16 do
		local item = turtle.getItemDetail(i)
		if item and TUMBLESTONE_ITEM[item.name] then
			turtle.select(i)
			return true
		end
	end
	return false
end

turtle.select(1)
homing = false

while not homing do
	local is_block, blockdata = turtle.inspect()
	if is_block then
		if TUMBLESTONE_STAGES[blockdata.name] then
			turtle.turnLeft()
			local is_block2, blockdata2 = turtle.inspect()
			if is_block2 then
				if TUMBLESTONE_STAGES[blockdata2.name] then
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
	local chest_is_full = false

	for i = 1, 16 do
		if turtle.getItemCount(i) > 0 then
			turtle.select(i)
			local item = turtle.getItemDetail()
			if item and TUMBLESTONE_ITEM[item.name] then
				if not turtle.dropUp() then
					chest_is_full = true
				end
			end
		end
	end
	turtle.select(1)

	term.clear()
	term.setCursorPos(1,1)

	if chest_is_full then
		print("chest is full - waiting...")
		sleep(2)
	else
		print("chest has space - mining")
		for side = 1, 4 do
			local is_block, blockdata = turtle.inspect()
			if is_block and TUMBLESTONE_FULLGROWN[blockdata.name] then
				turtle.dig()
				if selectTumblestone() then
					turtle.place()
				end
			end
			turtle.turnRight()
		end
	end
end
