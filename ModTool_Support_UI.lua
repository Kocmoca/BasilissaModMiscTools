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

function GetCityProductionInfoUI(playerID, cityID)
	local productionHash = GetCityProductionHashUI(playerID, cityID)
	if productionHash == 0 then return nil end
	local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return nil end
	local buildQueue = city:GetBuildQueue()
	local productionTable = {
		["unit"] = GameInfo.Units,
		["district"] = GameInfo.Districts,
		["building"] = GameInfo.Buildings,
		["project"] = GameInfo.Projects
	}
	local row = nil
	local cityProductionType = nil
	for productionType, tableType in pairs(productionTable) do
		row = tableType[productionHash]
		if row ~= nil then
			cityProductionType = productionType
			break
		end
	end
	if row == nil then return nil end
	local progressTable = {
		["unit"] = function(typeIndex) return buildQueue:GetUnitProgress(typeIndex) end,
		["district"] = function(typeIndex) return buildQueue:GetDistrictProgress(typeIndex) end,
		["building"] = function(typeIndex) return buildQueue:GetBuildingProgress(typeIndex) end,
		["project"] = function(typeIndex) return buildQueue:GetProjectCost(typeIndex) end
	}
	local productionProgress = progressTable[cityProductionType](row.Index)
	local typeNameTable = {
		["unit"] = function(typeIndex) return GameInfo.Units[typeIndex].UnitType end,
		["district"] = function(typeIndex) return GameInfo.Districts[typeIndex].DistrictType end,
		["building"] = function(typeIndex) return GameInfo.Buildings[typeIndex].BuildingType end,
		["project"] = function(typeIndex) return GameInfo.Projects[typeIndex].ProjectType end
	}
	local typeName = typeNameTable[cityProductionType](row.Index)
	local productionData = {}
	productionData.hash = productionHash
	productionData.productionType = cityProductionType
	productionData.typeIndex = row.Index
	productionData.typeName = typeName
	productionData.name = row.Name
	productionData.progress = productionProgress
	productionData.cost = row.Cost
	return productionData
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

-- ===========================================================================
-- 间谍（特工）正在执行的行动：给“间谍在干什么”这类面板用
--   （Plana and Arona → AssistantTopics.lua 通过 ExposedMembers.ModMiscToolUI 调）
--
-- 取数逻辑与原版 `UnitPanel.lua → ReadCustomUnitStats` 的 Espionage 段逐行对齐：
--   行动类型 = ACTIVITY_OPERATION → GetSpyOperation()（-1 = 没在干活）→
--   剩余回合 = GetSpyOperationEndTurn() - Game.GetCurrentGameTurn()；
--   总回合 = UnitManager.GetTimeToComplete(operationIndex, unit)。
-- 与原版唯一的差别是**间谍判定**：原版用 `GameInfo.Units[type].Spy == true`，
--   这里也照抄，而不是写死 'UNIT_SPY'（复制/自定义间谍单位、其它规则集都能认）。
--
-- 返回：spyOperation (UnitOperations.Index), spyRemainingTurns, spyTotalTurns
--       不是间谍 / 没在执行行动 ⇒ nil, nil, nil
-- ===========================================================================
function GetSpyOperations(playerID, unitID)
	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil then return nil, nil, nil end
	local unitTypeIndex = unit:GetType()
	local unitInfo = unitTypeIndex ~= nil and GameInfo.Units[unitTypeIndex] or nil
	if unitInfo == nil or unitInfo.Spy ~= true then return nil, nil, nil end
	local activityType = UnitManager.GetActivityType(unit)
	if activityType ~= ActivityTypes.ACTIVITY_OPERATION then return nil, nil, nil end
	local spyOperation = unit:GetSpyOperation()
	if spyOperation == nil or spyOperation == -1 then return nil, nil, nil end
	local spyRemainingTurns = unit:GetSpyOperationEndTurn() - Game.GetCurrentGameTurn()
	local spyTotalTurns = UnitManager.GetTimeToComplete(spyOperation, unit)
	return spyOperation, spyRemainingTurns, spyTotalTurns
end


function ShowLoadWarningPopup(messageKey)
    local message = Locale.Lookup(messageKey or "LOC_DIPLOMACY_REWORK_VASSAL_CONFLICT")
    local popup = PopupDialogInGame:new("UnitPanelPopup")
    popup:ShowOkDialog(message)
end
