-- Made by Ryuu89

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DEFAULT_TOGGLE_KEY = 0x58
local DEFAULT_RESOLVE_KEY = 0x52
local VK_SHIFT = 0x10
local REFERENCE_DPI = 96
local MIN_RING_SIZE = 125
local RESOLVE_MARGIN = 48
local RESOLVE_SETTLE_DELAY = 0.016
local DISPLAY_SETTINGS_FILE = "AutoBard.display.cfg"

local RUN_TOKEN = {}
_G.__MATCHA_AUTOBARD_RUN_TOKEN = RUN_TOKEN

local previousConnections = _G.__MATCHA_AUTOBARD_CONNECTIONS
if type(previousConnections) ~= "table" then
	previousConnections = { _G.__MATCHA_AUTOBARD_CONNECTION }
end

for _, connection in ipairs(previousConnections) do
	pcall(function()
		connection:Disconnect()
	end)
end

local DEFAULT_CONFIG = {
	threshold = 135,
	settleMs = 20,
	predictionMs = 0,
	prepareMarginPx = 10,
	mouseWigglePx = 3,
	windowsDpi = 130,
	scanIntervalMs = 10,
	cameraGuardMs = 75,
	dualScan = true,
	debug = false,
}

local SETTINGS = {
	{ name = "threshold", id = "ab_outer_threshold", min = MIN_RING_SIZE, max = 180 },
	{ name = "settleMs", id = "ab_settle_ms", min = 0, max = 30 },
	{ name = "mouseWigglePx", id = "ab_mouse_wiggle_px", min = 0, max = 10 },
	{ name = "predictionMs", id = "ab_prediction_ms", min = 0, max = 60 },
	{ name = "prepareMarginPx", id = "ab_prepare_margin", min = 10, max = 100 },
	{ name = "scanIntervalMs", id = "ab_track_ms", min = 0, max = 30 },
	{ name = "cameraGuardMs", id = "ab_camera_guard_ms", min = 0, max = 200 },
}

local config = {}
for key, value in pairs(DEFAULT_CONFIG) do
	config[key] = value
end

local function readStoredDisplayDpi()
	if type(isfile) ~= "function" or type(readfile) ~= "function" then
		return nil
	end

	local ok, value = pcall(function()
		if not isfile(DISPLAY_SETTINGS_FILE) then
			return nil
		end
		return tonumber(readfile(DISPLAY_SETTINGS_FILE))
	end)
	if not ok or type(value) ~= "number" or value < REFERENCE_DPI or value > REFERENCE_DPI * 5 then
		return nil
	end
	return math.floor(value + 0.5)
end

local storedDisplayDpi = readStoredDisplayDpi()
if storedDisplayDpi ~= nil then
	config.windowsDpi = storedDisplayDpi
end

local settingsByName = {}
for _, setting in ipairs(SETTINGS) do
	settingsByName[setting.name] = setting
end

local function newStats()
	return {
		clicks = 0,
		misses = 0,
		lastRingSize = 0,
		totalRingSize = 0,
	}
end

local state = {
	enabled = false,
	resolveEnabled = true,
	lastEnabled = false,
	lastHotkey = false,
	lastResolveHotkey = false,
	lastShift = false,
	hotkeyCode = DEFAULT_TOGGLE_KEY,
	hotkeyName = "X",
	resolveHotkeyCode = DEFAULT_RESOLVE_KEY,
	resolveHotkeyName = "R",
	shiftLockOn = false,
	cameraGuardUntil = 0,
	displaySource = storedDisplayDpi ~= nil and "Saved" or "Default",
	displayStatus = (storedDisplayDpi ~= nil and "Saved" or "Default") .. " | " .. math.floor(
		config.windowsDpi / REFERENCE_DPI * 100 + 0.5
	) .. "%",
	displayLocked = storedDisplayDpi ~= nil,
	displayProbeRequested = true,
	displaySavePending = false,
	displaySaveAt = 0,
	lastDisplayProbe = 0,
	displayWidth = 0,
	displayHeight = 0,
	syncingDisplayScale = false,
	lastScan = 0,
	lastConfigSync = 0,
	lastUISync = 0,
	sessionStartedAt = tick(),
	frameSeconds = 1 / 60,
	scanNumber = 0,
	scanInProgress = false,
	records = {},
	prepared = nil,
	resolve = nil,
	hasUI = UI ~= nil and UI.AddTab ~= nil and UI.GetValue ~= nil and UI.SetValue ~= nil,
	stats = newStats(),
}

