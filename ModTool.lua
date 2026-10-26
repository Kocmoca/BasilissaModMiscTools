-- 构建标记：用来在 Lua.log 里确认“游戏里跑的到底是哪一版”，排查加载类问题必备。
-- 三个阶段各打一次（gameplay 脚本 / InGame UI / 前端 hook），日志停在哪一步一目了然。
MODMISC_BUILD_TAG = "2026-10-26-A"   -- 单位类型索引 + 间谍行动查询（桩验证，待实机）
print("[ModMiscTool] gameplay scripts loading, build=" .. tostring(MODMISC_BUILD_TAG))

include('ModTool_Support_Functions.lua')
include('ModTool_WorldBuilderAPI.lua')
include('ModTool_MapRebuild.lua')
include('ModTool_GhostPlayers.lua')
include('ModTool_TurnEraAPI.lua')
-- ⚠️ 必须 include：ModTool_DataStore.lua 提供 ModMiscToolData（Set/Get/Has/Remove/BuildKey）。
-- 漏了它会让下面“暴露给其它 mod”的整段在 `ModMiscToolData.Set` 处报 attempt to index a nil value，
-- **Initialize 直接中断** —— 后面所有暴露（WorldBuilderAPI、TurnEraAPI…）全部静默失效。
-- 2026-10-05 实机日志抓到（表现为 Game:SetProperty 那条单向通道用不了）。
include('ModTool_DataStore.lua')
include('ModTool_TurnEvents.lua')
include('ModTool_TurnEventHandlers.lua')

local playerCitiesInfo = {}
local defeatedPlayers = {}
local allUnitData = {}
-- 按单位类型（UnitType 文本，如 'UNIT_SPY'）建的**派生索引**：
--   allUnitsTypeTable[playerID][unitTypeText][unitID] = unitData（与 allUnitData 同一张子表）
-- 只服务“按类型找单位”的查询（目前是间谍列表）。它**不落盘**：读档后由
-- InitializeAllUnitsTypeTable() 从 allUnitData 全量重建。写入口只有 WriteUnitDataToTypeTable，
-- 死单位/离场单位必须在 UnitDeathHandler / RefreshUnitData 里同步摘掉，否则索引里会留尸体。
local allUnitsTypeTable = {}
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

-- ===========================================================================
-- 单位类型索引（allUnitsTypeTable）
--
-- 需求：外部 mod（Plana and Arona 的“间谍在干什么”面板）要按类型拿单位，直接翻
--   allUnitData[playerID] 得按 unitID 逐个看 unitData.unitType，不方便。
-- 约定：
--   * 只存**活单位**（unitData.removed ~= true）；
--   * 值就是 allUnitData 里那张子表（同一份引用，读写都一致，不复制）；
--   * 索引不落盘，读档后重建（见 Initialize 里的 InitializeAllUnitsTypeTable）。
-- ===========================================================================

function WriteUnitDataToTypeTable(playerID, unitID)
	local playerUnitData = allUnitData[playerID]
	if type(playerUnitData) ~= 'table' then return false end   -- 坏档防御：存档里的脏数据不炸索引
	local unitData = playerUnitData[unitID]
	if type(unitData) ~= 'table' then return false end
	local unitTypeText = unitData.unitType
	if unitTypeText == nil then return false end
	-- 死单位不进索引；之前进过的顺手摘掉（战斗死亡、晋升换 ID 都会走到这里）
	if unitData.removed == true then
		RemoveUnitFromTypeTable(playerID, unitID)
		return false
	end
	if allUnitsTypeTable[playerID] == nil then allUnitsTypeTable[playerID] = {} end
	if allUnitsTypeTable[playerID][unitTypeText] == nil then allUnitsTypeTable[playerID][unitTypeText] = {} end
	allUnitsTypeTable[playerID][unitTypeText][unitID] = unitData
	return true
end

function RemoveUnitFromTypeTable(playerID, unitID)
	local playerTypeTable = allUnitsTypeTable[playerID]
	if playerTypeTable == nil then return end
	-- 扫全部类型桶：单位升级换了类型、或 unitData 里类型文本缺失时，也能摘干净
	for _, typeTable in pairs(playerTypeTable) do
		if typeTable[unitID] ~= nil then typeTable[unitID] = nil end
	end
