-- ===========================================================================
-- Mod Misc Tool: 前端「普通存档」探针（主界面 / 创建游戏 / 创建场景）
--
-- 【要验证什么】授权者 2026-10-05 提的方向：**能不能在前端建立并读取一份普通存档
-- （GAME_STATE）**，把它当成“特别命名的存档”来用。预期很可能是失败 —— 前端没有
-- 正在进行的对局，普通存档里没有游戏数据 —— 但值得一试。
--
-- 与另一个探针（FrontEnd_SaveProbe.lua，跑配置档）的区别：
--   * 那个写的是 GAME_CONFIGURATION（配置档，前端本来就能写，已 [已验证可用]）；
--   * 本探针写的是 **GAME_STATE（普通存档）**，前端没有对局时理论上写不出来/写出来是空壳。
--
-- 一次进入界面 = 一轮实验，日志前缀 [ModMiscTool][FeGameSaveProbe]，判定写在 VERDICT= 里：
--   step0 recon   自述：界面 / 上下文 / 游戏状态（PREGAME?）/ 各接口是否可用
--   step1 write   Network.SaveGame{ Type=SINGLE_PLAYER, FileType=GAME_STATE, Name=MMTGameSaveProbe~<时间> }
--   step2 wait    等 Events.SaveComplete（超时 N 帧就按“没回执”记）
--   step3 list    UI.QuerySaveGameList 查普通存档列表：我们的档在不在？**列表里还能读到什么字段**？
--                 （这一步回答“不用载入能读到多少”，元数据字段本身是重要证据）
--   step4 load    试着 Network.LoadGame(这份档) —— “前端能不能读普通存档”的核心问题
--   step5 clean   仍然活着的话，删掉探针档并复查（顺手把以前遗留的探针档也清掉）
--
-- 判定取值：
--   fe-gamesave-written / fe-gamesave-write-failed / fe-gamesave-no-complete
--   fe-gamesave-listed / fe-gamesave-not-listed
--   fe-gamesave-load-issued / fe-gamesave-load-call-failed
--   fe-gamesave-deleted / fe-gamesave-delete-failed
--
-- 【实现约定】本文件不自带 UI、也不自己 SetRefreshHandler —— 由 UI/Replacements/
-- Civ6Common.lua 里那条已经存在的刷新回调每帧驱动（与另一个前端探针同一套做法），
-- 否则会把幽灵 hook 的回调顶掉。
-- ===========================================================================

local MODMISC_FE_GAMESAVE_BUILD_TAG = "2026-10-05-A"

-- 探针档名前缀：认这个前缀的档才会被清理（别误删玩家自己的档）
local FE_GS_PROBE_PREFIX = "MMTGameSaveProbe"

-- 各阶段等待帧数（60 帧 ≈ 1 秒）
local FE_GS_WAIT_READY_FRAMES = 900      -- 等配置就绪（最多 ~15 秒）
local FE_GS_WAIT_SAVE_FRAMES = 600       -- 等 SaveComplete（最多 ~10 秒）
local FE_GS_WAIT_QUERY_FRAMES = 300      -- 等存档列表回包（最多 ~5 秒）
local FE_GS_WAIT_AFTER_LOAD_FRAMES = 300 -- 发出读档后观察多久（还活着就继续清理）

local function Log(message)
    print("[ModMiscTool][FeGameSaveProbe] " .. message)
end

-- ===========================================================================
-- 界面识别 / 就绪判断
-- ===========================================================================

local function ProbeContextKind()
    if Controls == nil then return nil end
    -- 共用 Civ6Common 里那份识别（三个界面各有一个只属于自己的控件），没有就用本地兜底
    if ModMiscToolFrontEndContextKind ~= nil then
        local ok, kind = pcall(ModMiscToolFrontEndContextKind)
        if ok and kind ~= nil then return kind end
    end
    if Controls.ScenarioDescription ~= nil then return "ScenarioSetup" end
    if Controls.SaveConfig ~= nil then return "AdvancedSetup" end
    if Controls.MainMenuOptionStack ~= nil then return "MainMenu" end
    return nil
end

local function SaveGameTypeReady()
    if Network == nil or Network.GetGameConfigurationSaveType == nil then return false end
    local ok, value = pcall(function() return Network.GetGameConfigurationSaveType() end)
    return ok and value ~= nil
end

local function TryCall(getter)
    if type(getter) ~= "function" then return nil, "not-a-function" end
    local ok, value = pcall(getter)
    if not ok then return nil, tostring(value) end
    return value
end

-- ===========================================================================
-- 状态
-- ===========================================================================

