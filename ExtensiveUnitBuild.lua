include('ModTool_Support_Functions.lua')

--add these 3 table to ExposedMembers
local forceValidPlots = {}
local forceValidUnits = {}
local forceValidPlayers = {}

local terrainListData = {}
local featureListData = {}
local resourceListData = {}
local requiredPlotOwnerListData = {}
local plotOwnerRequiredAlliances = {}

-- ===========================================================================
-- 初始化：从 SQL 数据库加载查找表缓存
-- ===========================================================================

function InitializeRequiredTerrainList()
	if GameInfo.Kocmoca_Build_RequireTerrainList == nil then print("error: Kocmoca_Build_RequireTerrainList table not found") return end
	for terrainListRow in GameInfo.Kocmoca_Build_RequireTerrainList() do
		local terrainList = terrainListRow.TerrainList
		if terrainListData[terrainList] == nil then terrainListData[terrainList] = {} end
		local terrainIndex = GameInfo.Terrains[terrainListRow.TerrainType].Index
		table.insert(terrainListData[terrainList], terrainIndex)
	end
end

function InitializeRequiredFeatureList()
	if GameInfo.Kocmoca_Build_RequireFeatureList == nil then print('error: RequireFeatureList not found') return end
	for featureListRow in GameInfo.Kocmoca_Build_RequireFeatureList() do
		local featureList = featureListRow.FeatureList
		if featureListData[featureList] == nil then featureListData[featureList] = {} end
		local featureIndex = GameInfo.Features[featureListRow.FeatureType].Index
		table.insert(featureListData[featureList], featureIndex)
	end
end

function InitializeRequiredResourceList()
	if GameInfo.Kocmoca_Build_RequireResourceList == nil then print('error: RequireResourceList not found') return end
	for resourceListRow in GameInfo.Kocmoca_Build_RequireResourceList() do
		local resourceList = resourceListRow.ResourceList
		if resourceListData[resourceList] == nil then resourceListData[resourceList] = {} end
		local resourceIndex = GameInfo.Resources[resourceListRow.ResourceType].Index
		table.insert(resourceListData[resourceList], resourceIndex)
	end
end

function InitializeRequiredPlotOwnerList()
	if GameInfo.Kocmoca_Build_RequirePlotOwnerList == nil then print('error: RequirePlotOwnerList not found') return end
	for plotOwnerRow in GameInfo.Kocmoca_Build_RequirePlotOwnerList() do
		local plotOwnerList = plotOwnerRow.PlotOwnerList
		if requiredPlotOwnerListData[plotOwnerList] == nil then requiredPlotOwnerListData[plotOwnerList] = {} end
		table.insert(requiredPlotOwnerListData[plotOwnerList], plotOwnerRow.PlotOwnerType)
		if plotOwnerRow.PlotOwnerType == 'Allied' then
			if plotOwnerRequiredAlliances[plotOwnerList] == nil then plotOwnerRequiredAlliances[plotOwnerList] = {} end
			table.insert(plotOwnerRequiredAlliances[plotOwnerList], plotOwnerRow.RequiredAllianceType)
		end
	end
end

-- ===========================================================================
-- 核心判断：检查地块是否符合 CaseType 的全部要求
-- @param plotIndex  地块索引
-- @param CaseType   建筑案例类型（对应 Kocmoca_Build_Cases.CaseType）
-- @param playerID   建造者玩家 ID（用于地块归属判断）
-- ===========================================================================

