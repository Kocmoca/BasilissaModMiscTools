-- ===========================================================================
-- Mod Misc Tool: 回合数 / 年代显示 接口探查与试写（UI 层）
--
-- 【2026-10-05 实机结论：**写回合 / 写年代 / 写开始年代，全都没生效**】
--   授权者用面板第 2 页签的试写按钮实测：`applied=false`（回读值不变），顶栏回合数、
--   年份、年代一个都没动。⇒ 重启换图之后**无法把新局拨回原来的回合与年代**；
--   这两个模块保留下来只做两件事：
--     ① 读现状（`GetTurnInfo` / `GetEraInfo` / `DescribeContext`）——读接口是好的；
--     ② 把“试过哪些写路径、结论是什么”钉在代码里，避免以后重复踩。
--   面板上的试写按钮已按授权者要求移除；`Set*` 系列函数保留但**不要再当可用接口用**。
--
-- 【要回答什么】“有没有接口能改回合数和年代显示”，用来配合「重启换图」：
-- 重启之后新局回到第 1 回合、远古时代，要假装「只是换了张图」，就得把回合与年代
-- 写回去（数据由跨存档通道带过来，那条已通）。
--
-- 【静态事实】（都来自游戏自带代码，详见 API_Verification_Status.md 第 13 节）
--   * 回合写：全库**只有一个**候选 `Game.SetCurrentGameTurn(n)`，出处是波兰场景的
--     gameplay 脚本且**被注释掉**（旁边写「回合与年份的做法还没定」）⇒ 纯待验证。
--   * 回合读：`Game.GetCurrentGameTurn()` / `Game.GetGameEndTurn()` / `Game.GetMaxGameTurns()`；
--     `GameConfiguration.GetStartTurn()` 是“这局从第几回合开始”。
--   * 回合上限：`GameConfiguration.SetMaxTurns(n)` + `SetTurnLimitType(TurnLimitTypes.CUSTOM)`
--     —— 引擎 Automation 用它，**对下一局生效**。
--   * 年代写：`WorldBuilder.PlayerManager():SetPlayerEra(playerID, eraType)`（**gameplay 层**，
--     地图编辑器的时代下拉框在用；本 mod 的 WorldBuilderAPI 已封装，属 [已验证可用] 通道）。
--   * 年代读：`Players[id]:GetEra()`（0 基）/ `Game.GetEras():GetCurrentEra()`
--     —— `Game.GetEras()` 上**只有读方法**（GetCurrentEra / GetCurrentEraStartTurn /
--     GetNextEraCountdown / GetPlayerNumAllowedCommemorations），没有 setter。
--   * 年代（下一局）：`GameConfiguration.SetStartEra(hash)` / `GAME_START_ERA` 配置键
--     （SetupParameters.xml:10，Hash="1" ⇒ 存的是哈希）。
--   * 年份显示：`Calendar.MakeYearStr(turn)` —— **年份是回合的纯函数**（TopPanel.lua:407），
--     所以「改年份显示」= 「改回合」；历法与速度来自 GameConfiguration。
--
-- 【两条调用路径】UI 层先直调；接口在 UI 层不存在或调用无效时，转 gameplay 侧
-- `ExposedMembers.ModMiscToolScript.TurnEraAPI`（见 ModTool_TurnEraAPI.lua）再试一次。
-- 每次都会把两条路径的结果都写进明细，方便判断“到底哪层能改”。
--
-- 【公开 API】本 mod 内直接调 ModMiscTurnEra.*
--   ⚠️ 带 `Set` / `Adjust` 的写接口**实测无效**（见上），仅留档。
--   DescribeContext()                 只读探测：回合/年份/年代现状 + 各候选接口可用性
--   DescribeFingerprint()             一行的现状摘要（开局探针与前后对比用）
--   GetTurnInfo()                     回合 / 结束回合 / 上限 / 开始回合
--   GetDateString(turn)               该回合对应的年份文本（Calendar）
--   GetEraEntries()                   时代清单（按 Index 排序，数据来自 GameInfo.Eras）
--   GetPlayerEraType(playerID)        该玩家当前时代类型
--   AdjustTurn(delta)                 回合 ±N（夹到 >= 1）
--   SetTurn(turn)                     试写回合（UI → gameplay 两条路）
--   AdjustPlayerEra(playerID, delta)  年代 ±1（按时代清单走）
--   SetPlayerEra(playerID, eraType)   试写年代（gameplay WorldBuilder 通道）
--   SetStartEra(eraType)              写「下一局的开始年代」（配置键 GAME_START_ERA）
--   ReportAfterLoad()                 开局探针：一行现状（由 Support_UI.Initialize 调一次）
--
-- ⚠️ 本文件**故意不挂 Events**（会被多个 context include）；开局探针由 Support_UI 调。
-- ===========================================================================

