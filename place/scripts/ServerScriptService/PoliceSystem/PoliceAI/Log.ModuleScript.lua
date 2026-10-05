--[[
	PoliceAI · Log
	Diagnostic output for major state transitions only. Identical lines inside a short
	window are dropped so nothing spams Output every frame.
]]

local Log = {}
local Tuning
local recent: { [string]: number } = {}
local count = 0

function Log.bind(ctx)
	Tuning = ctx.Tuning
end

local function emit(tag: string, fmt: string?, ...)
	local msg = ""
	if fmt then
		if select("#", ...) > 0 then
			local ok, s = pcall(string.format, fmt, ...)
			msg = if ok then s else fmt
		else
			msg = fmt
		end
	end
	local line = "[PoliceAI] " .. tag .. (if msg ~= "" then " " .. msg else "")
	local now = os.clock()
	local last = recent[line]
	if last and now - last < 1.5 then
		return
	end
	recent[line] = now
	count += 1
	if count > 400 then
		count = 0
		recent = {}
	end
	print(line)
end

-- Major transitions: INCIDENT CREATED, PRIMARY ASSIGNED, LOST VISUAL ...
function Log.event(tag: string, fmt: string?, ...)
	if Tuning and Tuning.Log == false then
		return
	end
	emit(tag, fmt, ...)
end

function Log.verbose(tag: string, fmt: string?, ...)
	if not Tuning or not Tuning.VerboseLog then
		return
	end
	emit(tag, fmt, ...)
end

local warned: { [string]: number } = {}
function Log.warn(where: string, err: any)
	local key = where .. tostring(err)
	local now = os.clock()
	if warned[key] and now - warned[key] < 10 then
		return
	end
	warned[key] = now
	warn("[PoliceAI] " .. where .. " failed (falling back): " .. tostring(err))
end

return Log
