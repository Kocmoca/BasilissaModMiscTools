-- ===========================================================================
-- Mod Misc Tool: 前端存档·读档探针（主界面 / 创建游戏 / 创建场景）
--
-- 背景：对局内的 Network.LoadGame 会**显式**读档（LoadScreen 出现、整局重载）；
--       授权者要求换方向 —— 把存档/读档挪到前端，并且**在主界面就强制读取**配置档，
--       没有就创建一个。（安卓上「高级选项」页面会横向溢出，所以验证不能依赖那个界面。）
--
-- 覆盖三个前端上下文，判据用各自独有的控件（任一命中即跑）：
--   MainMenu        Controls.MainMenuOptionStack   —— 启动即可用，不需要任何导航
--   AdvancedSetup   Controls.SaveConfig
--   ScenarioSetup   Controls.ScenarioDescription
--
-- 本文件不自带 UI，只打日志；由 UI/Replacements/Civ6Common.lua 里那条**已经存在**的
-- 刷新回调驱动 —— 不能自己再 SetRefreshHandler，否则会把幽灵那边的回调顶掉。
-- （异步部分走引擎事件，所以即使刷新回调中途被别的界面顶掉，流程也能走完。）
--
-- 一次「进入该界面」= 一次完整实验，日志前缀 [ModMiscTool][FrontEndProbe]：
--
--   step0 recon   自述：kind / contextID / SaveGame·LoadGame 是否可用 / 配置档类型
--   step1 write   写 CustomData（**沿用对局内探针的 key**，这样进对局后，
--                 对局内启动探针会把这份 payload 原样打在自己的 VERDICT 行里 —— 即
--                 “前端写的数据有没有进对局”的直接证据，对局内一行代码都不用改）
--   step2 query   UI.QuerySaveGameList 查配置档在不在（结果由 LuaEvents.FileListQueryResults
--                 回传，会把列表里的档名一起打出来；查询不可用/超时则按“不存在”处理）
--   step3 分支
--       在 → Network.LoadGame(这个档)      ← 本次要问的核心问题：前端能不能强制读配置档
--       不在 → Network.SaveGame(新建这个档) ← 没有就创建
--   step4 verify  仅创建路径：Events.SaveComplete 之后**再查一次列表**确认真的落盘
--                 （UI.GetLastSaveName() 在配置档这条路上实测是空串，当不了证据）
--
-- 【实机踩到的坑】存档列表里的 Name **带扩展名**（配置档是 "xxx.Civ6Cfg"），
-- 直接跟不带扩展名的目标比会永远判“不在” —— 比对前必须先 NormalizeSaveName 去扩展名。
--
-- 【另一个坑：种子】配置档连**地图/游戏种子**一起存。游戏自己走菜单读档时，
-- LoadGameMenu.OnLoadComplete 会 SetToPreGame + RegenerateSeeds + 清领袖选择
-- （源码注释：so that configs are more usable），但那段被 `if ContextPtr:IsVisible()`
-- 挡着；我们绕过菜单直接 Network.LoadGame 就吃不到这层收尾 → 种子被配置档锁死，
-- 表现是“同一领袖 + 不改设置 → 每次开局都是同一张图”。
-- 本文件因此自己挂 Events.LoadComplete 补跑这套收尾。
--
-- 判定写在日志的 VERDICT= 里：
--   fe-load-requested  读档请求已发出（是否被顶掉、是否显式，看后续日志）
--   fe-load-fail       读档调用失败
--   fe-save-ok-confirmed   创建成功，且复查列表里确实出现了这个档
--   fe-save-unconfirmed    收到了 SaveComplete，但列表里没有（未落盘）
--   fe-save-fail           创建失败/超时（含 Network.SaveGame 为 nil）
--
-- 【实机判读要点】对局内用 FileType=GAME_CONFIGURATION 调 Network.LoadGame，
-- 即使档不存在也是**静默无操作**（不报错、不返回 false、不打断当前局）——
-- 已实测两次。所以“有没有报错”不能当判据，只能看有没有真的重载：
--   LoadScreen: true / gameplay scripts loading / 探针再打一行 —— 三样都没有就是没读进去。
-- ===========================================================================

local MODMISC_FE_PROBE_BUILD_TAG = "2026-10-04-E"

-- 与对局内探针（UI/Support_UI.lua 的 CROSS_SAVE_PROBE_KEY）共用同一个 key：
-- 前端写进去的这份 payload，会被对局内启动探针原样读出来打印。
local FE_PROBE_KEY = "ModMiscToolCrossSaveProbe"

