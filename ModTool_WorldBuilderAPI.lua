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
--
-- 【2026-10-28 补 / 同日实机否掉】玩家生命周期补了 InitializePlayer 这一步
--   （原版地图编辑器 AddPlayer 之后由 SetPlayerLeader 顺带完成初始化）。
--   实机结论：补了初始化**仍然原生闪退**在 AI 外交子系统
--   （GameCore::AI::Diplomatic::GetDiplomaticStateIndex）⇒ 运行时造玩家这条路不可行，
--   缺的是引擎开局建玩家时才构造的 AI 对象，Lua 侧没有接口能补。
--   接口保留（调用顺序与防护都对，换思路复测可直接复用），但**不要再用来在运行中加玩家**。
--   细节见 API_Verification_Status.md §19.37 / #1。
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

-- ---------------------------------------------------------------------------
-- 玩家初始化（AddPlayer 之后必须补的一步）
--
-- 原版地图编辑器的玩家生命周期是三段：AddPlayer（建槽位）→ SetPlayerLeader（给身份）
-- → InitializePlayer（把玩家的运行期对象建出来）。官方调试面板
-- Debug/WorldBuilder.ltp「Initialize Player As Human / As AI」就是
-- SetPlayerSlotStatus + InitializePlayer 这个组合（原版 Lua 从不显式调用它，
-- 因为编辑器里的 SetPlayerLeader 会顺带完成初始化）。
--
-- 【为什么当时以为要补】只 AddPlayer 不 InitializePlayer，玩家只有配置没有运行期对象，
-- 进对局后引擎 AI 外交子系统空指针闪退：
--   signal 11 SIGSEGV … GameCore::AI::Diplomatic::GetDiplomaticStateIndex(PlayerTypes) const
--
-- ⚠️ **2026-10-28 实机：补了这一步照样闪退在同一符号** ⇒ 空指针来自引擎开局建玩家时
--    构造的 AI 外交对象，不是「玩家没初始化」。本组接口因此不构成运行时造玩家的方案
--    （证据见 API_Verification_Status.md §19.37 / 第 1 条）。
-- ---------------------------------------------------------------------------

-- 引擎的布尔返回值有时是 0/1，这里统一归一化（只把明确的真值算真）
local function ToBool(value)
    return value == true or value == 1
end

-- 槽位状态：现行引擎枚举是 SS_*。调试面板里那个 SlotStatus.HUMAN / SlotStatus.AI
-- 是历史名，现行 SlotStatus 表里没有（传 nil 等于没设），所以这里按 isAI 映射到 SS_*。
local function GetSlotStatusForPlayerType(isAI)
    if SlotStatus == nil then return nil end
    if isAI then return SlotStatus.SS_COMPUTER end
    return SlotStatus.SS_TAKEN
end

function API.GetPlayerSlotStatusValue(isAI)
    return GetSlotStatusForPlayerType(isAI)
end

function API.SetPlayerSlotStatus(playerID, slotStatus)
    if playerID == nil or playerID == -1 then return false end
    if slotStatus == nil then return false end
    return WorldBuilder.PlayerManager():SetPlayerSlotStatus(playerID, slotStatus)
end

function API.InitializePlayer(playerID)
    if playerID == nil or playerID == -1 then return false end
    return WorldBuilder.PlayerManager():InitializePlayer(playerID)
end