local MODMISC_TURNERA_BUILD_TAG = "2026-10-05-A"

ModMiscTurnEra = ModMiscTurnEra or {}
local API = ModMiscTurnEra
API.BuildTag = MODMISC_TURNERA_BUILD_TAG

local function Log(message)
    print("[ModMiscTool][TurnEra] " .. tostring(message))
end

-- 诊断代码一律不能影响主流程
local function TryCall(getter)
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter)
    if not ok then return nil end
    return value
end

local function IsAvailable(ownerName, memberName)
    local owner = _G[ownerName]
    if owner == nil then return false end
    if memberName == nil then return true end
    return owner[memberName] ~= nil
end

-- gameplay 侧的兜底通道（ModTool_TurnEraAPI.lua 暴露）
local function GetGameplayChannel()
    local members = ExposedMembers ~= nil and ExposedMembers.ModMiscToolScript or nil
    return members ~= nil and members.TurnEraAPI or nil
end

-- ===========================================================================
-- 现状：回合 / 年份 / 年代
-- ===========================================================================

function API.GetTurnInfo()
    local info = {}
    info.Turn = TryCall(function() return Game.GetCurrentGameTurn() end)
    info.EndTurn = TryCall(function() return Game.GetGameEndTurn() end)
    info.MaxTurns = TryCall(function() return Game.GetMaxGameTurns() end)
    info.StartTurn = TryCall(function() return GameConfiguration.GetStartTurn() end)
    -- 配置对象里的写法也一起探（有 named getter 不一定有同名配置键）
    info.StartTurnConfig = TryCall(function() return GameConfiguration.GetValue("START_TURN") end)
    info.ConfigMaxTurns = TryCall(function() return GameConfiguration.GetMaxTurns() end)
    return info
end

function API.GetDateString(turn)
    if turn == nil then turn = TryCall(function() return Game.GetCurrentGameTurn() end) end
    if turn == nil then return "?" end
    local text = TryCall(function() return Calendar.MakeYearStr(turn) end)
    if text == nil then
        text = TryCall(function()
            return Calendar.MakeDateStr(turn, GameConfiguration.GetCalendarType(),
                GameConfiguration.GetGameSpeedType(), false)
        end)
    end
    return text ~= nil and tostring(text) or "?"
end

-- 时代清单：按 Index 升序（数据驱动，加资料片时代不用改代码）
function API.GetEraEntries()
    local list = {}
    local ok = pcall(function()
        for row in GameInfo.Eras() do
            table.insert(list, { Index = row.Index, EraType = row.EraType, Name = row.Name })
        end
    end)
    if not ok or #list == 0 then return {} end
    table.sort(list, function(a, b) return (a.Index or 0) < (b.Index or 0) end)
    return list
end

function API.GetPlayerEraType(playerID)
    -- Players 整个表都可能不存在（诊断代码不许崩，本项目踩过“诊断把主逻辑带崩”）
    if playerID == nil or Players == nil or Players[playerID] == nil then return nil end
    local index = TryCall(function() return Players[playerID]:GetEra() end)
    if index == nil then return nil end
    local row = GameInfo.Eras[index]
    if row ~= nil then return row.EraType end
    return nil
end

function API.DescribeFingerprint()
    local turnInfo = API.GetTurnInfo()
    local playerID = TryCall(function() return Game.GetLocalPlayer() end)
    local gameEraIndex = TryCall(function() return Game.GetEras():GetCurrentEra() end)
    local gameEraType = "?"
    if gameEraIndex ~= nil and GameInfo.Eras[gameEraIndex] ~= nil then
        gameEraType = GameInfo.Eras[gameEraIndex].EraType
    end
    return string.format("turn=%s date=%s startTurn=%s endTurn=%s maxTurns=%s playerEra=%s gameEra=%s",
        tostring(turnInfo.Turn), API.GetDateString(turnInfo.Turn),
        tostring(turnInfo.StartTurn), tostring(turnInfo.EndTurn), tostring(turnInfo.MaxTurns),
        tostring(API.GetPlayerEraType(playerID)), tostring(gameEraType))
