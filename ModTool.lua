include('ModTool_Support_Functions.lua')
include('ModTool_WorldBuilderAPI.lua')
include('ModTool_GhostPlayers.lua')

local playerCitiesInfo = {}
local defeatedPlayers = {}
local allUnitData = {}
local playerPlotsInfo = {}
local playerAssetsInfo = {}

local upgradeCommandHash = GameInfo.UnitCommands['UNITCOMMAND_UPGRADE'].Hash
local increaseBuildChargeAbility = 'ABILITY_INCREASE_BUILD_CHARGE'
local decreaseBuildChargeAbility = 'ABILITY_DECREASE_BUILD_CHARGE'
local buildingsOfDistrict = {}

local currentRemovingCityData = {}
local currentUpgradingUnit = {}

function SaveData()
	Game:SetProperty('kocmoca_modtool_player_cities_table_prop', playerCitiesInfo)
	Game:SetProperty('kocmoca_modtool_defeated_player_table_prop', defeatedPlayers)
	Game:SetProperty('kocmoca_modtool_player_plots_info_prop', playerPlotsInfo)
	Game:SetProperty('kocmoca_modtool_player_asset_info_prop', playerAssetsInfo)
end

function SaveUnitsData()
	Game:SetProperty('kocmoca_modtool_all_units_table_prop', allUnitData)
end

function LoadData()
	playerCitiesInfo = Game:GetProperty('kocmoca_modtool_player_cities_table_prop') or {}
	defeatedPlayers = Game:GetProperty('kocmoca_modtool_defeated_player_table_prop') or {}
	allUnitData = Game:GetProperty('kocmoca_modtool_all_units_table_prop') or {}
	playerPlotsInfo = Game:GetProperty('kocmoca_modtool_player_plots_info_prop') or {}
	playerAssetsInfo = Game:GetProperty('kocmoca_modtool_player_asset_info_prop') or {}
end

function InitializeBuildingsOfDistrict()
	for buildingRow in GameInfo.Buildings() do
		local buildingType = buildingRow.BuildingType
		local districtType = buildingRow.PrereqDistrict
		if districtType ~= nil then
			if buildingsOfDistrict[districtType] == nil then buildingsOfDistrict[districtType] = {} end
			table.insert(buildingsOfDistrict[districtType], buildingType)
		end
	end
end

--city data record

function OnCityAdded(playerID, cityID, iX, iY)
	local city = CityManager.GetCity(playerID, cityID)
	if city == nil then return end
	if playerCitiesInfo[playerID] == nil then playerCitiesInfo[playerID] = {} end
	playerCitiesInfo[playerID][cityID] = {}
	local plot = Map.GetPlot(iX, iY)
	local plotIndex = plot:GetIndex()
	playerCitiesInfo[playerID][cityID].iX = iX
	playerCitiesInfo[playerID][cityID].iY = iY
	playerCitiesInfo[playerID][cityID].plotIndex = plotIndex
	SaveData()
	if currentRemovingCityData and currentRemovingCityData.plotIndex == plotIndex then
		LuaEvents.ModMiscToolCityOwnerChanged.Call(currentRemovingCityData.playerID, playerID, cityID, iX, iY, plotIndex)
	end
	currentRemovingCityData = nil
end

function OnCityRemoved(playerID, cityID)
	if not playerCitiesInfo[playerID] then return end
	local cityData = playerCitiesInfo[playerID][cityID]
	if cityData == nil then return end
	currentRemovingCityData = {}
	currentRemovingCityData.playerID = playerID
	currentRemovingCityData.cityID = cityID
	currentRemovingCityData.iX = cityData.iX
	currentRemovingCityData.iY = cityData.iY
	currentRemovingCityData.plotIndex = cityData.plotIndex
	PlayerDefeateHandler(playerID, cityID)
	playerCitiesInfo[playerID][cityID] = nil
	SaveData()
end

function OnCityTransfered(newOwnerID, cityID, oldOwnerID, transferType)
	CheckPlayerRevive(newOwnerID, cityID, oldOwnerID, transferType)
	SaveData()
end