local function round(value)
	return math.floor(value + 0.5)
end

local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

local function isCurrentRun()
	return _G.__MATCHA_AUTOBARD_RUN_TOKEN == RUN_TOKEN
end

local function log(message)
	if config.debug then
		print("[AutoBard] " .. message)
	end
end

local function getUIValue(id, default)
	if not state.hasUI then
		return default
	end
	local ok, value = pcall(UI.GetValue, id)
	if not ok or value == nil then
		return default
	end
	return value
end

local function setUIValue(id, value)
	if state.hasUI then
		pcall(UI.SetValue, id, value)
	end
end

local function setDisplayDpi(value, source, persist)
	if type(value) ~= "number" or value ~= value then
		return
	end

	local dpi = clamp(round(value), REFERENCE_DPI, REFERENCE_DPI * 5)
	config.windowsDpi = dpi
	state.displaySource = source
	local percentage = round(dpi / REFERENCE_DPI * 100)
	state.displayStatus = source .. " | " .. percentage .. "%"
	state.syncingDisplayScale = true
	setUIValue("ab_display_scale", percentage)
	state.syncingDisplayScale = false
	setUIValue("ab_cursor_alignment", state.displayStatus)

	if persist then
		state.displaySavePending = true
		state.displaySaveAt = tick() + 0.35
	end
end

local function setManualDisplayScale(value)
	if state.syncingDisplayScale or type(value) ~= "number" then
		return
	end

	local percentage = clamp(round(value), 100, 500)
	local dpi = round(percentage * REFERENCE_DPI / 100)
	if dpi == config.windowsDpi then
		return
	end

	state.displayLocked = true
	state.displayProbeRequested = false
	setDisplayDpi(dpi, "Custom", true)
end

local function dpiFromDimensions(physicalX, physicalY, logicalX, logicalY)
	if type(physicalX) ~= "number" or type(physicalY) ~= "number" then
		return nil
	end
	if type(logicalX) ~= "number" or type(logicalY) ~= "number" or logicalX <= 0 or logicalY <= 0 then
		return nil
	end

	local scaleX = physicalX / logicalX
	local scaleY = physicalY / logicalY
	if scaleX < 0.95 or scaleX > 5.05 or scaleY < 0.90 or scaleY > 5.05 then
		return nil
	end
	if math.abs(scaleX - scaleY) > math.max(0.08, scaleX * 0.10) then
		return nil
	end
	if scaleX < 1.08 then
		return nil
	end
	return round(clamp(scaleX, 1, 5) * REFERENCE_DPI)
end

local function readNativeDisplayDpi()
	for _, name in ipairs({ "getwindowdpi", "getdisplaydpi", "getwindowsdpi", "getdpi" }) do
		local provider = _G[name]
		if type(provider) == "function" then
			local ok, value = pcall(provider)
			if ok and type(value) == "number" and value >= REFERENCE_DPI and value <= REFERENCE_DPI * 5 then
				return round(value)
			end
		end
	end

	for _, name in ipairs({ "getdisplayscale", "getwindowscale", "getdpiscale" }) do
		local provider = _G[name]
		if type(provider) == "function" then
			local ok, value = pcall(provider)
			if ok and type(value) == "number" then
				local factor = value <= 5 and value or value / 100
				if factor >= 1 and factor <= 5 then
					return round(factor * REFERENCE_DPI)
				end
			end
		end
	end
	return nil
end

local function readDisplayResolution(provider)
	if type(provider) ~= "function" then
		return nil, nil
	end
	local ok, first, second = pcall(provider)
	if not ok then
		return nil, nil
	end
	if type(first) == "number" and type(second) == "number" then
		return first, second
	end
	local valid, x, y = pcall(function()
		return first.X, first.Y
	end)
	if valid and type(x) == "number" and type(y) == "number" then
		return x, y
	end
	return nil, nil
end