function IsPlotMatchRequirement(plotIndex, CaseType, playerID)
	-- 强制有效检查（用于调试/override）
	local function CheckIsForceValid()
		if forceValidPlots[CaseType] == nil then return false end
		if TableContains(forceValidPlots[CaseType], plotIndex) then return true end
		return false
	end
	if CheckIsForceValid() then return true end

	-- 确认 CaseType 存在
	if GameInfo.Kocmoca_Build_Cases == nil then return false end
	local caseRow = GameInfo.Kocmoca_Build_Cases[CaseType]
	if caseRow == nil then return false end

	-- 无要求模型 = 无条件通过
	local RequirementModel = caseRow.RequirementModel
	if RequirementModel == nil then return true end

	-- 获取要求模型行
	local requirementRow = GameInfo.Kocmoca_Build_RequirementModels[RequirementModel]
	if requirementRow == nil then return true end

	-- 获取地块对象
	local plot = Map.GetPlotByIndex(plotIndex)
	if plot == nil then return false end

	-- 地形、地貌、资源列表任一匹配即可（OR）；空列表视为不限制
	local terrainList = requirementRow.TerrainList
	local featureList = requirementRow.FeatureList
	local resourceList = requirementRow.ResourceList
	local hasListRequirement = terrainList ~= nil or featureList ~= nil or resourceList ~= nil
	if hasListRequirement then
		local terrainMatched = terrainList ~= nil
			and CheckPlotTerrainRequirement(plot, terrainList)
		local featureMatched = featureList ~= nil
			and CheckPlotFeatureRequirement(plot, featureList)
		local resourceMatched = resourceList ~= nil
			and CheckPlotResourceRequirement(plot, resourceList)

		if not (terrainMatched or featureMatched or resourceMatched) then
			return false
		end
	end

	-- 地块归属、附加检查仍需同时满足
	if not CheckPlotOwnerListRequirement(plot, playerID, requirementRow.PlotOwnerList) then return false end
	if not AdditionalPlotCheck(plot, CaseType, playerID) then return false end

	return true
end

-- ===========================================================================
-- 检查地块特征（Feature）
-- ===========================================================================

function CheckPlotFeatureRequirement(plot, featureList)
	if featureList == nil then return true end
	if featureListData[featureList] == nil then return true end
	if #featureListData[featureList] <= 0 then return true end
	local feature = plot:GetFeature()
	if feature == nil then return false end
	local plotFeatureIndex = feature:GetType()
	if TableContains(featureListData[featureList], plotFeatureIndex) then return true end
	return false
end

-- ===========================================================================
-- 检查地块地形（Terrain）
-- ===========================================================================

function CheckPlotTerrainRequirement(plot, terrainList)
	if terrainList == nil then return true end
	if terrainListData[terrainList] == nil then return true end
	if #terrainListData[terrainList] <= 0 then return true end
	local plotTerrainIndex = plot:GetTerrainType()
	if TableContains(terrainListData[terrainList], plotTerrainIndex) then return true end
	return false
end

-- ===========================================================================
-- 检查地块资源（Resource）
-- ===========================================================================

function CheckPlotResourceRequirement(plot, resouceList)
	if resouceList == nil then return true end
	if resourceListData[resouceList] == nil then return true end
	if #resourceListData[resouceList] <= 0 then return true end
	local plotResource = plot:GetResourceType()
	if TableContains(resourceListData[resouceList], plotResource) then return true end
	return false
end

-- ===========================================================================
-- 地块归属检查（独立函数）
-- @param plot       地块对象
-- @param playerID   建造者玩家 ID
-- @param ownerType  归属类型：'Self' / 'Neutral' / 'Allied' / 'Hostile'
-- ===========================================================================

function CheckPlotOwnerMatch(plot, playerID, ownerType, plotOwnerList)
	if plot == nil then return false end
	local plotOwner = plot:GetOwner()

	if ownerType == 'Self' then
		return plotOwner == playerID
	elseif ownerType == 'Neutral' then
		return plotOwner == -1 or plotOwner == nil
	elseif ownerType == 'Allied' then
		if plotOwner == -1 or plotOwner == nil then return false end
		local hasAlliance = IsPlayerHasAlliance(playerID, plotOwner)
		if hasAlliance == false or hasAlliance == nil then return false end
		return IsAllianceTypeMetRequirement(playerID, plotOwner, plotOwnerList)
	elseif ownerType == 'Hostile' then
		if plotOwner == -1 or plotOwner == nil then return false end
		return IsPlayerAtWar(playerID, plotOwner)
	end

	return false