end

-- 读档后全量重建：allUnitsTypeTable 不随存档保存，只由 allUnitData 派生。
-- 注意两点：① 原地清空（ExposedMembers 里挂的是这个表的引用，重新赋值会让外部拿到旧表）；
--           ② 跳过 removed 的单位（历史记录仍留在 allUnitData 里，供事件查询用）。
function InitializeAllUnitsTypeTable()
	for playerID in pairs(allUnitsTypeTable) do
		allUnitsTypeTable[playerID] = nil
	end
	local unitCount = 0
	for playerID, playerUnitData in pairs(allUnitData) do
		if type(playerUnitData) == 'table' then
			for unitID, unitData in pairs(playerUnitData) do
				if type(unitData) == 'table' and unitData.removed ~= true
					and WriteUnitDataToTypeTable(playerID, unitID) then
					unitCount = unitCount + 1
				end
			end
		end
	end
	print("[ModMiscTool][UnitTypeTable] 重建完成：活单位=" .. tostring(unitCount))
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
	if unit == nil then
		unitData.removed = true
		RemoveUnitFromTypeTable(playerID, unitID)
		return
	end
	if unitData.removed == true then return end
	if unitData.unitType == nil then
		local unitTypeIndex = unit:GetType()
		unitData.unitType = GameInfo.Units[unitTypeIndex].UnitType
		unitData.promotionClass = GameInfo.Units[unitTypeIndex].PromotionClass
	end
	local plotIndex, iX, iY = GetUnitPlotIndexAndCoordinate(unit)
	if plotIndex == nil then
		unitData.removed = true
		RemoveUnitFromTypeTable(playerID, unitID)
		return
	end
	-- 【实机 2026-10-06】UI 侧的 ExposedMembers 是**后发布**的：gameplay 早一步调用就会
	-- “function expected instead of nil”（ModTool.lua:159）。所以这里防御式调用，拿不到就当没经验。
	local expPoint, promotions = 0, nil
	local uiMembers = ExposedMembers ~= nil and ExposedMembers.ModMiscToolUI or nil
	local expGetter = uiMembers ~= nil and uiMembers.GetExperienceAndPromotionsUI or nil
	if expGetter ~= nil then
		local gotOk, gotPoint, gotPromotions = pcall(expGetter, playerID, unitID)
		if gotOk then
			expPoint = gotPoint or 0
			promotions = gotPromotions
		end
	end
	unitData.playerID = playerID
	unitData.unitID = unitID
	unitData.iX = iX
	unitData.iY = iY
	unitData.plotIndex = plotIndex
	unitData.expPoint = expPoint
	unitData.promotions = promotions
	unitData.militaryFormation = unit:GetMilitaryFormation()
	unitData.damage = unit:GetDamage()
	-- 显式写 false：外部 mod 用 `unitData.removed == false` 判“活着”（之前只有 true/nil，
	-- 那种写法会永远判假 —— Plana and Arona 的间谍列表就踩过这个坑）
	unitData.removed = unitData.damage >= 100
	WriteUnitDataToTypeTable(playerID, unitID)
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
	-- 索引只放活单位：死亡/被移除立刻出表（allUnitData 里的历史记录保留）
	RemoveUnitFromTypeTable(playerID, unitID)
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
	-- 索引不落盘：读档后从 allUnitData 重建（新局 allUnitData 为空，等事件增量写入）
	InitializeAllUnitsTypeTable()
	InitializeBuildingsOfDistrict()
	-- 【自检】城邦身份合规：修掉“城邦玩家 + 主流领袖”这类会让官方城邦面板打不开的状态
	pcall(RepairCityStatePlayerIdentities)
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
	ExposedMembers.ModMiscToolScript.InitializeCityStateGhostPlayers = InitializeCityStateGhostPlayers
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
	ExposedMembers.ModMiscToolScript.ClaimGhostPlayer = ClaimGhostPlayer
	ExposedMembers.ModMiscToolScript.ReleaseGhostPlayer = ReleaseGhostPlayer
	ExposedMembers.ModMiscToolScript.IsGhostPlayerClaimed = IsGhostPlayerClaimed
	ExposedMembers.ModMiscToolScript.GetGhostPlayerClaims = GetGhostPlayerClaims
	-- 城邦幽灵池（与主流幽灵池分开）：旧接口继续指主流幽灵，城邦走这一套。
	-- 池子只在建局侧按 mod 申报量产生；GetCityStateGhostPoolLimit 报告本局的申报上限
	-- （nil = 没这道数据/不限额，0 = 没有 mod 申报 ⇒ 不产生城邦幽灵）。
	-- 城邦身份合规：校验/修复（官方城邦面板要求“文明级 + 小文明原型领袖”）
	ExposedMembers.ModMiscToolScript.IsLegalCityStateIdentity = IsLegalCityStateIdentity
	ExposedMembers.ModMiscToolScript.RepairCityStatePlayerIdentities = RepairCityStatePlayerIdentities
	-- 见面幽灵转回主流（授权者 2026-10-15：见面后转城邦会让官方城邦面板打不开、回合被卡死）
	ExposedMembers.ModMiscToolScript.RestoreMetGhostsAsMajorPlayers = RestoreMetGhostsAsMajorPlayers
	ExposedMembers.ModMiscToolScript.LocalPlayerHasMet = LocalPlayerHasMet
	ExposedMembers.ModMiscToolScript.GetCityStateGhostPoolLimit = GetCityStateGhostPoolLimit
	ExposedMembers.ModMiscToolScript.GetMajorGhostPoolLimit = GetMajorGhostPoolLimit
	ExposedMembers.ModMiscToolScript.GetCityStateGhostPlayers = GetCityStateGhostPlayers
	ExposedMembers.ModMiscToolScript.GetCityStateGhostPlayerCount = GetCityStateGhostPlayerCount
	ExposedMembers.ModMiscToolScript.IsCityStateGhostPlayer = IsCityStateGhostPlayer
	ExposedMembers.ModMiscToolScript.IsCityStateGhostPlayerAvailable = IsCityStateGhostPlayerAvailable
	ExposedMembers.ModMiscToolScript.GetAvailableCityStateGhostPlayers = GetAvailableCityStateGhostPlayers
	ExposedMembers.ModMiscToolScript.GetAvailableCityStateGhostPlayerCount = GetAvailableCityStateGhostPlayerCount
	ExposedMembers.ModMiscToolScript.GetAvailableCityStateGhostPlayerID = GetAvailableCityStateGhostPlayerID
	ExposedMembers.ModMiscToolScript.ClaimAvailableCityStateGhostPlayer = ClaimAvailableCityStateGhostPlayer
	ExposedMembers.ModMiscToolScript.ClaimCityStateGhostPlayer = ClaimCityStateGhostPlayer
	ExposedMembers.ModMiscToolScript.ReleaseCityStateGhostPlayer = ReleaseCityStateGhostPlayer
	ExposedMembers.ModMiscToolScript.IsCityStateGhostPlayerClaimed = IsCityStateGhostPlayerClaimed
	ExposedMembers.ModMiscToolScript.GetCityStateGhostPlayerClaims = GetCityStateGhostPlayerClaims
	ExposedMembers.ModMiscToolScript.GetGhostPlayerPoolType = GetGhostPlayerPoolType
	ExposedMembers.ModMiscToolScript.IsKnownGhostPlayer = IsKnownGhostPlayer
	ExposedMembers.ModMiscToolScript.IsKnownGhostPlayerAvailable = IsKnownGhostPlayerAvailable
	ExposedMembers.ModMiscToolScript.ReleaseAnyGhostPlayer = ReleaseAnyGhostPlayer
	ExposedMembers.ModMiscToolScript.MovePlayerOffMap = MovePlayerOffMap
	-- 幽灵“新鲜度”：激活/建城后立刻出池；其它 mod 用完幽灵（比如定制附庸落地）也可主动刷新
	ExposedMembers.ModMiscToolScript.RemoveGhostPlayerFromPool = RemoveGhostPlayerFromPool
	ExposedMembers.ModMiscToolScript.RefreshGhostPoolsFromCities = RefreshGhostPoolsFromCities
	ExposedMembers.ModMiscToolScript.PlayerOwnsCity = PlayerOwnsCity
	ExposedMembers.ModMiscToolScript.ConvertGhostPlayerToCityState = ConvertGhostPlayerToCityState
	-- 一键把所有主流幽灵城邦化（面板按钮 = 手动入口，2026-10-26 起被拦截；
	-- 建首城自动路径由 TryAutoConvertGhostsOnFirstCity 传 'auto_first_city' 放行）
	ExposedMembers.ModMiscToolScript.ConvertAllGhostMajorPlayersToCityState = ConvertAllGhostMajorPlayersToCityState
	-- 幽灵“原身份”台账 + 自动城邦化（Vassal System 取幽灵时按原身份优先匹配）
	ExposedMembers.ModMiscToolScript.GetGhostOriginalIdentities = GetGhostOriginalIdentities
	ExposedMembers.ModMiscToolScript.GetGhostOriginalIdentity = GetGhostOriginalIdentity
	ExposedMembers.ModMiscToolScript.GetGhostOriginalIdentityScore = GetGhostOriginalIdentityScore
	ExposedMembers.ModMiscToolScript.RecordGhostOriginalIdentity = RecordGhostOriginalIdentity
	ExposedMembers.ModMiscToolScript.TryAutoConvertGhostsOnFirstCity = TryAutoConvertGhostsOnFirstCity
	ExposedMembers.ModMiscToolScript.IsGhostAutoConvertDone = IsGhostAutoConvertDone
	ExposedMembers.ModMiscToolScript.GetGhostifyBlockReason = GetGhostifyBlockReason
	-- 【授权者 2026-10-26】幽灵 debug 面板：列表快照 + 主流化 / 建城 / 移除
	ExposedMembers.ModMiscToolScript.GetGhostPlayerDebugList = GetGhostPlayerDebugList
	ExposedMembers.ModMiscToolScript.RestoreGhostPlayerAsMajor = RestoreGhostPlayerAsMajor
	ExposedMembers.ModMiscToolScript.FoundCityForGhostPlayer = FoundCityForGhostPlayer
	ExposedMembers.ModMiscToolScript.RemoveGhostPlayerByKillingUnits = RemoveGhostPlayerByKillingUnits
	-- 【授权者 2026-10-26】调试面板扩展：列出全部存活玩家；对任意玩家执行“杀死”
	--   （有城市 ⇒ 全部转自由城市；不杀单位，见 ModTool_GhostPlayers.lua 的注释）
	ExposedMembers.ModMiscToolScript.GetPlayerDebugList = GetPlayerDebugList
	ExposedMembers.ModMiscToolScript.KillSelectedPlayer = KillSelectedPlayer
	-- 救档：一键把未见面主流幽灵转成城邦（批量入口，来源 debug_panel）
	ExposedMembers.ModMiscToolScript.ConvertUnmetMajorGhostsToCityState = ConvertUnmetMajorGhostsToCityState
	ExposedMembers.ModMiscToolScript.ConfigureGhostPlayerIdentity = ConfigureGhostPlayerIdentity
	ExposedMembers.ModMiscToolScript.TransferCityToGhostPlayer = TransferCityToGhostPlayer
	ExposedMembers.ModMiscToolScript.CreateCityForGhostPlayer = CreateCityForGhostPlayer
	ExposedMembers.ModMiscToolScript.PlayerHasOnMapUnit = PlayerHasOnMapUnit
	-- 【2026-10-17 授权者】开拓者归位：城市落地时把地图外的开拓者移动进城市
	ExposedMembers.ModMiscToolScript.GetGhostSettlerCount = GetGhostSettlerCount
	ExposedMembers.ModMiscToolScript.GetGhostOffMapSettlerCount = GetGhostOffMapSettlerCount
	ExposedMembers.ModMiscToolScript.RelocateOffMapSettlersIntoCity = RelocateOffMapSettlersIntoCity
	ExposedMembers.ModMiscToolScript.EnsureGhostSettlerInCity = EnsureGhostSettlerInCity
	ExposedMembers.ModMiscToolScript.HandleGhostCityAddedToMap = HandleGhostCityAddedToMap
	ExposedMembers.ModMiscToolScript.HandleGhostCityTransfered = HandleGhostCityTransfered
	ExposedMembers.ModMiscToolScript.SweepGhostOffMapSettlers = SweepGhostOffMapSettlers
	ExposedMembers.ModMiscToolScript.IsGhostOrFormerGhost = IsGhostOrFormerGhost
	ExposedMembers.ModMiscToolScript.GetKnownGhostPlayerIDs = GetKnownGhostPlayerIDs
	ExposedMembers.ModMiscToolScript.allUnitData = allUnitData
	-- 派生索引：allUnitsTypeTable[playerID][unitTypeText][unitID] = unitData（只含活单位）
	ExposedMembers.ModMiscToolScript.allUnitsTypeTable = allUnitsTypeTable
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
	ExposedMembers.ModMiscToolScript.playerAssetsInfo = playerAssetsInfo
	ExposedMembers.ModMiscToolScript.playerPlotsInfo = playerPlotsInfo
	-- 暴露给其它 mod 的几组 API：**逐组 pcall** —— 某一组缺模块只打一行日志，
	-- 不会像以前那样把 Initialize 整段中断（那会把后面所有暴露一起带走）。
	local exposeGroups = {
		{
			Name = "DataStore",
			-- 跨存档数据存取（gameplay 侧）：底层是 Game:SetProperty，随存档自动保存/还原；
			-- UI 端用不了这个 API，需要就经 ExposedMembers 转。
			Run = function()
				ExposedMembers.ModMiscToolScript.SetData = ModMiscToolData.Set
				ExposedMembers.ModMiscToolScript.GetData = ModMiscToolData.Get
				ExposedMembers.ModMiscToolScript.HasData = ModMiscToolData.Has
				ExposedMembers.ModMiscToolScript.RemoveData = ModMiscToolData.Remove
				ExposedMembers.ModMiscToolScript.BuildDataKey = ModMiscToolData.BuildKey
			end,
		},
		{
			Name = "WorldBuilderAPI",
			-- WorldBuilder（地图编辑器）接口模块：Gameplay 后端，UI 层通过它调用
			Run = function()
				ExposedMembers.ModMiscToolScript.WorldBuilderAPI = WorldBuilderAPI
	ExposedMembers.ModMiscToolScript.MapRebuild = MapRebuild
	ExposedMembers.ModMiscToolScript.RebuildMap = MapRebuild.RebuildMap
			end,
		},
		{
			Name = "TurnEvents",
			-- 回合事件（gameplay 后端）：收件入列 + 到点执行 + 文本事件广播。
			-- 逻辑回合偏移由 UI 侧推过来（回合同步只做逻辑，不改引擎回合）。
			Run = function()
				ExposedMembers.ModMiscToolScript.TurnEvents = TurnEvents
			end,
		},
		{
			Name = "TurnEventHandlers",
			-- 回合事件的**默认处理方式**（金币/单位/资源）—— 其它 mod 可 Disable 或用更高
			-- 优先级的处理器接管；核心只做定时触发（见 ModTool_TurnEvents.lua 头注释）。
			Run = function()
				ExposedMembers.ModMiscToolScript.TurnEventHandlers = TurnEventHandlers
			end,
		},
		{
			Name = "TurnEraAPI",
			-- 回合 / 年代（gameplay 后端）：UI 层直调失败时经它兜底；也供别的 mod 直接用。
			-- 接口与静态依据见 ModTool_TurnEraAPI.lua 头部。
			Run = function()
				ExposedMembers.ModMiscToolScript.TurnEraAPI = TurnEraAPI
			end,
		},
	}
	for _, group in ipairs(exposeGroups) do
		local ok, err = pcall(group.Run)
		if ok then
			print("[ModMiscTool] exposed: " .. group.Name)
		else
			print("[ModMiscTool] 暴露 " .. group.Name .. " 失败 -> " .. tostring(err)
				.. "（只影响这一组，其余继续）")
		end
	end
end
Events.LoadGameViewStateDone.Add(Initialize)