end

-- ===========================================================================
-- 只读探测：候选接口在**当前上下文**里可不可用 + 现状
-- ===========================================================================

local TURNERA_API_FLAGS = {
    { Label = "Game.GetCurrentGameTurn",        Owner = "Game", Member = "GetCurrentGameTurn" },
    { Label = "Game.GetGameEndTurn",            Owner = "Game", Member = "GetGameEndTurn" },
    { Label = "Game.GetMaxGameTurns",           Owner = "Game", Member = "GetMaxGameTurns" },
    { Label = "Game.SetCurrentGameTurn",        Owner = "Game", Member = "SetCurrentGameTurn" },
    { Label = "Game.GetEras",                   Owner = "Game", Member = "GetEras" },
    { Label = "Calendar.MakeYearStr",           Owner = "Calendar", Member = "MakeYearStr" },
    { Label = "Calendar.MakeDateStr",           Owner = "Calendar", Member = "MakeDateStr" },
    { Label = "GameConfiguration.GetStartTurn", Owner = "GameConfiguration", Member = "GetStartTurn" },
    { Label = "GameConfiguration.GetStartEra",  Owner = "GameConfiguration", Member = "GetStartEra" },
    { Label = "GameConfiguration.SetStartEra",  Owner = "GameConfiguration", Member = "SetStartEra" },
    { Label = "GameConfiguration.SetMaxTurns",  Owner = "GameConfiguration", Member = "SetMaxTurns" },
    { Label = "GameConfiguration.SetValue",     Owner = "GameConfiguration", Member = "SetValue" },
    { Label = "TurnLimitTypes",                 Owner = "TurnLimitTypes" },
    { Label = "WorldBuilder",                   Owner = "WorldBuilder" },
    { Label = "AutoplayManager",                Owner = "AutoplayManager" },
    { Label = "Events.PlayerEraChanged",        Owner = "Events", Member = "PlayerEraChanged" },
    { Label = "DB.MakeHash",                    Owner = "DB", Member = "MakeHash" },
}

local function BuildApiFlagText()
    local parts = {}
    for _, spec in ipairs(TURNERA_API_FLAGS) do
        table.insert(parts, spec.Label .. "=" .. (IsAvailable(spec.Owner, spec.Member) and "y" or "n"))
    end
    return table.concat(parts, " ")
end