local function inferDisplayDpi(viewport)
	local dpi = readNativeDisplayDpi()
	if dpi ~= nil then
		return dpi
	end

	for _, name in ipairs({ "getscreenresolution", "getdisplayresolution", "getscreensize", "getresolution" }) do
		local width, height = readDisplayResolution(_G[name])
		dpi = dpiFromDimensions(width, height, viewport.X, viewport.Y)
		if dpi ~= nil then
			return dpi
		end
	end

	local player = Players.LocalPlayer
	if player == nil then
		return nil
	end

	local mouseOk, mouseWidth, mouseHeight = pcall(function()
		local mouse = player:GetMouse()
		return mouse.ViewSizeX, mouse.ViewSizeY
	end)
	if mouseOk then
		dpi = dpiFromDimensions(mouseWidth, mouseHeight, viewport.X, viewport.Y)
		if dpi ~= nil then
			return dpi
		end
	end

	local guiOk, guiWidth, guiHeight = pcall(function()
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if playerGui == nil then
			return nil, nil
		end
		local bardGui = playerGui:FindFirstChild("BardGui")
		if bardGui == nil then
			return nil, nil
		end
		local size = bardGui.AbsoluteSize
		return size.X, size.Y
	end)
	if guiOk then
		dpi = dpiFromDimensions(viewport.X, viewport.Y, guiWidth, guiHeight)
		if dpi ~= nil then
			return dpi
		end
		if mouseOk then
			return dpiFromDimensions(mouseWidth, mouseHeight, guiWidth, guiHeight)
		end
	end

	return nil
end

local function requestDisplayCalibration()
	state.displayLocked = false
	state.displayProbeRequested = true
	state.lastDisplayProbe = 0
	state.displayStatus = "Checking display scale"
	setUIValue("ab_cursor_alignment", state.displayStatus)
end

local function updateDisplayAlignment(now)
	if now - state.lastDisplayProbe < 0.5 then
		return
	end
	state.lastDisplayProbe = now

	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local viewport = camera.ViewportSize
	if viewport == nil or viewport.X <= 0 or viewport.Y <= 0 then
		return
	end

	local resized = state.displayWidth ~= viewport.X or state.displayHeight ~= viewport.Y
	state.displayWidth = viewport.X
	state.displayHeight = viewport.Y
	if not state.displayProbeRequested and (not resized or state.displayLocked) then
		return
	end
	if state.displayLocked then
		state.displayProbeRequested = false
		return
	end

	state.displayProbeRequested = false
	local dpi = inferDisplayDpi(viewport)
	if dpi ~= nil then
		setDisplayDpi(dpi, "Automatic", true)
		log("Display scale detected: " .. tostring(dpi) .. " DPI")
		return
	end

	setDisplayDpi(config.windowsDpi, state.displaySource, false)
	log("Display DPI unavailable; keeping the working cursor alignment")
end

local function saveDisplayAlignment(now)
	if not state.displaySavePending or now < state.displaySaveAt then
		return
	end
	state.displaySavePending = false
	if type(writefile) == "function" then
		pcall(writefile, DISPLAY_SETTINGS_FILE, tostring(config.windowsDpi))
	end
end

local function setNumber(name, value, minimum, maximum)
	if type(value) ~= "number" then
		return
	end
	local normalized = clamp(round(value), minimum, maximum)
	if config[name] ~= normalized then
		config[name] = normalized
		state.lastUISync = 0
	end
end

local function addSlider(section, name, label)
	local setting = settingsByName[name]
	section:SliderInt(setting.id, label, setting.min, setting.max, DEFAULT_CONFIG[name], function(value)
		setNumber(name, value, setting.min, setting.max)
	end)
end

local function syncSettings(now)
	if not state.hasUI or now - state.lastConfigSync < 0.05 then
		return
	end
	state.lastConfigSync = now

	local enabled = getUIValue("ab_master", state.enabled)
	if type(enabled) == "boolean" then
		state.enabled = enabled
	end

	local shiftLock = getUIValue("ab_shiftlock", state.shiftLockOn)
	if type(shiftLock) == "boolean" then
		state.shiftLockOn = shiftLock
	end

	local resolveEnabled = getUIValue("ab_resolve_enabled", state.resolveEnabled)
	if type(resolveEnabled) == "boolean" then
		state.resolveEnabled = resolveEnabled
	end

	for _, setting in ipairs(SETTINGS) do
		local value = getUIValue(setting.id, config[setting.name])
		setNumber(setting.name, value, setting.min, setting.max)
	end

	setManualDisplayScale(getUIValue("ab_display_scale", nil))

	local dualScan = getUIValue("ab_dual_scan", config.dualScan)
	if type(dualScan) == "boolean" then
		config.dualScan = dualScan
	end

	local debug = getUIValue("ab_debug", config.debug)
	if type(debug) == "boolean" then
		config.debug = debug
	end