end

function IsAllianceTypeMetRequirement(playerID, subPlayerID, plotOwnerList)
	local allianceType = ExposedMembers.ModMiscToolUI.GetPlayerAllianceType(playerID, subPlayerID)
	local vallidAllianceList = plotOwnerRequiredAlliances[plotOwnerList]
	if vallidAllianceList == nil then return true end
	if #vallidAllianceList <= 0 then return true end
	if not TableContains(vallidAllianceList, allianceType) then return false end
	return true
end

-- ===========================================================================
-- 检查地块归属列表（独立函数）
-- 遍历 PlotOwnerList 中的所有类型，任一匹配即通过
-- ===========================================================================

function CheckPlotOwnerListRequirement(plot, playerID, plotOwnerList)
	if plotOwnerList == nil then return true end
	local ownerTypes = requiredPlotOwnerListData[plotOwnerList]
	if ownerTypes == nil then return true end
	for _, ownerType in ipairs(ownerTypes) do
		if CheckPlotOwnerMatch(plot, playerID, ownerType, plotOwnerList) then
			return true
		end
	end
	return false
end

-- ===========================================================================
-- 附加地块检查：根据 ItemCatagory 验证地块是否允许建造
-- ===========================================================================

function AdditionalPlotCheck(plot, CaseType, playerID)
	local caseRow = GameInfo.Kocmoca_Build_Cases[CaseType]
	if caseRow == nil then return false end
	local itemType = caseRow.ItemType
	local itemCatagory = caseRow.ItemCatagory
	local plotImprovementIndex = plot:GetImprovementType()
	local plotDistrictIndex = plot:GetDistrictType()
	local hasImprovement = (plotImprovementIndex ~= -1 and plotImprovementIndex ~= nil)
	local hasDistrict = (plotDistrictIndex ~= -1 and plotDistrictIndex ~= nil)

	if itemCatagory == 'Improvement' then
		if hasImprovement or hasDistrict then return false end
	elseif itemCatagory == 'District' then
		if hasDistrict then return false end
	elseif itemCatagory == 'Building' then
		if not hasDistrict then return false end
		local districtRow = GameInfo.Districts[plotDistrictIndex]
		if districtRow == nil then return false end
		local buildingRow = GameInfo.Buildings[itemType]
		if buildingRow == nil then return false end
		-- 直接查 GameInfo.Buildings.PrereqDistrict：地块上的区域必须是该建筑的前置区域
		return buildingRow.PrereqDistrict == districtRow.DistrictType
	elseif itemCatagory == 'Route' then
		local plotIndex = plot:GetIndex()
		local routeRow = GameInfo.Routes[itemType]
		if routeRow == nil then return false end
		local routeIndex = routeRow.Index
		return IsPlotValidForRouteUpgrade(plotIndex, routeIndex)
	end
	return true
end

-- ===========================================================================
-- 检查地块属性要求（通用）
-- 地块属性（PlotPropertyType）及数量（PlotPropertyNum）
-- ===========================================================================

function CheckPlotPropertyRequirement(plot, propertyType, propertyNum)
	if propertyType == nil then return true end
	local objectProperty = plot:GetProperty(propertyType)
	if objectProperty == nil then return false end
	if propertyNum ~= nil then
		if type(objectProperty) ~= 'number' then return false end
		if objectProperty < propertyNum then return false end
	end
	return true
end

-- ===========================================================================
-- 单位要求检查（硬性）
-- UnitType, AbilityType, BuildCharge, UnitPropertyType, UnitPropertyNum
-- ===========================================================================

