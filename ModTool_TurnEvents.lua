-- ===========================================================================
-- Mod Misc Tool: 回合事件（gameplay 后端）
--
-- 【干什么】接收别的存档“发过来”的事件（预设类型：单位 / 金币 / 资源），
-- 存进**本局游戏状态**里的「回合事件列表」，到点（逻辑回合）自动执行，
-- 并通过 LuaEvents 广播一条文本事件，供其它 mod 定义提示文案。
--
-- 【为什么用 Game:SetProperty 存列表】它是游戏状态的一部分：随档保存、读档还原，
-- 所以“已接收但还没到点”的事件会跟着存档走（也能被任何一次存档带走）。
-- 封装在 ModTool_DataStore.lua 里（键前缀 kocmoca_modmisctool_）。
--
-- 【回合同步是“逻辑”的，不做硬同步】（授权者 2026-10-05 明确）
--   分支从主线某回合分叉出去时，引擎回合会从 1 重新数；逻辑上它接着主线的回合走：
--       主线第 18 回合开分支 → 分支的引擎第 1 回合 = 逻辑第 18 回合
--       ⇒ 分支引擎第 3 回合 = 逻辑第 20 回合（偏移 = 18 - 1 = 17）
--   偏移由 UI 侧算好（它知道树的父子与节点记录的逻辑回合），开局时推给这里：
--       TurnEvents.SetLogicalOffset(offset)
--   这里只用它换算，**绝不改引擎回合**（引擎回合也改不动，见第 47 条）。
--
-- 【事件记录】{ Type, Detail, Amount, AcceptTurn(逻辑), FromNode, FromPlayerID,
--              FromCiv, Stamp, Overdue }
--   Type      GOLD / UNIT / RESOURCE
--   Detail    UNIT 事件是单位类型名，RESOURCE 事件是资源类型名，GOLD 为空
--   AcceptTurn 接受回合（逻辑）：到点或已过点就执行
--   Overdue   收到时就已过期 ⇒ 下一回合触发（授权者定的口径），文案可标“补发”
--
-- 【发放通道】
--   GOLD      player:GetTreasury():ChangeGoldBalance(n)（游戏自带场景脚本在用）
--   UNIT      首都地块上 UnitManager.InitUnit(playerID, unitType, x, y)；没有首都 → 顺延到下一回合
--   RESOURCE  ① 先探库存通道 player:GetResources():ChangeResourceAmount(idx, n)（引擎没有文档化写接口）
--             ② 不行就落到地图上：WorldBuilderAPI.SetResourceType(plot, idx, n)（本 mod 已验证通道）
--             两条都没成 → 记失败并广播文本事件（不静默吞掉）
--
-- 【文本提示】执行/失败时广播：
--   LuaEvents.ModMiscToolTurnEventFired.Call(type, detail, amount, fromNode, overdue, toPlayerID, result)
--   UI 侧（Support_UI）收到后按类型组默认文案，并允许其它 mod 注册解析函数覆盖/补充：
--   ExposedMembers.ModMiscToolUI.RegisterTurnEventTextResolver(fn)
--
-- 公开 API（本 mod 内直接调；外部 mod 走 ExposedMembers.ModMiscToolScript.TurnEvents）：
--   SetLogicalOffset(offset) / GetLogicalOffset() / GetLogicalTurn()
--   AddIncoming(event)        收件：入列（过期则排到下一回合）
--   GetAll() / Clear()        列表副本 / 清空
--   ProcessDue(reason)        结算到点事件（每回合开始自动跑一次）
--   ExecuteEvent(event)       手动执行单条（面板/调试用）
-- ===========================================================================

local MODMISC_TURNEVENTS_BUILD_TAG = "2026-10-05-A"
local MODMISC_TURNEVENTS_KEY = "turnevents"
local MODMISC_TURNEVENTS_OFFSET_KEY = "turnevents_offset"

local function Log(message)
    print("[ModMiscTool][TurnEvent] " .. tostring(message))
end

TurnEvents = TurnEvents or {}
local API = TurnEvents
API.BuildTag = MODMISC_TURNEVENTS_BUILD_TAG

local function GetStore()
    return ModMiscToolData
end

local function ReadKey(key)
    local store = GetStore()
    if store == nil or store.Get == nil then return nil end
    local ok, value = pcall(store.Get, key)
    if not ok then return nil end
    return value
end

local function WriteKey(key, value)
    local store = GetStore()
    if store == nil or store.Set == nil then
        Log("写入 " .. tostring(key) .. " 失败：ModMiscToolData 不可用（漏 include？）")
        return false
    end
    local ok, err = pcall(store.Set, key, value)
    if not ok then
        Log("写入 " .. tostring(key) .. " 失败 -> " .. tostring(err))
        return false
    end
    return true
end

-- ===========================================================================
-- 逻辑回合
-- ===========================================================================

function API.SetLogicalOffset(offset)
    local value = tonumber(offset) or 0
    WriteKey(MODMISC_TURNEVENTS_OFFSET_KEY, value)
    Log("逻辑回合偏移已设为 " .. tostring(value)
        .. "（引擎第 1 回合 = 逻辑第 " .. tostring(value + 1) .. " 回合）")
    return true
