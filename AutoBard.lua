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
local DISPLAY_CALIBRATION_TIMEOUT = 45
local DISPLAY_NOTE_LIFETIME = 0.45
local DISPLAY_MIN_NOTE_DISTANCE = 32
local DISPLAY_MAX_WINDOW_OFFSET = 32768

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

local function readStoredDisplayAlignment()
	if type(isfile) ~= "function" or type(readfile) ~= "function" then
		return nil
	end

	local ok, content = pcall(function()
		if not isfile(DISPLAY_SETTINGS_FILE) then
			return nil
		end
		return readfile(DISPLAY_SETTINGS_FILE)
	end)
	if not ok or type(content) ~= "string" then
		return nil
	end

	local dpi, offsetX, offsetY, viewportX, viewportY =
		string.match(content, "^%s*(%d+),(%-?%d+),(%-?%d+),(%d+),(%d+)%s*$")
	if dpi == nil then
		dpi = tonumber(content)
		offsetX, offsetY, viewportX, viewportY = 0, 0, 0, 0
	else
		dpi = tonumber(dpi)
		offsetX = tonumber(offsetX)
		offsetY = tonumber(offsetY)
		viewportX = tonumber(viewportX)
		viewportY = tonumber(viewportY)
	end

	if type(dpi) ~= "number" or dpi < REFERENCE_DPI or dpi > REFERENCE_DPI * 5 then
		return nil
	end
	if math.abs(offsetX) > DISPLAY_MAX_WINDOW_OFFSET or math.abs(offsetY) > DISPLAY_MAX_WINDOW_OFFSET then
		return nil
	end
	if viewportX > DISPLAY_MAX_WINDOW_OFFSET or viewportY > DISPLAY_MAX_WINDOW_OFFSET then
		return nil
	end

	return {
		dpi = math.floor(dpi + 0.5),
		offsetX = offsetX,
		offsetY = offsetY,
		viewportX = viewportX,
		viewportY = viewportY,
	}
end

local storedDisplayAlignment = readStoredDisplayAlignment()
if storedDisplayAlignment ~= nil then
	config.windowsDpi = storedDisplayAlignment.dpi
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
	displaySource = storedDisplayAlignment ~= nil and "Saved" or "Default",
	displayStatus = (storedDisplayAlignment ~= nil and "Saved" or "Default") .. " | " .. math.floor(
		config.windowsDpi / REFERENCE_DPI * 100 + 0.5
	) .. "%",
	displayCalibration = nil,
	displayOffsetX = storedDisplayAlignment ~= nil and storedDisplayAlignment.offsetX or 0,
	displayOffsetY = storedDisplayAlignment ~= nil and storedDisplayAlignment.offsetY or 0,
	displayViewportX = storedDisplayAlignment ~= nil and storedDisplayAlignment.viewportX or 0,
	displayViewportY = storedDisplayAlignment ~= nil and storedDisplayAlignment.viewportY or 0,
	lastDisplayViewportCheck = 0,
	displaySavePending = false,
	displaySaveAt = 0,
	syncingDisplayScale = false,
	lastScan = 0,
	lastConfigSync = 0,
	lastUISync = 0,
	playbackElapsed = 0,
	playbackStartedAt = nil,
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
	if state.displayOffsetX ~= 0 or state.displayOffsetY ~= 0 then
		state.displayStatus = state.displayStatus
			.. string.format(" | offset %+d,%+d", state.displayOffsetX, state.displayOffsetY)
	end
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

	setDisplayDpi(dpi, "Custom", true)
end

local function requestDisplayCalibration()
	if state.displayCalibration ~= nil then
		local message = state.displayCalibration.anchor == nil
				and "Click the first Bard note to set the window reference."
			or "Click the center of a different Bard note to finish calibration."
		notify(message, "Display Calibration", 4)
		return
	end

	local wasEnabled = state.enabled
	state.enabled = false
	state.lastEnabled = false
	state.prepared = nil
	state.resolve = nil
	setUIValue("ab_master", false)

	state.displayCalibration = {
		startedAt = tick(),
		lastMouseDown = ismouse1pressed(),
		notes = {},
		firstNote = nil,
		anchor = nil,
		resumeAutoplay = wasEnabled,
	}
	state.displayStatus = "Step 1/2 - start a song"
	setUIValue("ab_cursor_alignment", state.displayStatus)
	notify("Start a song and click the first Bard note, then click another note.", "Display Calibration", 7)
end

local function saveDisplayAlignment(now)
	if not state.displaySavePending or now < state.displaySaveAt then
		return
	end
	state.displaySavePending = false
	if type(writefile) == "function" then
		local alignment = string.format(
			"%d,%d,%d,%d,%d",
			config.windowsDpi,
			state.displayOffsetX,
			state.displayOffsetY,
			state.displayViewportX,
			state.displayViewportY
		)
		pcall(writefile, DISPLAY_SETTINGS_FILE, alignment)
	end
end