function IsUnitMatchRequirement(unitID, CaseType, playerID)
	-- load CaseType's RequirementModel and CostModel from SQL
	-- force valid check
	local function CheckIsForceValid()
		if forceValidUnits[CaseType] == nil then return false end
		if TableContains(forceValidUnits[CaseType], unitID) then return true end
		return false
	end
	if CheckIsForceValid() then return true end

	local caseRow = GameInfo.Kocmoca_Build_Cases[CaseType]
	if caseRow == nil then return false end

	local reqTable = GameInfo.Kocmoca_Build_RequirementModels
		if reqTable == nil then return true end
		local requirementRow = reqTable[caseRow.RequirementModel]
	if requirementRow == nil then return true end

	local costTable = GameInfo.Kocmoca_Build_CostModels
		if costTable == nil then return true end
		local costRow = costTable[caseRow.CostModel]

	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil then return false end

	-- from RequirementModel: UnitType, AbilityType
	-- from CostModel: UnitPropertyType, UnitPropertyNum
	local unitPropertyType, unitPropertyNum
	if costRow ~= nil then
		unitPropertyType = costRow.UnitPropertyType
		unitPropertyNum = costRow.UnitPropertyNum
	end

	return CheckUnitHardRequirement(unit, requirementRow.UnitType, requirementRow.AbilityType, unitPropertyType, unitPropertyNum)
end

function CheckUnitHardRequirement(unit, unitType, abilityType, unitPropertyType, unitPropertyNum)
	if unit == nil then return false end

	-- 单位类型检查
	if unitType ~= nil then
		if GameInfo.Units[unit:GetType()].UnitType ~= unitType then return false end
	end

	-- 单位能力检查
	if abilityType ~= nil then
		if not unit:HasAbility(abilityType) then return false end
	end

	-- 单位属性检查
	if unitPropertyType ~= nil then
		local unitProp = unit:GetProperty(unitPropertyType)
		if unitProp == nil then return false end
		if unitPropertyNum ~= nil then
			if type(unitProp) ~= 'number' then return false end
			if unitProp < unitPropertyNum then return false end
		end
	end

	return true
end

-- ===========================================================================
-- 玩家要求检查（硬性）
-- TraitType, GoldAmount, FaithAmount, ResourceAmount,
-- PlayerPropertyType, PlayerPropertyNum
-- ===========================================================================

function IsPlayerMatchRequirement(CaseType, playerID)
	-- load CaseType's RequirementModel and CostModel from SQL
	-- force valid check
	local function CheckIsForceValid()
		if forceValidPlayers[CaseType] == nil then return false end
		if TableContains(forceValidPlayers[CaseType], playerID) then return true end
		return false
	end
	if CheckIsForceValid() then return true end

	local caseRow = GameInfo.Kocmoca_Build_Cases[CaseType]
	if caseRow == nil then return false end

	local reqTable = GameInfo.Kocmoca_Build_RequirementModels
		if reqTable == nil then return true end
		local requirementRow = reqTable[caseRow.RequirementModel]
	if requirementRow == nil then return true end

	local costTable = GameInfo.Kocmoca_Build_CostModels
		if costTable == nil then return true end
		local costRow = costTable[caseRow.CostModel]

	-- from RequirementModel: TraitType
	-- from CostModel: GoldAmount, FaithAmount, ResourceType, ResourceAmount, PlayerPropertyType, PlayerPropertyNum
	local goldAmount, faithAmount, resourceType, resourceAmount, playerPropertyType, playerPropertyNum
	if costRow ~= nil then
		goldAmount = costRow.GoldAmount
		faithAmount = costRow.FaithAmount
		resourceType = costRow.ResourceType
		resourceAmount = costRow.ResourceAmount
		playerPropertyType = costRow.PlayerPropertyType
		playerPropertyNum = costRow.PlayerPropertyNum
	end

	return CheckPlayerHardRequirement(playerID, requirementRow.TraitType, requirementRow.TechType, requirementRow.CivicType, goldAmount, faithAmount, resourceType, resourceAmount, playerPropertyType, playerPropertyNum)
end