end

local function updateHotkey(keybind, codeField, nameField, lastField)
	if keybind == nil then
		return
	end

	local okCode, keyCode = pcall(function()
		return keybind:GetKey()
	end)
	if okCode and type(keyCode) == "number" and keyCode >= 0 and keyCode <= 255 and state[codeField] ~= keyCode then
		state[codeField] = keyCode
		state[lastField] = keyCode > 0 and iskeypressed(keyCode) or false
		state.lastUISync = 0
	end

	local okName, keyName = pcall(function()
		return keybind:GetKeyName()
	end)
	if okName and type(keyName) == "string" and keyName ~= "" then
		state[nameField] = string.upper(keyName)
	elseif state[codeField] == 0 then
		state[nameField] = "UNBOUND"
	end
end

local function armCameraGuard()
	state.cameraGuardUntil = math.max(state.cameraGuardUntil, tick() + config.cameraGuardMs / 1000)
end

local function cancelPendingInput(reason)
	if state.prepared == nil then
		return
	end

	state.prepared = nil
	log("Pending cursor action canceled: " .. reason)
end

local function resolveBlockReason()
	if not isCurrentRun() then
		return "Script is no longer active"
	end
	if not state.resolveEnabled then
		return "Resolve is disabled"
	end
	if not isrbxactive() then
		return "Roblox is not focused"
	end
	if ismouse2pressed() then
		return "Right mouse button is already held"
	end
	if iskeypressed(VK_SHIFT) or state.shiftLockOn then
		return "Shift Lock is active"
	end
	return nil
end

local function cancelResolve(reason)
	state.resolve = nil
	armCameraGuard()
	log("Resolve canceled: " .. reason)
end

local function startResolve()
	if state.resolve ~= nil then
		return false
	end

	local reason = resolveBlockReason()
	if reason ~= nil then
		log("Resolve unavailable: " .. reason)
		return false
	end

	local camera = Workspace.CurrentCamera
	if camera == nil then
		log("Resolve unavailable: camera not found")
		return false
	end

	local viewport = camera.ViewportSize
	if viewport == nil or viewport.X <= 0 or viewport.Y <= 0 then
		log("Resolve unavailable: invalid viewport")
		return false
	end

	local maxMargin = math.max(1, math.floor(math.min(viewport.X, viewport.Y) / 2))
	local margin = clamp(RESOLVE_MARGIN, 1, maxMargin)
	local scale = config.windowsDpi / REFERENCE_DPI
	local targetX = round((viewport.X - margin) * scale)
	local targetY = round(margin * scale)

	cancelPendingInput("Casting Resolve")
	state.resolve = { readyAt = tick(), x = targetX, y = targetY }

	setrobloxinput(true)
	reason = resolveBlockReason()
	if reason ~= nil then
		cancelResolve(reason)
		return false
	end
	mousemoveabs(targetX, targetY)

	reason = resolveBlockReason()
	if reason ~= nil then
		cancelResolve(reason)
		return false
	end
	mousemoverel(-1, 0)

	state.resolve.readyAt = tick() + RESOLVE_SETTLE_DELAY
	return true
end

local function finishResolve(now)
	local resolve = state.resolve
	if resolve == nil or now < resolve.readyAt then
		return
	end

	local reason = resolveBlockReason()
	if reason ~= nil then
		cancelResolve(reason)
		return
	end

	mouse2click()
	state.resolve = nil
	armCameraGuard()
	log("Resolve used at " .. resolve.x .. ", " .. resolve.y)
end

