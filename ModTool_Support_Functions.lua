local maxAngle = 360
local waterTerrianClassIndex = GameInfo.TerrainClasses["TERRAIN_CLASS_WATER"].Index
local mountainTerrianClassIndex = GameInfo.TerrainClasses["TERRAIN_CLASS_MOUNTAIN"].Index
local unpack = table.unpack or unpack

--rely on UI script

function GetBuildingsIndexInPlot(plot)
	if plot == nil then return {} end
	local indexes = {}
	--exposed member changes in every mod
	local modMiscToolUI = ExposedMembers and ExposedMembers.ModMiscToolUI
	if not modMiscToolUI or not modMiscToolUI.GetBuildingsIndexAtPlotUI then
		indexes = GetAllBuildingsInPlotGameplay(plot)
	else
		indexes = modMiscToolUI.GetBuildingsIndexAtPlotUI(plot:GetX(), plot:GetY())
	end
	return indexes
end

--normal support functions

function TableContains(testTable, testElement)
	for _, value in ipairs(testTable) do
		if value == testElement then
			return true
		end
	end
	return false
end

function StringContains(strA, strB)
	if strB == "" then
		return true
	end
	return string.find(strA, strB, 1, true) ~= nil
end

function CopyTable(origTable)
	if type(origTable) ~= "table" then
		return origTable
	end
	local copy = {}
	for k, v in pairs(origTable) do
		if type(v) == "table" then
			copy[k] = CopyTable(v)
		else
			copy[k] = v
		end
	end
	return copy
end

function MergeTable(toTable, fromTable, seenTable)
	if toTable == nil or fromTable == nil then return end
	if type(toTable) ~= 'table' or type(fromTable) ~= 'table' then return end
	if seenTable == nil then
		seenTable = {}
		for _, value in ipairs(toTable) do
			seenTable[value] = true
		end
	end
	for _, value in ipairs(fromTable) do
		if not seenTable[value] then
			seenTable[value] = true
			table.insert(toTable, value)
		end
	end
end

function IsTableSame(t1, t2)
	if t1 == nil or t2 == nil then
		return t1 == t2
	end
	for key, value in pairs(t1) do
		if t2[key] == nil then
			return false
		end
		if type(value) == "table" and type(t2[key]) == "table" then
			if not IsTableSame(value, t2[key]) then
				return false
			end
		elseif value ~= t2[key] then
			return false
		end
	end
	for key, _ in pairs(t2) do
		if t1[key] == nil then
			return false
		end
	end
	return true
end

function TableIntersection(...)
	local tables = { ... }
	local tableCount = #tables
	if tableCount == 0 then return {} end
	if tableCount == 1 then
		local result = {}
		local seen = {}
		for _, value in ipairs(tables[1]) do
			if not seen[value] then seen[value] = true
			table.insert(result, value) end
		end
		return result
	end

	local lookups = {}
	for index = 2, tableCount do
		local lookup = {}
		for _, value in ipairs(tables[index]) do
			lookup[value] = true
		end
		lookups[index] = lookup
	end

	local function existsInAll(value)
		for index = 2, tableCount do
			if not lookups[index][value] then return false end
		end
		return true
	end

	local result = {}
	local seen = {}
	for _, value in ipairs(tables[1]) do
		if not seen[value] and existsInAll(value) then
			seen[value] = true
			table.insert(result, value)
		end
	end
	return result
end

function IsTableElementSame(table1, table2)
	if table1 == table2 then return true end
	if type(table1) ~= type(table2) then return false end
	for key, value1 in pairs(table1) do
		local value2 = table2[key]
		if type(value2) == 'table' then
			if type(value1) ~= 'table' or not IsTableElementSame(value1, value2) then
				return false
			end
		end
		if value1 ~= value2 then
			return false
		end
	end
	return true
end

function RemoveFromTable(targetTable, element)
	if #targetTable <= 0 then return end
	for i = #targetTable, 1, -1 do
		local shouldRemove = false
		if type(element) == 'table' then
			shouldRemove = IsTableElementSame(targetTable[i], element)
		else
			shouldRemove = (targetTable[i] == element)
		end
		if shouldRemove then
			table.remove(targetTable, i)
		end
	end
end

function GetTableNonSets(leftTable, rightTable)
	local leftUnique = {}
	local rightUnique = {}
	local function copyTable(src)
		local dst = {}
		for i, v in ipairs(src) do
			dst[i] = v
		end
		return dst
	end
		
	if #leftTable <= 0 then
		rightUnique = copyTable(rightTable)
		return leftUnique, rightUnique
	end
		
	if #rightTable <= 0 then
		leftUnique = copyTable(leftTable)
		return leftUnique, rightUnique
	end
	for i = 1, #leftTable do
		if not TableContains(rightTable, leftTable[i]) then
			table.insert(leftUnique, leftTable[i])
		end
	end
		
	for i = 1, #rightTable do
		if not TableContains(leftTable, rightTable[i]) then
			table.insert(rightUnique, rightTable[i])
		end
	end
	return leftUnique, rightUnique
end

function TableCountForDictionary(testTable)
	local count = 0
	for k, v in pairs(testTable) do
		count = count + 1
	end
	return count
end

function DatabaseToBool(value)
	if type(value) == "boolean" then
		return value
	elseif type(value) == "number" then
		return value == 1
	elseif type(value) == "string" then
		return value == "1" or value == "true"
	end
	return false
end

function GetRandomElements(inputTable, k)
	local result = {}
	local tableLength = #inputTable
	if k >= tableLength then
		return CopyTable(inputTable)
	end
	if tableLength <= 0 or k <= 0 then return {} end
	local selected = {}
	local selectedCount = 0
	while selectedCount < k do
		local randomIndex = ThrowDice(tableLength)
		if not selected[randomIndex] then
			selected[randomIndex] = true
			selectedCount = selectedCount + 1
			result[selectedCount] = inputTable[randomIndex]
		end
	end
	return result
