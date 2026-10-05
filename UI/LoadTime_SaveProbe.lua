-- ===========================================================================
-- Mod Misc Tool: 「游戏加载完成之前」存档/读档探针
--
-- 【授权者 2026-10-05 的方向】主界面（纯前端、没有对局）建立普通存档会**闪退** —— 那条路
-- 不可行。换个时机试：**刚开始读档 / 创建游戏、游戏还没加载完的时候**做存档读档操作，
-- 看看会发生什么。
--
-- 【这个时机在哪】引擎事件 `Events.LoadScreenContentReady` —— 载入界面自己的注释写着
-- 「All game data exists for the player in order to fill out the screen」：
-- **游戏数据已经存在、但游戏视图还没就绪**。它由引擎在 LoadScreen 上下文活着的时候发出，
-- 而 LoadScreen 会 include Civ6Common（本文件就是被它带进来的），所以我们在载入界面里
-- 一定能收到这个事件 —— 这就是“加载完成之前”的窗口。
--   载入界面上下文判据：`Controls.PortraitContainer`（全前端只有 LoadScreen.xml 有它）
--   同一次加载会有多个 context 收到事件 ⇒ 用 CustomData 写一个时间片守卫，只让第一个跑
--   （CustomData 是引擎级的，跨 context 可见 ✓）。
--
-- 【做什么】分阶段、每步调用前先打日志（真出事时日志最后一行就是罪魁）：
--   L0 recon   环境：gameState / IsInFrontEnd / Network.GetLocalPlayerID /
--              UI.GetSaveGameMetaData()（“正在加载的那份档”的元数据——载入期能不能读到）
--   L1 read    CustomData 里现在有什么（载入进行到这一步，存档的快照还原了没有）
--   L2 write   写一个加载期标记（进游戏后再看它有没有活下来）
--   L3 query   UI.QuerySaveGameList（载入期能不能列存档列表）
--   L4 save    Network.SaveGame 一份普通存档（**核心问题**：载入期能不能写档）  ← 开关
--   L5 load    Network.LoadGame（载入期再发起一次读档，最可能把加载器搞乱）    ← 开关，默认关
--   进游戏后（in-game 的 LoadGameViewStateDone）：
--   P2 verify  标记活下来没有 / 探针档在不在列表里（字段全打出来）
--   P2 clean   删掉探针档（只认 MMTLoadProbe 前缀，绝不碰玩家自己的档）
--
-- 判定写在 VERDICT= 里：
--   lt-l0-ok / lt-l1-customdata / lt-l2-written / lt-l3-listed /
--   lt-l4-save-ok / lt-l4-save-failed / lt-l4-save-no-complete /
--   lt-p2-marker-gone / lt-p2-marker-alive / lt-p2-probe-save-listed / lt-p2-probe-save-missing /
--   lt-p2-cleaned
--
-- 开关（本文件顶部）：
--   LOADTIME_PROBE_ENABLED     总开关（Civ6Common 里也有一份，默认开）
--   LOADTIME_SAVE_STEP_ENABLED  L4：载入期写普通存档（默认开 —— 这是本轮要问的）
--   LOADTIME_LOAD_STEP_ENABLED  L5：载入期再读一次档（默认关；打开前先看文档 §17.3）
-- ===========================================================================

local LOADTIME_PROBE_BUILD_TAG = "2026-10-05-B"
local LOADTIME_SAVE_STEP_ENABLED = true
local LOADTIME_LOAD_STEP_ENABLED = false

local LOADTIME_PROBE_PREFIX = "MMTLoadProbe"
local LOADTIME_GUARD_KEY = "ModMiscToolLoadProbeStamp"
local LOADTIME_MARK_KEY = "ModMiscToolLoadProbeMarker"

local m_Phase = nil            -- "load" / "p2"
local m_Stamp = nil
local m_QueryRows = nil
local m_QueryRequestId = nil
local m_SaveComplete = false
local m_ProbeName = nil
local m_ProbeSaveIssued = false
local m_CleanupOnly = false     -- 阶段二只做清理（本局没有加载期标记，多为上一轮崩在半路）

local function Log(message)
    print("[ModMiscTool][LoadTimeProbe] " .. tostring(message))
end

local function TryCall(getter)
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter)
    if not ok then return nil end
    return value
end

