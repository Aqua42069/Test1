-- Guided camera tour (rewritten to use TweenService instead of Camera:Interpolate).
-- Enabled/disabled by SideMenu.Play/FrameTween when the Tour panel opens/closes.

local tourStops = {
{"Airport", "This is the spawn for Americans and Visitors.\nYou can also buy tickets to visit other US cities inside.", (workspace.AirportSign:GetBoundingBox()) * CFrame.new(30, 30, 0) * CFrame.Angles(0, math.rad(90), 0), CFrame.new(162, 0.4, 728.8)}
, 
{"You Buy Car Now (YBCN)", "This is where you can purchase a car to drive around LV.\nBeware of carjackers though.", CFrame.new(161.2, 47, 242), CFrame.new(74, 4, 338)}
, 
{"Lord Sprayer", "Here you can respray your car, as long as it is a civilian car, for a fee.", CFrame.new(-78.5, 40, 184), CFrame.new(-70, 16.5, 220)}
, 
{"Come Here While I Bomb You", "This garage will allow you to fit bombs to your car, but the flashing light will give you away to the cops.", CFrame.new(844, 27, -489), CFrame.new(844, 22, -505)}
, 
{"Bloodbath & Beyond", "This is the gun shop, you can buy legal firearms from here instead of using the gun dealers around the city.", CFrame.new(1730, 18, 444.6), CFrame.new(1769, 7.5, 444)}
, 
{"Prison Facility", "This is where you will end up if you commit crime. Try to stay out of here.", CFrame.new(-618.2, 94, -2346.1), CFrame.new(-624.9, 83, -2329.6)}
, 
{"Bank", "You will want to start storing your money here for safekeeping. Just be aware that robbing the vault is illegal.", CFrame.new(932.1, 39.9, -2056.9), CFrame.new(917.4, 35.3, -2071.2)}
, 
{"Casino", "This is where you can gamble money assuming you have the appropriate GamePass.", CFrame.new(1336.4, 238, 21), CFrame.new(1179, 6, -305)}
, 
{"Beautique", "Here you can purchase clothing created by a partner of USA.", CFrame.new(1853.7, 13.6, -71.6), CFrame.new(1853.7, 13.6, -79.1)}
, 
{"Hospital", "Here is where you go if you want that edge on the competition, it is where medical staff spawn and where you can purchase medicine.", CFrame.new(1300.1, 107.4, -796.7), CFrame.new(1310.6, 99.6, -818.6)}
, 
{"Gun Dealer", "It is best to avoid these guys if you want to stay on the right side of the law, Jose is 1 of 3 in the city.", CFrame.new(784, 26.5, -166.9), CFrame.new(794.2, 20.1, -166.9)}
, 
{"Estate Agent", "Here you can purchase property to own in the server.\n Houses are kept only until you leave", CFrame.new(616.3, 24.9, -835), CFrame.new(636.4, 15.4, -855.2)}
, 
{"Furniture Shop", "Now that you are going to purchase property, you need something to go in it. Here is the place to get it\n Furniture will save across servers.", CFrame.new(82.3, 15.3, -960.5), CFrame.new(69, 12.6, -960.5)}
, 
{"Ad Agency", "Here is where you can purchase ads to go around the city as long as you have the Advertiser gamepass.", CFrame.new(82.3, 15.3, -1027.7), CFrame.new(69, 12.6, -1027.7)}
, 
{"Street Racer", "You better watch the speed of this guy, he holds the records for all races in Las Vegas. You can challenge him if you have the Street Racer gamepass though.", CFrame.new(1105.5, 27.4, -1499.3), CFrame.new(1107.3, 13.5, -1527.5)}
}

local TweenService = game:GetService("TweenService")
local frame = script.Parent
local currFrame = 1
local tweenInfo = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

local function updateCam(index)
	local stop = tourStops[index]
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	local from = stop[3].Position
	local target = CFrame.lookAt(from, stop[4].Position)
	TweenService:Create(cam, tweenInfo, { CFrame = target }):Play()
	frame.TourPos.Text = stop[1]
	frame.TourDesc.Text = stop[2]
end

frame:WaitForChild("Prev").MouseButton1Click:Connect(function()
	currFrame = (currFrame - 2) % #tourStops + 1
	updateCam(currFrame)
end)
frame:WaitForChild("Next").MouseButton1Click:Connect(function()
	currFrame = currFrame % #tourStops + 1
	updateCam(currFrame)
end)
updateCam(currFrame)
