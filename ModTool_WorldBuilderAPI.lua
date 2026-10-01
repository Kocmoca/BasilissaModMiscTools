-- ===========================================================================
-- Mod Misc Tool: WorldBuilder（地图编辑器）接口封装（Gameplay 后端）
--
-- 本文件是独立模块，由 gameplay 脚本 ModTool.lua include，运行在 Gameplay Lua
-- 状态；再通过 ExposedMembers.ModMiscToolScript.WorldBuilderAPI 提供给 UI 层
-- （测试面板等）调用。mod 内其它 gameplay 逻辑（如 ExtensiveUnitBuild.lua）
-- 也是直接使用 WorldBuilder.* 的，因此这里沿用同一条调用路径。
--
-- 参考的原版实现：
--   Base/Assets/UI/WorldBuilder.lua
--   Base/Assets/UI/WorldBuilderPlayerEditor.lua
--   Base/Assets/UI/WorldBuilderPlacement.lua
--   Base/Assets/UI/WorldBuilderPlotEditor.lua
--   Base/Assets/UI/WorldBuilderMapEditor.lua
--
-- 这里的接口都取自原版地图编辑器的实际调用，方法名与参数顺序与原版保持一致；
-- 属于已知可用接口（[已验证可用]），因此直接调用，不做 API 存在性检测。
-- [已验证失败] 早期曾在 UI 层做存在性探测 —— 那是误判：UI 层看不到这些接口，
-- “探测不到”被当成了“不可用”。探测逻辑已全部移除。
--
-- 原版典型用法：
--   local player = WorldBuilder.PlayerManager():AddPlayer(true)
--   WorldBuilder.PlayerManager():SetPlayerLeader(player, "LEADER_TRAJAN", "CIVILIZATION_ROME", "CIVILIZATION_LEVEL_FULL_CIV")
--   WorldBuilder.PlayerManager():SetPlayerEra(player, "ERA_ANCIENT")
--   WorldBuilder.CityManager():Create(player, plot)
--   WorldBuilder.MapManager():SetTerrainType(plot, terrainIndex)
-- ===========================================================================

WorldBuilderAPI = WorldBuilderAPI or {}
local API = WorldBuilderAPI

-- ===========================================================================
-- 运行环境：WorldBuilder 及其管理器在普通对局的 Gameplay/UI Lua 状态中同样存在，
-- 可直接调用。IsActive() 只表示是否处于地图编辑器模式，供 UI 显示/判断，
-- 不作为接口可用性判定。
-- ===========================================================================

function API.IsActive()
    return WorldBuilder.IsActive() == true
end

function API.GetAdvancedMode()
    return WorldBuilder.GetWBAdvancedMode()
end

-- ===========================================================================
-- PlayerManager：添加文明 / 删除文明 / 改文明类型 / 领袖 / 时代 / 科技 / 金币
-- ===========================================================================

function API.AddPlayer(isAI)
    return WorldBuilder.PlayerManager():AddPlayer(isAI and true or false)
end

function API.RemovePlayer(playerID)
    return WorldBuilder.PlayerManager():UninitializePlayer(playerID)
end

function API.IsPlayerInitialized(playerID)
    return WorldBuilder.PlayerManager():IsPlayerInitialized(playerID)
end

function API.GetPlayerConfig(playerID)
    return WorldBuilder.PlayerManager():GetPlayerConfig(playerID)
end

function API.GetSlotStatus(slotIndex)
    return WorldBuilder.PlayerManager():GetSlotStatus(slotIndex)
end

function API.SetPlayerLeader(playerID, leaderType, civType, civLevel)
    return WorldBuilder.PlayerManager():SetPlayerLeader(playerID, leaderType, civType, civLevel)
end

function API.SetPlayerEra(playerID, eraType)
    return WorldBuilder.PlayerManager():SetPlayerEra(playerID, eraType)
end

function API.SetPlayerGold(playerID, amount)
    return WorldBuilder.PlayerManager():SetPlayerGold(playerID, amount)
end

function API.SetPlayerFaith(playerID, amount)
    return WorldBuilder.PlayerManager():SetPlayerFaith(playerID, amount)
end

function API.PlayerHasTech(playerID, techIndex)
    return WorldBuilder.PlayerManager():PlayerHasTech(playerID, techIndex)
end

function API.SetPlayerHasTech(playerID, techIndex, progress)
    return WorldBuilder.PlayerManager():SetPlayerHasTech(playerID, techIndex, progress)
end

function API.PlayerHasCivic(playerID, civicIndex)
    return WorldBuilder.PlayerManager():PlayerHasCivic(playerID, civicIndex)
end

function API.SetPlayerHasCivic(playerID, civicIndex, progress)
    return WorldBuilder.PlayerManager():SetPlayerHasCivic(playerID, civicIndex, progress)
end