local function updateKeys()
	local hotkeyDown = state.hotkeyCode > 0 and iskeypressed(state.hotkeyCode) or false
	local resolveDown = state.resolveHotkeyCode > 0 and iskeypressed(state.resolveHotkeyCode) or false
	local shiftDown = iskeypressed(VK_SHIFT)
	local rmbDown = ismouse2pressed()

	if not isrbxactive() then
		armCameraGuard()
		cancelPendingInput("Roblox is not focused")
		state.lastHotkey = hotkeyDown
		state.lastResolveHotkey = resolveDown
		state.lastShift = shiftDown
		return
	end

	if rmbDown or shiftDown then
		armCameraGuard()
		cancelPendingInput(rmbDown and "Right mouse button held" or "Shift key held")
	end

	if hotkeyDown and not state.lastHotkey then
		state.enabled = not state.enabled
		setUIValue("ab_master", state.enabled)
	end
	state.lastHotkey = hotkeyDown

	if shiftDown and not state.lastShift then
		state.shiftLockOn = not state.shiftLockOn
		setUIValue("ab_shiftlock", state.shiftLockOn)
	end
	state.lastShift = shiftDown

	if resolveDown and not state.lastResolveHotkey then
		startResolve()
	end
	state.lastResolveHotkey = resolveDown
end

local function pauseReason()
	if not isrbxactive() then
		armCameraGuard()
		return "Roblox is not focused"
	end
	if state.resolve ~= nil then
		return "Casting Resolve"
	end
	if ismouse2pressed() then
		armCameraGuard()
		return "Right mouse button held"
	end
	if iskeypressed(VK_SHIFT) then
		armCameraGuard()
		return "Shift key held"
	end
	if state.shiftLockOn then
		return "Shift Lock is active"
	end
	if tick() < state.cameraGuardUntil then
		return "Camera input is settling"
	end
	return nil
end

local function canSendInput()
	if not isCurrentRun() or not state.enabled then
		cancelPendingInput("Auto Play is unavailable")
		return false
	end

	local reason = pauseReason()
	if reason ~= nil then
		cancelPendingInput(reason)
		return false
	end

	return true
end

local function getBardGui()
	local player = Players.LocalPlayer
	if player == nil then
		return nil
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		return nil
	end
	return playerGui:FindFirstChild("BardGui")
end

local function readNote(button)
	if button.Name ~= "Button" or button.ClassName ~= "ImageButton" or button.Visible == false then
		return nil
	end

	local ring = button:FindFirstChild("OuterRing")
	if ring == nil or ring.ClassName ~= "ImageLabel" or ring.Visible == false then
		return nil
	end

	local address = button.Address
	local position = button.AbsolutePosition
	local buttonSize = button.AbsoluteSize
	local ringSize = ring.AbsoluteSize
	if address == nil or position == nil or buttonSize == nil or ringSize == nil then
		return nil
	end

	return {
		key = tostring(address),
		x = position.X + buttonSize.X * 0.5,
		y = position.Y + buttonSize.Y * 0.5,
		size = math.max(ringSize.X, ringSize.Y),
	}
end

local function updateVelocity(record, sample, now)
	if record.lastSize == nil then
		record.lastSize = sample.size
		record.lastSizeTime = now
		return
	end

	local difference = record.lastSize - sample.size
	if math.abs(difference) <= 0.02 then
		return
	end

	local elapsed = now - record.lastSizeTime
	if difference > 0 and elapsed > 0.0005 then
		local instantVelocity = difference / elapsed
		if instantVelocity > 0 and instantVelocity < 10000 then
			record.velocity = record.velocity == nil and instantVelocity
				or record.velocity * 0.35 + instantVelocity * 0.65
		end
	elseif difference < -3 then
		record.clicked = false
		record.velocity = nil
	end

	record.lastSize = sample.size
	record.lastSizeTime = now
end

local function estimateArrival(sample)
	if sample.size <= config.threshold then
		return 0
	end
	if sample.velocity ~= nil and sample.velocity > 0 then
		return (sample.size - config.threshold) / sample.velocity
	end
	return math.huge
end