end

function GetOrCreateNestedValue(table, elements)
	if not table or type(table) ~= "table" then return end
	if not elements or type(elements) ~= "table" or #elements <= 0 then return end
	local currentLevel = table
	for i = 1, #elements do
		local key = elements[i]
		if currentLevel[key] == nil then
			currentLevel[key] = {}
		elseif type(currentLevel[key]) ~= "table" then
			return currentLevel[key]
		end
		currentLevel = currentLevel[key]
	end
	return currentLevel
end

function GetNestedValue(table, elements)
	if not table or type(table) ~= "table" then return end
	if not elements or type(elements) ~= "table" or #elements <= 0 then return end
	local currentLevel = table
	for i = 1, #elements do
		local key = elements[i]
		if currentLevel[key] == nil then
			return nil
		elseif type(currentLevel[key]) ~= "table" then
			return currentLevel[key]
		end
		currentLevel = currentLevel[key]
	end
	return currentLevel
end

function ThrowDice(num)
	local dicePoint = Game.GetRandNum(num) + 1
	return dicePoint
end

function print_key_value_pairs(table, indent)
    indent = indent or 0
    local prefix = string.rep(" ", indent)
    
    if type(table) == "table" then
        for key, value in pairs(table) do
            if type(value) == "table" then
                print(prefix .. tostring(key) .. ":")
                print_key_value_pairs(value, indent + 2)
            else
                print(prefix .. tostring(key) .. ": " .. tostring(value))
            end
        end
    else
        print(prefix .. tostring(table))
    end
end

--[[
    GameCoordinate:(x,y)
    CalculatedCoordinate:[x,y]
    (0,2)        (1,2)
    [-0.5,2]     [0.5,2]
        #       #
         \     /
(-1,1)    \   /
[-1,1]     \ /        (1,1)
    #------ # ------# [1,1]
           / \  (0,1)
          /   \ [0,1]
         /     \
   (0,0)#       #(1,0)
   [-0.5,0]      [0.5,0]
--]]

function CalculateRealX(inputX, inputY)
    local realX
    local offsetX = ((math.abs(inputY)+2)%2)/2-0.5
    realX = inputX + offsetX
    return realX
end

function RevertToGameX(calculateX, gameY)
    local gameX
    local offsetX = ((math.abs(gameY)+2)%2)/2-0.5
    gameX = calculateX - offsetX
    return gameX
end

function IsInteger(num)
	return math.floor(num) == num
end

function GetMapMaxX()
    --print('starting calculate max X')
    local MaxX = 0
    local zeroPlots = Map.GetNeighborPlots(0, 0, 1)
    for _,ckPlot in ipairs(zeroPlots) do
        local ckX = ckPlot:GetX()
        if ckX >= MaxX then
            MaxX = ckX
        end
    end
    if MaxX <= 0 then
        print('error, failed to get size x')
        return
    end
    return MaxX
end

--convert civ6 coordinates into polar coordinates
--[[
    plots ipair order
    reversed clock
        7       2		17
         \     /	   /
          \   /		  /
           \ /       /
    3------ 1 ------6 ------16  Game Axis: 4
           / \  				New Axis: 0
          /   \ 
         /     \
        5       4
--]]

function AxisConverter(axisIndex)
    local conversionMap = {
        [0] = 1,
        [1] = 3,
        [2] = 5,
        [3] = 4,
        [4] = 0,
        [5] = 2
    }
    local result = conversionMap[axisIndex]
    if result == nil then
        print("Warning: Invalid axisIndex in AxisConverter:", axisIndex)
        result = 0
    end
    return result
end

function AxisAndOffsetCalculator(index, circum, length)
	local endPoint = 3 * length * (length + 1)
	local startPoint = endPoint - circum + 1
	local sideLength = length
	local axis = math.floor((index - startPoint)/sideLength)
	local offset = index - startPoint - axis * sideLength
	local newAxis = AxisConverter(axis)
	local newIndex = startPoint + newAxis * sideLength + offset
	local deltaAngle = maxAngle/circum
	--print('calculating angle', offset, newAxis, newIndex, deltaAngle)
	local angle = newAxis * (maxAngle/6) + offset * deltaAngle
	return newIndex, newAxis, offset, angle
end

function CalculatePlotData(plot, index, circum, length)
	local pData = {}
	if plot == nil then return nil end
	if index == 0 then return nil end
	local newIndex, newAxis, offset, angle = AxisAndOffsetCalculator(index, circum, length)
	pData.index = newIndex
	pData.iX = plot:GetX()
	pData.iY = plot:GetY()
	pData.length = length
	pData.circum = circum
	pData.axis = newAxis
	pData.offset = offset
	pData.angle = angle
	return pData
end

function CreateDataForPlots(plots)
	local length = 1
	local plotsData = {}
	for i,plot in ipairs(plots) do
		local circum = 6 * length
		local endPoint = 3 * length * (length + 1)
		local index = i - 1
		local iData = CalculatePlotData(plot, index, circum, length)
		if iData ~= nil then
			table.insert(plotsData, iData)
		end
		if index >= endPoint then length = length + 1 end
	end
	return plotsData
end

-- 返回 (iX,iY) 六边形范围内所有地块的索引（供 UI 层选点使用；UI 没有 Map.GetNeighborPlots）
function GetPlotsInRange(iX, iY, range)
	local plots = Map.GetNeighborPlots(iX, iY, range)
	local plotIndexes = {}
	if plots == nil then return plotIndexes end
	for _, plot in ipairs(plots) do
		if plot ~= nil then
			table.insert(plotIndexes, plot:GetIndex())
		end
	end
	return plotIndexes
end

