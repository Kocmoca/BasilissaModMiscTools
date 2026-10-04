-- ===========================================================================
-- Mod Misc Tool: 回合数 / 年代 接口封装（Gameplay 后端）
--
-- 【为什么放 gameplay】候选的**唯一**回合写接口 `Game.SetCurrentGameTurn(n)` 只在
-- 游戏自带的 gameplay 脚本里出现过：
--     DLC/PolandScenario/Scripts/PolandScenario.lua:63（由 <AddGameplayScripts> 注册）
--     -- NEED A FINAL APPROACH TO TURN AND YEAR
--     -- Game.SetCurrentGameTurn(1);
-- 那行是**被注释掉的**，旁边还写着「回合与年份的做法还没定」⇒ 能不能用、在哪个
-- 上下文能用，全是未知。所以本模块把 gameplay 这条路先备好：UI 层直调失败（或接口
-- 在 UI 层不存在）时，经 ExposedMembers 转到这里再试一次。年代那边的写接口
-- `SetPlayerEra` 本来就在 gameplay（WorldBuilder），一并收在这里。
--
-- 【静态事实】（都来自游戏自带代码，不是推断）
--   * 回合读：`Game.GetCurrentGameTurn()` / `Game.GetGameEndTurn()` / `Game.GetMaxGameTurns()`
--   * 回合写：全库**只有** `Game.SetCurrentGameTurn`（就是上面那条被注释的）
--   * 回合上限写：`GameConfiguration.SetMaxTurns(n)` + `SetTurnLimitType(TurnLimitTypes.CUSTOM)`
--     —— 引擎自己的 Automation 用它，**对下一局生效**（见 Automation_StandardTests.lua:219）
--   * 年代读：`Players[id]:GetEra()`（0 基）/ `Game.GetEras():GetCurrentEra()`
--     `Game.GetEras()` 上的方法只有读：GetCurrentEra / GetCurrentEraStartTurn /
--     GetNextEraCountdown / GetPlayerNumAllowedCommemorations —— **没有 setter**
--   * 年代写：`WorldBuilder.PlayerManager():SetPlayerEra(playerID, eraType)`
--     （地图编辑器的时代下拉框就是调它：WorldBuilderPlayerEditor.lua:1282）
--   * 年份显示：`Calendar.MakeYearStr(turn)` / `Calendar.MakeDateStr(turn, 历法, 速度, false)`
--     ⇒ 年份是**回合的纯函数**，改回合就等于改年份显示
--
-- 公开 API（本 mod 内直接调；外部 mod 走 ExposedMembers.ModMiscToolScript.TurnEraAPI）：
--   GetTurnInfo()                        当前回合 / 结束回合 / 上限 / 开始回合
--   SetCurrentGameTurn(turn)             试写回合（返回 ok, 明细）
--   GetEraInfo(playerID)                 该玩家的时代序号 + 类型 + 全局当前时代
--   SetPlayerEra(playerID, eraType)      试写年代（WorldBuilder 通道）
--   SetCurrentEra(eraType, playerIDs)    批量给玩家写同一个年代（不传玩家 = 全部存活主要文明）
--
-- ⚠️ 这些接口**都没在设备上验证过**（除了 SetPlayerEra，本 mod 的 WorldBuilder 面板在用）。
--    调用一律 pcall；结论看 Lua.log 前缀 [ModMiscTool][TurnEra]。
-- ===========================================================================

local MODMISC_TURNERA_BUILD_TAG = "2026-10-05-A"

local function Log(message)
    print("[ModMiscTool][TurnEra] " .. tostring(message))
end

TurnEraAPI = TurnEraAPI or {}
local API = TurnEraAPI
API.BuildTag = MODMISC_TURNERA_BUILD_TAG

-- ===========================================================================
-- 读取
-- ===========================================================================

function API.GetTurnInfo()
    local info = {}
    info.Turn = nil
    info.EndTurn = nil
    info.MaxTurns = nil
    info.StartTurn = nil

    local ok, turn = pcall(function() return Game.GetCurrentGameTurn() end)
    if ok then info.Turn = turn end
    ok, turn = pcall(function() return Game.GetGameEndTurn() end)
    if ok then info.EndTurn = turn end
    ok, turn = pcall(function() return Game.GetMaxGameTurns() end)
    if ok then info.MaxTurns = turn end
    ok, turn = pcall(function() return GameConfiguration.GetStartTurn() end)
    if ok then info.StartTurn = turn end

    return info
end