end

function API.GetLogicalOffset()
    return tonumber(ReadKey(MODMISC_TURNEVENTS_OFFSET_KEY)) or 0
end

function API.GetLogicalTurn()
    local turn = 1
    local ok, value = pcall(function() return Game.GetCurrentGameTurn() end)
    if ok and value ~= nil then turn = tonumber(value) or 1 end
    return turn + API.GetLogicalOffset()
end

-- ===========================================================================
-- 列表读写
-- ===========================================================================

local function GetList()
    local value = ReadKey(MODMISC_TURNEVENTS_KEY)
    if type(value) ~= "table" then return {} end
    return value
end

local function SaveList(list)
    return WriteKey(MODMISC_TURNEVENTS_KEY, list or {})
end

function API.GetAll()
    local copy = {}
    for index, event in ipairs(GetList()) do
        copy[index] = event
    end
    return copy
end

function API.Clear()
    local count = #GetList()
    SaveList({})
    Log("已清空回合事件列表（原 " .. tostring(count) .. " 条）")
    return count
end

-- ===========================================================================
-- 收件
-- ===========================================================================

-- 过期判定：接受回合 < 当前逻辑回合 ⇒ 排到下一回合（授权者口径）
function API.AddIncoming(event)
    if type(event) ~= "table" or event.Type == nil then
        return false, "事件格式不对"
    end
    local currentTurn = API.GetLogicalTurn()
    local accept = tonumber(event.AcceptTurn) or currentTurn
    if accept < currentTurn then
        event.Overdue = true
        event.AcceptTurn = currentTurn + 1
        Log("事件已过期（接受回合 " .. tostring(accept) .. " < 当前逻辑回合 "
            .. tostring(currentTurn) .. "）→ 排到下一回合触发")
    end
    local list = GetList()
    table.insert(list, event)
    SaveList(list)
    Log("已入列：" .. tostring(event.Type) .. " " .. tostring(event.Detail or "")
        .. " x" .. tostring(event.Amount or "?")
        .. " 接受回合=" .. tostring(event.AcceptTurn)
        .. " 来自=" .. tostring(event.FromNode) .. "（现有 " .. tostring(#list) .. " 条）")
    return true
end

-- ===========================================================================
-- 执行
-- ===========================================================================

local function ResolvePlayer(event)
    local wantedID = tonumber(event.FromPlayerID)
    local wantedCiv = event.FromCiv

    if wantedID ~= nil and Players[wantedID] ~= nil then
        local config = PlayerConfigurations ~= nil and PlayerConfigurations[wantedID] or nil
        local civType = nil
        if config ~= nil and config.GetCivilizationTypeName ~= nil then
            local ok, value = pcall(function() return config:GetCivilizationTypeName() end)
            if ok then civType = value end
        end
        if wantedCiv == nil or civType == nil or civType == wantedCiv then
            return Players[wantedID], "id"
        end
    end

    -- id 对不上（不同分支的玩家表可能不同）→ 按文明类型找
    if wantedCiv ~= nil then
        for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
            local player = Players[playerID]
            if player ~= nil then
                local config = PlayerConfigurations ~= nil and PlayerConfigurations[playerID] or nil
                if config ~= nil and config.GetCivilizationTypeName ~= nil then
                    local ok, civType = pcall(function() return config:GetCivilizationTypeName() end)
                    if ok and civType == wantedCiv then
                        return player, "civ"
                    end
                end
            end
        end
    end

    local localPlayerID = Game.GetLocalPlayer()
    if localPlayerID ~= nil and localPlayerID >= 0 and Players[localPlayerID] ~= nil then
        return Players[localPlayerID], "local-fallback"
    end
    return nil, "no-player"
end

local function GetPlayerCapital(player)
    if player == nil then return nil end
    local cities = player:GetCities()
    if cities == nil then return nil end
    return cities:GetCapitalCity()
end

local function ExecuteGold(player, event)
    local amount = tonumber(event.Amount) or 0
    if amount == 0 then return false, "amount=0" end
    if ChangePlayerGoldAmount ~= nil then
        local ok, err = pcall(ChangePlayerGoldAmount, player:GetID(), amount)
        if not ok then return false, tostring(err) end
        return true, "treasury"
    end
    local treasury = player:GetTreasury()
    local ok, err = pcall(function() return treasury:ChangeGoldBalance(amount) end)
    if not ok then return false, tostring(err) end
    return true, "treasury"
end

local function ExecuteUnit(player, event)
    local unitType = event.Detail
    if unitType == nil or tostring(unitType) == "" then return false, "没给单位类型" end
    local capital = GetPlayerCapital(player)
    if capital == nil then return false, "no-capital" end
    local playerID = player:GetID()
    local x, y = capital:GetX(), capital:GetY()
    local ok, err = pcall(UnitManager.InitUnit, playerID, tostring(unitType), x, y)
    if not ok then return false, tostring(err) end
    return true, "capital@" .. tostring(x) .. "," .. tostring(y)
end

local function ExecuteResource(player, event)
    local resourceType = event.Detail
    if resourceType == nil or tostring(resourceType) == "" then return false, "没给资源类型" end
    local row = GameInfo.Resources[resourceType]
    if row == nil then return false, "未知资源 " .. tostring(resourceType) end
    local amount = tonumber(event.Amount) or 1

    -- ① 库存通道（引擎没有文档化写接口，先探一手；有就用，符合“加进库存”的口径）
    local resources = player:GetResources()
    if resources ~= nil and resources.ChangeResourceAmount ~= nil then
        local ok = pcall(function() return resources:ChangeResourceAmount(row.Index, amount) end)
        if ok then return true, "stockpile" end
    end

    -- ② 地图通道：首都附近找一块自己的陆地放下去（WorldBuilderAPI 是已验证通道）
    local capital = GetPlayerCapital(player)
    if capital == nil then return false, "no-capital" end
    local playerID = player:GetID()
    if GetPlotsInRange == nil or WorldBuilderAPI == nil then return false, "地图通道不可用" end
    local plotIndexes = GetPlotsInRange(capital:GetX(), capital:GetY(), 3)
    for _, plotIndex in ipairs(plotIndexes) do
        local plot = Map.GetPlotByIndex(plotIndex)
        if plot ~= nil and not plot:IsWater() and plot:GetOwner() == playerID then
            local ok = pcall(WorldBuilderAPI.SetResourceType, plot, row.Index, amount)
            if ok then return true, "map@" .. tostring(plotIndex) end
        end
    end
    return false, "首都附近没有可放资源的地块"
end

local EXECUTORS = {
    GOLD = ExecuteGold,
    UNIT = ExecuteUnit,
    RESOURCE = ExecuteResource,
}

local function FireEventText(event, result)
    if LuaEvents == nil or LuaEvents.ModMiscToolTurnEventFired == nil then return end
    pcall(function()
        LuaEvents.ModMiscToolTurnEventFired.Call(
            tostring(event.Type), tostring(event.Detail or ""), tonumber(event.Amount) or 0,
            tostring(event.FromNode or ""), event.Overdue == true,
            tonumber(event.FromPlayerID) or -1, tostring(result or ""))
    end)
end

function API.ExecuteEvent(event)
    if type(event) ~= "table" then return false, "事件格式不对" end
    local executor = EXECUTORS[tostring(event.Type)]
    if executor == nil then return false, "未知事件类型 " .. tostring(event.Type) end

    local player, how = ResolvePlayer(event)
    if player == nil then return false, "找不到接收玩家（" .. tostring(how) .. "）" end
    local ok, result = executor(player, event)
    if ok then
        Log("已执行：" .. tostring(event.Type) .. " " .. tostring(event.Detail or "")
            .. " x" .. tostring(event.Amount or "?")
            .. " → 玩家 " .. tostring(player:GetID()) .. "（" .. tostring(how) .. "）通道=" .. tostring(result))
    else
        Log("执行未完成：" .. tostring(event.Type) .. " → " .. tostring(result))
    end
    return ok, result, player:GetID()
end

-- 结算到点事件：每回合开始跑一次；面板也能手动触发
function API.ProcessDue(reason)
    local list = GetList()
    if #list == 0 then return 0 end

    local currentTurn = API.GetLogicalTurn()
    local remaining = {}
    local executed = 0
    for _, event in ipairs(list) do
        local accept = tonumber(event.AcceptTurn) or currentTurn
        if accept > currentTurn then
            table.insert(remaining, event)
        else
            local ok, result = API.ExecuteEvent(event)
            if ok then
                executed = executed + 1
                FireEventText(event, result)
            elseif result == "no-capital" or result == "首都附近没有可放资源的地块" then
                -- 还没条件发放（例如首都还没建）：顺延，别丢
                Log("顺延到下一回合：" .. tostring(event.Type) .. " → " .. tostring(result))
                table.insert(remaining, event)
            else
                executed = executed + 1
                FireEventText(event, "failed:" .. tostring(result))
            end
        end
    end
    SaveList(remaining)
    Log("结算完成（" .. tostring(reason) .. "）：执行 " .. tostring(executed)
        .. " 条，剩余 " .. tostring(#remaining) .. " 条（逻辑回合 " .. tostring(currentTurn) .. "）")

    -- 批次收尾事件：UI 侧用它把本回合的多条提示合成一条弹窗
    if executed > 0 and LuaEvents ~= nil and LuaEvents.ModMiscToolTurnEventBatch ~= nil then
        pcall(function() LuaEvents.ModMiscToolTurnEventBatch.Call(executed, currentTurn) end)
    end
    return executed
end

-- 每回合开始结算一次（gameplay 侧只加载一次，不存在重复注册问题）
if Events ~= nil and Events.LocalPlayerTurnBegin ~= nil then
    Events.LocalPlayerTurnBegin.Add(function()
        local ok, err = pcall(API.ProcessDue, "turn-begin")
        if not ok then
            Log("回合结算失败 -> " .. tostring(err))
        end
    end)
end