local function prepareCursor(sample)
	if not canSendInput() then
		return false
	end

	local scale = config.windowsDpi / REFERENCE_DPI
	local commandX = round(sample.x * scale)
	local commandY = round(sample.y * scale)
	local wiggle = config.mouseWigglePx

	setrobloxinput(true)
	if not canSendInput() then
		return false
	end
	mousemoveabs(commandX, commandY)

	if wiggle > 0 then
		if not canSendInput() then
			return false
		end
		mousemoverel(wiggle, 0)
	end

	if not canSendInput() then
		return false
	end

	local now = tick()
	state.prepared = {
		key = sample.key,
		readyAt = now + config.settleMs / 1000,
		lastWiggle = now,
		wiggleDirection = 1,
	}
	log("Cursor prepared at " .. commandX .. ", " .. commandY .. " | hover motion=" .. wiggle .. " px")
	return true
end

local function refreshHover()
	if not canSendInput() then
		return false
	end

	local prepared = state.prepared
	local wiggle = config.mouseWigglePx
	if prepared == nil or wiggle <= 0 then
		return true
	end

	local now = tick()
	if now - prepared.lastWiggle < 0.008 then
		return true
	end

	if not canSendInput() then
		return false
	end
	prepared.wiggleDirection = -prepared.wiggleDirection
	mousemoverel(prepared.wiggleDirection * wiggle, 0)
	prepared.lastWiggle = now
	return true
end

local function clickNote(sample)
	if not canSendInput() then
		return false
	end

	mouse1click()
	local record = state.records[sample.key]
	if record ~= nil then
		record.clicked = true
	end
	state.prepared = nil
	state.stats.clicks = state.stats.clicks + 1
	state.stats.lastRingSize = sample.size
	state.stats.totalRingSize = state.stats.totalRingSize + sample.size
	log(
		string.format(
			"Clicked %d/%d px at %d, %d",
			round(sample.size),
			config.threshold,
			round(sample.x),
			round(sample.y)
		)
	)
	return true
end

local function compareNotes(left, right)
	local leftDue = left.size <= config.threshold
	local rightDue = right.size <= config.threshold
	if leftDue ~= rightDue then
		return leftDue
	end
	if leftDue then
		return left.size < right.size
	end
	local leftArrival = estimateArrival(left)
	local rightArrival = estimateArrival(right)
	if leftArrival ~= rightArrival then
		return leftArrival < rightArrival
	end
	return left.size < right.size
end

local function processNotes(samples)
	if #samples == 0 then
		state.prepared = nil
		return
	end
	if not canSendInput() then
		return
	end

	if #samples > 1 then
		table.sort(samples, compareNotes)
	end
	for _, sample in ipairs(samples) do
		if not canSendInput() then
			return
		end

		local record = state.records[sample.key]
		if record ~= nil and not record.clicked and sample.size >= MIN_RING_SIZE then
			if sample.size <= config.threshold then
				if state.prepared == nil or state.prepared.key ~= sample.key then
					if not prepareCursor(sample) then
						return
					end
				end

				local prepared = state.prepared
				if prepared == nil then
					return
				end
				if tick() >= prepared.readyAt then
					clickNote(sample)
				else
					refreshHover()
					return
				end
			elseif state.prepared == nil then
				local arrival = estimateArrival(sample)
				local preparationWindow = (config.settleMs + config.predictionMs) / 1000 + state.frameSeconds
				local withinMargin = sample.size <= config.threshold + config.prepareMarginPx
				if (arrival <= preparationWindow or withinMargin) and not prepareCursor(sample) then
					return
				end
			elseif state.prepared.key == sample.key and not refreshHover() then
				return
			end
		end
	end
end