local function updateDisplayViewport(now)
	if state.displayCalibration ~= nil or now - state.lastDisplayViewportCheck < 0.5 then
		return
	end
	state.lastDisplayViewportCheck = now

	if state.displayViewportX <= 0 or state.displayViewportY <= 0 then
		return
	end

	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local viewport = camera.ViewportSize
	if viewport == nil or viewport.X <= 0 or viewport.Y <= 0 then
		return
	end
	if viewport.X == state.displayViewportX and viewport.Y == state.displayViewportY then
		return
	end

	state.displayOffsetX = 0
	state.displayOffsetY = 0
	state.displayViewportX = 0
	state.displayViewportY = 0
	setDisplayDpi(config.windowsDpi, "Window changed", true)
	notify("Roblox was resized. Run Detect Display Scale again.", "Display Calibration", 5)
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
	if state.displayCalibration ~= nil then
		return "Display calibration is in progress"
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

local function mapCursorPosition(x, y)
	local scale = config.windowsDpi / REFERENCE_DPI
	return round(x * scale + state.displayOffsetX), round(y * scale + state.displayOffsetY)
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
	local targetX, targetY = mapCursorPosition(viewport.X - margin, margin)

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

	if state.displayCalibration ~= nil then
		state.lastHotkey = hotkeyDown
		state.lastResolveHotkey = resolveDown
		state.lastShift = shiftDown
		return
	end

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
		radius = math.max(buttonSize.X, buttonSize.Y) * 0.5,
		size = math.max(ringSize.X, ringSize.Y),
	}
end

local function finishDisplayCalibration(calibration, alignment, message)
	if state.displayCalibration ~= calibration then
		return
	end

	state.displayCalibration = nil
	if alignment ~= nil then
		state.displayOffsetX = alignment.offsetX
		state.displayOffsetY = alignment.offsetY

		local camera = Workspace.CurrentCamera
		local viewport = camera ~= nil and camera.ViewportSize or nil
		state.displayViewportX = viewport ~= nil and round(viewport.X) or 0
		state.displayViewportY = viewport ~= nil and round(viewport.Y) or 0

		setDisplayDpi(alignment.dpi, "Calibrated", true)
	else
		setDisplayDpi(config.windowsDpi, state.displaySource, false)
	end

	state.enabled = calibration.resumeAutoplay
	state.lastEnabled = state.enabled
	setUIValue("ab_master", state.enabled)
	notify(message, "Display Calibration", alignment ~= nil and 5 or 6)
end

local function collectCalibrationNotes(calibration, now)
	local bardGui = getBardGui()
	if bardGui ~= nil then
		local ok, buttons = pcall(function()
			return bardGui:GetChildren()
		end)
		if ok and type(buttons) == "table" then
			for _, button in ipairs(buttons) do
				local valid, sample = pcall(readNote, button)
				if valid and sample ~= nil then
					sample.seenAt = now
					calibration.notes[sample.key] = sample
					if calibration.anchor == nil and calibration.firstNote == nil then
						calibration.firstNote = sample
					end
				end
			end
		end
	end

	local count = 0
	for key, sample in pairs(calibration.notes) do
		if now - sample.seenAt > DISPLAY_NOTE_LIFETIME then
			calibration.notes[key] = nil
		else
			count = count + 1
		end
	end

	if calibration.anchor == nil and calibration.firstNote ~= nil then
		if calibration.notes[calibration.firstNote.key] == nil then
			calibration.firstNote = nil
		end
	end

	return count
end

local function inferWindowAlignment(calibration, mouseX, mouseY)
	local anchor = calibration.anchor
	if anchor == nil then
		return nil
	end

	local cursorDeltaX = mouseX - anchor.mouseX
	local cursorDeltaY = mouseY - anchor.mouseY
	local currentScale = config.windowsDpi / REFERENCE_DPI
	local bestNote = nil
	local bestScale = nil
	local bestScore = math.huge

	for _, sample in pairs(calibration.notes) do
		if sample.key ~= anchor.key then
			local noteDeltaX = sample.x - anchor.noteX
			local noteDeltaY = sample.y - anchor.noteY
			local distanceSquared = noteDeltaX * noteDeltaX + noteDeltaY * noteDeltaY
			if distanceSquared >= DISPLAY_MIN_NOTE_DISTANCE * DISPLAY_MIN_NOTE_DISTANCE then
				local scale = (cursorDeltaX * noteDeltaX + cursorDeltaY * noteDeltaY) / distanceSquared
				if scale >= 0.9 and scale <= 5.1 then
					local errorX = cursorDeltaX - noteDeltaX * scale
					local errorY = cursorDeltaY - noteDeltaY * scale
					local error = math.sqrt(errorX * errorX + errorY * errorY)
					local tolerance = math.max(18, (anchor.radius + sample.radius) * scale * 0.6)
					if error <= tolerance then
						local score = error + math.abs(scale - currentScale) * 8
						if score < bestScore then
							bestNote = sample
							bestScale = scale
							bestScore = score
						end
					end
				end
			end
		end
	end

	if bestNote == nil or bestScale == nil then
		return nil
	end

	local dpi = math.abs(bestScale - currentScale) <= 0.018 and config.windowsDpi
		or clamp(round(bestScale * REFERENCE_DPI), REFERENCE_DPI, REFERENCE_DPI * 5)
	local scale = dpi / REFERENCE_DPI
	local offsetX = round((anchor.mouseX - anchor.noteX * scale + mouseX - bestNote.x * scale) * 0.5)
	local offsetY = round((anchor.mouseY - anchor.noteY * scale + mouseY - bestNote.y * scale) * 0.5)
	if math.abs(offsetX) > DISPLAY_MAX_WINDOW_OFFSET or math.abs(offsetY) > DISPLAY_MAX_WINDOW_OFFSET then
		return nil
	end

	return { dpi = dpi, offsetX = offsetX, offsetY = offsetY }
