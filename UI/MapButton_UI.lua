include("InstanceManager")

local m_MapButtonIM = nil
local m_MapButtonInstances = {}
local m_MapHighlightLayer = nil
local m_MapButtonCloseCallback = nil
local m_MapButtonPlayerID = -1

local function GetMapColorValue(color)
	if type(color) == "number" then
		return color
	end
	if type(color) ~= "table" then
		return UI.GetColorValue(1.0, 0.15, 0.1, 0.35)
	end

	local r = color[1] or 0.0
	local g = color[2] or 0.0
	local b = color[3] or 0.0
	local a = color[4] or 1.0
	if r > 1 or g > 1 or b > 1 or a > 1 then
		r, g, b, a = r / 255.0, g / 255.0, b / 255.0, a / 255.0
	end
	return UI.GetColorValue(r, g, b, a)
end

local function SetLocalizedTooltip(control, text)
	if control == nil or text == nil then
		return
	end
	if type(text) == "string" and string.sub(text, 1, 4) == "LOC_" then
		control:SetToolTipString(Locale.Lookup(text))
	else
		control:SetToolTipString(text)
	end
end

function HideMapButtons()
	if m_MapButtonIM ~= nil then
		for _, instance in pairs(m_MapButtonInstances) do
			if instance ~= nil and instance.ModMiscMapButtonAnchor ~= nil then
				instance.ModMiscMapButtonAnchor:SetHide(true)
				m_MapButtonIM:ReleaseInstance(instance)
			end
		end
	end
	m_MapButtonInstances = {}
	m_MapButtonCloseCallback = nil
	m_MapButtonPlayerID = -1

	if m_MapHighlightLayer ~= nil then
		UILens.ClearLayerHexes(m_MapHighlightLayer)
		if UILens.IsLayerOn(m_MapHighlightLayer) then
			UILens.ToggleLayerOff(m_MapHighlightLayer)
		end
	end

	if Controls.ModMiscMapCloseButton ~= nil then
		Controls.ModMiscMapCloseButton:SetHide(true)
	end
end

function OnModMiscMapCloseButtonClicked()
	local callback = m_MapButtonCloseCallback
	HideMapButtons()
	if callback ~= nil then
		callback()
	end
end

function ShowMapButtons(config)
	if config == nil then
		return
	end

	HideMapButtons()
	if m_MapButtonIM == nil then
		return
	end

	m_MapButtonPlayerID = config.playerID or Game.GetLocalPlayer()
	m_MapButtonCloseCallback = config.onClose

	local buttonSize = config.buttonSize or 128
	local buttons = config.buttons or {}
	local buttonPlotIndexes = {}

	for _, buttonData in ipairs(buttons) do
		local plotIndex = buttonData
		local icon = config.icon
		local callback = config.callback
		local tooltip = config.tooltip
		local size = buttonSize

		if type(buttonData) == "table" then
			plotIndex = buttonData.plotIndex or buttonData[1]
			icon = buttonData.icon or icon
			callback = buttonData.callback or callback
			tooltip = buttonData.tooltip or tooltip
			size = buttonData.size or size
		end

		if plotIndex ~= nil then
			table.insert(buttonPlotIndexes, plotIndex)

			local instance = m_MapButtonIM:GetInstance()
			m_MapButtonInstances[plotIndex] = instance

			local worldX, worldY = UI.GridToWorld(plotIndex)
			instance.ModMiscMapButtonAnchor:SetWorldPositionVal(worldX, worldY, 0)
			instance.ModMiscMapButtonAnchor:SetHide(false)
			instance.ModMiscMapButton:SetHide(false)
			instance.ModMiscMapButton:SetSizeVal(size, size)
			instance.ModMiscMapButtonIcon:SetSizeVal(size, size)

			if icon ~= nil then
				instance.ModMiscMapButtonIcon:SetIcon(icon)
			end
			if tooltip ~= nil then
				SetLocalizedTooltip(instance.ModMiscMapButton, tooltip)
			end

			instance.ModMiscMapButton:ClearCallback(Mouse.eLClick)
			if callback ~= nil then
				instance.ModMiscMapButton:RegisterCallback(Mouse.eLClick, function()
					callback(plotIndex, buttonData)
				end)
			end
		end
	end

	local highlightPlots = config.highlightPlots or buttonPlotIndexes
	if config.highlight ~= false and #highlightPlots > 0 and m_MapHighlightLayer ~= nil then
		UILens.SetLayerHexesArea(
			m_MapHighlightLayer,
			m_MapButtonPlayerID,
			highlightPlots,
			GetMapColorValue(config.highlightColor)
		)
		UILens.ToggleLayerOn(m_MapHighlightLayer)
	end

	if Controls.ModMiscMapCloseButton ~= nil then
		SetLocalizedTooltip(Controls.ModMiscMapCloseButton, config.closeTooltip or "LOC_HUD_CLOSE")
		Controls.ModMiscMapCloseButton:SetHide(false)
	end
end

function IsMapButtonsOpen()
	if next(m_MapButtonInstances) ~= nil then
		return true
	end
	if Controls.ModMiscMapCloseButton ~= nil and not Controls.ModMiscMapCloseButton:IsHidden() then
		return true
	end
	return false
end

local function InitializeMapButtons()
	if Controls.ModMiscMapButtonContainer == nil or Controls.ModMiscMapFullScreenContainer == nil then
		return
	end

	local worldViewControl = ContextPtr:LookUpControl("/InGame/WorldViewControls")
	local inGameControl = ContextPtr:LookUpControl("/InGame")
	if worldViewControl ~= nil then
		Controls.ModMiscMapButtonContainer:ChangeParent(worldViewControl)
	end
	if inGameControl ~= nil then
		Controls.ModMiscMapFullScreenContainer:ChangeParent(inGameControl)
	end

	m_MapButtonIM =
		InstanceManager:new("ModMiscMapButtonInstance", "ModMiscMapButtonAnchor", Controls.ModMiscMapButtonContainer)
	m_MapHighlightLayer = UILens.CreateLensLayerHash("Hex_Coloring_Attack")
	Controls.ModMiscMapCloseButton:RegisterCallback(Mouse.eLClick, OnModMiscMapCloseButtonClicked)
end

function Initialize()
	InitializeMapButtons()
	if not ExposedMembers.ModMiscToolUI then
		ExposedMembers.ModMiscToolUI = {}
	end
	ExposedMembers.ModMiscToolUI.ShowMapButtons = ShowMapButtons
	ExposedMembers.ModMiscToolUI.HideMapButtons = HideMapButtons
	ExposedMembers.ModMiscToolUI.IsMapButtonsOpen = IsMapButtonsOpen
end

Events.LoadGameViewStateDone.Add(Initialize)