local function scanNotes(now)
	local bardGui = getBardGui()
	if bardGui == nil then
		state.prepared = nil
		if next(state.records) ~= nil then
			state.records = {}
		end
		return
	end

	state.scanNumber = state.scanNumber + 1
	local scanNumber = state.scanNumber
	local samples = {}

	for _, button in ipairs(bardGui:GetChildren()) do
		local ok, sample = pcall(readNote, button)
		if ok and sample ~= nil then
			local record = state.records[sample.key]
			if record == nil then
				record = { clicked = false }
				state.records[sample.key] = record
			end

			record.scanNumber = scanNumber
			updateVelocity(record, sample, now)
			sample.velocity = record.velocity
			if not record.clicked then
				samples[#samples + 1] = sample
			end
		end
	end

	for key, record in pairs(state.records) do
		if record.scanNumber ~= scanNumber then
			if not record.clicked then
				state.stats.misses = state.stats.misses + 1
			end
			state.records[key] = nil
			if state.prepared ~= nil and state.prepared.key == key then
				state.prepared = nil
			end
		end
	end

	if canSendInput() then
		processNotes(samples)
	end
end

local function resetStats()
	state.sessionStartedAt = tick()
	state.stats = newStats()
	state.records = {}
	state.prepared = nil
	log("Statistics reset")
	state.lastUISync = 0
end

local function restoreDefaults()
	for _, setting in ipairs(SETTINGS) do
		local value = DEFAULT_CONFIG[setting.name]
		setNumber(setting.name, value, setting.min, setting.max)
		setUIValue(setting.id, value)
	end

	setDisplayDpi(DEFAULT_CONFIG.windowsDpi, "Default", true)
	state.displayLocked = false
	state.displayProbeRequested = true
	config.dualScan = DEFAULT_CONFIG.dualScan
	config.debug = DEFAULT_CONFIG.debug
	setUIValue("ab_dual_scan", config.dualScan)
	setUIValue("ab_debug", config.debug)
	log("Settings restored")
	state.lastUISync = 0
end

local function syncStats(now)
	if not state.hasUI or now - state.lastUISync < 0.25 then
		return
	end
	state.lastUISync = now

	local stats = state.stats
	local total = stats.clicks + stats.misses
	local accuracy = total > 0 and stats.clicks / total * 100 or 0
	local elapsed = math.max(0, now - state.sessionStartedAt)
	local notesPerMinute = elapsed > 0 and stats.clicks / elapsed * 60 or 0
	local errors = stats.misses == 1 and "error" or "errors"
	local timing = "No notes clicked yet"

	if stats.clicks > 0 then
		timing = string.format(
			"Last: %d px | Average: %.1f px",
			round(stats.lastRingSize),
			stats.totalRingSize / stats.clicks
		)
	end

	setUIValue("ab_accuracy", string.format("%.1f%% | %d %s", accuracy, stats.misses, errors))
	setUIValue("ab_completion_rate", string.format("%d / %d | %.1f notes/min", stats.clicks, total, notesPerMinute))
	setUIValue("ab_ring_timing", timing)
	setUIValue("ab_cursor_alignment", state.displayStatus)
end

local function scanFrame(now)
	if not state.enabled then
		cancelPendingInput("Auto Play is disabled")
		return
	end
	if state.scanInProgress then
		return
	end
	if not canSendInput() then
		return
	end

	local scanInterval = config.scanIntervalMs / 1000
	if scanInterval > 0 and now - state.lastScan < scanInterval then
		return
	end
	state.lastScan = now
	state.scanInProgress = true
	local ok, errorMessage = pcall(scanNotes, now)
	state.scanInProgress = false
	if not ok then
		log("Note scan failed: " .. tostring(errorMessage))
	end
end

if state.hasUI then
	UI.AddTab("Auto Bard", function(tab)
		local playback = tab:Section("Playback", "Left")
		playback:Toggle("ab_master", "AutoPlay", false, function(enabled)
			state.enabled = enabled == true
			if not state.enabled then
				cancelPendingInput("Auto Play is disabled")
			end
		end)
		local hotkey = playback:Keybind("ab_toggle_hotkey", DEFAULT_TOGGLE_KEY, "toggle")
		updateHotkey(hotkey, "hotkeyCode", "hotkeyName", "lastHotkey")
		playback:Tip("Choose the key used to toggle autoplay.")
		playback:Toggle("ab_shiftlock", "Shift Lock Active", false, function(enabled)
			state.shiftLockOn = enabled == true
			if state.shiftLockOn then
				armCameraGuard()
				cancelPendingInput("Shift Lock is active")
			end
		end)
		playback:Tip("Autoplay pauses while Shift Lock is active.")
		addSlider(playback, "cameraGuardMs", "Camera Safety Delay (ms)")
		playback:Tip("Wait before resuming after camera movement.")

		local timing = tab:Section("Timing", "Left")
		addSlider(timing, "threshold", "Hit Window (px)")
		timing:Tip("Click when the outer ring reaches this size.")
		addSlider(timing, "settleMs", "Cursor Settle Time (ms)")
		timing:Tip("Give Roblox time to recognize the cursor.")
		addSlider(timing, "predictionMs", "Aim Lead Time (ms)")
		addSlider(timing, "prepareMarginPx", "Pre-Aim Distance (px)")

		local cursor = tab:Section("Cursor & Display", "Left")
		addSlider(cursor, "mouseWigglePx", "Hover Movement (px)")
		cursor:Tip("Small movement makes notes register under the cursor.")
		cursor:SliderInt(
			"ab_display_scale",
			"Display Scale (%)",
			100,
			500,
			round(config.windowsDpi / REFERENCE_DPI * 100),
			setManualDisplayScale
		)
		cursor:Tip("Match Windows Settings > System > Display > Scale. Saved automatically.")
		cursor:InputText("ab_cursor_alignment", "Cursor Alignment", state.displayStatus)
		cursor:Button("Detect Display Scale", requestDisplayCalibration)
		cursor:Tip("Keeps the current setting when no reliable display data is available.")

		local detection = tab:Section("Performance", "Right")
		addSlider(detection, "scanIntervalMs", "Scan Interval (ms)")
		detection:Tip("Lower values scan more often; 0 scans every frame.")
		detection:Toggle("ab_dual_scan", "Dual-Phase Scan", DEFAULT_CONFIG.dualScan, function(enabled)
			config.dualScan = enabled == true
		end)
		detection:Tip("Check notes during both render and heartbeat frames.")
		detection:Toggle("ab_debug", "Debug Logging", DEFAULT_CONFIG.debug, function(enabled)
			config.debug = enabled == true
		end)

		local resolve = tab:Section("Resolve", "Right")
		resolve:Toggle("ab_resolve_enabled", "Resolve", true, function(enabled)
			state.resolveEnabled = enabled == true
			if not state.resolveEnabled and state.resolve ~= nil then
				cancelResolve("Resolve is disabled")
			end
		end)
		local resolveHotkey = resolve:Keybind("ab_resolve_hotkey", DEFAULT_RESOLVE_KEY, "toggle")
		updateHotkey(resolveHotkey, "resolveHotkeyCode", "resolveHotkeyName", "lastResolveHotkey")

		local summary = tab:Section("Statistics", "Right")
		summary:InputText("ab_accuracy", "Accuracy / Errors", "0.0% | 0 errors")
		summary:InputText("ab_completion_rate", "Completion", "0 / 0 | 0.0 notes/min")
		summary:InputText("ab_ring_timing", "Click Timing", "No notes clicked yet")
		summary:Button("Reset Statistics", resetStats)
		summary:Button("Restore Defaults", restoreDefaults)
		summary:Text("Made by Ryuu89")
	end)
else
	warn("[AutoBard] Matcha UI Binding is unavailable; the default X hotkey remains active.")
end
notify(
	"Auto Bard v1.0.0 by Ryuu89 is ready. Toggle: " .. state.hotkeyName .. " | Resolve: " .. state.resolveHotkeyName,
	"Auto Bard",
	4
)

local renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
	if not isCurrentRun() then
		return
	end

	local now = tick()
	if type(deltaTime) == "number" and deltaTime > 0 and deltaTime < 0.2 then
		state.frameSeconds = state.frameSeconds * 0.7 + deltaTime * 0.3
	end

	updateKeys()
	syncSettings(now)
	updateDisplayAlignment(now)
	saveDisplayAlignment(now)
	finishResolve(now)
	if state.enabled ~= state.lastEnabled then
		state.lastEnabled = state.enabled
		if not state.enabled then
			state.prepared = nil
			state.records = {}
		end
		notify(state.enabled and "Auto Play enabled" or "Auto Play disabled", "Auto Bard", 2)
	end

	syncStats(now)
	scanFrame(now)
end)

local heartbeatConnection = RunService.Heartbeat:Connect(function()
	if not isCurrentRun() then
		return
	end

	local now = tick()
	finishResolve(now)
	if config.dualScan and state.enabled then
		scanFrame(now)
	end
end)

_G.__MATCHA_AUTOBARD_CONNECTION = renderConnection
_G.__MATCHA_AUTOBARD_CONNECTIONS = { renderConnection, heartbeatConnection }