local function ReadCustomDataSafe(key)
    if ReadCustomData == nil then return nil end
    local ok, value = pcall(ReadCustomData, key)
    if not ok or value == nil then return nil end
    local text = tostring(value)
    if text == "" then return nil end
    return text
end

local function WriteCustomDataSafe(key, value)
    if WriteCustomData == nil then return false end
    local ok = pcall(WriteCustomData, key, tostring(value or ""))
    return ok
end

-- 载入界面上下文判据。
-- **踩过的坑**：一开始只看 `Controls.PortraitContainer` —— 那是桌面版 LoadScreen.xml 的控件，
-- 安卓用的是 LoadScreen_PHONE.xml，里面**没有** PortraitContainer（只有 Portrait），
-- 于是判据在手机上恒为 false、阶段一永远不会跑（静态核对游戏自带文件时抓到的）。
-- 三个变体（LoadScreen.xml / _PHONE / _TABLET）根节点都是 `<Context Name="LoadScreen">`，
-- 所以先认 `ContextPtr:GetID()`，控件只作退路。
-- 本 context 的名字（日志里要看是哪个 context 抢到了这次机会）
local function ContextName()
    if ContextPtr ~= nil and ContextPtr.GetID ~= nil then
        local ok, id = pcall(function() return ContextPtr:GetID() end)
        if ok and type(id) == "string" and id ~= "" then return id end
    end
    return "?"
end

local function IsLoadScreenContext()
    local id = ContextName()
    if id ~= "?" then return id == "LoadScreen" end
    if Controls == nil then return false end
    return Controls.PortraitContainer ~= nil
        or (Controls.CivName ~= nil and Controls.LeaderInfo ~= nil and Controls.FadeAnim ~= nil)
end

local function DescribeEntry(entry)
    local parts = {}
    for key, value in pairs(entry) do
        if type(value) ~= "table" and type(value) ~= "function" then
            table.insert(parts, tostring(key) .. "=" .. tostring(value))
        end
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- 前置声明：查询回调要用它（异步回包时才推进阶段二）
local PhaseTwoFollowUp = nil