function GetNearbyPlotsData(iX, iY, range)
	local plots = Map.GetNeighborPlots(iX, iY, range)
	local coordinatedPlotsData = CreateDataForPlots(plots)
	return coordinatedPlotsData
end

function GetNearbyUnits(iX, iY, range)
	local plots = Map.GetNeighborPlots(iX, iY, range)
	local units = GetAllUnitsInPlots(plots)
	return units
end

function GetNearbyEnemies(playerID, iX, iY, range)
	local plots = Map.GetNeighborPlots(iX, iY, range)
	local units = GetEnemyUnitsInPlots(playerID, plots)
	return units
end

function GetPlotRoute(iX, iY)
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return nil end
	return plot:GetRouteType()
end

function IsPlotHasDistrict(plot, districtIndex)
	if plot == nil then return false end
	local disType = plot:GetDistrictType()
	if disType == districtIndex then return true end
	return false
end

function AoeEnemiesForPlot(aoeX, aoeY, aoeOwner, aoeAmount, aoeRadius)
	local plots = Map.GetNeighborPlots(aoeX, aoeY, aoeRadius)
	local enemies = GetEnemyUnitsInPlots(aoeOwner, plots)
	for _,iEnemy in ipairs(enemies) do
		DamageToUnit(iEnemy, aoeOwner, aoeAmount)
	end
end

function AoeAllUnitsForPlot(aoeX, aoeY, aoeOwner, aoeAmount, aoeRadius)
	local plots = Map.GetNeighborPlots(aoeX, aoeY, aoeRadius)
	local enemies = GetAllUnitsInPlots(plots)
	for _,iEnemy in ipairs(enemies) do
		DamageToUnit(iEnemy, aoeOwner, aoeAmount)
	end
end

function DamageToUnit(targetUnit, damageFromPlayer, damageNum, isDamageToOwner)
	if targetUnit == nil or targetUnit:GetDamage() >= 100 then return true end
	if damageNum == 0 then return false end
	if isDamageToOwner == nil then isDamageToOwner = false end
	if targetUnit:GetOwner() == damageFromPlayer and isDamageToOwner ~= true then return false end
	local unitDamage = targetUnit:GetDamage()
	local unitHealth = 100 - unitDamage
	damageNum = math.min(damageNum, unitHealth)
	damageNum = math.max(damageNum, -unitDamage)
	if damageNum + unitDamage >= 100 then
		targetUnit:SetDamage(100)
		UnitManager.Kill(targetUnit)
		return true
	else
		targetUnit:ChangeDamage(damageNum)
		return false
	end
end

function ChangePlotToRoad(plotIndex, roadIndex)
	local plot = Map.GetPlotByIndex(plotIndex)
	if plot == nil then return end
	if not IsPlotValidForPlaceRoute(plot, roadIndex) then return end
	RouteBuilder.SetRouteType(plot, roadIndex)
end

function IsPlotValidForPlaceRoute(plot, roadIndex)
	local plotRoadIndex = plot:GetRouteType()
	if plotRoadIndex == roadIndex then return false end
	local terrianClass = plot:GetTerrainClassType()
	if terrianClass == waterTerrianClassIndex then return false end
	return true
end

function IsPlotValidForRouteUpgrade(plotIndex, roadIndex)
	local plot = Map.GetPlotByIndex(plotIndex)
	if plot == nil then return false end
	local plotRoadIndex = plot:GetRouteType()
	if plotRoadIndex == -1 or plotRoadIndex == nil then return true end
	if plotRoadIndex == roadIndex then return false end
	local newMovementCost = GameInfo.Routes[roadIndex].MovementCost
	local oldMovementCost = GameInfo.Routes[plotRoadIndex].MovementCost
	if newMovementCost > oldMovementCost then return false end
	return true
end

function PlotIndexToXY(plotIndex)
    local plot = Map.GetPlotByIndex(plotIndex)
	if plot == nil then return nil, nil end
	local iX = plot:GetX()
	local iY = plot:GetY()
	if math.abs(iX) == 9999 or math.abs(iY) == 9999 then return nil, nil end
	return iX, iY
end

function CoordinateToPlotIndex(iX, iY)
	if math.abs(iX) == 9999 or math.abs(iY) == 9999 then return nil end
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return nil end
	return plot:GetIndex()
end

function IsPlayerAtWar(firstID, secondID)
	local firstPlayer = Players[firstID]
	if firstPlayer == nil then return false end
	if firstPlayer:GetDiplomacy():IsAtWarWith(secondID) then
		return true
	end
	return false
end

function IsPlayerHasAlliance(firstID, secondID)
	local firstPlayer = Players[firstID]
	if firstPlayer == nil then return false end
	if firstPlayer:GetDiplomacy():HasAllied(secondID) then
		return true
	end
	return false
end

function IsUnitValidEnemyForPlayer(playerID, unit)
	if unit == nil or unit:GetDamage() >= 100 then return false end
	if unit:GetCombat() <= 0 then return false end
	local unitOwnerID = unit:GetOwner()
	if IsPlayerAtWar(playerID, unitOwnerID) then
		return true
	end
	return false
end

function GetPlayerCapital(playerID)
	local player = Players[playerID]
	if player == nil then return nil end
	local playerCities = player:GetCities()
	if playerCities == nil then return nil end
	local capital = playerCities:GetCapitalCity()
	if capital == nil then return nil end
	return capital
end

function CheckIsPlayerDead(playerID)
	local playerCapital = GetPlayerCapital(playerID)
	if playerCapital ~= nil then return false end

	local defeatedPlayers = ExposedMembers
		and ExposedMembers.ModMiscToolScript
		and ExposedMembers.ModMiscToolScript.defeatedPlayers
	if defeatedPlayers ~= nil and not TableContains(defeatedPlayers, playerID) then
		table.insert(defeatedPlayers, playerID)
	end
	return true
