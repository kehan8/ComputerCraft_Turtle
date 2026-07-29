turtle.select(1)
homing = false
start = false

while not homing do
	local is_block, blockdata = turtle.inspect()
	if is_block then
		if blockdata.name == "minecraft:wheat" then
			turtle.turnLeft()
			local is_block, blockdata = turtle.inspect()
			if is_block then
				if blockdata.name == "minecraft:wheat" then
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
		turtle.turnLeft()
	end
end

while true do
sleep(0.1)
local chest_is_full = false

for i = 2, 16 do
	if turtle.getItemCount(i) > 0 then
		turtle.select(i)
		local item = turtle.getItemDetail()
		
		if item then
			if item.name == "minecraft:wheat" then
				if not turtle.dropUp() then
					chest_is_full = true
				end
			elseif item.name == "minecraft:wheat_seeds" then
				if not turtle.transferTo(1) then
					turtle.dropDown()
				end
			else
				turtle.dropDown()
			end
		end
	end
end
turtle.select(1)

if chest_is_full then
	term.clear()
	term.setCursorPos(1,1)
	print("chest is full - waiting...")
	sleep(2)
else
	term.clear()
	term.setCursorPos(1,1)
	print("chest has space - farming")
	local is_block, blockdata = turtle.inspect()
	if is_block then
			if blockdata.state.age == 7 then
				turtle.dig()
				turtle.place() 
			end
	end
	turtle.turnLeft()
	local is_block, blockdata = turtle.inspect()

	if is_block then
		if blockdata.state.age == 7 then
			turtle.dig()
			turtle.place() 
		end
	end
	turtle.turnRight()  
end
end