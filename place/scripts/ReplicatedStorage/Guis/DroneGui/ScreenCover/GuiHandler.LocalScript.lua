-- params : ...

script.Parent:WaitForChild("FlightName")
generateSerial = function(length)
  
  local str = ""
  for i = 1, length do
    local number = math.random(2)
    if number == 1 then
      str = str .. string.char(math.random(48, 57))
    else
      str = str .. string.char(math.random(65, 90))
    end
  end
  return str
end

script.Parent.FlightName.Text = "Drone " .. generateSerial(8) .. " Online"