end

function IsPlayerHasTech(playerID, techIndex)
	local player = Players[playerID]
	if player == nil then return false end
	return player:GetTechs():HasTech(techIndex)
end

function GetAllUnitsInPlots(plots)
	local units = {}
	for _,iPlot in ipairs(plots) do
		for _,unit in ipairs(Units.GetUnitsInPlotLayerID(iPlot:GetX(), iPlot:GetY(), MapLayers.ANY)) do
			table.insert(units, unit)
		end
	end
	return units
end

function GetEnemyUnitsInPlots(playerID, plots)
	local enemyUnits = {}
	local units = GetAllUnitsInPlots(plots)
	for _,iUnit in ipairs(units) do
		if IsUnitValidEnemyForPlayer(playerID, iUnit) then
			table.insert(enemyUnits, iUnit)
		end
	end
	return enemyUnits
end

function GetSettlerCoordinate(playerID)
	local units = GetPlayerUnitsList(playerID)
	for i, unit in ipairs(units) do
		if GameInfo.Units[unit:GetType()].UnitType=='UNIT_SETTLER' then
			return unit:GetX(), unit:GetY()
		end
	end
	return nil, nil
end

function GetCapitalCoordinate(playerID)
	local player = Players[playerID]
	local cities = player:GetCities()
	if cities == nil or cities:GetCapitalCity() == nil then return nil, nil end
	local capital = cities:GetCapitalCity()
	return capital:GetX(), capital:GetY()
end

function GetNearestCity(plotX, plotY, playerID)
	local dist = 9999
	local city = nil
	local playerCities = Players[playerID]:GetCities()
	if playerCities == nil then return nil end
	for i, iCity in playerCities:Members() do
		local iDistance = Map.GetPlotDistance(plotX, plotY, iCity:GetX(), iCity:GetY())
		if (iDistance < dist) then
			dist = iDistance
			city = iCity
		end
	end
	if city == nil then city = playerCities:GetCapitalCity() end
	return city, dist
end

function GetCityPlotIndex(city)
	if city == nil then return end
	local iX = city:GetX()
	local iY = city:GetY()
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return end
	return plot:GetIndex()
end

function GetCityForPlot(iX, iY)
    local plot = Map.GetPlot(iX, iY)
    if plot == nil then return end
    local city = Cities.GetPlotPurchaseCity(plot)
    return city
end

function RespawnUnit(unit, newX, newY, newOwnerID)
	local currentPromotions = {}
	for gPromotion in GameInfo.UnitPromotions() do
		if gPromotion ~= nil and unit:GetExperience():HasPromotion(gPromotion.Index) then
			table.insert(currentPromotions, gPromotion.Index)
		end
	end
	local oldUnitType = GameInfo.Units[unit:GetType()].UnitType
	local oldUnitMltFormation = unit:GetMilitaryFormation()
	local oldUnitDamage = unit:GetDamage()
	UnitManager.Kill(unit)
	local newUnit = UnitManager.InitUnit(newOwnerID, oldUnitType, newX, newY)
	if newUnit == nil then return end
	newUnit:SetDamage(oldUnitDamage)
	if #currentPromotions > 0 then
		for _, promotionIndex in ipairs(currentPromotions) do
			newUnit:GetExperience():SetPromotion(promotionIndex)
		end
	end
	if (oldUnitMltFormation ~= nil and oldUnitMltFormation > 0) then
		newUnit:SetMilitaryFormation(oldUnitMltFormation)
	end
	return newUnit
end

function IsPlotHasDefense(plot)
	if plot == nil then return false end
	local disType = plot:GetDistrictType()
	if disType == nil or disType == -1 then return false end
	local district = CityManager.GetDistrictAt(plot:GetX(), plot:GetY())
	if district == nil then return false end
	local districtHitpoints = district:GetMaxDamage(DefenseTypes.DISTRICT_GARRISON)
	if districtHitpoints == nil or districtHitpoints <= 0 then return false end
	return true
end

function IsPlotPassableForUnit(unit, plot)
	if unit == nil or plot == nil then return false end
	local terrianClass = plot:GetTerrainClassType()
	if terrianClass == mountainTerrianClassIndex then return false end
	if IsPlotHasDefense(plot) and plot:GetOwner() ~= unit:GetOwner() then return false end
	local unitDomain = GameInfo.Units[unit:GetType()].Domain
	if unitDomain == 'DOMAIN_SEA' and terrianClass ~= waterTerrianClassIndex then return false end
	if unitDomain == 'DOMAIN_LAND' and terrianClass == waterTerrianClassIndex then return false end
	return true
end

function AddDummyBuilding(city, buildingIndex)
    if not city:GetBuildings():HasBuilding(buildingIndex) then
		city:GetBuildQueue():CreateIncompleteBuilding(buildingIndex, city:GetPlot(), 100)
	end
end

function RemoveDummyBuilding(city, buildingIndex)
    if city:GetBuildings():HasBuilding(buildingIndex) then
		city:GetBuildings():RemoveBuilding(buildingIndex)
	end
end