function CheckPlayerHardRequirement(playerID, traitType, techType, civicType, goldAmount, faithAmount, resourceType, resourceAmount, playerPropertyType, playerPropertyNum)
	if playerID == nil then return false end
	local player = Players[playerID]
	if player == nil then return false end

	-- 特质检查
	if traitType ~= nil then
		if not IsPlayerHasTrait(playerID, traitType) then return false end
	end

	-- 科技检查（参照 WMD_Script: HasTech）
	if techType ~= nil then
		local playerTechs = player:GetTechs()
		local techRow = GameInfo.Technologies[techType]
		if techRow and not playerTechs:HasTech(techRow.Index) then return false end
	end

	-- 市政检查（参照 WMD_Script: HasCivic）
	if civicType ~= nil then
		local playerCivics = player:GetCulture()
		local civicRow = GameInfo.Civics[civicType]
		if civicRow and not playerCivics:HasCivic(civicRow.Index) then return false end
	end

	-- 金币量检查
	if goldAmount ~= nil and goldAmount ~= 0 then
		local treasury = player:GetTreasury()
		if treasury ~= nil and treasury:GetGoldBalance() < goldAmount then return false end
	end

	-- 信仰量检查
	if faithAmount ~= nil and faithAmount ~= 0 then
		local religion = player:GetReligion()
		if religion ~= nil and religion:GetFaithBalance() < faithAmount then return false end
	end

	-- 资源量检查
	if resourceType ~= nil and resourceAmount ~= nil and resourceAmount ~= 0 then
		local playerResources = player:GetResources()
		local currentAmount = playerResources:GetResourceAmount(resourceType)
		if currentAmount < resourceAmount then return false end
	end

	-- 玩家属性检查
	if playerPropertyType ~= nil then
		local playerProp = player:GetProperty(playerPropertyType)
		if playerProp == nil then return false end
		if playerPropertyNum ~= nil then
			if type(playerProp) ~= 'number' then return false end
			if playerProp < playerPropertyNum then return false end
		end
	end

	return true
end

-- ===========================================================================
-- 处理建造花费扣除
-- @param playerID  玩家 ID
-- @param unitID    单位 ID（可能为 nil）
-- @param costModel 花费模型名称（对应 CostModel）
-- ===========================================================================

function ProcessBuildCost(playerID, unitID, plotIndex, costModel)
	local costRow = GameInfo.Kocmoca_Build_CostModels[costModel]
	if costRow == nil then return end

	-- 消耗建造次数（使用 ModTool.lua 的 ChangeBuildCharge）
	if costRow.BuildCharge ~= nil and costRow.BuildCharge ~= 0 and unitID ~= nil then
		ExposedMembers.ModMiscToolScript.ChangeBuildCharge(playerID, unitID, -costRow.BuildCharge)
	end

	-- 消耗金币
	if costRow.GoldAmount ~= nil and costRow.GoldAmount ~= 0 then
		ChangePlayerGoldAmount(playerID, -costRow.GoldAmount)
	end

	-- 消耗信仰
	if costRow.FaithAmount ~= nil and costRow.FaithAmount ~= 0 then
		ChangePlayerFaithAmount(playerID, -costRow.FaithAmount)
	end

	-- 消耗资源（使用资源索引）
	if costRow.ResourceType ~= nil and costRow.ResourceAmount ~= nil and costRow.ResourceAmount ~= 0 then
		local resourceRow = GameInfo.Resources[costRow.ResourceType]
		if resourceRow ~= nil then
			local player = Players[playerID]
			if player ~= nil then
				local playerResources = player:GetResources()
				playerResources:ChangeResourceAmount(resourceRow.Index, -costRow.ResourceAmount)
			end
		end
	end

	-- 设置玩家属性（先读旧值再累加）
	if costRow.PlayerPropertyType ~= nil then
		local player = Players[playerID]
		if player ~= nil then
			local oldVal = player:GetProperty(costRow.PlayerPropertyType) or 0
			local newVal = oldVal + (costRow.PlayerPropertyNum or 0)
			player:SetProperty(costRow.PlayerPropertyType, newVal)
		end
	end

	-- 设置单位属性（先读旧值再累加）
	if costRow.UnitPropertyType ~= nil and unitID ~= nil then
		local unit = UnitManager.GetUnit(playerID, unitID)
		if unit ~= nil then
			local oldVal = unit:GetProperty(costRow.UnitPropertyType) or 0
			local newVal = oldVal + (costRow.UnitPropertyNum or 0)
			unit:SetProperty(costRow.UnitPropertyType, newVal)
		end
	end

	-- 设置地块属性（先读旧值再累加）
	if costRow.PlotPropertyType ~= nil then
		local plot = Map.GetPlotByIndex(plotIndex)
		if plot ~= nil then
			local oldVal = plot:GetProperty(costRow.PlotPropertyType) or 0
			local newVal = oldVal + (costRow.PlotPropertyNum or 0)
			plot:SetProperty(costRow.PlotPropertyType, newVal)
		end
	end