function CheckPlayerRevive(newOwnerID, cityID, oldOwnerID, transferType)
	local city = CityManager.GetCity(newOwnerID, cityID)
	if city == nil then return end
	local iX = city:GetX()
	local iY = city:GetY()
	if not TableContains(defeatedPlayers, newOwnerID) then return end
	for i = #defeatedPlayers, 1, -1 do
		if defeatedPlayers[i] == newOwnerID then
			table.remove(defeatedPlayers, i)
		end
	end
	LuaEvents.ModMiscToolReturnCityToDefeated.Call(oldOwnerID, newOwnerID, cityID, iX, iY)
end

function PlayerDefeateHandler(playerID, cityID)
	if not CheckIsPlayerDefeated(playerID) then return end
	LuaEvents.ModMiscToolLastCityCaptured.Call(playerID, cityID)
end

function CheckIsPlayerDefeated(playerID)
	if playerID == 62 or playerID == 63 then return end
	local capital = GetPlayerCapital(playerID)
	if capital == nil then
		if not TableContains(defeatedPlayers, playerID) then
			table.insert(defeatedPlayers, playerID)
		end
		return true
	end
	return false
end

--unit data record

function GetUnitData(playerID, unitID)
	if allUnitData[playerID] == nil then return nil end
	local unitData = allUnitData[playerID][unitID]
	return unitData
end

function OnUnitAdded(playerID, unitID, iX, iY)
	RefreshUnitData(playerID, unitID)
	SaveUnitsData()
end

function RefreshUnitData(playerID, unitID)
	if allUnitData[playerID] == nil then allUnitData[playerID] = {} end
	allUnitData[playerID][unitID] = {}
	local unitData = allUnitData[playerID][unitID]
	local unit = Players[playerID]:GetUnits():FindID(unitID)
	if unit == nil then unitData.removed = true return end
	if unitData.removed == true then return end
	if unitData.unitType == nil then
		local unitTypeIndex = unit:GetType()
		unitData.unitType = GameInfo.Units[unitTypeIndex].UnitType
		unitData.promotionClass = GameInfo.Units[unitTypeIndex].PromotionClass
	end
	local plotIndex, iX, iY = GetUnitPlotIndexAndCoordinate(unit)
	if plotIndex == nil then unitData.removed = true return end
	local expPoint, promotions = ExposedMembers.ModMiscToolUI.GetExperienceAndPromotionsUI(playerID, unitID)
	unitData.playerID = playerID
	unitData.unitID = unitID
	unitData.iX = iX
	unitData.iY = iY
	unitData.plotIndex = plotIndex
	unitData.expPoint = expPoint
	unitData.promotions = promotions
	unitData.militaryFormation = unit:GetMilitaryFormation()
	unitData.damage = unit:GetDamage()
	if unitData.damage >= 100 then unitData.removed = true end
end

function OnUnitRemovedFromMap(playerID, unitID)
	UnitDeathHandler(playerID, unitID)
	SaveUnitsData()
end

function UnitDeathHandler(playerID, unitID)
	if allUnitData[playerID] == nil then allUnitData[playerID] = {} end
	local unitData = allUnitData[playerID][unitID] or {}
	unitData.removed = true
	allUnitData[playerID][unitID] = unitData
end

function OnUnitPromoted(playerID, unitID)
	RefreshUnitData(playerID, unitID)
	SaveUnitsData()
end

function OnUnitSelectionChanged(playerID, unitID, plotX, plotY, plotZ, bSelected, bEditable)
	if not bSelected then return end
	RefreshUnitData(playerID, unitID)
	SaveUnitsData()
end

function OnUnitMoveComplete(playerID, unitID, iX, iY)
	RefreshUnitData(playerID, unitID)
	SaveUnitsData()
end

