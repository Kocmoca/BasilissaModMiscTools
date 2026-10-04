-- ===========================================================================
-- Mod Misc Tool: 前端（ScenarioSetup / 创建场景）存档·读档探针
--
-- 背景：对局内的 Network.LoadGame 会**显式**读档（LoadScreen 出现、整局重载），
--       授权者要求换方向 —— 把存档/读档挪到前端来试，先在 ScenarioSetup 上做。
--
-- 这个文件只在前端“创建场景”上下文里干活（判据：Controls.ScenarioDescription），
-- 不自带 UI，只打日志；由 UI/Replacements/Civ6Common.lua 里那条**已经存在**的
-- 刷新回调驱动 —— 不能自己再 SetRefreshHandler，否则会把幽灵那边的回调顶掉。
--
-- 一次「打开创建场景界面」= 一次完整实验。打开界面即自动开跑，日志按 step 顺序打：
--
--   step0 recon   上下文自述：contextID / SaveGame·LoadGame 是否可用 / 配置档类型
--   step1 write   写 CustomData（**沿用对局内探针的 key**，这样读档进对局后，
--                 对局内启动探针会把这份 payload 原样打在自己的 VERDICT 行里 —— 即
--                 “前端写的数据有没有进对局”的直接证据，对局内一行代码都不用改）
--   step2 save    Network.SaveGame(FileType = SaveFileTypes.GAME_CONFIGURATION)
--                 —— 前端没有运行中的对局，这一枪能不能成、会不会产出“配置档”这种
--                 特殊存档类型，就是本探针要问的第一个问题
--   step3 verify  Events.SaveComplete + UI.GetLastSaveName() —— 文件是否真的落盘
--   step4 load    Network.LoadGame(同一个档) —— 前端能否读回来、是否显式、
--                 CustomData 是否跟着回来（读回来的证据看下一轮 step1 的 prev）
--
-- 判定写在日志的 VERDICT= 里：
--   fe-save-fail       前端存档失败/超时（含 Network.SaveGame 为 nil）
--   fe-save-ok         前端存档成功并收到 SaveComplete
--   fe-load-fail       前端读档调用失败
--   fe-load-requested  前端读档调用已发出（是否被顶掉、是否显式，看后续日志）
-- ===========================================================================

local MODMISC_FE_PROBE_BUILD_TAG = "2026-10-04-A"

-- 与对局内探针（UI/Support_UI.lua 的 CROSS_SAVE_PROBE_KEY）共用同一个 key：
-- 前端写进去的这份 payload，会被对局内启动探针原样读出来打印。
local FE_PROBE_KEY = "ModMiscToolCrossSaveProbe"

-- 前端产出的“特殊存档”：游戏自己的“保存配置”走的就是 GAME_CONFIGURATION 档
local FE_CONFIG_SAVE_NAME = "ModMiscScenarioProbe"

-- 存档完成最多等多少帧（60 帧≈1 秒，按 10 秒算）
local FE_SAVE_TIMEOUT_FRAMES = 600

local m_Step = nil              -- nil = 本轮还没开跑
local m_RunIndex = 0            -- 本次进程里第几次打开创建场景界面
local m_LastHidden = true       -- 用来识别“隐藏 → 显示”这一刻
local m_SaveComplete = false
local m_WaitFrames = 0
local m_ConfigFile = nil

local function Log(message)
    print("[ModMiscTool][ScenarioProbe] " .. message)
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
-- 各 step：每个 step 跑完就把 m_Step 推到下一个（字典分派，避免 if/else 长链）
-- ===========================================================================

local function OnSaveComplete()
    m_SaveComplete = true
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
    m_Step = "save"
end

local function StepSave()
    if Network == nil or Network.SaveGame == nil then
        Log("step2 save FAILED -> Network.SaveGame is nil; VERDICT=fe-save-fail")
        m_Step = "done"
        return
    end

    m_ConfigFile = BuildConfigFile()
    if m_ConfigFile == nil then
        Log("step2 save FAILED -> SaveLocations/SaveFileTypes/SaveTypes 缺失; VERDICT=fe-save-fail")
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
        Log("step2 save FAILED -> " .. tostring(err) .. "; VERDICT=fe-save-fail")
        m_Step = "done"
        return
    end

    Log("step2 save requested: name=" .. FE_CONFIG_SAVE_NAME
        .. " type=" .. tostring(m_ConfigFile.Type)
        .. " fileType=GAME_CONFIGURATION")
    m_Step = "verify"
end

local function StepVerify()
    m_WaitFrames = m_WaitFrames + 1
    if not m_SaveComplete then
        if m_WaitFrames < FE_SAVE_TIMEOUT_FRAMES then return end
        Log("step3 verify TIMEOUT（" .. tostring(FE_SAVE_TIMEOUT_FRAMES)
            .. " 帧没等到 Events.SaveComplete）; VERDICT=fe-save-fail")
        m_Step = "done"
        return
    end

    local lastName = "?"
    if UI ~= nil and UI.GetLastSaveName ~= nil then
        local ok, name = pcall(function() return UI.GetLastSaveName() end)
        if ok and name ~= nil then lastName = tostring(name) end
    end
    Log("step3 verify SaveComplete; UI.GetLastSaveName()=" .. lastName
        .. "; VERDICT=fe-save-ok")
    m_Step = "load"
end

local function StepLoad()
    if Network == nil or Network.LoadGame == nil then
        Log("step4 load FAILED -> Network.LoadGame is nil; VERDICT=fe-load-fail")
        m_Step = "done"
        return
    end

    -- 与 LoadGameMenu.OnLoadYes 一致：GAME_CONFIGURATION **不** LeaveGame
    -- （游戏自己注释：配置档要保持当前状态），这里照抄，免得把前端会话踢掉
    local serverType = nil
    if ServerType ~= nil then serverType = ServerType.SERVER_TYPE_NONE end

    local ok, result = pcall(Network.LoadGame, m_ConfigFile, serverType)
    if not ok then
        Log("step4 load FAILED -> " .. tostring(result) .. "; VERDICT=fe-load-fail")
        m_Step = "done"
        return
    end

    Log("step4 load requested result=" .. tostring(result)
        .. "; VERDICT=fe-load-requested"
        .. "（若前端没被顶掉：下一次打开本界面，step1 的 prev 就是这次写的 payload）")
    m_Step = "done"
end

local m_Steps = {
    recon = StepRecon,
    write = StepWrite,
    save = StepSave,
    verify = StepVerify,
    load = StepLoad,
}

-- ===========================================================================
-- 对外唯一入口：由 Civ6Common replacement 的刷新回调每帧调用
-- 只认“创建场景”界面；其它前端界面（创建游戏/主菜单/选项/大厅…）直接返回
-- ===========================================================================

function ModMiscScenarioProbeRefresh()
    if Controls == nil or Controls.ScenarioDescription == nil then return end

    local hidden = ContextPtr:IsHidden()
    if m_LastHidden and not hidden then
        -- 隐藏 → 显示：新的一轮
        m_Step = "recon"
        m_RunIndex = m_RunIndex + 1
    end
    m_LastHidden = hidden

    if hidden or m_Step == nil then return end
    local step = m_Steps[m_Step]
    if step == nil then return end
    step()
end