-- 前端产出的“特殊存档”：游戏自己的“保存配置”走的就是 GAME_CONFIGURATION 档
local FE_CONFIG_SAVE_NAME = "ModMiscFrontEndProbe"

-- 存档完成最多等多少帧（60 帧≈1 秒，按 10 秒算）
local FE_SAVE_TIMEOUT_FRAMES = 600
-- 等“开始游戏”按钮可点的上限（30 秒）：超时就按现状继续，免得永远等不到日志
local FE_READY_TIMEOUT_FRAMES = 1800
-- 等存档列表查询回音的上限（5 秒）：超时按“不存在”处理
local FE_QUERY_TIMEOUT_FRAMES = 300

local m_Step = nil              -- nil = 本轮还没开跑
local m_ContextKind = nil       -- MainMenu / AdvancedSetup / ScenarioSetup
local m_ContextInstance = nil   -- tostring(ContextPtr)：用来识别“上下文被重建了”
local m_RunIndex = 0            -- 本次进程里第几次进入界面
local m_LastHidden = true       -- 用来识别“隐藏 → 显示”这一刻
local m_LoggedWait = false
local m_SaveComplete = false
local m_WaitFrames = 0
local m_ConfigFile = nil

local m_QueryIssued = false
local m_QueryPending = false
local m_QueryResolved = false
local m_QueryFound = false
local m_QueryRequestId = nil
local m_BranchTaken = false
local m_QueryMode = nil

-- 【前置声明】下面的事件回调（查询回音 / SaveComplete）要在 step 函数定义之前
-- 引用它们。Lua 5.1 里不前置声明的话，函数体里的 StepLoad/StepSave 会被解析成
-- 全局变量，运行时是 nil（"attempt to call a nil value"）。
local StepLoad, StepSave

local function Log(message)
    print("[ModMiscTool][FrontEndProbe] " .. message)
end

-- ===========================================================================
-- 上下文判据：三个界面各有一个只属于自己的控件
-- ===========================================================================

local function ModMiscFrontEndProbeContextKind()
    if Controls == nil then return nil end
    if Controls.ScenarioDescription ~= nil then return "ScenarioSetup" end
    if Controls.SaveConfig ~= nil then return "AdvancedSetup" end
    if Controls.MainMenuOptionStack ~= nil then return "MainMenu" end
    return nil
end

-- 配置档类型拿得到 = 游戏配置已经载入。主界面一开机就显示，比创建界面早得多，
-- 只用 StartButton 判会太早（那时 Network/GameConfiguration 还没就绪）
local function ModMiscFrontEndProbeConfigReady()
    if Network == nil or Network.GetGameConfigurationSaveType == nil then return false end
    local ok, value = pcall(function() return Network.GetGameConfigurationSaveType() end)
    return ok and value ~= nil
end

-- 配置没载入完就存档会产出退化档，所以等就绪再动手：
--   ① 配置档类型拿得到（三个界面通用）
--   ② 创建界面额外要求“开始游戏”按钮可点（主界面没有这个控件，跳过）
local function ModMiscFrontEndProbeSetupReady()
    if not ModMiscFrontEndProbeConfigReady() then return false end
    if Controls == nil or Controls.StartButton == nil then return true end
    if Controls.StartButton.IsDisabled == nil then return true end
    local ok, disabled = pcall(function() return Controls.StartButton:IsDisabled() end)
    if not ok then return true end
    return not disabled
end

-- ===========================================================================
-- CustomData 读写（前端可写已在幽灵功能上验证过，这里仍全部 pcall 兜底）
-- ===========================================================================

local function ReadProbe()
    if ReadCustomData == nil then return nil end
    local ok, value = pcall(ReadCustomData, FE_PROBE_KEY)
    if not ok then return nil end
    if value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

local function WriteProbe(payload)
    if WriteCustomData == nil then return false, "WriteCustomData is nil" end
    local ok, err = pcall(WriteCustomData, FE_PROBE_KEY, payload)
    if not ok then return false, tostring(err) end
    return true
end

-- ===========================================================================
-- 存档表：照抄游戏自己的“保存配置”路径
--   AdvancedSetup.OnSaveConfig → SaveGameMenu(g_FileType=GAME_CONFIGURATION) →
--   Network.SaveGame{Name, Location, Type=g_GameType, FileType}
-- 其中 g_GameType 来自 Network.GetGameConfigurationSaveType()
-- ===========================================================================