end

local function updateGuidedDisplayCalibration(now)
	local calibration = state.displayCalibration
	if calibration == nil then
		return
	end
	if now - calibration.startedAt >= DISPLAY_CALIBRATION_TIMEOUT then
		finishDisplayCalibration(calibration, nil, "Calibration timed out. The previous alignment was kept.")
		return
	end

	local mouseDown = ismouse1pressed()
	local clicked = mouseDown and not calibration.lastMouseDown
	calibration.lastMouseDown = mouseDown
	if not isrbxactive() then
		return
	end

	local noteCount = collectCalibrationNotes(calibration, now)
	if calibration.anchor == nil and calibration.firstNote ~= nil then
		local firstNote = calibration.firstNote
		state.displayStatus = string.format("Step 1/2 - first note at %d,%d", round(firstNote.x), round(firstNote.y))
		setUIValue("ab_cursor_alignment", state.displayStatus)
	end
	if not clicked or noteCount == 0 then
		return
	end

	local player = Players.LocalPlayer
	if player == nil then
		return
	end
	local ok, mouseX, mouseY = pcall(function()
		local mouse = player:GetMouse()
		return mouse.X, mouse.Y
	end)
	if not ok or type(mouseX) ~= "number" or type(mouseY) ~= "number" then
		finishDisplayCalibration(
			calibration,
			nil,
			"Mouse coordinates are unavailable. The previous alignment was kept."
		)
		return
	end

	if calibration.anchor == nil then
		local firstNote = calibration.firstNote
		if firstNote == nil then
			return
		end

		calibration.anchor = {
			key = firstNote.key,
			noteX = firstNote.x,
			noteY = firstNote.y,
			mouseX = mouseX,
			mouseY = mouseY,
			radius = firstNote.radius,
		}
		calibration.notes[firstNote.key] = nil
		state.displayStatus = "Step 2/2 - click a different note"
		setUIValue("ab_cursor_alignment", state.displayStatus)
		notify("First note captured. Click the center of a different Bard note.", "Display Calibration", 5)
		return
	end

	local alignment = inferWindowAlignment(calibration, mouseX, mouseY)
	if alignment == nil then
		state.displayStatus = "Step 2/2 - click a note farther away"
		setUIValue("ab_cursor_alignment", state.displayStatus)
		return
	end

	local percentage = round(alignment.dpi / REFERENCE_DPI * 100)
	local message =
		string.format("Calibrated: %d%% | window offset %+d,%+d.", percentage, alignment.offsetX, alignment.offsetY)
	finishDisplayCalibration(calibration, alignment, message)
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

	local commandX, commandY = mapCursorPosition(sample.x, sample.y)
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
	state.playbackElapsed = 0
	state.playbackStartedAt = state.enabled and tick() or nil
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

	state.displayOffsetX = 0
	state.displayOffsetY = 0
	state.displayViewportX = 0
	state.displayViewportY = 0
	setDisplayDpi(DEFAULT_CONFIG.windowsDpi, "Default", true)
	config.dualScan = DEFAULT_CONFIG.dualScan
	config.debug = DEFAULT_CONFIG.debug
	setUIValue("ab_dual_scan", config.dualScan)
	setUIValue("ab_debug", config.debug)
	log("Settings restored")
	state.lastUISync = 0
end

local function updatePlaybackClock(now)
	if state.enabled then
		if state.playbackStartedAt == nil then
			state.playbackStartedAt = now
		end
		return
	end

	if state.playbackStartedAt ~= nil then
		state.playbackElapsed = state.playbackElapsed + math.max(0, now - state.playbackStartedAt)
		state.playbackStartedAt = nil
	end
end

local function syncStats(now)
	if not state.hasUI or now - state.lastUISync < 0.25 then
		return
	end
	state.lastUISync = now

	local stats = state.stats
	local total = stats.clicks + stats.misses
	local accuracy = total > 0 and stats.clicks / total * 100 or 0
	local elapsed = state.playbackElapsed
	if state.enabled and state.playbackStartedAt ~= nil then
		elapsed = elapsed + math.max(0, now - state.playbackStartedAt)
	end
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
		cursor:Tip("Click the first note, then a different note to calibrate display scale and window position.")

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
	updateDisplayViewport(now)
	updateGuidedDisplayCalibration(now)
	saveDisplayAlignment(now)
	finishResolve(now)
	updatePlaybackClock(now)
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