function API.SetPlayerStartingPosition(playerID, plot)
    return WorldBuilder.PlayerManager():SetPlayerStartingPosition(playerID, plot)
end

function API.ClearPlayerStartingPosition(playerID)
    return WorldBuilder.PlayerManager():ClearPlayerStartingPosition(playerID)
end

function API.ClearStartingPosition(plot)
    return WorldBuilder.PlayerManager():ClearStartingPosition(plot)
end

function API.GetStartPositionInfo(plot)
    return WorldBuilder.PlayerManager():GetStartPositionInfo(plot)
end

function API.GetStartPositionPlayer(plot)
    return WorldBuilder.PlayerManager():GetStartPositionPlayer(plot)
end

function API.SetRandomMajorStartingPosition(plot)
    return WorldBuilder.PlayerManager():SetRandomMajorStartingPosition(plot)
end

function API.SetRandomMinorStartingPosition(plot)
    return WorldBuilder.PlayerManager():SetRandomMinorStartingPosition(plot)
end

function API.SetLeaderStartingPosition(leaderIndex, plot)
    return WorldBuilder.PlayerManager():SetLeaderStartingPosition(leaderIndex, plot)
end

function API.SetCivilizationStartingPosition(civIndex, plot)
    return WorldBuilder.PlayerManager():SetCivilizationStartingPosition(civIndex, plot)
end

-- ===========================================================================
-- CityManager：城市 / 区域 / 建筑 / 地块归属
-- ===========================================================================

function API.CreateCity(playerID, plot)
    return WorldBuilder.CityManager():Create(playerID, plot)
end

function API.RemoveCityAt(plot)
    return WorldBuilder.CityManager():RemoveAt(plot)
end

function API.RemoveCity(city)
    return WorldBuilder.CityManager():Remove(city)
end

function API.GetCity(playerID, cityID)
    return WorldBuilder.CityManager():GetCity(playerID, cityID)
end

function API.GetPlotOwner(plot)
    return WorldBuilder.CityManager():GetPlotOwner(plot)
end

function API.SetPlotOwner(plot, ownerID)
    return WorldBuilder.CityManager():SetPlotOwner(plot, ownerID)
end

function API.GetCityValue(city, valueName)
    return WorldBuilder.CityManager():GetCityValue(city, valueName)
end

function API.SetCityValue(city, valueName, value)
    return WorldBuilder.CityManager():SetCityValue(city, valueName, value)
end

function API.CreateDistrict(city, districtType, completePercent, plot)
    return WorldBuilder.CityManager():CreateDistrict(city, districtType, completePercent, plot)
end

function API.RemoveDistrict(district)
    return WorldBuilder.CityManager():RemoveDistrict(district)
end

function API.GetDistrictValue(district, valueName)
    return WorldBuilder.CityManager():GetDistrictValue(district, valueName)
end

function API.SetDistrictValue(district, valueName, value)
    return WorldBuilder.CityManager():SetDistrictValue(district, valueName, value)
end

function API.CreateBuilding(city, buildingType, completePercent, plot)
    return WorldBuilder.CityManager():CreateBuilding(city, buildingType, completePercent, plot)
end

function API.RemoveBuilding(city, buildingType)
    return WorldBuilder.CityManager():RemoveBuilding(city, buildingType)
end

-- ===========================================================================
-- MapManager：地形 / 特征 / 资源 / 改良 / 路线 / 河流 / 悬崖 / 可见度
-- ===========================================================================

function API.SetTerrainType(plot, terrainIndex)
    return WorldBuilder.MapManager():SetTerrainType(plot, terrainIndex)
end

function API.SetFeatureType(plot, featureIndex, options)
    return WorldBuilder.MapManager():SetFeatureType(plot, featureIndex, options)
end

function API.CanPlaceFeature(plot, featureIndex, options)
    return WorldBuilder.MapManager():CanPlaceFeature(plot, featureIndex, options)
end

function API.GetFeaturePlacementPlotList(plot, featureIndex, options)
    return WorldBuilder.MapManager():GetFeaturePlacementPlotList(plot, featureIndex, options)
end

function API.IsWonderTooClose(plot, featureIndex)
    return WorldBuilder.MapManager():IsWonderTooClose(plot, featureIndex)
end

function API.SetResourceType(plot, resourceIndex, amount)
    return WorldBuilder.MapManager():SetResourceType(plot, resourceIndex, amount)
end

function API.CanPlaceResource(plot, resourceIndex, ignoreExisting)
    return WorldBuilder.MapManager():CanPlaceResource(plot, resourceIndex, ignoreExisting)
end

function API.SetImprovementType(plot, improvementIndex, ownerID)
    return WorldBuilder.MapManager():SetImprovementType(plot, improvementIndex, ownerID)
end

function API.CanPlaceImprovement(plot, improvementIndex, ownerID, ignoreExisting)
    return WorldBuilder.MapManager():CanPlaceImprovement(plot, improvementIndex, ownerID, ignoreExisting)