local function GetConfigSaveType()
    if Network ~= nil and Network.GetGameConfigurationSaveType ~= nil then
        local ok, value = pcall(function() return Network.GetGameConfigurationSaveType() end)
        if ok and value ~= nil then return value end
    end
    if SaveTypes ~= nil then return SaveTypes.SINGLE_PLAYER end
    return nil
end

local function BuildConfigFile()
    if SaveLocations == nil or SaveFileTypes == nil then return nil end
    local saveType = GetConfigSaveType()
    if saveType == nil then return nil end
    local configFile = {
        Name = FE_CONFIG_SAVE_NAME,
        Location = SaveLocations.LOCAL_STORAGE,
        Type = saveType,
        FileType = SaveFileTypes.GAME_CONFIGURATION,
    }
    if SaveDirectories ~= nil then
        configFile.Directory = SaveDirectories.DEFAULT
    end
    return configFile
end

-- ===========================================================================
-- 存档列表查询：发一次、结果走 LuaEvents 回传
--   mode = "existence" 开跑时查在不在；"recheck" 创建完成后复查是否真落盘
-- 前置声明 OnConfigQueryResults：助手要先注册它，而它定义在后面（Lua 5.1 前向引用坑）
-- ===========================================================================
local OnConfigQueryResults

local function IssueConfigQuery(mode)
    if UI == nil or UI.QuerySaveGameList == nil or LuaEvents == nil
        or LuaEvents.FileListQueryResults == nil or SaveLocationOptions == nil then
        Log("query 不可用（QuerySaveGameList/SaveLocationOptions 缺失）")
        return false
    end
    local queryFile = BuildConfigFile()
    if queryFile == nil then
        Log("query 建不了存档表")
        return false
    end

    local options = SaveLocationOptions.NORMAL + SaveLocationOptions.QUICKSAVE
        + SaveLocationOptions.LOAD_METADATA
    m_QueryMode = mode
    m_QueryPending = true
    m_QueryResolved = false
    m_WaitFrames = 0
    LuaEvents.FileListQueryResults.Add(OnConfigQueryResults)
    m_QueryRequestId = UI.QuerySaveGameList(queryFile.Location, queryFile.Type,
        options, queryFile.FileType, nil)
    Log("query 已发出(" .. tostring(mode) .. "): 找[" .. FE_CONFIG_SAVE_NAME .. "]")
    return true
end

-- ===========================================================================
-- 配置档读入后的收尾：必须照抄游戏自己的做法
--
-- 游戏走菜单读配置档时，LoadGameMenu.OnLoadComplete（源码注释：Reset the seeds and
-- leader selection when loading a config so that configs are more usable）会做三件事：
--     ① GameConfiguration.SetToPreGame()
--     ② GameConfiguration.RegenerateSeeds()
--     ③ 清掉每个玩家的领袖/文明选择
-- 而那段代码外面套着 `if ContextPtr:IsVisible()`（菜单可见才做）。
-- 我们是**绕过菜单**直接 Network.LoadGame 的 → 菜单不可见 → 收尾不跑 →
-- 配置档里的种子原样留在 GameConfiguration 里 → 之后每次开局都是同一张图。
-- 这一条是授权者实机观察（“同一领袖 + 不改设置 → 地图总是不变”）对着源码找出来的。
-- ===========================================================================

local function OnConfigLoadComplete(eResult, eType, eOptions, eFileType)
    if SaveFileTypes == nil or eFileType ~= SaveFileTypes.GAME_CONFIGURATION then return end
    Log("LoadComplete: 配置档读完(result=" .. tostring(eResult) .. ") → 补跑游戏菜单里的收尾")

    if GameConfiguration == nil then
        Log("收尾跳过：GameConfiguration 为 nil")
        return
    end

    if GameConfiguration.SetToPreGame ~= nil then
        pcall(function() GameConfiguration.SetToPreGame() end)
    end

    if GameConfiguration.RegenerateSeeds ~= nil then
        pcall(function() GameConfiguration.RegenerateSeeds() end)
        Log("已 RegenerateSeeds()：下次开局的 Map Seed 应当是新的"
            .. "（对照游戏启动那行 GenerateRandomMap: Map Seed = ...）")
    else
        Log("RegenerateSeeds 不可用 → 地图种子仍会被配置档锁住")
    end

    if GameConfiguration.GetParticipatingPlayerIDs == nil or PlayerConfigurations == nil then return end
    local ok, playerIDs = pcall(function() return GameConfiguration.GetParticipatingPlayerIDs() end)
    if not ok or playerIDs == nil then return end
    for _, playerID in ipairs(playerIDs) do
        local playerConfig = PlayerConfigurations[playerID]
        if playerConfig ~= nil then
            pcall(function()
                playerConfig:SetLeaderTypeName(nil)
                playerConfig:SetCivilizationTypeName(nil)
            end)
        end
    end
    Log("已清掉玩家领袖/文明选择（与游戏菜单一致：配置档当模板用）")