function OnCombat(pCombatResult)
	if pCombatResult == nil then return end
	local location = pCombatResult[CombatResultParameters.LOCATION]
	local defender = pCombatResult[CombatResultParameters.DEFENDER]
	local defInfo = defender and defender[CombatResultParameters.ID] or nil
	local attacker = pCombatResult[CombatResultParameters.ATTACKER]
	local atkInfo = attacker and attacker[CombatResultParameters.ID] or nil

	local iX = location and location.x or nil
	local iY = location and location.y or nil
	local plotIndex = nil
	if iX ~= nil and iY ~= nil then
		local plot = Map.GetPlot(iX, iY)
		if plot ~= nil then plotIndex = plot:GetIndex() end
	end

	-- 将官方 Events.Combat 重新分发为 Mod Misc Tool 的公共事件。
	-- 订阅者仍可使用原始 pCombatResult，同时可直接拿到战斗地点坐标。
	LuaEvents.ModMiscToolCombat.Call(pCombatResult, iX, iY, plotIndex)

	if atkInfo == nil or defInfo == nil then return end

	local bUnitVsUnit = atkInfo.type == ComponentType.UNIT and defInfo.type == ComponentType.UNIT

	local function GetDistrictInfo(iX, iY)
		local district = CityManager.GetDistrictAt(iX, iY)
		if district == nil then return nil, nil end

		local districtType = nil
		local districtTypeIndex = district:GetType()
		if type(districtTypeIndex) == 'string' then
			districtType = districtTypeIndex
		elseif districtTypeIndex ~= nil and GameInfo.Districts[districtTypeIndex] ~= nil then
			districtType = GameInfo.Districts[districtTypeIndex].DistrictType
		end

		local cityID = nil
		local city = district:GetCity()
		if city ~= nil then cityID = city:GetID() end
		return districtType, cityID
	end

	local function RecordCombatUnitData(playerID, unitID, enemyPlayerID, enemyUnitID, bKilledInUnitCombat)
		local unit = UnitManager.GetUnit(playerID, unitID)
		if unit == nil or unit:GetDamage() >= 100 then
			UnitDeathHandler(playerID, unitID)
			local unitData = allUnitData[playerID][unitID]
			if unitData ~= nil then
				unitData.combatDeathX = iX
				unitData.combatDeathY = iY
			end
			LuaEvents.ModMiscToolUnitLostInCombat.Call(playerID, unitID, pCombatResult)
			if bKilledInUnitCombat then
				LuaEvents.ModMiscToolUnitKilledInCombat.Call(playerID, unitID, enemyPlayerID, enemyUnitID, iX, iY, plotIndex, pCombatResult)
			end
			return
		end
		RefreshUnitData(playerID, unitID)
	end

	-- 单位 vs 单位战斗才分发单位击杀事件；攻击区域等非单位战斗不套用该接口
	if bUnitVsUnit then
		RecordCombatUnitData(atkInfo.player, atkInfo.id, defInfo.player, defInfo.id, true)
		RecordCombatUnitData(defInfo.player, defInfo.id, atkInfo.player, atkInfo.id, true)
	else
		if atkInfo.type == ComponentType.UNIT then
			RecordCombatUnitData(atkInfo.player, atkInfo.id, defInfo.player, defInfo.id, false)
		end
		if defInfo.type == ComponentType.UNIT then
			RecordCombatUnitData(defInfo.player, defInfo.id, atkInfo.player, atkInfo.id, false)
		end
	end

	-- 攻击区域：防御方为 DISTRICT 时单独分发，输出区域类型与城市ID
	if defInfo.type == ComponentType.DISTRICT then
		local districtType, cityID = GetDistrictInfo(iX, iY)
		LuaEvents.ModMiscToolDistrictAttacked.Call(
			atkInfo.player, atkInfo.id,
			defInfo.player, defInfo.id,
			districtType, cityID,
			iX, iY, plotIndex, pCombatResult)
	end

	SaveUnitsData()
end

--event order or unit upgrade:
--1,UnitRemovedFromMap(oldUnit),2,UnitAddedToMap(newUnit),3,UnitPromoted(newUnit),4,UnitCommandStarted(oldUnit)
--thank you firaxis for your confusing code

function OnUnitUpgraded(playerID, unitID)
    if currentUpgradingUnit[playerID] == nil then currentUpgradingUnit[playerID] = {} end
    currentUpgradingUnit[playerID].newUnitID = unitID
    UnitUpgradeEventTrigger(playerID)
