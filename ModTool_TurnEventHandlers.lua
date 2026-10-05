-- ===========================================================================
-- Mod Misc Tool: 回合事件的**默认处理方式**（gameplay）
--
-- 【定位】回合事件的核心（ModTool_TurnEvents.lua）**只做定时触发**，不写死执行方式；
-- 真正“触发之后干什么”由处理器决定（TurnEvents.RegisterHandler）。
-- 本文件就是本 mod 自带的那一套默认处理器，服务当前测试框架：
--
--     GOLD      → player:GetTreasury():ChangeGoldBalance(n)（游戏自带场景脚本在用；
--                  本项目已有封装 ChangePlayerGoldAmount）
--     UNIT      → 接收方**首都**地块上 UnitManager.InitUnit(playerID, unitType, x, y)；
--                  还没有首都 → 返回 "defer"（顺延到下一回合，事件不丢）
--     RESOURCE  → ① 先探库存通道 player:GetResources():ChangeResourceAmount(idx, n)
--                    （引擎里没有任何调用点/文档，属探测）
--                 ② 不行就落到地图：WorldBuilderAPI.SetResourceType(plot, idx, n)
--                    （本 mod 已验证通道），在首都附近找一块己方陆地
--
-- 【其它 mod 怎么接管】
--   * 注册更高优先级的处理器，抢在默认之前接手：
--         ExposedMembers.ModMiscToolScript.TurnEvents.RegisterHandler("GOLD", fn, 100)
--   * 或者先把默认的关掉/清掉：
--         ExposedMembers.ModMiscToolScript.TurnEventHandlers.Disable()
--         ExposedMembers.ModMiscToolScript.TurnEvents.ClearHandlers("GOLD")
--   * 处理器契约：fn(event) → ("handled"|"defer"|"failed", detail)
--
-- 【事件记录】{ Type, Detail, Amount, AcceptTurn(逻辑), FromNode, FromPlayerID, FromCiv, Stamp, Overdue }
--
-- 公开 API（本 mod 内直接调；外部走 ExposedMembers.ModMiscToolScript.TurnEventHandlers）：
--   Enable() / Disable() / IsEnabled()   开关整套默认处理器
--   GetHandlers()                        当前注册的处理器类型（诊断）
-- ===========================================================================

local MODMISC_TURNHDLR_BUILD_TAG = "2026-10-05-A"

local function Log(message)
    print("[ModMiscTool][TurnEventHandler] " .. tostring(message))
end

TurnEventHandlers = TurnEventHandlers or {}
local API = TurnEventHandlers
API.BuildTag = MODMISC_TURNHDLR_BUILD_TAG

local m_Enabled = true

-- ===========================================================================
-- 通用：找接收玩家 / 找首都
-- ===========================================================================

local function ResolvePlayer(event)
    local wantedID = tonumber(event.FromPlayerID)
    local wantedCiv = event.FromCiv

    if wantedID ~= nil and Players ~= nil and Players[wantedID] ~= nil then
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
    if wantedCiv ~= nil and Players ~= nil and GameDefines ~= nil then
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

-- ===========================================================================
-- 三个默认处理器
-- ===========================================================================

local function HandleGold(event)
    local player, how = ResolvePlayer(event)
    if player == nil then return "failed", "找不到接收玩家（" .. tostring(how) .. "）" end

    local amount = tonumber(event.Amount) or 0
    if amount == 0 then return "failed", "金额为 0" end

    local ok, err
    if ChangePlayerGoldAmount ~= nil then
        ok, err = pcall(ChangePlayerGoldAmount, player:GetID(), amount)
    else
        local treasury = player:GetTreasury()
        ok, err = pcall(function() return treasury:ChangeGoldBalance(amount) end)
    end
    if not ok then return "failed", tostring(err) end
    return "handled", "treasury/" .. tostring(how) .. "/player" .. tostring(player:GetID())
end