local m_RunIndex = 0
local m_ContextKind = nil
local m_ContextInstance = nil
local m_LastHidden = true
local m_Step = nil
local m_Frames = 0
local m_ProbeName = nil          -- 本轮要写的档名（不带扩展名）
local m_SaveIssued = false
local m_SaveComplete = false
local m_QueryRequestId = nil
local m_QueryRows = nil
local m_QueryMode = nil          -- "verify" / "cleanup" / "recheck"
local m_LoadIssued = false
local m_FramesAfterLoad = 0
local m_IssuedAt = 0

local function Stamp()
    local ok, text = pcall(function() return os.date("%Y%m%d-%H%M%S") end)
    if ok and text ~= nil then return tostring(text) end
    return tostring(TryCall(function() return os.time() end) or 0)
end

local function IsProbeName(name)
    if name == nil then return false end
    return tostring(name):sub(1, #FE_GS_PROBE_PREFIX) == FE_GS_PROBE_PREFIX
end

-- ===========================================================================
-- 查询存档列表（严格对号请求号；列表里的 Name 带扩展名）
-- ===========================================================================

local function OnFileListResults(fileList, requestId)
    if m_QueryRequestId == nil or requestId ~= m_QueryRequestId then return end
    m_QueryRequestId = nil
    if LuaEvents ~= nil and LuaEvents.FileListQueryResults ~= nil then
        LuaEvents.FileListQueryResults.Remove(OnFileListResults)
    end
    m_QueryRows = type(fileList) == "table" and fileList or {}
    Log("列表回包" .. tostring(#m_QueryRows) .. " 条（mode=" .. tostring(m_QueryMode) .. "）")
end

local function StartQuery(mode)
    if UI == nil or UI.QuerySaveGameList == nil or LuaEvents == nil
        or LuaEvents.FileListQueryResults == nil or SaveLocationOptions == nil then
        Log("查询不可用（UI.QuerySaveGameList / LuaEvents.FileListQueryResults / SaveLocationOptions 缺失）")
        return false
    end
    m_QueryMode = mode
    m_QueryRows = nil
    local options = SaveLocationOptions.NORMAL + SaveLocationOptions.QUICKSAVE
        + SaveLocationOptions.LOAD_METADATA
    LuaEvents.FileListQueryResults.Add(OnFileListResults)
    m_QueryRequestId = UI.QuerySaveGameList(SaveLocations.LOCAL_STORAGE, SaveTypes.SINGLE_PLAYER,
        options, SaveFileTypes.GAME_STATE, nil)
    Log("已发出普通存档列表查询（mode=" .. tostring(mode) .. "，请求号 " .. tostring(m_QueryRequestId) .. "）")
    return true
end

local function StripExtension(name)
    if name == nil then return nil end
    local text = tostring(name)
    text = text:gsub("%.Civ6Save$", ""):gsub("%.Civ6Cfg$", "")
    return text
end

-- 把一条列表记录里的**所有**字段打出来 —— “不用载入能读到什么”就是这一步的答案
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

local function FindEntry(rows, wantedName)
    for _, entry in ipairs(rows) do
        if entry ~= nil and StripExtension(entry.Name) == wantedName then return entry end
    end
    return nil
end

-- ===========================================================================
-- 各步骤
-- ===========================================================================

local function StepRecon()
    Log("step0 recon: kind=" .. tostring(m_ContextKind)
        .. " context=" .. tostring(ContextPtr))
    Log("  api: SaveGame=" .. tostring(Network ~= nil and Network.SaveGame ~= nil)
        .. " LoadGame=" .. tostring(Network ~= nil and Network.LoadGame ~= nil)
        .. " QuerySaveGameList=" .. tostring(UI ~= nil and UI.QuerySaveGameList ~= nil)
        .. " DeleteSavedGame=" .. tostring(UI ~= nil and UI.DeleteSavedGame ~= nil)
        .. " WriteCustomData=" .. tostring(WriteCustomData ~= nil)
        .. " SaveTypes=" .. tostring(SaveTypes ~= nil and SaveTypes.SINGLE_PLAYER ~= nil)
        .. " SaveFileTypes.GAME_STATE=" .. tostring(SaveFileTypes ~= nil and SaveFileTypes.GAME_STATE ~= nil))
    local gameState, stateErr = TryCall(function() return GameConfiguration.GetGameState() end)
    Log("  gameState=" .. tostring(gameState) .. "（" .. tostring(stateErr or "ok")
        .. "）｜ IsInFrontEnd=" .. tostring(TryCall(function() return UI.IsInFrontEnd() end)))
end

local function StepWrite()
    if Network == nil or Network.SaveGame == nil then
        Log("VERDICT=fe-gamesave-write-failed：Network.SaveGame 不可用")
        m_Step = "done"
        return
    end
    if SaveTypes == nil or SaveFileTypes == nil or SaveLocations == nil then
        Log("VERDICT=fe-gamesave-write-failed：SaveTypes / SaveFileTypes / SaveLocations 缺失")
        m_Step = "done"
        return
    end

    m_ProbeName = FE_GS_PROBE_PREFIX .. "~" .. Stamp()
    local saveFile = {
        Name = m_ProbeName,
        Location = SaveLocations.LOCAL_STORAGE,
        Type = SaveTypes.SINGLE_PLAYER,
        FileType = SaveFileTypes.GAME_STATE,
        IsAutosave = false,
        IsQuicksave = false,
    }
    if SaveDirectories ~= nil then saveFile.Directory = SaveDirectories.DEFAULT end

    -- 档案里放一段可识别的标记：万一这份“空壳档”真能被读进来，进对局后能靠它认出来
    if WriteCustomData ~= nil then
        local ok = pcall(WriteCustomData, "ModMiscToolFeGameSaveProbe",
            "name=" .. tostring(m_ProbeName) .. ";t=" .. tostring(os.time()))
        Log("  已在 CustomData 写入探针标记（结果=" .. tostring(ok) .. "）")
    end

    Log("step1 write: 即将调用 Network.SaveGame（前端、无对局）name=" .. tostring(m_ProbeName)
        .. " Type=SINGLE_PLAYER FileType=GAME_STATE")
    local ok, err = pcall(Network.SaveGame, saveFile)
    m_SaveIssued = true
    m_IssuedAt = TryCall(function() return os.time() end) or 0
    if not ok then
        Log("VERDICT=fe-gamesave-write-failed：调用抛错 -> " .. tostring(err))
        m_Step = "done"
        return
    end
    Log("  Network.SaveGame 调用已返回（没卡死），等 Events.SaveComplete / 或超时")
    m_Step = "wait-save"
    m_Frames = 0
end

local function StepVerifyList()
    if StartQuery("verify") then
        m_Step = "wait-query"
        m_Frames = 0
    else
        m_Step = "load-attempt"
    end
end

local function ReportVerify()
    local entry = FindEntry(m_QueryRows or {}, m_ProbeName)
    if entry == nil then
        Log("VERDICT=fe-gamesave-not-listed：普通存档列表里没有 " .. tostring(m_ProbeName)
            .. "（列表 " .. tostring(#(m_QueryRows or {})) .. " 条）")
        for _, row in ipairs(m_QueryRows or {}) do
            Log("    列表项：" .. DescribeEntry(row))
        end
    else
        Log("VERDICT=fe-gamesave-listed：列表里找到了 " .. tostring(m_ProbeName))
        Log("    这条档能读到的字段：" .. DescribeEntry(entry))
    end
end

local function StepLoadAttempt()
    if m_LoadIssued then
        m_Step = "after-load"
        m_FramesAfterLoad = 0
        return
    end
    local entry = FindEntry(m_QueryRows or {}, m_ProbeName)
    if entry == nil then
        Log("step4 load: 列表里没有这条档，跳过读档尝试")
        m_Step = "cleanup"
        return
    end
    if Network == nil or Network.LoadGame == nil or ServerType == nil then
        Log("VERDICT=fe-gamesave-load-call-failed：Network.LoadGame / ServerType 不可用")
        m_Step = "cleanup"
        return
    end

    m_LoadIssued = true
    Log("step4 load: 即将在前端调用 Network.LoadGame（这份档没有游戏数据，很可能失败/无反应）name="
        .. tostring(m_ProbeName))
    local ok, err = pcall(Network.LoadGame, entry, ServerType.SERVER_TYPE_NONE)
    if not ok then
        Log("VERDICT=fe-gamesave-load-call-failed：调用抛错 -> " .. tostring(err))
        m_Step = "cleanup"
        return
    end
    Log("VERDICT=fe-gamesave-load-issued：调用已返回（没卡死）。"
        .. "接下来看有没有 LoadScreen / 进对局日志；还停在前端就继续清理")
    m_Step = "after-load"
    m_FramesAfterLoad = 0
end

local function StepCleanup()
    if StartQuery("cleanup") then
        m_Step = "wait-cleanup-query"
        m_Frames = 0
    else
        m_Step = "done"
    end
end

local function DoCleanup(rows)
    local removed, failed = 0, 0
    -- 清掉本轮这份 + 以前遗留的探针档（只认前缀，绝不碰玩家自己的档）
    for _, entry in ipairs(rows or {}) do
        if entry ~= nil and IsProbeName(StripExtension(entry.Name)) then
            if UI ~= nil and UI.DeleteSavedGame ~= nil then
                local ok, err = pcall(UI.DeleteSavedGame, entry)
                if ok then
                    removed = removed + 1
                    Log("  已删除探针档 " .. tostring(entry.Name))
                else
                    failed = failed + 1
                    Log("  删除失败 " .. tostring(entry.Name) .. " -> " .. tostring(err))
                end
            end
        end
    end
    if removed == 0 and failed == 0 then
        Log("VERDICT=fe-gamesave-delete-failed：列表里没有可删的探针档（可能本来就没写成功）")
    elseif failed == 0 then
        Log("VERDICT=fe-gamesave-deleted：清掉 " .. tostring(removed) .. " 个探针档")
    else
        Log("VERDICT=fe-gamesave-delete-failed：删成功 " .. tostring(removed)
            .. "，失败 " .. tostring(failed))
    end
    m_Step = "done"
end

-- ===========================================================================
-- 对外唯一入口：由 Civ6Common replacement 的刷新回调每帧调用
-- ===========================================================================

function ModMiscFrontEndGameSaveProbeRefresh()
    local contextKind = ProbeContextKind()
    if contextKind == nil then return end

    -- 上下文实例变了 = 前端被重建 → 当作新的一轮（与另一个探针同一套判据）
    local contextInstance = tostring(ContextPtr)
    if m_ContextInstance ~= contextInstance then
        m_ContextInstance = contextInstance
        m_LastHidden = true
    end

    local hidden = ContextPtr:IsHidden()
    if m_LastHidden and not hidden then
        m_RunIndex = m_RunIndex + 1
        m_ContextKind = contextKind
        m_Step = "wait-ready"
        m_Frames = 0
        m_SaveIssued = false
        m_SaveComplete = false
        m_LoadIssued = false
        m_ProbeName = nil
        Log("===== 第 " .. tostring(m_RunIndex) .. " 轮（kind=" .. tostring(contextKind)
            .. "）build=" .. tostring(MODMISC_FE_GAMESAVE_BUILD_TAG) .. " =====")
    end
    m_LastHidden = hidden
    if hidden or m_Step == nil then return end

    m_Frames = m_Frames + 1

    if m_Step == "wait-ready" then
        if not SaveGameTypeReady() and m_Frames < FE_GS_WAIT_READY_FRAMES then return end
        StepRecon()
        m_Step = "write"
        m_Frames = 0
        return
    end

    if m_Step == "write" then
        StepWrite()
        return
    end

    if m_Step == "wait-save" then
        if not m_SaveComplete and m_Frames < FE_GS_WAIT_SAVE_FRAMES then return end
        if m_SaveComplete then
            Log("VERDICT=fe-gamesave-written：收到 SaveComplete（等 " .. tostring(m_Frames) .. " 帧）")
        else
            Log("VERDICT=fe-gamesave-no-complete：等 " .. tostring(m_Frames)
                .. " 帧没等到 SaveComplete，仍然去列表里查一次")
        end
        StepVerifyList()
        return
    end

    if m_Step == "wait-query" then
        if m_QueryRows == nil and m_Frames < FE_GS_WAIT_QUERY_FRAMES then return end
        if m_QueryRows == nil then
            Log("列表查询没回包（等 " .. tostring(m_Frames) .. " 帧），按空列表处理")
            m_QueryRows = {}
        end
        ReportVerify()
        m_Step = "load-attempt"
        return
    end

    if m_Step == "load-attempt" then
        StepLoadAttempt()
        return
    end

    if m_Step == "after-load" then
        -- 还活着 = 读档没把我们带走；等一会儿再清理，避免刚好在加载中途删档
        if m_FramesAfterLoad < FE_GS_WAIT_AFTER_LOAD_FRAMES then
            m_FramesAfterLoad = m_FramesAfterLoad + 1
            return
        end
        Log("读档调用之后仍停在前端（观察 " .. tostring(m_FramesAfterLoad) .. " 帧）")
        m_Step = "cleanup"
        return
    end

    if m_Step == "cleanup" then
        StepCleanup()
        return
    end

    if m_Step == "wait-cleanup-query" then
        if m_QueryRows == nil and m_Frames < FE_GS_WAIT_QUERY_FRAMES then return end
        DoCleanup(m_QueryRows or {})
        return
    end
    -- "done"：本轮结束，等下一次进入界面
end

-- 存档回执（异步，不受刷新回调是否还在影响）
if Events ~= nil and Events.SaveComplete ~= nil then
    Events.SaveComplete.Add(function(...)
        if m_SaveIssued then
            m_SaveComplete = true
            local first = ...
            Log("SaveComplete 回执：" .. tostring(first))
        end
    end)
end