function GetPlayerLeaderAndCivType(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return nil, nil end
	local civType = playerConfig:GetCivilizationTypeName()
	local leaderType = playerConfig:GetLeaderTypeName()
	return leaderType, civType
end

function GetPlayerTraits(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return {} end
	local leaderType = playerConfig:GetLeaderTypeName()
	local civType = playerConfig:GetCivilizationTypeName()
	local Traits = {}
	for civTrait in GameInfo.CivilizationTraits() do
		if civTrait.CivilizationType == civType then table.insert(Traits, civTrait.TraitType) end
	end
	for leaderTrait in GameInfo.LeaderTraits() do
		if leaderTrait.LeaderType == leaderType then table.insert(Traits, leaderTrait.TraitType) end
	end
	return Traits
end

function IsPlayerHasTrait(playerID, traitType)
	local traits = GetPlayerTraits(playerID)
	return TableContains(traits, traitType)
end

function IsPlotHasRiver(iX, iY)
	local plot = Map.GetPlot(iX, iY)
	if plot == nil then return false end
	local riverCount = plot:GetRiverCrossingCount()
	if riverCount <= 0 then return false end
	return true
end

function IsPlotCoastal(iX, iY)
	local plots = Map.GetNeighborPlots(iX, iY, 1)
	local isCoastal = false
	for _,plot in ipairs(plots) do
		if plot:GetTerrainClassType() == waterTerrianClassIndex then isCoastal = true end
	end
	return isCoastal
end

function GetCoastalCityForPlayer(playerID)
	local player = Players[playerID]
	if player == nil then return nil end
	local cities = player:GetCities()
	if cities == nil then return nil end
	for i, city in cities:Members() do
		if IsPlotCoastal(city:GetX(), city:GetY()) then
			return city
		end
	end
	return nil
end

function GetSpawnLocationForUnitType(playerID, unitType)
	local unitDomain = GameInfo.Units[unitType].Domain
	if unitDomain == 'DOMAIN_LAND' or unitDomain == 'DOMAIN_AIR' then
		return GetCapitalCoordinate(playerID)
	end
	local city = GetCoastalCityForPlayer(playerID)
	if city == nil then return nil, nil end
	return city:GetX(), city:GetY()
end

function SpawnUnitForPlayer(playerID, unitType)
	if unitType == nil or unitType == '' then return end
	local iX, iY = GetSpawnLocationForUnitType(playerID, unitType)
	if iX == nil or iY == nil then return end
	local newUnit = UnitManager.InitUnit(playerID, unitType, iX, iY)
	return newUnit
end

function GetUnitCoordinate(unit)
	if unit == nil or unit:GetDamage() >= 100 then return nil, nil end
	local unitX = unit:GetX()
	local unitY = unit:GetY()
	if unitX == 9999 or unitX == -9999 or unitY == 9999 or unitY == -9999 then return nil, nil end
	return unitX, unitY
end

function GetUnitPlotIndexAndCoordinate(unit)
	local unitX, unitY = GetUnitCoordinate(unit)
	if unitX == nil or unitY == nil then return nil, nil, nil end
	return CoordinateToPlotIndex(unitX, unitY), unitX, unitY
end

function GetSuzerainID(cityStateID)
	local player = Players[cityStateID]
	if player == nil then return nil end
	local playerInfluence = player:GetInfluence()
	if playerInfluence == nil then return nil end
	return playerInfluence:GetSuzerain()
end

function GetRingPlots(iX, iY, rangesTable)
	if iX == nil or iY == nil then return {} end
	if type(rangesTable) == 'number' then rangesTable = {rangesTable} end
	if type(rangesTable) ~= 'table' or #rangesTable <= 0 then rangesTable = {0} end
	table.sort(rangesTable)
	local uniqueRanges = {}
	local lastRange = nil
	for _, range in ipairs(rangesTable) do
		if range ~= lastRange then
			uniqueRanges[#uniqueRanges + 1] = range
			lastRange = range
		end
	end
	rangesTable = uniqueRanges
	local maxRange = rangesTable[#rangesTable]
	local plots = Map.GetNeighborPlots(iX, iY, maxRange)
	if not plots or #plots == 0 then return {} end
		
	local result = {}
	for _, range in ipairs(rangesTable) do
		result[range] = {}
	end
	local length = 0
	local endPoint = 0
	local rangeIndex = 1
		
	for i, plot in ipairs(plots) do
        local index = i - 1
        if index > 0 and index > endPoint then
            length = length + 1
            endPoint = 3 * length * (length + 1)
        end
        while rangeIndex <= #rangesTable and rangesTable[rangeIndex] < length do
            rangeIndex = rangeIndex + 1
        end
        if rangeIndex > #rangesTable then
            break
        end
        local range = rangesTable[rangeIndex]
        local rangeResults = result[range]
        rangeResults[#rangeResults + 1] = plot
    end
	return result
end

function DistrictDamage(plot, playerID, garrisonDamageValue, wallDamageValue, fractional, shouldDamageSelf)
	if shouldDamageSelf ~= false then shouldDamageSelf = true end
	if garrisonDamageValue == nil and wallDamageValue == nil then return end
	if garrisonDamageValue == nil then garrisonDamageValue = 0 end
	if wallDamageValue == nil then wallDamageValue = 0 end
	if fractional ~= false then fractional = true end
	if plot == nil then return end
	if plot:GetOwner() == playerID and shouldDamageSelf == false then return end
	local disType = plot:GetDistrictType()
	if disType == -1 or disType == nil then return end
	local district = CityManager.GetDistrictAt(plot:GetX(), plot:GetY())
	local districtHitpoints = district:GetMaxDamage(DefenseTypes.DISTRICT_GARRISON)
	if districtHitpoints == nil or districtHitpoints <= 0 then return end
	local currentDistrictDamage = district:GetDamage(DefenseTypes.DISTRICT_GARRISON)
	local wallHitpoints = district:GetMaxDamage(DefenseTypes.DISTRICT_OUTER)
	local currentWallDamage = district:GetDamage(DefenseTypes.DISTRICT_OUTER)
	local disHealth = districtHitpoints - currentDistrictDamage
	local wallHealth = wallHitpoints - currentWallDamage
	if fractional == true then
	    garrisonDamageValue = (garrisonDamageValue / 100) * districtHitpoints
	    wallDamageValue = (wallDamageValue / 100) * wallHitpoints
	end
	local disDamage = math.min(garrisonDamageValue, disHealth)
	disDamage = math.max(disDamage, -currentDistrictDamage)
	local wallDamage = math.min(wallDamageValue, wallHealth)
	wallDamage = math.max(wallDamage, -currentWallDamage)
	district:ChangeDamage(DefenseTypes.DISTRICT_GARRISON, disDamage)
	district:ChangeDamage(DefenseTypes.DISTRICT_OUTER, wallDamage)
end

function ChangePlotImprovementStatus(plot, command)
	if command == 'no_effect' or command == nil then return end
	if plot == nil then return end
	local improvementTypeIndex = plot:GetImprovementType()
	if improvementTypeIndex == nil or improvementTypeIndex == -1 then return end
	if command == 'repair' then ImprovementBuilder.SetImprovementPillaged(plot, false) return end
	if command == 'pillage' then ImprovementBuilder.SetImprovementPillaged(plot, true) return end
	if command == 'remove' then ImprovementBuilder.SetImprovementType(plot, -1, -1) return end
end

function ChangePlotDistrictStatus(plot, command)
	if command == 'no_effect' or command == nil then return end
	if plot == nil then return end
	local disType = plot:GetDistrictType()
	if disType == nil or disType == -1 then return end
	local district = CityManager.GetDistrictAt(plot:GetX(), plot:GetY())
	if district == nil then return end
	if command == 'repair' then district:SetPillaged(false) return end
	if command == 'pillage' then district:SetPillaged(true) return end
	if command == 'remove' then RemoveDistrict(plot) return end
end

function ChangePlotRoadStatus(plot, command)
	if command == 'no_effect' or command == nil then return end
	if plot == nil then return end
	local routeType = plot:GetRouteType()
	if routeType == -1 then return end
	if command == 'repair' then RouteBuilder.SetRoutePillaged(plot, false) return end
	if command == 'pillage' then RouteBuilder.SetRoutePillaged(plot, true) return end
	if command == 'remove' then RouteBuilder.SetRouteType(plot, -1) return end
end

function ChangePlotBuildingStatus(plot, command, depth)
	if command == 'no_effect' or command == nil then return end
	local plotBuildings = GetBuildingsIndexInPlot(plot)
	if plotBuildings == nil or #plotBuildings <= 0 then return end
	local city = Cities.GetPlotPurchaseCity(plot)
	if city == nil then return end
	local cityBuildings = city:GetBuildings()
	if depth == nil then depth = 99 end
	for i,buildingIndex in ipairs(plotBuildings) do
		if i >= depth then break end
		if command == 'repair' then cityBuildings:SetPillaged(buildingIndex, false)
		elseif command == 'pillage' then cityBuildings:SetPillaged(buildingIndex, true)
		elseif command == 'remove' then cityBuildings:RemoveBuilding(buildingIndex)
		end
	end
end

function DamageToUnitsInPlots(plots, playerID, damageNum, isDamageToOwner)
	if damageNum == nil or damageNum == 0 then return end
	if plots == nil or #plots <= 0 then return end
	local units = GetAllUnitsInPlots(plots)
	if #units <= 0 then return end
	for _,unit in ipairs(units) do
		DamageToUnit(unit, playerID, damageNum, isDamageToOwner)
	end
end

function ChangePlotFalloutStatus(plot, falloutTurns)
	if falloutTurns == 0 then return end
	if plot == nil or falloutTurns == nil then return end
	local plotIndex = plot:GetIndex()
	local currentFalloutTurns = Game.GetFalloutManager():GetFalloutTurnsRemaining(plotIndex)
	local turns = currentFalloutTurns + falloutTurns
	if turns <= 0 then Game.GetFalloutManager():RemoveFallout(plotIndex) return end
	Game.GetFalloutManager():SetFalloutTurnsRemaining(plotIndex, turns)
end

--less effective than UI version
function GetAllBuildingsInPlotGameplay(plot)
	local disType = plot:GetDistrictType()
	if disType == nil or disType == -1 then return {} end
	local city = Cities.GetPlotPurchaseCity(plot)
	if city == nil then return {} end
	local plotIndex = plot:GetIndex()
	local cityBuildings = city:GetBuildings()
	local disTypeText = GameInfo.Districts[disType].DistrictType
	if disTypeText == nil then return {} end
	local possibleBuildingsIndex = {}
	for buildingRow in GameInfo.Buildings() do
		if buildingRow.PrereqDistrict == disTypeText or (buildingRow.IsWonder == true and disTypeText == 'DISTRICT_WONDER') then
			table.insert(possibleBuildingsIndex, buildingRow.Index)
		end
	end
	if #possibleBuildingsIndex <= 0 then return {} end
	local existedBuildings = {}
	for _,buildingIndex in ipairs(possibleBuildingsIndex) do
		if cityBuildings:HasBuilding(buildingIndex) then
			table.insert(existedBuildings, buildingIndex)
		end
	end
	if #existedBuildings <= 0 then return {} end
	local returnList = {}
	for _,buildingIndex in ipairs(existedBuildings) do
		local buildingPlotIndex = cityBuildings:GetBuildingLocation(buildingIndex)
		if plotIndex == buildingPlotIndex then
			table.insert(returnList, buildingIndex)
		end
	end
	return returnList
end

function RemoveDistrict(plot)
	if plot == nil then return end
	--remove district requires a dummy district, otherwise game can not remove specific district when there are multiple districts in same type
	local disType = plot:GetDistrictType()
	if disType == nil or disType == -1 then return end
	local distObject = CityManager.GetDistrictAt(plot)
	if distObject == nil then return end
	local city = distObject:GetCity()
	if city == nil then return end
	if GameInfo.Districts[disType].DistrictType == 'DISTRICT_CITY_CENTER' then
		CityManager.DestroyCity(city)
	end
	if GameInfo.Districts['DISTRICT_KOCMOCA_DUMMY_FOR_REMOVAL'] == nil then
		print('error, no dummy district defined')
		return
	end
	local dummyDistrictIndex = GameInfo.Districts['DISTRICT_KOCMOCA_DUMMY_FOR_REMOVAL'].Index
	city:GetBuildQueue():CreateIncompleteDistrict(dummyDistrictIndex, plot, 100)
	distObject = CityManager.GetDistrictAt(plot)
	if distObject == nil then return end
	WorldBuilder.CityManager():RemoveDistrict(distObject)
end

function ChangeCityPopulation(playerID, city, changeValue, shouldAffectSelf)
	local cityOwner = city:GetOwner()
	if shouldAffectSelf == nil then shouldAffectSelf = true end
	if cityOwner == playerID and shouldAffectSelf == false then return end
	local population = city:GetPopulation()
	if changeValue + population < 1 then changeValue = population - 1 end
	city:ChangePopulation(changeValue)
end

function ChangePlayerWeaponCount(playerID, weaponIndex, changeNumber)
	local player = Players[playerID]
	if player == nil then return end
	local weaponType = GameInfo.WMDs[weaponIndex].WeaponType
	local playerWMDs = player:GetWMDs()
	local count = playerWMDs:GetWeaponCount(weaponIndex)
	if changeNumber < 0 then changeNumber = math.max(changeNumber, -count) end
	playerWMDs:ChangeWeaponCount(weaponType, changeNumber)
end

function GetPlotsVisibility(playerID, plots)
	local playerVisibility = PlayersVisibility[playerID]
	for _,plot in ipairs(plots) do
		playerVisibility:ChangeVisibilityCount(plot:GetIndex(), 1)
	end
end

function ChangePlayerGoldAmount(playerID, amount)
	local player = Players[playerID]
	if player == nil then return end
	local playerTreasury = player:GetTreasury()
	playerTreasury:ChangeGoldBalance(amount)
end

function ChangePlayerFaithAmount(playerID, amount)
	local player = Players[playerID]
	if player == nil then return end
	local playerReligion = player:GetReligion()
	playerReligion:ChangeFaithBalance(amount)
end

function GetPlayerValidRoute(playerID)
    local player = Players[playerID]
    if player == nil then return end
    
    local eraToRoute = {}
    local validEras = {}
    
    for routeRow in GameInfo.Routes() do
        if routeRow.PrereqEra then
            local routeEraIndex = GameInfo.Eras[routeRow.PrereqEra].Index
            eraToRoute[routeEraIndex] = routeRow.Index
            table.insert(validEras, routeEraIndex)
        end
    end
    
    table.sort(validEras, function(a, b) return a < b end)
    
    local highestRouteEraIndex = 0
    local playerEraIndex = player:GetEra()
    for i = #validEras, 1, -1 do
        if validEras[i] <= playerEraIndex then
            highestRouteEraIndex = validEras[i]
            break
        end
    end
    
    return eraToRoute[highestRouteEraIndex]
end

function GetPlayerCitiesList(playerID)
	local player = Players[playerID]
	if player == nil then return {} end
	local playerCities = player:GetCities()
	if playerCities == nil then return {} end
	local result = {}
	for i,city in playerCities:Members() do
		table.insert(result, city)
	end
	return result
end

function GetPlayerUnitsList(playerID)
	local player = Players[playerID]
	if player == nil then return {} end
	local result = {}
	local units = player:GetUnits()
	for i, unit in units:Members() do
		table.insert(result, unit)
	end
	return result
end

function GetLeaderIconAndName(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return nil, nil end
	local player = Players[playerID]
	if player == nil then return nil, nil end
	local leaderType = playerConfig:GetLeaderTypeName()
	local leaderIcon = 'ICON_'..leaderType
	local leaderName = GameInfo.Leaders[leaderType].Name
	if not player:IsMajor() then
        local civType = playerConfig:GetCivilizationTypeName()
        leaderIcon = 'ICON_'..civType
	end
	return leaderIcon, leaderName
end

function GetCivilizationIconAndName(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then return nil, nil end
	local player = Players[playerID]
	if player == nil then return nil, nil end
	local civType = playerConfig:GetCivilizationTypeName()
	local civIcon = 'ICON_'..civType
	local civName = GameInfo.Civilizations[civType].Name
	return civIcon, civName
end

function GetUnitIconAndName(unitIndex)
	local unitRow = GameInfo.Units[unitIndex]
	if unitRow == nil then return nil, nil, nil end
	local unitType = unitRow.UnitType
	local unitName = unitRow.Name
	local unitIcon = 'ICON_'..unitType
	local unitPortrait = 'ICON_'..unitType..'_PORTRAIT'
	return unitIcon, unitPortrait, unitName
end

function CanUnitTypeGetExp(unitIndex)
	local unitRow = GameInfo.Units[unitIndex]
	if unitRow == nil then return false end
	local promotionClass = unitRow.PromotionClass
	if promotionClass == nil then return false end

	local canEarnExperience = true
	local unitXP2Row
	if GameInfo.Units_XP2 ~= nil then
		unitXP2Row = GameInfo.Units_XP2[unitIndex]
	end
	if unitXP2Row ~= nil and unitXP2Row.CanEarnExperience ~= nil then
		canEarnExperience = unitXP2Row.CanEarnExperience
	elseif unitRow.CanEarnExperience ~= nil then
		canEarnExperience = unitRow.CanEarnExperience
	end
	if canEarnExperience == false then return false end
	return IsPromotionClassHasPromotion(promotionClass)
end

function IsPromotionClassHasPromotion(promotionClassType)
	local promotionClassRow = GameInfo.UnitPromotionClasses[promotionClassType]
	if promotionClassRow == nil then return false end
	local modMiscToolUI = ExposedMembers and ExposedMembers.ModMiscToolUI
	local allPromotions = modMiscToolUI and modMiscToolUI.allUnitPromotions
	if allPromotions == nil then return true end
	local promotionsInClass = allPromotions[promotionClassType]
	if promotionsInClass == nil or #promotionsInClass <= 0 then return false end
	return true
end

function IsPlotValidForPass(plotIndex, isWaterPlotValid)
	if isWaterPlotValid == nil then isWaterPlotValid = false end
	local plot = Map.GetPlotByIndex(plotIndex)
	if plot == nil then return false end
	local terrianClass = plot:GetTerrainClassType()
	if terrianClass == nil then return false end
	if terrianClass == mountainTerrianClassIndex then return false end
	if terrianClass == waterTerrianClassIndex and not isWaterPlotValid then return false end
	return true
end

function GetPathInRadius(plotIndex, targetPlotIndexList, maxRadius, isWaterPlotValid)
	if maxRadius == nil then maxRadius = 32 end
	if isWaterPlotValid == nil then isWaterPlotValid = false end
	if type(targetPlotIndexList) ~= "table" then
		targetPlotIndexList = {targetPlotIndexList}
	end

	local fromPlot = Map.GetPlotByIndex(plotIndex)
	if fromPlot == nil then print('GetPathInRadius: fromPlot is nil for index', plotIndex); return {} end
	local fromX, fromY = fromPlot:GetX(), fromPlot:GetY()

	-- 过滤目标：只保留在 maxRadius 范围内的格子，并找出最远距离
	local filteredTargets = {}
	local maxTargetDistance = 0
	local function CheckSinglePlotDistance(targetIndex)
		local targetPlot = Map.GetPlotByIndex(targetIndex)
		if targetPlot == nil then return end
		local dist = Map.GetPlotDistance(fromX, fromY, targetPlot:GetX(), targetPlot:GetY())
		if dist > maxRadius then return end
		filteredTargets[targetIndex] = true
		if dist > maxTargetDistance then
			maxTargetDistance = dist
		end
	end
	for _, targetIndex in ipairs(targetPlotIndexList) do
		CheckSinglePlotDistance(targetIndex)
	end

	local result = {}

	-- 起点本身是目标的情况
	if filteredTargets[plotIndex] then
		filteredTargets[plotIndex] = nil
		result[plotIndex] = {plotIndex}
	end

	if not next(filteredTargets) then
		print('GetPathInRadius: no valid targets within radius')
		return result
	end

    --[[
	print('GetPathInRadius start', 'from', plotIndex,
		'fromXY', fromX, fromY,
		'maxRadius', maxRadius, 'waterValid', isWaterPlotValid,
		'maxTargetDistance', maxTargetDistance,
		'targetsCount', #targetPlotIndexList)--]]

	-- 使用 Map.GetNeighborPlots 获取最远距离半径内的所有单元格
	local neighborPlots = Map.GetNeighborPlots(fromX, fromY, maxTargetDistance)
	--print('GetPathInRadius: neighborPlots count=', neighborPlots and #neighborPlots or -1)
	if not neighborPlots or #neighborPlots == 0 then
		--print('GetPathInRadius: no neighbor plots found, maxTargetDistance=', maxTargetDistance)
		return result
	end

	-- 构建该半径内的有效单元格集合（含起点）
	local validCount = 0
	local validPlots = {}
	validPlots[plotIndex] = true
	validCount = validCount + 1
	for i = 1, #neighborPlots do
		local nPlot = neighborPlots[i]
		if nPlot then
			local nIndex = nPlot:GetIndex()
			if nIndex and IsPlotValidForPass(nIndex, isWaterPlotValid) then
				validPlots[nIndex] = true
				validCount = validCount + 1
			end
		end
	end
	--print('GetPathInRadius: validPlots count=', validCount)

	-- BFS 在有效单元格集合内搜索所有目标的最短路径
	local visited = {}
	local parent = {}
	local queue = {plotIndex}
	visited[plotIndex] = true
	local foundCount = 0
	local targetCount = 0
	for _, _ in pairs(filteredTargets) do targetCount = targetCount + 1 end
	--print('GetPathInRadius: BFS start targetCount=', targetCount)
	
	local function ReconstructPath(toIndex)
		local path = {}
		local current = toIndex
		while current ~= plotIndex do
			table.insert(path, 1, current)
			current = parent[current]
			if current == nil then return nil end
		end
		table.insert(path, 1, plotIndex)
		return path
	end

	-- 检查起点相邻格，看是否在 validPlots 中
	local startPlot = Map.GetPlotByIndex(plotIndex)
	if startPlot then
		for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1, 1 do
			local nPlot = Map.GetAdjacentPlot(startPlot:GetX(), startPlot:GetY(), direction)
			if nPlot then
				local nIndex = nPlot:GetIndex()
				local inValid = validPlots[nIndex] and true or false
				local isValid = IsPlotValidForPass(nIndex, isWaterPlotValid) and true or false
				--print('GetPathInRadius: adj direction=', direction, 'index=', nIndex, 'inValidPlots=', inValid, 'IsPlotValidForPass=', isValid)
			end
		end
	end

	local idx = 1
	while idx <= #queue and targetCount > 0 do
		local current = queue[idx]

		if filteredTargets[current] then
			filteredTargets[current] = nil
			targetCount = targetCount - 1
			local path = ReconstructPath(current)
			if path then
				result[current] = path
				foundCount = foundCount + 1
			end
		end

		local plot = Map.GetPlotByIndex(current)
		if plot then
			for direction = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1, 1 do
				local nPlot = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), direction)
				if nPlot then
					local nIndex = nPlot:GetIndex()
					if not visited[nIndex] and validPlots[nIndex] then
						visited[nIndex] = true
						parent[nIndex] = current
						table.insert(queue, nIndex)
					end
				end
			end
		end

		idx = idx + 1
	end

	--print('GetPathInRadius: found=', foundCount, 'visited=', #queue)
	return result
end
