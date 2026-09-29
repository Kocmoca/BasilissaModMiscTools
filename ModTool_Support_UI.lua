include("PopupDialog")

--functions listedd below only works in UI

function GetBuildingsIndexAtPlotUI(iX, iY)
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return {} end
	local city = Cities.GetPlotPurchaseCity(plot)
	if city == nil then return {} end
	local cityBuildings = city:GetBuildings()
	if cityBuildings == nil then return {} end
	local plotId = plot:GetIndex()
	local buildingTypes = cityBuildings:GetBuildingsAtLocation(plotId)
	return buildingTypes
end

function GetGreatWorksNum(playerID, cityID, buildingIndex)
	local city = CityManager.GetCity(playerID, cityID)
	local cityBuildings = city:GetBuildings()
	local numSlots = cityBuildings:GetNumGreatWorkSlots(buildingIndex)
	local count = 0
	for index = 0, numSlots - 1 do
		local gwIndex = cityBuildings:GetGreatWorkInSlot(buildingIndex, index)
		if gwIndex ~= -1 then
			count = count + 1
		end
	end
	return count
end

function IsPlotUnderSiege(iX, iY)
    local districyObj = CityManager.GetDistrictAt(iX, iY)
	if districyObj == nil then return false end
	if districyObj:IsUnderSiege() then
		return true
	end
	return false
end

function RequestUnitWMDsOperationUI(playerID, unitID, wmdIndex, targetX, targetY)
	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil or unit:GetDamage() >= 100 then return end
	local tParameters = {}
	tParameters[UnitOperationTypes.PARAM_X] = targetX
	tParameters[UnitOperationTypes.PARAM_Y] = targetY
	tParameters[UnitOperationTypes.PARAM_WMD_TYPE] = wmdIndex
	UnitManager.RequestOperation(unit, UnitOperationTypes.WMD_STRIKE, tParameters)
end

function RequestRangedAttack(playerID, unitID, plotX, plotY)
	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil then return end
	local unitIndex = unit:GetUnitType()
	local tParameters = {}
	tParameters[UnitOperationTypes.PARAM_X] = plotX
	tParameters[UnitOperationTypes.PARAM_Y] = plotY
	tParameters[UnitOperationTypes.PARAM_MODIFIERS] = UnitOperationMoveModifiers.NONE
	if GameInfo.Units[unitIndex].Domain == "DOMAIN_AIR" then
		UnitManager.RequestOperation(unit, UnitOperationTypes.AIR_ATTACK, tParameters)
	else
		UnitManager.RequestOperation(unit, UnitOperationTypes.RANGE_ATTACK, tParameters)
	end
end

function RequestCityDestroyOperationUI(playerID, cityID, command)
	local city = CityManager.GetCity(playerID, cityID)
    if city == nil then return end
    local tParameters = {}
	local convertion = {}
	convertion['return_previous'] = CityDestroyDirectives.LIBERATE_PREVIOUS_OWNER
	convertion['return_founder'] = CityDestroyDirectives.LIBERATE_FOUNDER
	convertion['keep'] = CityDestroyDirectives.KEEP
	convertion['raze'] = CityDestroyDirectives.RAZE
	if command == nil or command == '' then command = 'keep' end
	local action = convertion[command]
	if action == nil then action = CityDestroyDirectives.KEEP end
	tParameters[UnitOperationTypes.PARAM_FLAGS] = action
	CityManager.RequestCommand( city, CityCommandTypes.DESTROY, tParameters)
end

function RequestPlayerPeaceUI(player1ID, player2ID)
	local localPlayerID = Game.GetLocalPlayer()
	-- print('RequestPlayerPeaceUI called: player1=', player1ID, 'player2=', player2ID, 'localPlayer=', localPlayerID)

	local parameters = {}
	parameters[ PlayerOperations.PARAM_PLAYER_ONE ] = player1ID
	parameters[ PlayerOperations.PARAM_PLAYER_TWO ] = player2ID

	-- print('RequestPlayerPeaceUI: RequestPlayerOperation localPlayerID=', localPlayerID,
	-- 	'operation=', PlayerOperations.DIPLOMACY_MAKE_PEACE,
	-- 	'paramOne=', parameters[ PlayerOperations.PARAM_PLAYER_ONE ],
	-- 	'paramTwo=', parameters[ PlayerOperations.PARAM_PLAYER_TWO ])

	local success, err = pcall(function()
		UI.RequestPlayerOperation(localPlayerID, PlayerOperations.DIPLOMACY_MAKE_PEACE, parameters)
	end)
	-- print('RequestPlayerPeaceUI: RequestPlayerOperation result success=', success, 'err=', err)
end

function GetCityProductionHashUI(playerID, cityID)
    local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return 0 end
	local productionHash = city:GetBuildQueue():GetCurrentProductionTypeHash()
	return productionHash
end

function GetCityFreePower(playerID, cityID)
    local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return 0 end
	local cityPower = city:GetPower()
	local freePower = cityPower:GetFreePower()
	return freePower
end

function GetCityTemporaryPower(playerID, cityID)
    local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return 0 end
	local cityPower = city:GetPower()
	local temporaryPower = cityPower:GetTemporaryPower()
	return temporaryPower
end

function GetCityRequiredPower(playerID, cityID)
    local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return 0 end
	local cityPower = city:GetPower()
	local requiredPower = cityPower:GetRequiredPower()
	return requiredPower
end

function AddPlayerToTeam(playerID, teamID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return end
	local civilizationLevel = playerConfig:GetCivilizationLevelTypeID()
	if civilizationLevel ~= CivilizationLevelTypes.CIVILIZATION_LEVEL_FULL_CIV then return end
	playerConfig:SetTeam(teamID)
	--print('team set', playerID, teamID, playerConfig:GetTeam(), Players[playerID]:GetTeam())
end

function GetPlayerTeam(playerID)
    local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return nil end
	local realID = playerConfig:GetTeam()
	if realID == -1 then realID = nil end
	return realID
end

function GetUnitMoveToPathUI(playerID, unitID, plotIndex)
	local unit = UnitManager.GetUnit(playerID, unitID)
	print('starting get plots', playerID, unitID, plotIndex)
	if unit == nil then return {} end
	local plots = UnitManager.GetMoveToPath(unit, plotIndex) or {}
	print('support ui plots get', #plots)
	return plots
end


function ShowLoadWarningPopup(messageKey)
    local message = Locale.Lookup(messageKey or "LOC_DIPLOMACY_REWORK_VASSAL_CONFLICT")
    local popup = PopupDialogInGame:new("UnitPanelPopup")
    popup:ShowOkDialog(message)
end