end

-- 只在第一次 include 时挂一次（前端上下文重建时会再 include，别重复挂）
if Events ~= nil and Events.LoadComplete ~= nil
    and ModMiscFrontEndProbeLoadHookInstalled == nil then
    ModMiscFrontEndProbeLoadHookInstalled = true
    Events.LoadComplete.Add(OnConfigLoadComplete)
end

-- ===========================================================================
-- 各 step：每个 step 跑完就把 m_Step 推到下一个（字典分派，避免 if/else 长链）
-- ===========================================================================

-- SaveComplete 是引擎事件，不依赖刷新回调 —— 刷新回调万一被别的界面顶掉，
-- 判据也照样能打出来，所以收尾放在这里而不是放在 StepVerify 里
local function OnSaveComplete()
    m_SaveComplete = true
    if m_Step ~= "verify" then return end

    -- UI.GetLastSaveName() 在配置档这条路上实测是空串，不能当“落盘”的证据 ——
    -- 所以保存完再查一次列表，以“列表里真的出现了这个档”为准
    Log("step4 verify SaveComplete（引擎已接受创建请求）; 复查列表确认落盘")
    if not IssueConfigQuery("recheck") then
        Log("step4 recheck 发不出去; VERDICT=fe-save-ok（未复查）")
        m_Step = "done"
    end
end

-- 存档列表里的 Name **带扩展名**（实机实测配置档是 "ModMiscFrontEndProbe.Civ6Cfg"），
-- 直接拿它跟不带扩展名的目标比会永远判“不在”——这一步是实机撞出来的坑。
local function NormalizeSaveName(name)
    if name == nil then return nil end
    local text = tostring(name)
    local stripped = text:match("^(.*)%.[^%.]+$")
    if stripped ~= nil and stripped ~= "" then return stripped end
    return text
end

-- 查询回调：引擎通过 LuaEvents 回传 (fileList, 请求号)
OnConfigQueryResults = function(fileList, requestId)
    if not m_QueryPending then return end
    if requestId ~= nil and m_QueryRequestId ~= nil and requestId ~= m_QueryRequestId then
        return
    end
    m_QueryPending = false
    m_QueryResolved = true

    local names = {}
    local found = false
    local matchedName = nil
    if fileList ~= nil then
        for _, entry in ipairs(fileList) do
            if entry ~= nil and entry.Name ~= nil then
                local entryName = tostring(entry.Name)
                table.insert(names, entryName)
                if NormalizeSaveName(entryName) == FE_CONFIG_SAVE_NAME then
                    found = true
                    matchedName = entryName
                end
            end
        end
    end
    m_QueryFound = found

    local listing = "(空)"
    if #names > 0 then listing = table.concat(names, ",") end
    Log("query 回结果(" .. tostring(m_QueryMode) .. "): 档[" .. FE_CONFIG_SAVE_NAME .. "]="
        .. (found and "在" or "不在") .. "; 列表=[" .. listing .. "]"
        .. (matchedName ~= nil and ("; 命中=" .. matchedName) or ""))

    if m_QueryMode == "recheck" then
        if found then
            Log("step4 recheck 通过: 档已在列表里 [" .. tostring(matchedName)
                .. "]; VERDICT=fe-save-ok-confirmed")
        else
            Log("step4 recheck 未通过: 收到了 SaveComplete，但列表里没有这个档;"
                .. " VERDICT=fe-save-unconfirmed")
        end
        m_Step = "done"
        return
    end

    -- 分支也放在事件里：不依赖刷新回调还活着
    m_BranchTaken = true
    if found then
        Log("step3 分支：档已存在 → 强制读取")
        StepLoad()
    else
        Log("step3 分支：档不存在 → 创建")
        StepSave()
    end
end