end

function OnUnitCommand(playerID, unitID, hCommand, iData1)
	if hCommand ~= upgradeCommandHash then return end
	if currentUpgradingUnit[playerID] == nil then currentUpgradingUnit[playerID] = {} end
	currentUpgradingUnit[playerID].oldUnitID = unitID
	UnitUpgradeEventTrigger(playerID)
end

function UnitUpgradeEventTrigger(playerID)
	if currentUpgradingUnit[playerID] == nil then return nil end
	if currentUpgradingUnit[playerID].newUnitID == nil or currentUpgradingUnit[playerID].oldUnitID == nil then return end
	LuaEvents.ModMiscToolUnitUpgraded.Call(playerID, currentUpgradingUnit[playerID].oldUnitID, currentUpgradingUnit[playerID].newUnitID)
	currentUpgradingUnit[playerID] = {}
end

function OnModMiscToolUnitUpgraded(playerID, oldUnitID, newUnitID)
	if allUnitData[playerID] == nil then return end
	local oldUnitData = allUnitData[playerID][oldUnitID]
	local newUnitData = allUnitData[playerID][newUnitID]
	oldUnitData.upgradeTo = newUnitID
	newUnitData.upgradeFrom = oldUnitID
	SaveUnitsData()
end

--player assets record

local function CollectPlotAssetsByPrefix(playerID, plotIndex, prefix)
	local result = {}
	local playerPlots = playerPlotsInfo[playerID]
	if playerPlots == nil then return result end
	local plotAssets = playerPlots[plotIndex]
	if plotAssets == nil then return result end
	for assetType, _ in pairs(plotAssets) do
		if prefix == nil or StringContains(assetType, prefix) then
			table.insert(result, assetType)
		end
	end
	return result
end

function GetPlayerAssetNumber(playerID, assetType)
	local count = 0
	if playerAssetsInfo[playerID] ~= nil and playerAssetsInfo[playerID][assetType] ~= nil then
		count = TableCountForDictionary(playerAssetsInfo[playerID][assetType])
	end
	if count == 0 then
		print("[ModMiscTool][Asset] count=0 playerID=" .. tostring(playerID) .. " assetType=" .. tostring(assetType) .. " turn=" .. tostring(Game.GetCurrentGameTurn()))
	end
	return count
end

function GetPlayerAssetPlotIndexes(playerID, assetType)
	local result = {}
	if playerAssetsInfo[playerID] == nil or playerAssetsInfo[playerID][assetType] == nil then
		return result
	end
	for plotIndex, _ in pairs(playerAssetsInfo[playerID][assetType]) do
		table.insert(result, plotIndex)
	end
	table.sort(result)
	return result
end

function GetPlotAssetTypes(playerID, plotIndex)
	local result = {}
	if playerPlotsInfo[playerID] == nil or playerPlotsInfo[playerID][plotIndex] == nil then
		return result
	end
	for assetType, _ in pairs(playerPlotsInfo[playerID][plotIndex]) do
		table.insert(result, assetType)
	end
	table.sort(result)
	return result
end

function HasPlayerAsset(playerID, assetType, plotIndex)
	if playerAssetsInfo[playerID] == nil or playerAssetsInfo[playerID][assetType] == nil then
		return false
	end
	return playerAssetsInfo[playerID][assetType][plotIndex] ~= nil
end

function SaveAsset(playerID, assetType, plotIndex)
	if playerID == nil or assetType == nil or plotIndex == nil then return end
	if playerAssetsInfo[playerID] == nil then playerAssetsInfo[playerID] = {} end
	if playerAssetsInfo[playerID][assetType] == nil then playerAssetsInfo[playerID][assetType] = {} end
	playerAssetsInfo[playerID][assetType][plotIndex] = true
	if playerPlotsInfo[playerID] == nil then playerPlotsInfo[playerID] = {} end
	if playerPlotsInfo[playerID][plotIndex] == nil then playerPlotsInfo[playerID][plotIndex] = {} end
	playerPlotsInfo[playerID][plotIndex][assetType] = true