end

-- ===========================================================================
-- 在地图放置物件效果
-- 参照 ME_Builds_Bridge、ME_BuildCanal、Another Strategic Fort
-- ===========================================================================

-- 与 ME_Builds_Bridge 保持一致：优先取地块所属城市，没有时退回到玩家最近城市。
local function GetBuildCityForPlot(plot, playerID)
	if plot == nil then return nil end
	local city = GetCityForPlot(plot:GetX(), plot:GetY())
	if city == nil and playerID ~= nil then
		city = GetNearestCity(plot:GetX(), plot:GetY(), playerID)
	end
	return city
end

function ProcessBuildEffect(plot, itemType, itemCatagory, playerID)
	if plot == nil then return end

	if itemCatagory == 'Improvement' then
		local improvementRow = GameInfo.Improvements[itemType]
		if improvementRow ~= nil then
			ImprovementBuilder.SetImprovementType(plot, improvementRow.Index, playerID)
		end

	elseif itemCatagory == 'District' then
		local districtRow = GameInfo.Districts[itemType]
		if districtRow ~= nil then
			local city = GetBuildCityForPlot(plot, playerID)
			if city ~= nil then
				-- 参照 ME_BuildCanal：先清掉改良，再通过城市建造队列创建区域。
				WorldBuilder.CityManager():SetPlotOwner(plot, city)
				WorldBuilder.MapManager():SetImprovementType(plot, -1)
				city:GetBuildQueue():CreateIncompleteDistrict(districtRow.Index, plot, 100)
			end
		end

	elseif itemCatagory == 'Building' then
		local buildingRow = GameInfo.Buildings[itemType]
		if buildingRow ~= nil then
			local city = GetBuildCityForPlot(plot, playerID)
			if city ~= nil then
				-- 参照 ME_Builds_Bridge：先确保地块归属城市，再创建建筑。
				WorldBuilder.CityManager():SetPlotOwner(plot, city)
				city:GetBuildQueue():CreateIncompleteBuilding(buildingRow.Index, plot, 100)
			end
		end

	elseif itemCatagory == 'Route' then
		local routeRow = GameInfo.Routes[itemType]
		if routeRow ~= nil then
			-- 参照 Another Strategic Fort：走 ChangePlotToRoad 统一放置/升级道路。
			ChangePlotToRoad(plot:GetIndex(), routeRow.Index)
		end

	elseif itemCatagory == 'Terrain' then
		local terrainRow = GameInfo.Terrains[itemType]
		if terrainRow ~= nil then
			TerrainBuilder.SetTerrainType(plot, terrainRow.Index)
		end

	elseif itemCatagory == 'Feature' then
		local featureRow = GameInfo.Features[itemType]
		if featureRow ~= nil then
			local currentFeature = plot:GetFeatureType()
			if currentFeature ~= -1 and currentFeature ~= nil then
				TerrainBuilder.SetFeatureType(plot, -1)
			end
			TerrainBuilder.SetFeatureType(plot, featureRow.Index)
		end

	elseif itemCatagory == 'Resource' then
		local resourceRow = GameInfo.Resources[itemType]
		if resourceRow ~= nil then
			ResourceBuilder.SetResourceType(plot, resourceRow.Index, 1)
		end
	end
end