function API.DescribeContext()
    local turnInfo = API.GetTurnInfo()
    local playerID = TryCall(function() return Game.GetLocalPlayer() end)
    local gameplayChannel = GetGameplayChannel()

    local lines = {}
    table.insert(lines, "now: " .. API.DescribeFingerprint())
    table.insert(lines, "turn: turn=" .. tostring(turnInfo.Turn)
        .. " endTurn=" .. tostring(turnInfo.EndTurn)
        .. " maxTurns=" .. tostring(turnInfo.MaxTurns)
        .. " startTurn=" .. tostring(turnInfo.StartTurn)
        .. " startTurnConfig=" .. tostring(turnInfo.StartTurnConfig)
        .. " configMaxTurns=" .. tostring(turnInfo.ConfigMaxTurns))
    table.insert(lines, "era: player(" .. tostring(playerID) .. ")=" .. tostring(API.GetPlayerEraType(playerID))
        .. " startEraHash=" .. tostring(TryCall(function() return GameConfiguration.GetStartEra() end))
        .. " calendar=" .. tostring(TryCall(function() return GameConfiguration.GetCalendarType() end))
        .. " calendarConfig=" .. tostring(TryCall(function() return GameConfiguration.GetValue("CALENDAR_TYPE") end))
        .. " speed=" .. tostring(TryCall(function() return GameConfiguration.GetGameSpeedType() end))
        .. " eras=" .. tostring(#API.GetEraEntries()))
    table.insert(lines, "routes: gameplayChannel=" .. tostring(gameplayChannel ~= nil)
        .. " gameplaySetTurn=" .. tostring(gameplayChannel ~= nil and gameplayChannel.SetCurrentGameTurn ~= nil)
        .. " gameplaySetEra=" .. tostring(gameplayChannel ~= nil and gameplayChannel.SetPlayerEra ~= nil)
        .. " wbApi=" .. tostring(ExposedMembers ~= nil and ExposedMembers.ModMiscToolScript ~= nil
            and ExposedMembers.ModMiscToolScript.WorldBuilderAPI ~= nil))
    table.insert(lines, "api: " .. BuildApiFlagText())

    for _, line in ipairs(lines) do
        Log(line)
    end
    return table.concat(lines, "\n")
end

-- ===========================================================================
-- 写入：回合（先 UI 直调，再 gameplay 兜底）
-- ===========================================================================

local function ReadBackTurn()
    return TryCall(function() return Game.GetCurrentGameTurn() end)
end

-- [已验证失败] 2026-10-05：UI 直调与 gameplay 兜底都写不进去（applied=false，回读不变）
function API.SetTurn(turn)
    local target = tonumber(turn)
    if target == nil then return false, "turn 不是数字：" .. tostring(turn) end

    local before = ReadBackTurn()
    local results = {}

    -- ① UI 层直调
    if Game ~= nil and Game.SetCurrentGameTurn ~= nil then
        Log("SetTurn: 即将调用（UI 直调）Game.SetCurrentGameTurn(" .. tostring(target) .. ")")
        local ok, err = pcall(Game.SetCurrentGameTurn, target)
        table.insert(results, "ui=" .. tostring(ok))
        if not ok then Log("SetTurn: UI 直调失败 -> " .. tostring(err)) end
    else
        table.insert(results, "ui=skip")
    end

    local after = ReadBackTurn()
    if after ~= nil and tonumber(after) == target then
        local detail = string.format("route=ui target=%d before=%s after=%s", target,
            tostring(before), tostring(after))
        Log("SetTurn: applied=true " .. detail)
        return true, detail
    end

    -- ② gameplay 兜底
    local channel = GetGameplayChannel()
    if channel ~= nil and channel.SetCurrentGameTurn ~= nil then
        Log("SetTurn: 即将调用（gameplay 兜底）TurnEraAPI.SetCurrentGameTurn(" .. tostring(target) .. ")")
        local ok, applied, detail = pcall(channel.SetCurrentGameTurn, target)
        table.insert(results, "gameplay=" .. tostring(ok and applied))
        if not ok then Log("SetTurn: gameplay 兜底失败 -> " .. tostring(applied)) end
        after = ReadBackTurn()
        if after ~= nil and tonumber(after) == target then
            local text = string.format("route=gameplay target=%d before=%s after=%s",
                target, tostring(before), tostring(after))
            Log("SetTurn: applied=true " .. text)
            return true, text
        end
    else
        table.insert(results, "gameplay=skip")
    end

    local detail = string.format("applied=false target=%d before=%s after=%s routes[%s]",
        target, tostring(before), tostring(after), table.concat(results, " "))
    Log("SetTurn: " .. detail)
    return false, detail
end

function API.AdjustTurn(delta)
    local step = tonumber(delta)
    if step == nil then return false, "delta 不是数字" end
    local current = ReadBackTurn()
    if current == nil then return false, "读不到当前回合" end
    local target = current + step
    if target < 1 then target = 1 end
    return API.SetTurn(target)
end

-- ===========================================================================
-- 写入：年代（gameplay WorldBuilder 通道）
-- ===========================================================================

-- [已验证失败] 2026-10-05：通道本身可用（地图编辑器在用），但普通对局里改年代不生效
function API.SetPlayerEra(playerID, eraType)
    if playerID == nil or eraType == nil then return false, "参数不全" end

    local before = API.GetPlayerEraType(playerID)
    local results = {}

    -- ① gameplay 通道（WorldBuilder 在 gameplay 层；UI 层看不到这些接口）
    local channel = GetGameplayChannel()
    if channel ~= nil and channel.SetPlayerEra ~= nil then
        Log("SetPlayerEra: 即将调用（gameplay）player=" .. tostring(playerID)
            .. " -> " .. tostring(eraType))
        local ok, applied, detail = pcall(channel.SetPlayerEra, playerID, eraType)
        table.insert(results, "gameplay=" .. tostring(ok and applied))
        if not ok then Log("SetPlayerEra: gameplay 调用失败 -> " .. tostring(applied)) end
    else
        table.insert(results, "gameplay=skip")
    end

    local after = API.GetPlayerEraType(playerID)
    local applied = after ~= nil and tostring(after) == tostring(eraType)
    local detail = string.format("applied=%s player=%s target=%s before=%s after=%s routes[%s]",
        tostring(applied), tostring(playerID), tostring(eraType), tostring(before), tostring(after),
        table.concat(results, " "))
    Log("SetPlayerEra: " .. detail)
    return applied, detail
end

-- 该玩家“偏移 N 个时代”之后是哪个时代（夹在清单首尾之间）。
-- 多处要用（年代 ±1、下一局开始年代），所以只此一份。
function API.GetEraTypeByOffset(playerID, delta)
    local step = tonumber(delta)
    if step == nil then return nil, "delta 不是数字" end
    if playerID == nil or Players == nil or Players[playerID] == nil then return nil, "玩家无效" end

    local currentIndex = TryCall(function() return Players[playerID]:GetEra() end)
    if currentIndex == nil then return nil, "读不到该玩家的时代" end
    local entries = API.GetEraEntries()
    if #entries == 0 then return nil, "读不到时代清单" end

    local targetIndex = currentIndex + step
    if targetIndex < entries[1].Index then targetIndex = entries[1].Index end
    local last = entries[#entries].Index
    if targetIndex > last then targetIndex = last end

    for _, entry in ipairs(entries) do
        if entry.Index == targetIndex then return entry.EraType end
    end
    return nil, "没有 Index=" .. tostring(targetIndex) .. " 的时代"
end

-- 按时代清单 ±N（用来验证“能不能来回改”，也是恢复存档年代的最小动作）
function API.AdjustPlayerEra(playerID, delta)
    local eraType, err = API.GetEraTypeByOffset(playerID, delta)
    if eraType == nil then return false, tostring(err) end
    return API.SetPlayerEra(playerID, eraType)
end

-- ===========================================================================
-- 写入：下一局的开始年代（配置键 GAME_START_ERA；重启换图后用来复位年代）
-- ===========================================================================

-- [已验证失败] 2026-10-05：写入与回读都可能成功，但**下一局并不按它开局**（实测未生效）
function API.SetStartEra(eraType)
    if eraType == nil or tostring(eraType) == "" then return false, "eraType 为空" end
    if GameConfiguration == nil or GameConfiguration.SetValue == nil then
        return false, "GameConfiguration.SetValue 不可用"
    end

    local hash = TryCall(function() return DB.MakeHash(tostring(eraType)) end)
    local before = TryCall(function() return GameConfiguration.GetStartEra() end)
    local results = {}

    if GameConfiguration.SetStartEra ~= nil and hash ~= nil then
        local ok = pcall(GameConfiguration.SetStartEra, hash)
        table.insert(results, "SetStartEra(hash)=" .. tostring(ok))
    else
        table.insert(results, "SetStartEra=skip")
    end

    local readback = TryCall(function() return GameConfiguration.GetStartEra() end)
    if readback == nil or (hash ~= nil and tonumber(readback) ~= hash) then
        local ok = pcall(GameConfiguration.SetValue, "GAME_START_ERA", hash)
        table.insert(results, "SetValue(hash)=" .. tostring(ok))
        readback = TryCall(function() return GameConfiguration.GetStartEra() end)
    end

    local applied = readback ~= nil and hash ~= nil and tonumber(readback) == hash
    local detail = string.format("applied=%s era=%s hash=%s before=%s after=%s routes[%s]",
        tostring(applied), tostring(eraType), tostring(hash), tostring(before), tostring(readback),
        table.concat(results, " "))
    Log("SetStartEra: " .. detail)
    return applied, detail
end

-- ===========================================================================
-- 开局探针：每次进游戏一行现状（重启换图前后对比就看它）
-- ===========================================================================

function API.ReportAfterLoad()
    Log("after-load: " .. API.DescribeFingerprint())
end