end

function RemoveSpecificAssets(playerID, assetType, plotIndex)
	if playerID == nil or assetType == nil or plotIndex == nil then return end
	if playerAssetsInfo[playerID] ~= nil and playerAssetsInfo[playerID][assetType] ~= nil then
		playerAssetsInfo[playerID][assetType][plotIndex] = nil
		if next(playerAssetsInfo[playerID][assetType]) == nil then
			playerAssetsInfo[playerID][assetType] = nil
		end
	end
	if playerPlotsInfo[playerID] ~= nil and playerPlotsInfo[playerID][plotIndex] ~= nil then
		playerPlotsInfo[playerID][plotIndex][assetType] = nil
		if next(playerPlotsInfo[playerID][plotIndex]) == nil then
			playerPlotsInfo[playerID][plotIndex] = nil
		end
	end
end

function RemoveAssetFromPlot(playerID, assetType, plotIndex)
	RemoveSpecificAssets(playerID, assetType, plotIndex)
end

function OnBuildingAdded(iX, iY, buildingIndex, playerID, cityID, percentComplete)
	if playerID == nil or buildingIndex == nil then return end
	local buildingInfo = GameInfo.Buildings[buildingIndex]
	if buildingInfo == nil then return end
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return end
	SaveAsset(playerID, buildingInfo.BuildingType, plot:GetIndex())
	SaveData()
end

function OnBuildingRemoved(iX, iY)
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return end
	local plotIndex = plot:GetIndex()
	local plotDistrictTypeIndex = plot:GetDistrictType()
	if plotDistrictTypeIndex == nil or plotDistrictTypeIndex == -1 then return end
	local playerID = plot:GetOwner()
	if playerID == nil then return end
	if playerPlotsInfo[playerID] == nil or playerPlotsInfo[playerID][plotIndex] == nil then return end
	local oldBuildingAssets = CollectPlotAssetsByPrefix(playerID, plotIndex, 'BUILDING_')
	if #oldBuildingAssets <= 0 then return end
	local newBuildingIndexes = GetBuildingsIndexInPlot(plot)
	local newBuildingAssets = {}
	for _, buildingIndex in ipairs(newBuildingIndexes) do
		local buildingInfo = GameInfo.Buildings[buildingIndex]
		if buildingInfo ~= nil then
			table.insert(newBuildingAssets, buildingInfo.BuildingType)
		end
	end
	for _, assetType in ipairs(oldBuildingAssets) do
		if not TableContains(newBuildingAssets, assetType) then
			RemoveSpecificAssets(playerID, assetType, plotIndex)
			LuaEvents.ModMiscToolBuildingRemoved.Call(playerID, iX, iY, plotIndex, assetType)
		end
	end
	SaveData()
end

function OnDistrictAdded(playerID, districtID, cityID, iX, iY, districtIndex, percentComplete)
	if playerID == nil or districtIndex == nil then return end
	local districtInfo = GameInfo.Districts[districtIndex]
	if districtInfo == nil then return end
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return end
	SaveAsset(playerID, districtInfo.DistrictType, plot:GetIndex())
	SaveData()
end

function OnDistrictRemoved(playerID, districtID, cityID, iX, iY, districtIndex)
	if playerID == nil or districtIndex == nil then return end
	local districtInfo = GameInfo.Districts[districtIndex]
	if districtInfo == nil then return end
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return end
	local plotIndex = plot:GetIndex()
	if playerPlotsInfo[playerID] == nil or playerPlotsInfo[playerID][plotIndex] == nil then return end
	local buildingAssets = CollectPlotAssetsByPrefix(playerID, plotIndex, 'BUILDING_')
	RemoveSpecificAssets(playerID, districtInfo.DistrictType, plotIndex)
	for _, assetType in ipairs(buildingAssets) do
		RemoveSpecificAssets(playerID, assetType, plotIndex)
		LuaEvents.ModMiscToolBuildingRemoved.Call(playerID, iX, iY, plotIndex, assetType)
	end
	SaveData()
end