end

function API.IsImprovementPlaceable(plot, improvementIndex)
    return WorldBuilder.MapManager():IsImprovementPlaceable(plot, improvementIndex)
end

function API.SetImprovementPillaged(plot, pillaged)
    return WorldBuilder.MapManager():SetImprovementPillaged(plot, pillaged)
end

function API.SetRouteType(plot, routeIndex, pillaged)
    return WorldBuilder.MapManager():SetRouteType(plot, routeIndex, pillaged)
end

function API.SetContinentType(plot, continentIndex)
    return WorldBuilder.MapManager():SetContinentType(plot, continentIndex)
end

function API.EditRiver(plot, edge, add, unknown)
    return WorldBuilder.MapManager():EditRiver(plot, edge, add, unknown)
end

function API.EditCliff(plot, edge, add, unknown)
    return WorldBuilder.MapManager():EditCliff(plot, edge, add, unknown)
end

function API.DoesPlotBorderRiver(plotIndex)
    return WorldBuilder.MapManager():DoesPlotBorderRiver(plotIndex)
end

function API.GetContinentPlots(continentIndex)
    return WorldBuilder.MapManager():GetContinentPlots(continentIndex)
end

function API.SetCoastalLowland(plot, lowlandType)
    return WorldBuilder.MapManager():SetCoastalLowland(plot, lowlandType)
end

function API.SetPlotValue(plot, valueName, value)
    return WorldBuilder.MapManager():SetPlotValue(plot, valueName, value)
end

-- 原版用法：WorldBuilder.MapManager():SetAllRevealed(true, entry.PlayerIndex)
function API.SetAllRevealed(revealed, playerID)
    return WorldBuilder.MapManager():SetAllRevealed(revealed, playerID)
end

function API.SetRevealed(plot, revealed)
    return WorldBuilder.MapManager():SetRevealed(plot, revealed)
end

-- ===========================================================================
-- UnitManager：单位放置 / 删除
-- ===========================================================================

function API.CreateUnit(unitTypeIndex, playerID, plot)
    return WorldBuilder.UnitManager():Create(unitTypeIndex, playerID, plot)
end

function API.RemoveUnitAt(plot)
    return WorldBuilder.UnitManager():RemoveAt(plot)
end

function API.RemoveUnit(unit)
    return WorldBuilder.UnitManager():Remove(unit)
end

-- ===========================================================================
-- ConfigurationManager / ModManager：地图级配置与文本
-- ===========================================================================

function API.SetMapValue(key, value)
    return WorldBuilder.ConfigurationManager():SetMapValue(key, value)
end

function API.GetMapValues()
    return WorldBuilder.ConfigurationManager():GetMapValues()
end

function API.GetKeyStringPairByIndex(index, language)
    return WorldBuilder.ModManager():GetKeyStringPairByIndex(index, language)
end

function API.SetKeyStringPairByIndex(index, key, text, language)
    return WorldBuilder.ModManager():SetKeyStringPairByIndex(index, key, text, language)
end

function API.SetString(key, text, language)
    return WorldBuilder.ModManager():SetString(key, text, language)
end

function API.RemoveString(key, language)
    return WorldBuilder.ModManager():RemoveString(key, language)
end

-- ===========================================================================
-- WorldBuilder 顶层：撤销 / 重做 / ID / 模式
-- ===========================================================================

function API.StartUndoBlock()
    return WorldBuilder.StartUndoBlock()
end

function API.EndUndoBlock()
    return WorldBuilder.EndUndoBlock()
end

function API.Undo()
    return WorldBuilder.Undo()
end

function API.Redo()
    return WorldBuilder.Redo()
end

function API.CanUndo()
    return WorldBuilder.CanUndo()
end

function API.CanRedo()
    return WorldBuilder.CanRedo()
end

function API.GetID()
    return WorldBuilder.GetID()
end

function API.SetID(id)
    return WorldBuilder.SetID(id)
end

function API.GenerateID()
    return WorldBuilder.GenerateID()
end

function API.IsMod()
    return WorldBuilder.IsMod()
end

function API.SetMod(isMod)
    return WorldBuilder.SetMod(isMod)
end

function API.SetWBAdvancedMode(enabled)
    return WorldBuilder.SetWBAdvancedMode(enabled)
end

function API.SetVisibilityPreviewPlayer(playerID)
    return WorldBuilder.SetVisibilityPreviewPlayer(playerID)
end

function API.ClearVisibilityPreviewPlayer()
    return WorldBuilder.ClearVisibilityPreviewPlayer()
end

-- ===========================================================================
-- 由 ModTool.lua 在 ExposedMembers.ModMiscToolScript.WorldBuilderAPI 暴露给
-- UI 层与其他 mod 使用。
-- ===========================================================================