local function OnFileListResults(fileList, requestId)
    if m_QueryRequestId == nil or requestId ~= m_QueryRequestId then return end
    m_QueryRequestId = nil
    if LuaEvents ~= nil and LuaEvents.FileListQueryResults ~= nil then
        LuaEvents.FileListQueryResults.Remove(OnFileListResults)
    end
    m_QueryRows = type(fileList) == "table" and fileList or {}
    Log("列表回包 " .. tostring(#m_QueryRows) .. " 条（phase=" .. tostring(m_Phase) .. "）")
    for _, entry in ipairs(m_QueryRows) do
        Log("    " .. DescribeEntry(entry))
    end
    -- 阶段二的核对与清理在回包之后做（查询是异步的，不能指望调用点之后立刻就有数据）
    if m_Phase == "p2" and PhaseTwoFollowUp ~= nil then
        local ok, err = pcall(PhaseTwoFollowUp)
        if not ok then Log("阶段二核对异常 -> " .. tostring(err)) end
    end
end

local function StartQuery()
    if UI == nil or UI.QuerySaveGameList == nil or LuaEvents == nil
        or LuaEvents.FileListQueryResults == nil or SaveLocationOptions == nil then
        Log("查询不可用（QuerySaveGameList / FileListQueryResults / SaveLocationOptions 缺失）")
        return false
    end
    m_QueryRows = nil
    local options = SaveLocationOptions.NORMAL + SaveLocationOptions.QUICKSAVE
        + SaveLocationOptions.LOAD_METADATA
    LuaEvents.FileListQueryResults.Add(OnFileListResults)
    m_QueryRequestId = UI.QuerySaveGameList(SaveLocations.LOCAL_STORAGE, SaveTypes.SINGLE_PLAYER,
        options, SaveFileTypes.GAME_STATE, nil)
    Log("已发出存档列表查询（请求号 " .. tostring(m_QueryRequestId) .. "）")
    return true
end

-- ===========================================================================
-- 阶段一：游戏加载完成之前（Events.LoadScreenContentReady）
-- ===========================================================================

local function StepL0Recon()
    Log("L0 recon：context=" .. ContextName() .. "（句柄 " .. tostring(ContextPtr) .. "）"
        .. " gameState=" .. tostring(TryCall(function() return GameConfiguration.GetGameState() end))
        .. " IsInFrontEnd=" .. tostring(TryCall(function() return UI.IsInFrontEnd() end))
        .. " localPlayerID(Network)=" .. tostring(TryCall(function() return Network.GetLocalPlayerID() end))
        .. " turn=" .. tostring(TryCall(function() return Game.GetCurrentGameTurn() end)))
    Log("  api: SaveGame=" .. tostring(Network ~= nil and Network.SaveGame ~= nil)
        .. " LoadGame=" .. tostring(Network ~= nil and Network.LoadGame ~= nil)
        .. " QuerySaveGameList=" .. tostring(UI ~= nil and UI.QuerySaveGameList ~= nil)
        .. " GetSaveGameMetaData=" .. tostring(UI ~= nil and UI.GetSaveGameMetaData ~= nil)
        .. " GetLastSaveName=" .. tostring(UI ~= nil and UI.GetLastSaveName ~= nil))

    -- “正在加载的是哪份档”：载入期能不能读到元数据
    local meta = TryCall(function() return UI.GetSaveGameMetaData() end)
    if type(meta) == "table" then
        Log("  GetSaveGameMetaData 返回 " .. tostring(#meta) .. " 条：")
        for index, item in ipairs(meta) do
            if type(item) == "table" then
                Log("    [" .. tostring(index) .. "] " .. DescribeEntry(item))
            end
        end
    else
        Log("  GetSaveGameMetaData -> " .. tostring(meta))
    end
    Log("  GetLastSaveName -> " .. tostring(TryCall(function() return UI.GetLastSaveName() end)))
    Log("VERDICT=lt-l0-ok")
end

local function StepL1ReadCustomData()
    local nodeId = ReadCustomDataSafe("ModMiscSaveGraph_NodeId")
    local offset = ReadCustomDataSafe("ModMiscSaveGraph_Offset")
    local marker = ReadCustomDataSafe(LOADTIME_MARK_KEY)
    Log("L1 CustomData（载入进行到这一步的快照）：")
    Log("  ModMiscSaveGraph_NodeId=" .. tostring(nodeId)
        .. " Offset=" .. tostring(offset) .. " 上次的加载标记=" .. tostring(marker))
    Log("VERDICT=lt-l1-customdata")
end

local function StepL2WriteMarker()
    local text = "load@" .. tostring(m_Stamp) .. ";t=" .. tostring(os.time())
        .. ";phase=LoadScreenContentReady"
    local ok = WriteCustomDataSafe(LOADTIME_MARK_KEY, text)
    Log("L2 写加载期标记 [" .. text .. "] 结果=" .. tostring(ok))
    if ok then Log("VERDICT=lt-l2-written") end
end

local function StepL4Save()
    if not LOADTIME_SAVE_STEP_ENABLED then
        Log("L4 跳过（LOADTIME_SAVE_STEP_ENABLED=false）")
        return
    end
    if Network == nil or Network.SaveGame == nil then
        Log("VERDICT=lt-l4-save-failed：Network.SaveGame 不可用")
        return
    end
    m_ProbeName = LOADTIME_PROBE_PREFIX .. "~load~" .. tostring(m_Stamp)
    -- 字段照抄游戏自己的存法（Menus/SaveGameMenu.lua 用 Name/Location/Type/FileType；
    -- InGameTopOptionsMenu 的快速存档则用 Network.GetGameConfigurationSaveType() 当 Type）。
    -- 这里优先用引擎给的当前对局类型，拿不到才退回 SINGLE_PLAYER。
    local gameType = TryCall(function() return Network.GetGameConfigurationSaveType() end)
    if gameType == nil and SaveTypes ~= nil then gameType = SaveTypes.SINGLE_PLAYER end
    local saveFile = {
        Name = m_ProbeName,
        Location = SaveLocations ~= nil and SaveLocations.LOCAL_STORAGE or nil,
        Type = gameType,
        FileType = SaveFileTypes ~= nil and SaveFileTypes.GAME_STATE or nil,
        IsAutosave = false,
        IsQuicksave = false,
    }
    if SaveDirectories ~= nil then saveFile.Directory = SaveDirectories.DEFAULT end

    Log("L4 即将调用 Network.SaveGame（**游戏加载完成之前**）name=" .. tostring(m_ProbeName)
        .. " Type=" .. tostring(gameType) .. "（引擎给的当前对局类型）FileType=GAME_STATE"
        .. " Location=" .. tostring(saveFile.Location))
    m_ProbeSaveIssued = true
    local ok, err = pcall(Network.SaveGame, saveFile)
    if not ok then
        Log("VERDICT=lt-l4-save-failed：调用抛错 -> " .. tostring(err))
        return
    end
    Log("  Network.SaveGame 调用已返回（没卡死），等 Events.SaveComplete / 或进游戏后再看列表")
end

local function StepL5Load()
    if not LOADTIME_LOAD_STEP_ENABLED then
        Log("L5 跳过（LOADTIME_LOAD_STEP_ENABLED=false —— 载入期再读档最容易把加载器搞乱，"
            .. "要试就先看文档 §17.3）")
        return
    end
    -- 有目标才试：优先用刚才写的探针档
    local target = nil
    for _, entry in ipairs(m_QueryRows or {}) do
        if entry ~= nil and tostring(entry.Name):sub(1, #LOADTIME_PROBE_PREFIX) == LOADTIME_PROBE_PREFIX then
            target = entry
            break
        end
    end
    if target == nil then
        Log("L5 没有可读的目标（列表里没有探针档），跳过")
        return
    end
    Log("L5 即将调用 Network.LoadGame（**载入期读档**）name=" .. tostring(target.Name))
    -- ServerType 是引擎给的枚举；拿不到就传 nil（别让它把阶段一打断）
    local serverType = ServerType ~= nil and ServerType.SERVER_TYPE_NONE or nil
    local ok, err = pcall(Network.LoadGame, target, serverType)
    Log(ok and "  Network.LoadGame 调用已返回（没卡死）"
        or ("  Network.LoadGame 调用抛错 -> " .. tostring(err)))
end

local function PhaseOne()
    if not IsLoadScreenContext() then return end      -- 只让载入界面那个 context 跑
    if m_Phase == "load" then return end

    -- 同一次加载会有多个 context 收到事件 → 用 CustomData 时间片守卫，只让第一个跑
    local stamp = tostring(math.floor((TryCall(function() return os.time() end) or 0) / 30))
    local guard = ReadCustomDataSafe(LOADTIME_GUARD_KEY)
    if guard == stamp then return end
    WriteCustomDataSafe(LOADTIME_GUARD_KEY, stamp)

    m_Phase = "load"
    m_Stamp = stamp
    Log("===== 载入期探针开始（LoadScreenContentReady）build=" .. LOADTIME_PROBE_BUILD_TAG .. " =====")
    StepL0Recon()
    StepL1ReadCustomData()
    StepL2WriteMarker()
    if StartQuery() then
        -- 查询是异步的；L4 不等它（载入期时间窗很短，先问最关键的）
    end
    StepL4Save()
    StepL5Load()
    Log("===== 载入期探针：阶段一代码跑完（没崩就说明这些调用在载入期是安全的） =====")
end

-- ===========================================================================
-- 阶段二：游戏起来之后核对（in-game 的 LoadGameViewStateDone）
-- ===========================================================================

local function PhaseTwo()
    if IsLoadScreenContext() then return end          -- 载入界面自己那份不跑阶段二
    if m_Phase == "p2" then return end
    m_Phase = "p2"
    -- in-game 里 include 过 Civ6Common 的 context 有一堆，都会收到这个事件 →
    -- 用 CustomData 写个一次性守卫，只让第一个做核对与清理（**先占守卫再干活**）
    local token = ReadCustomDataSafe(LOADTIME_GUARD_KEY) or ("notime" .. tostring(os.time()))
    local guardKey = LOADTIME_GUARD_KEY .. "_p2"
    if ReadCustomDataSafe(guardKey) == token then
        Log("P2 跳过：别的 context 已经在做核对与清理了（一次性守卫）")
        return
    end
    WriteCustomDataSafe(guardKey, token)

    -- 只有“刚刚经历过载入期探针”的这一局才核对：标记在不在
    local marker = ReadCustomDataSafe(LOADTIME_MARK_KEY)
    if marker == nil then
        -- 没有任何加载期痕迹：阶段一没跑（载入界面 include 得太晚 / 事件名不对），
        -- 或者标记没活下来，或者**上一轮载入期直接崩了**（阶段二没跑到、探针档留在盘上）
        Log("VERDICT=lt-p1-missed：这一局看不到加载期探针的痕迹（阶段一没跑或标记没活下来）")
        Log("  仍然查一遍列表，把历史遗留的探针档清掉")
        m_CleanupOnly = true
        StartQuery()
        return
    end
    -- 正常情况：本 context 没经历载入期（阶段一在载入界面那个 context 里跑的）
    Log("（本 context 没跑阶段一，标记来自载入界面：这是正常的）")
    Log("===== 载入期探针：阶段二核对（in-game）build=" .. LOADTIME_PROBE_BUILD_TAG
        .. " context=" .. ContextName() .. " =====")
    Log("P2 加载期标记：" .. marker)
    if marker:find("phase=LoadScreenContentReady", 1, true) ~= nil then
        Log("VERDICT=lt-p2-marker-alive：加载期写的标记活到了对局里")
    else
        Log("VERDICT=lt-p2-marker-gone")
    end
    if StartQuery() then
        Log("  已发出列表查询，下一帧看结果（含探针档在不在）")
    end
end

PhaseTwoFollowUp = function()
    if m_Phase ~= "p2" or m_QueryRows == nil then return end
    local found = nil
    local stale = {}
    for _, entry in ipairs(m_QueryRows) do
        if entry ~= nil and tostring(entry.Name):sub(1, #LOADTIME_PROBE_PREFIX) == LOADTIME_PROBE_PREFIX then
            if tostring(entry.Name):find("load~", 1, true) ~= nil then
                found = entry
            else
                table.insert(stale, entry)
            end
        end
    end
    if m_CleanupOnly then
        Log("（只清理模式：本局没有加载期标记，不判断探针档写没写成）")
    elseif found ~= nil then
        Log("VERDICT=lt-p2-probe-save-listed：载入期写的档在列表里 —— " .. DescribeEntry(found))
    else
        Log("VERDICT=lt-p2-probe-save-missing：列表里没有载入期写的档（可能没写成功）")
    end

    -- 清理：本轮这份 + 以前遗留的探针档
    local removed = 0
    for _, entry in ipairs(m_QueryRows) do
        if entry ~= nil and tostring(entry.Name):sub(1, #LOADTIME_PROBE_PREFIX) == LOADTIME_PROBE_PREFIX then
            if UI ~= nil and UI.DeleteSavedGame ~= nil then
                local ok = pcall(UI.DeleteSavedGame, entry)
                if ok then
                    removed = removed + 1
                    Log("  已删除探针档 " .. tostring(entry.Name))
                end
            end
        end
    end
    if removed > 0 then Log("VERDICT=lt-p2-cleaned：清掉 " .. tostring(removed) .. " 个探针档") end
    -- 标记清掉：免得它跟着玩家之后的存档一直传下去（下次读档又会跑一遍核对）
    WriteCustomDataSafe(LOADTIME_MARK_KEY, "")
    m_QueryRows = nil
end

-- ===========================================================================
-- 注册（在 include 阶段就挂上 —— 必须早于 LoadScreen 自己的 Initialize）
-- ===========================================================================

if Events ~= nil and Events.LoadScreenContentReady ~= nil then
    Events.LoadScreenContentReady.Add(function()
        local ok, err = pcall(PhaseOne)
        if not ok then Log("阶段一异常 -> " .. tostring(err)) end
    end)
end
if Events ~= nil and Events.LoadGameViewStateDone ~= nil then
    Events.LoadGameViewStateDone.Add(function()
        local ok, err = pcall(PhaseTwo)
        if not ok then Log("阶段二异常 -> " .. tostring(err)) end
    end)
end
if Events ~= nil and Events.SaveComplete ~= nil then
    Events.SaveComplete.Add(function(...)
        if m_ProbeSaveIssued then
            m_SaveComplete = true
            local first = ...
            Log("SaveComplete 回执：" .. tostring(first) .. "（载入期的存档请求）")
            Log("VERDICT=lt-l4-save-ok")
        end
    end)
end

-- 这个全局是 include 幂等标记（Civ6Common 会被同一 context include 两次）
ModMiscLoadTimeSaveProbeLoaded = true