function OnImprovementAddToMap(iX, iY, eImprovement, playerID)
	if playerID == nil or eImprovement == nil then return end
	local improvementInfo = GameInfo.Improvements[eImprovement]
	if improvementInfo == nil then return end
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return end
	SaveAsset(playerID, improvementInfo.ImprovementType, plot:GetIndex())
	SaveData()
end

function OnImprovementRemoved(iX, iY, playerID)
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return end
	local plotIndex = plot:GetIndex()
	local improvementAssets = CollectPlotAssetsByPrefix(playerID, plotIndex, 'IMPROVEMENT_')
	if #improvementAssets <= 0 then return end
	for _, assetType in ipairs(improvementAssets) do
		RemoveSpecificAssets(playerID, assetType, plotIndex)
		LuaEvents.ModMiscToolImprovementRemoved.Call(playerID, iX, iY, plotIndex, assetType)
	end
	SaveData()
end

--change build charge

function ChangeBuildCharge(playerID, unitID, amount)
	if amount == nil or amount == 0 then return end
	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil or unit:GetDamage() >= 100 then return end
	local abilityType
	if amount > 0 then
		abilityType = increaseBuildChargeAbility
	else
		abilityType = decreaseBuildChargeAbility
	end
	local number = math.ceil(math.abs(amount))
	for i = 1, number, 1 do
		unit:GetAbility():ChangeAbilityCount(abilityType, 1)
		unit:GetAbility():ChangeAbilityCount(abilityType, -1)
	end
end