-- ===========================================================================
-- 后端邻居地块筛选（UI 环境无法调用 Map.GetNeighborPlots）
-- 返回满足 case 要求的相邻地块 index 数组，供 UI 侧显示地图选择按钮。
-- ===========================================================================

function GetBuildableNeighborPlotIndexes(playerID, unitID, caseType, buildRange)
	if playerID == nil or unitID == nil or caseType == nil then return nil end

	local unit = UnitManager.GetUnit(playerID, unitID)
	if unit == nil then return nil end

	local range = buildRange or 1
	local plots = Map.GetNeighborPlots(unit:GetX(), unit:GetY(), range)
	if plots == nil then return nil end

	local plotIndexes = {}
	for _, plot in ipairs(plots) do
		local plotIndex = plot:GetIndex()
		if IsPlotMatchRequirement(plotIndex, caseType, playerID) then
			table.insert(plotIndexes, plotIndex)
		end
	end
	return plotIndexes
end

-- ===========================================================================
-- BuildItemOnMap（核心建造入口）
-- 调用 ProcessBuildCost 扣除花费，调用 ProcessBuildEffect 放置物件
-- 所有需求检查已在 UI 侧完成，此处仅执行建造与消耗
-- ===========================================================================

function BuildItemOnMap(playerID, unitID, plotIndex, itemType, itemCatagory, costModel)
	if playerID == nil or plotIndex == nil then return end
	local plot = Map.GetPlotByIndex(plotIndex)
	if plot == nil then return end

	-- 扣除花费
	if costModel ~= nil then
		ProcessBuildCost(playerID, unitID, plotIndex, costModel)
	end

	-- 放置物件
	ProcessBuildEffect(plot, itemType, itemCatagory, playerID)

	-- 消耗单位移动力
	if unitID ~= nil then
		local unit = UnitManager.GetUnit(playerID, unitID)
		if unit ~= nil then
			-- 读取 CostModel 中的 UnitMovement，若未设定则消耗全部剩余移动力
			local movementCost
			if costModel ~= nil then
				local costRow = GameInfo.Kocmoca_Build_CostModels[costModel]
				if costRow ~= nil and costRow.UnitMovement ~= nil and costRow.UnitMovement ~= 0 then
					movementCost = costRow.UnitMovement
				end
			end
			if movementCost == nil then
				-- GetMovesRemaining 只能获取整数部分，但多扣不会导致问题
				movementCost = unit:GetMovesRemaining()
			end
			local movementLoss = math.ceil(movementCost)
			if movementLoss > 0 then
				UnitManager.ChangeMovesRemaining(unit, -movementLoss)
			end
		end
	end

	-- 建造完成事件（供其他 mod 监听）
	LuaEvents.ModMiscToolBuildCompleted.Call(playerID, unitID, plotIndex, itemType, itemCatagory, costModel)
end


function Initialize()
	InitializeRequiredTerrainList()
	InitializeRequiredFeatureList()
	InitializeRequiredResourceList()
	InitializeRequiredPlotOwnerList()
	if not ExposedMembers.ModMiscToolScript then
		ExposedMembers.ModMiscToolScript = {}
	end
	ExposedMembers.ModMiscToolScript.forceValidPlots = forceValidPlots
	ExposedMembers.ModMiscToolScript.forceValidUnits = forceValidUnits
	ExposedMembers.ModMiscToolScript.forceValidPlayers = forceValidPlayers
	ExposedMembers.ModMiscToolScript.IsPlayerMatchRequirement = IsPlayerMatchRequirement
	ExposedMembers.ModMiscToolScript.IsUnitMatchRequirement = IsUnitMatchRequirement
	ExposedMembers.ModMiscToolScript.IsPlotMatchRequirement = IsPlotMatchRequirement
	ExposedMembers.ModMiscToolScript.GetBuildableNeighborPlotIndexes = GetBuildableNeighborPlotIndexes
	ExposedMembers.ModMiscToolScript.BuildItemOnMap = BuildItemOnMap
end
Events.LoadGameViewStateDone.Add(Initialize)