local function HandleUnit(event)
    local unitType = event.Detail
    if unitType == nil or tostring(unitType) == "" then return "failed", "没给单位类型" end

    local player, how = ResolvePlayer(event)
    if player == nil then return "failed", "找不到接收玩家（" .. tostring(how) .. "）" end

    local capital = GetPlayerCapital(player)
    if capital == nil then
        -- 还没有首都：顺延，别丢（等建了城下一回合再发）
        return "defer", "接收方还没有首都"
    end

    local playerID = player:GetID()
    local x, y = capital:GetX(), capital:GetY()
    local ok, err = pcall(UnitManager.InitUnit, playerID, tostring(unitType), x, y)
    if not ok then return "failed", tostring(err) end
    return "handled", "capital@" .. tostring(x) .. "," .. tostring(y) .. "/player" .. tostring(playerID)
end

local function HandleResource(event)
    local resourceType = event.Detail
    if resourceType == nil or tostring(resourceType) == "" then return "failed", "没给资源类型" end

    local row = GameInfo.Resources[resourceType]
    if row == nil then return "failed", "未知资源 " .. tostring(resourceType) end

    local player, how = ResolvePlayer(event)
    if player == nil then return "failed", "找不到接收玩家（" .. tostring(how) .. "）" end
    local amount = tonumber(event.Amount) or 1

    -- ① 库存通道（引擎里没有文档化写接口，先探一手）
    local resources = player:GetResources()
    if resources ~= nil and resources.ChangeResourceAmount ~= nil then
        local ok = pcall(function() return resources:ChangeResourceAmount(row.Index, amount) end)
        if ok then return "handled", "stockpile/player" .. tostring(player:GetID()) end
    end

    -- ② 地图通道：首都附近找一块己方陆地放下去（WorldBuilderAPI 是已验证通道）
    local capital = GetPlayerCapital(player)
    if capital == nil then return "defer", "接收方还没有首都" end
    if GetPlotsInRange == nil or WorldBuilderAPI == nil then
        return "failed", "地图通道不可用（GetPlotsInRange / WorldBuilderAPI 缺失）"
    end

    local playerID = player:GetID()
    for _, plotIndex in ipairs(GetPlotsInRange(capital:GetX(), capital:GetY(), 3)) do
        local plot = Map.GetPlotByIndex(plotIndex)
        if plot ~= nil and not plot:IsWater() and plot:GetOwner() == playerID then
            local ok = pcall(WorldBuilderAPI.SetResourceType, plot, row.Index, amount)
            if ok then
                return "handled", "map@" .. tostring(plotIndex) .. "/player" .. tostring(playerID)
            end
        end
    end
    return "defer", "首都附近暂时没有可放资源的地块"
end

local DEFAULT_HANDLERS = {
    { Type = "GOLD",     Handler = HandleGold },
    { Type = "UNIT",     Handler = HandleUnit },
    { Type = "RESOURCE", Handler = HandleResource },
}
local mRegistered = false

local function RegisterDefaults()
    if TurnEvents == nil or TurnEvents.RegisterHandler == nil then
        Log("注册失败：TurnEvents.RegisterHandler 不可用（include 顺序？）")
        return false
    end
    for _, entry in ipairs(DEFAULT_HANDLERS) do
        TurnEvents.RegisterHandler(entry.Type, entry.Handler, 0)
    end
    mRegistered = true
    Log("默认处理器已注册（GOLD / UNIT / RESOURCE，优先级 0 —— 其它 mod 用更高优先级即可接管）")
    return true
end

local function UnregisterDefaults()
    if TurnEvents == nil or TurnEvents.UnregisterHandler == nil then return false end
    for _, entry in ipairs(DEFAULT_HANDLERS) do
        TurnEvents.UnregisterHandler(entry.Type, entry.Handler)
    end
    mRegistered = false
    Log("默认处理器已注销")
    return true
end

function API.IsEnabled()
    return m_Enabled
end

function API.Enable()
    if m_Enabled and mRegistered then return true end
    m_Enabled = true
    RegisterDefaults()
    return true
end

function API.Disable()
    m_Enabled = false
    UnregisterDefaults()
    return true
end

function API.GetHandlers()
    if TurnEvents == nil or TurnEvents.GetHandlerTypes == nil then return {} end
    return TurnEvents.GetHandlerTypes()
end

-- 模块加载就注册（这是当前测试框架使用的默认处理方式）
RegisterDefaults()