function Initialize()
	LoadData()
	InitializeBuildingsOfDistrict()
	Events.CityAddedToMap.Add(OnCityAdded)
	Events.CityRemovedFromMap.Add(OnCityRemoved)
	Events.CityTransfered.Add(OnCityTransfered)
	
	Events.UnitAddedToMap.Add(OnUnitAdded)
	Events.UnitRemovedFromMap.Add(OnUnitRemovedFromMap)
	Events.UnitPromoted.Add(OnUnitPromoted)
	Events.UnitCommandStarted.Add(OnUnitCommand)
	Events.UnitUpgraded.Add(OnUnitUpgraded)
	Events.UnitSelectionChanged.Add(OnUnitSelectionChanged)
	Events.UnitMoveComplete.Add(OnUnitMoveComplete)
	Events.Combat.Add(OnCombat)
	LuaEvents.ModMiscToolUnitUpgraded.Add(OnModMiscToolUnitUpgraded)
	
	Events.BuildingAddedToMap.Add(OnBuildingAdded)
	Events.BuildingRemovedFromMap.Add(OnBuildingRemoved)
	Events.DistrictAddedToMap.Add(OnDistrictAdded)
	Events.DistrictRemovedFromMap.Add(OnDistrictRemoved)
	Events.ImprovementAddedToMap.Add(OnImprovementAddToMap)
	Events.ImprovementRemovedFromMap.Add(OnImprovementRemoved)
	if not ExposedMembers.ModMiscToolScript then
		ExposedMembers.ModMiscToolScript = {}
	end
	-- 幽灵玩家（引擎认可的 off-map 玩家）：由 UI 层传入玩家原本的城邦数量后建立池子
	ExposedMembers.ModMiscToolScript.InitializeGhostPlayers = InitializeGhostPlayers
	ExposedMembers.ModMiscToolScript.InitializeGhostMajorPlayers = InitializeGhostMajorPlayers
	ExposedMembers.ModMiscToolScript.CreateGhostPlayerFromEmptySlot = CreateGhostPlayerFromEmptySlot
	ExposedMembers.ModMiscToolScript.CreateGhostPlayerFromMajorCiv = CreateGhostPlayerFromMajorCiv
	ExposedMembers.ModMiscToolScript.GetLastGhostCreateDiagnostics = GetLastGhostCreateDiagnostics
	ExposedMembers.ModMiscToolScript.GetPlayerSlotSummary = GetPlayerSlotSummary
	ExposedMembers.ModMiscToolScript.GetGhostPlayers = GetGhostPlayers
	ExposedMembers.ModMiscToolScript.GetGhostPlayerCount = GetGhostPlayerCount
	ExposedMembers.ModMiscToolScript.IsGhostPlayer = IsGhostPlayer
	ExposedMembers.ModMiscToolScript.IsGhostPlayerAvailable = IsGhostPlayerAvailable
	ExposedMembers.ModMiscToolScript.GetAvailableGhostPlayers = GetAvailableGhostPlayers
	ExposedMembers.ModMiscToolScript.GetAvailableGhostPlayerCount = GetAvailableGhostPlayerCount
	ExposedMembers.ModMiscToolScript.GetAvailableGhostPlayerID = GetAvailableGhostPlayerID
	ExposedMembers.ModMiscToolScript.ClaimAvailableGhostPlayer = ClaimAvailableGhostPlayer
	ExposedMembers.ModMiscToolScript.ReleaseGhostPlayer = ReleaseGhostPlayer
	ExposedMembers.ModMiscToolScript.IsGhostPlayerClaimed = IsGhostPlayerClaimed
	ExposedMembers.ModMiscToolScript.GetGhostPlayerClaims = GetGhostPlayerClaims
	ExposedMembers.ModMiscToolScript.MovePlayerOffMap = MovePlayerOffMap
	ExposedMembers.ModMiscToolScript.ConvertGhostPlayerToCityState = ConvertGhostPlayerToCityState
	ExposedMembers.ModMiscToolScript.GetGhostifyBlockReason = GetGhostifyBlockReason
	ExposedMembers.ModMiscToolScript.PlayerHasOnMapUnit = PlayerHasOnMapUnit
	ExposedMembers.ModMiscToolScript.allUnitData = allUnitData
	ExposedMembers.ModMiscToolScript.defeatedPlayers = defeatedPlayers
	ExposedMembers.ModMiscToolScript.playerCitiesInfo = playerCitiesInfo
	ExposedMembers.ModMiscToolScript.buildingsOfDistrict = buildingsOfDistrict
	ExposedMembers.ModMiscToolScript.GetUnitData = GetUnitData
	ExposedMembers.ModMiscToolScript.GetPlayerAssetNumber = GetPlayerAssetNumber
	ExposedMembers.ModMiscToolScript.GetPlayerAssetPlotIndexes = GetPlayerAssetPlotIndexes
	ExposedMembers.ModMiscToolScript.GetPlotAssetTypes = GetPlotAssetTypes
	ExposedMembers.ModMiscToolScript.HasPlayerAsset = HasPlayerAsset
	ExposedMembers.ModMiscToolScript.SaveAsset = SaveAsset
	ExposedMembers.ModMiscToolScript.RemoveSpecificAssets = RemoveSpecificAssets
	ExposedMembers.ModMiscToolScript.RemoveAssetFromPlot = RemoveAssetFromPlot
	ExposedMembers.ModMiscToolScript.ChangeBuildCharge = ChangeBuildCharge
	ExposedMembers.ModMiscToolScript.CanUnitTypeGetExp = CanUnitTypeGetExp
	-- 通用辅助函数：供依赖 Mod Misc Tool 的其他 mod 直接引用
	ExposedMembers.ModMiscToolScript.TableContains = TableContains
	ExposedMembers.ModMiscToolScript.PlotIndexToXY = PlotIndexToXY
	ExposedMembers.ModMiscToolScript.GetCityPlotIndex = GetCityPlotIndex
	ExposedMembers.ModMiscToolScript.GetUnitCoordinate = GetUnitCoordinate
	ExposedMembers.ModMiscToolScript.DamageToUnit = DamageToUnit
	ExposedMembers.ModMiscToolScript.AoeAllUnitsForPlot = AoeAllUnitsForPlot
	ExposedMembers.ModMiscToolScript.GetPlotsInRange = GetPlotsInRange
	-- WorldBuilder（地图编辑器）接口模块：Gameplay 后端，UI 层通过它调用
	ExposedMembers.ModMiscToolScript.WorldBuilderAPI = WorldBuilderAPI
end
Events.LoadGameViewStateDone.Add(Initialize)