-- 新增玩家的一站式入口：AddPlayer → SetPlayerSlotStatus → SetPlayerLeader →
-- InitializePlayer →（可选）和所有在场玩家互相“见过面”。
--
-- 返回**一张表**（跨 context 多返回值不可靠，见 API_Verification_Status #24）：
--   { ok=布尔, playerID=, reason=失败原因,
--     steps={ {step=, ok=, detail=}, ... },
--     wbInitialized=编辑器侧状态, engineInitialized=Players[id]:IsInitialized(),
--     metCount=互相 SetHasMet 成功的对数 }
function API.AddPlayerAndInitialize(isAI, leaderType, civType, civLevel, meetEveryone)
    local result = {
        ok = false,
        playerID = nil,
        reason = nil,
        steps = {},
        wbInitialized = nil,
        engineInitialized = nil,
        metCount = 0,
    }

    local function Record(stepName, stepOk, detail)
        table.insert(result.steps, { step = stepName, ok = stepOk, detail = detail })
        print(string.format("[ModMiscTool][WorldBuilderAPI] add player: step=%s ok=%s detail=%s",
            tostring(stepName), tostring(stepOk), tostring(detail)))
    end

    -- ① AddPlayer：失败会返回 -1，绝不能把 -1 继续传给后面的接口（无效玩家 id ⇒ 崩溃）
    local addOk, playerID = pcall(function() return API.AddPlayer(isAI) end)
    if not addOk then
        Record("AddPlayer", false, playerID)
        result.reason = "AddPlayer 抛错: " .. tostring(playerID)
        return result
    end
    result.playerID = playerID
    if playerID == nil or playerID == -1 then
        Record("AddPlayer", false, "playerID=" .. tostring(playerID))
        result.reason = "AddPlayer 返回 " .. tostring(playerID)
        return result
    end
    Record("AddPlayer", true, "playerID=" .. tostring(playerID))

    -- ② SetPlayerSlotStatus：AddPlayer(isAI) 通常已经设好，这里在初始化之前显式再设一次，
    --    确保 InitializePlayer 看到的是“有人占用的 AI/人类槽位”（官方调试面板同顺序）
    local slotStatus = GetSlotStatusForPlayerType(isAI)
    if slotStatus ~= nil then
        local statusOk, statusErr = pcall(function()
            return API.SetPlayerSlotStatus(playerID, slotStatus)
        end)
        Record("SetPlayerSlotStatus", statusOk, statusOk and tostring(slotStatus) or statusErr)
    else
        Record("SetPlayerSlotStatus", false, "SlotStatus 枚举不可用，跳过")
    end

    -- ③ SetPlayerLeader：身份（领袖/文明/文明等级）由调用方决定，这里只执行
    if leaderType ~= nil and civType ~= nil and civLevel ~= nil then
        local leaderOk, leaderErr = pcall(function()
            return API.SetPlayerLeader(playerID, leaderType, civType, civLevel)
        end)
        Record("SetPlayerLeader", leaderOk, leaderOk and (civType .. "/" .. leaderType) or leaderErr)
    else
        Record("SetPlayerLeader", false, "身份参数不全，跳过")
    end

    -- ④ InitializePlayer：这一步就是本次补的功能
    local initOk, initResult = pcall(function() return API.InitializePlayer(playerID) end)
    Record("InitializePlayer", initOk, initOk and ("returned " .. tostring(initResult)) or tostring(initResult))

    -- ⑤ 探针：编辑器侧 / 引擎侧各查一次，判断玩家到底算不算初始化完成
    --    注意：不能写 `result.x = ok and value or nil` —— value 是 false 时会被 or 吞成 nil
    local wbOk, wbValue = pcall(function() return API.IsPlayerInitialized(playerID) end)
    if wbOk then result.wbInitialized = wbValue end
    Record("IsPlayerInitialized", wbOk, wbOk and tostring(wbValue) or tostring(wbValue))

    local engineOk, engineValue = pcall(function()
        local player = Players[playerID]
        if player == nil then return nil end
        return player:IsInitialized()
    end)
    if engineOk then result.engineInitialized = engineValue end
    Record("PlayerIsInitialized", engineOk, engineOk and tostring(engineValue) or tostring(engineValue))

    -- ⑥ 可选：让新玩家和所有在场玩家互相“见过面”。
    --    开局新增玩家不会走 DiplomaticStartStates 的播种，先按原版场景脚本的做法铺一遍
    --    （Base/Assets/Scenarios/ColdWarScenario/ColdWarScenario_StartScript.lua:30-37）。
    if meetEveryone ~= false then
        result.metCount = API.MeetAllAlivePlayers(playerID)
    end

    result.ok = ToBool(result.wbInitialized) or ToBool(result.engineInitialized)
    if not result.ok then
        result.reason = "InitializePlayer 调到了，但两个探针都没返回已初始化"
    end
    return result
end

-- 让 playerID 和所有存活玩家互相 SetHasMet；返回成功的对数。
-- 独立成函数：面板/其它 mod 也可能只想铺外交关系、不想新建玩家。
function API.MeetAllAlivePlayers(playerID)
    if playerID == nil or playerID == -1 then return 0 end
    local player = Players[playerID]
    if player == nil then return 0 end
    local diplomacy = player:GetDiplomacy()
    if diplomacy == nil then return 0 end

    local metCount = 0
    for _, otherPlayerID in ipairs(PlayerManager.GetAliveIDs()) do
        if otherPlayerID ~= playerID then
            local otherPlayer = Players[otherPlayerID]
            local otherDiplomacy = otherPlayer ~= nil and otherPlayer:GetDiplomacy() or nil
            local firstOk = pcall(function() diplomacy:SetHasMet(otherPlayerID) end)
            local secondOk = otherDiplomacy ~= nil
                and pcall(function() otherDiplomacy:SetHasMet(playerID) end)
            if firstOk and secondOk then
                metCount = metCount + 1
            end
        end
    end
    print("[ModMiscTool][WorldBuilderAPI] meet all players: player=" .. tostring(playerID)
        .. " pairs=" .. tostring(metCount))
    return metCount
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

function API.ChangePlayerLeader(playerID, newLeaderType)
	local playerConfig = API.GetPlayerConfig(playerID)
	API.SetPlayerLeader(playerID, newLeaderType, playerConfig.Civ, playerConfig.CivLevel)
end

function API.ChangePlayerCivilization(playerID, newCivType)
	local playerConfig = API.GetPlayerConfig(playerID)
	API.SetPlayerLeader(playerID, playerConfig.Leader, newCivType, playerConfig.CivLevel)
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