function API.GetEraInfo(playerID)
    local info = {}
    if playerID ~= nil and Players ~= nil and Players[playerID] ~= nil then
        local ok, era = pcall(function() return Players[playerID]:GetEra() end)
        if ok then info.PlayerEraIndex = era end
        if info.PlayerEraIndex ~= nil and GameInfo.Eras[info.PlayerEraIndex] ~= nil then
            info.PlayerEraType = GameInfo.Eras[info.PlayerEraIndex].EraType
        end
    end
    local ok, gameEra = pcall(function() return Game.GetEras():GetCurrentEra() end)
    if ok then info.GameEraIndex = gameEra end
    if info.GameEraIndex ~= nil and GameInfo.Eras[info.GameEraIndex] ~= nil then
        info.GameEraType = GameInfo.Eras[info.GameEraIndex].EraType
    end
    local ok2, startTurn = pcall(function() return Game.GetEras():GetCurrentEraStartTurn() end)
    if ok2 then info.GameEraStartTurn = startTurn end
    local ok3, countdown = pcall(function() return Game.GetEras():GetNextEraCountdown() end)
    if ok3 then info.NextEraCountdown = countdown end
    return info
end

-- ===========================================================================
-- 写入：回合
-- ===========================================================================

function API.SetCurrentGameTurn(turn)
    local target = tonumber(turn)
    if target == nil then return false, "turn 不是数字：" .. tostring(turn) end
    if Game == nil or Game.SetCurrentGameTurn == nil then
        return false, "Game.SetCurrentGameTurn 在 gameplay 层也不存在"
    end

    local before = API.GetTurnInfo().Turn
    Log("SetCurrentGameTurn: 即将调用 Game.SetCurrentGameTurn(" .. tostring(target)
        .. ")（当前 turn=" .. tostring(before) .. "）")
    local ok, err = pcall(Game.SetCurrentGameTurn, target)
    if not ok then
        Log("SetCurrentGameTurn: 调用失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    local after = API.GetTurnInfo().Turn
    local applied = (after ~= nil and tonumber(after) == target)
    Log("SetCurrentGameTurn: applied=" .. tostring(applied)
        .. " before=" .. tostring(before) .. " after=" .. tostring(after))
    return applied, string.format("before=%s after=%s", tostring(before), tostring(after))
end

-- ===========================================================================
-- 写入：年代（WorldBuilder 通道）
-- ===========================================================================

local function ResolveWorldBuilder()
    if WorldBuilderAPI ~= nil and WorldBuilderAPI.SetPlayerEra ~= nil then
        return WorldBuilderAPI, "WorldBuilderAPI"
    end
    if WorldBuilder ~= nil and WorldBuilder.PlayerManager ~= nil then
        return { SetPlayerEra = function(playerID, eraType)
            return WorldBuilder.PlayerManager():SetPlayerEra(playerID, eraType)
        end }, "WorldBuilder 直调"
    end
    return nil, "WorldBuilder 不可用"
end

function API.SetPlayerEra(playerID, eraType)
    if playerID == nil or eraType == nil then
        return false, "参数不全"
    end
    local channel, channelName = ResolveWorldBuilder()
    if channel == nil then return false, channelName end

    local before = API.GetEraInfo(playerID).PlayerEraType
    Log("SetPlayerEra: 即将调用（" .. channelName .. "）player=" .. tostring(playerID)
        .. " -> " .. tostring(eraType) .. "（当前 " .. tostring(before) .. "）")
    local ok, err = pcall(channel.SetPlayerEra, playerID, eraType)
    if not ok then
        Log("SetPlayerEra: 调用失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    local after = API.GetEraInfo(playerID).PlayerEraType
    local applied = (after ~= nil and tostring(after) == tostring(eraType))
    Log("SetPlayerEra: applied=" .. tostring(applied)
        .. " player=" .. tostring(playerID)
        .. " before=" .. tostring(before) .. " after=" .. tostring(after))
    return applied, string.format("player=%s before=%s after=%s",
        tostring(playerID), tostring(before), tostring(after))
end

-- 批量：不传 playerIDs 时给所有存活的主要文明写同一个年代
function API.SetCurrentEra(eraType, playerIDs)
    if eraType == nil then return false, "eraType 为空" end
    local targets = playerIDs
    if targets == nil then
        targets = {}
        if Players == nil or GameDefines == nil then
            return false, "Players / GameDefines 不可用，请显式传玩家列表"
        end
        for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
            local player = Players[playerID]
            if player ~= nil then
                -- 判定用 pcall：槽位桩对象上可能没有这些方法，不能让筛选把整个调用带崩
                local okMajor, isMajor = pcall(function() return player:IsMajor() end)
                local okBarb, isBarbarian = pcall(function() return player:IsBarbarian() end)
                if okMajor and isMajor == true and not (okBarb and isBarbarian == true) then
                    table.insert(targets, playerID)
                end
            end
        end
    end

    local applied, attempted = 0, 0
    for _, playerID in ipairs(targets) do
        attempted = attempted + 1
        local ok = API.SetPlayerEra(playerID, eraType)
        if ok then applied = applied + 1 end
    end
    Log("SetCurrentEra: " .. tostring(eraType) .. " applied=" .. tostring(applied)
        .. "/" .. tostring(attempted))
    return applied > 0, string.format("applied=%d/%d", applied, attempted)
end