local function StepRecon()
    local contextID = "?"
    if ContextPtr ~= nil and ContextPtr.GetID ~= nil then
        local ok, id = pcall(function() return ContextPtr:GetID() end)
        if ok and id ~= nil then contextID = tostring(id) end
    end

    local hasSaveGame = (Network ~= nil and Network.SaveGame ~= nil) and "y" or "n"
    local hasLoadGame = (Network ~= nil and Network.LoadGame ~= nil) and "y" or "n"
    local hasSaveComplete = (Events ~= nil and Events.SaveComplete ~= nil) and "y" or "n"

    Log("step0 recon run=" .. tostring(m_RunIndex)
        .. " kind=" .. tostring(m_ContextKind)
        .. " contextID=" .. contextID
        .. " SaveGame=" .. hasSaveGame
        .. " LoadGame=" .. hasLoadGame
        .. " SaveComplete=" .. hasSaveComplete
        .. " configSaveType=" .. tostring(GetConfigSaveType())
        .. " build=" .. MODMISC_FE_PROBE_BUILD_TAG)
    m_Step = "write"
end

local function StepWrite()
    local previous = ReadProbe()
    local payload = "fe=1;run=" .. tostring(m_RunIndex)
        .. ";ctx=" .. tostring(m_ContextKind)
        .. ";t=" .. tostring(os.time())
        .. ";r=" .. tostring(math.random(100000, 999999))
        .. ";prev=" .. tostring(previous)

    local ok, err = WriteProbe(payload)
    if not ok then
        Log("step1 write FAILED -> " .. tostring(err))
        m_Step = "done"
        return
    end

    Log("step1 write ok; payload=[" .. payload
        .. "] readBack=[" .. tostring(ReadProbe()) .. "]")
    m_Step = "query"
end

local function StepQuery()
    if not m_QueryIssued then
        m_QueryIssued = true
        if not IssueConfigQuery("existence") then
            -- 查不了就按“不存在”处理，直接走创建（授权者要求：没有就创建）
            m_QueryResolved = true
            m_QueryFound = false
            m_BranchTaken = true
            Log("step2 query 不可用 → 按“不存在”处理，直接创建")
            StepSave()
            return
        end
    end

    if m_BranchTaken then return end

    if not m_QueryResolved then
        m_WaitFrames = m_WaitFrames + 1
        if m_WaitFrames < FE_QUERY_TIMEOUT_FRAMES then return end
        m_QueryPending = false
        Log("query 超时（" .. tostring(FE_QUERY_TIMEOUT_FRAMES)
            .. " 帧没等到 LuaEvents.FileListQueryResults）→ 按“不存在”处理")
        m_QueryResolved = true
        m_QueryFound = false
    end

    if UI ~= nil and UI.CloseFileListQuery ~= nil and m_QueryRequestId ~= nil then
        pcall(function() UI.CloseFileListQuery(m_QueryRequestId) end)
        m_QueryRequestId = nil
    end

    -- 正常路径已由 OnConfigQueryResults 分支；这里只兜“查询根本没回音”的那种
    m_BranchTaken = true
    Log("step3 分支：档不存在 → 创建（查询无回音兜底）")
    StepSave()
end

StepLoad = function()
    if Network == nil or Network.LoadGame == nil then
        Log("step3 load FAILED -> Network.LoadGame is nil; VERDICT=fe-load-fail")
        m_Step = "done"
        return
    end

    m_ConfigFile = BuildConfigFile()
    if m_ConfigFile == nil then
        Log("step3 load FAILED -> 存档表构建不了; VERDICT=fe-load-fail")
        m_Step = "done"
        return
    end

    -- 与 LoadGameMenu.OnLoadYes 一致：GAME_CONFIGURATION **不** LeaveGame
    -- （游戏自己注释：配置档要保持当前状态），这里照抄，免得把前端会话踢掉
    local serverType = nil
    if ServerType ~= nil then serverType = ServerType.SERVER_TYPE_NONE end

    local ok, result = pcall(Network.LoadGame, m_ConfigFile, serverType)
    if not ok then
        Log("step3 load FAILED -> " .. tostring(result) .. "; VERDICT=fe-load-fail")
        m_Step = "done"
        return
    end

    Log("step3 load requested result=" .. tostring(result)
        .. "; VERDICT=fe-load-requested"
        .. "（若前端没被顶掉：下一次进入本界面的 step1，prev 就是这次写的 payload）")
    m_Step = "done"
end

StepSave = function()
    if Network == nil or Network.SaveGame == nil then
        Log("step3 save FAILED -> Network.SaveGame is nil; VERDICT=fe-save-fail")
        m_Step = "done"
        return
    end

    m_ConfigFile = BuildConfigFile()
    if m_ConfigFile == nil then
        Log("step3 save FAILED -> SaveLocations/SaveFileTypes/SaveTypes 缺失; VERDICT=fe-save-fail")
        m_Step = "done"
        return
    end

    m_SaveComplete = false
    m_WaitFrames = 0
    if Events ~= nil and Events.SaveComplete ~= nil then
        Events.SaveComplete.Remove(OnSaveComplete)
        Events.SaveComplete.Add(OnSaveComplete)
    end

    local ok, err = pcall(Network.SaveGame, m_ConfigFile)
    if not ok then
        Log("step3 save FAILED -> " .. tostring(err) .. "; VERDICT=fe-save-fail")
        m_Step = "done"
        return
    end

    Log("step3 save requested（创建配置档）: name=" .. FE_CONFIG_SAVE_NAME
        .. " type=" .. tostring(m_ConfigFile.Type)
        .. " fileType=GAME_CONFIGURATION")
    m_Step = "verify"
end

-- 只看门：收尾在 OnSaveComplete（事件驱动）里做
local function StepVerify()
    if m_SaveComplete then
        -- 已进入复查阶段：给复查也配个看门狗，免得“复查列表确认落盘”之后一片空白
        if m_QueryMode == "recheck" and not m_QueryResolved then
            m_WaitFrames = m_WaitFrames + 1
            if m_WaitFrames < FE_QUERY_TIMEOUT_FRAMES then return end
            Log("step4 recheck 超时（列表查询无回音）; VERDICT=fe-save-ok（未复查）")
            m_Step = "done"
        end
        return
    end
    m_WaitFrames = m_WaitFrames + 1
    if m_WaitFrames < FE_SAVE_TIMEOUT_FRAMES then return end
    Log("step4 verify TIMEOUT（" .. tostring(FE_SAVE_TIMEOUT_FRAMES)
        .. " 帧没等到 Events.SaveComplete）; VERDICT=fe-save-fail")
    m_Step = "done"
end

local m_Steps = {
    recon = StepRecon,
    write = StepWrite,
    query = StepQuery,
    load = StepLoad,
    save = StepSave,
    verify = StepVerify,
}

-- ===========================================================================
-- 对外唯一入口：由 Civ6Common replacement 的刷新回调每帧调用
-- 只认上面三个界面；其它前端界面（选项/大厅/存档菜单…）直接返回
-- ===========================================================================

function ModMiscFrontEndProbeRefresh()
    local contextKind = ModMiscFrontEndProbeContextKind()
    if contextKind == nil then return end

    -- 上下文实例变了 = 前端被重建（进对局会把前端上下文销毁重建）→ 当作新的一轮。
    -- 只靠“隐藏→显示”不够：进对局时上下文是被销毁的，最后一次 Refresh 时它还是可见的，
    -- m_LastHidden 停在 false，回来以后再也判不出新一轮 ——
    -- 实测表现就是“一个进程里只有第一次进前端会跑探针”。
    local contextInstance = tostring(ContextPtr)
    if m_ContextInstance ~= contextInstance then
        m_ContextInstance = contextInstance
        m_LastHidden = true
    end

    local hidden = ContextPtr:IsHidden()
    if m_LastHidden and not hidden then
        -- 新实例 / 隐藏 → 显示：新的一轮
        m_RunIndex = m_RunIndex + 1
        m_ContextKind = contextKind
        m_LoggedWait = false
        m_WaitFrames = 0
        m_QueryIssued = false
        m_QueryResolved = false
        m_QueryFound = false
        m_BranchTaken = false
        m_QueryMode = nil
        m_Step = "wait-ready"
    end
    m_LastHidden = hidden

    if hidden or m_Step == nil then return end

    -- 等配置就绪（配置档类型拿得到 + 创建界面的开始按钮可点）再动手；
    -- 超时也继续，保证一定有日志可看
    if m_Step == "wait-ready" then
        m_WaitFrames = m_WaitFrames + 1
        if not ModMiscFrontEndProbeSetupReady() then
            if not m_LoggedWait then
                m_LoggedWait = true
                Log("界面已打开 kind=" .. tostring(m_ContextKind)
                    .. "，但配置还没就绪（配置档类型取不到 / 开始按钮禁用）；等最多 "
                    .. tostring(FE_READY_TIMEOUT_FRAMES) .. " 帧")
            end
            if m_WaitFrames < FE_READY_TIMEOUT_FRAMES then return end
            Log("等待超时，按现状继续（产出的档可能不完整）")
        end
        m_WaitFrames = 0
        m_Step = "recon"
    end

    local step = m_Steps[m_Step]
    if step == nil then return end
    step()
end
