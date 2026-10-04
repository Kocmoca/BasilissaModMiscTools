-- ===========================================================================
-- Mod Misc Tool: 对局内「创建新局 / 换地图」验证模块（UI 层）
--
-- 【要验证什么】在**对局内**调用 ScenarioSetup 的「创建游戏」功能是否可行。
-- 目标是这两行（Base/Assets/UI/FrontEnd/ScenarioSetup.lua:728 的普通分支）：
--     Events.SetGameEntryMethod("Scenario Start");
--     Network.HostGame(ServerType.SERVER_TYPE_NONE);
-- ScenarioSetup 是前端上下文，对局内没有它 —— 所以这里**照抄这两行调用**，
-- 从对局内 UI 上下文发出，看引擎接不接受。接受 = 能就地重开一局 / 就地换一张图；
-- 再配合已验证的对局内读档接口（`Network.LoadGame`，见 API_Verification_Status.md
-- 第 38 条）就能模拟「游戏中切换地图」。
--
-- 【静态事实】（都来自游戏自己的代码，不是推断）
--   * `Network.RestartGame()` 是引擎自带的**对局内**重开：
--     Base/Assets/UI/Menus/InGameTopOptionsMenu.lua:78
--     「Start a fresh game using the existing game configuration.」
--     —— 对局内建新局的官方路径，本模块拿它当对照组。
--   * `GameConfiguration` 在对局内可用（同一个文件 :316 就在读
--     `IsAnyMultiplayer` / `GetGameSpeedType` / `IsSavedGame`）。
--   * `MapConfiguration` 在对局内代码里**没有任何调用点** ⇒ 可用性未知，正是本模块要探的。
--   * 引擎自己的 Automation 要求 HostGame 必须站在主菜单：
--     Automation_StandardTests.lua:489「We must be at the Main Menu to do this test」，
--     不在就 `Events.ExitToMainMenu()` 退出去。⇒ 对局内直调 HostGame 大概率不被支持；
--     验证它就是为了把这条结论钉死（失败也是结论）。
--   * 配置键（Configuration 库，Base/Assets/Configuration/Data/SetupParameters.xml）：
--       Map  组  MAP_SCRIPT        地图脚本文件名（如 "Continents.lua"）
--       Map  组  MAP_SIZE          尺寸；注意 `MapConfiguration.GetMapSize()` 返回的是**哈希**
--       Game 组  RULESET / GAME_HANDICAP / GAME_SPEED_TYPE / CITY_STATE_COUNT
--     写配置**绕过了前端的 SetupParameters 参数系统**，所以前端那套
--     `ChangeableAfterGameStart` / `GAMESTATE_PREGAME` 拦截在这里不适用 —— 能不能写、
--     写了算不算数，只能实测。
--
-- 【证据链：标记协议】依据 API_Verification_Status.md 第 21 / 39 条：CustomData 随局随档，
-- **新局不继承**。所以调用前先往 CustomData 写一份「切换前快照」（ArmMarker），然后看：
--     * 进程没了       → Lua.log 停在「即将调用 …」那一行（调用把引擎干掉了），
--                        取 tombstone 看 backtrace 即可
--     * 还在原来这一局 → 面板照常打出「调用已返回」+ 当前指纹 ⇒ 调用是空操作
--     * 进了新的一局   → 开局探针 ReportAfterCreateInGame() 读不到标记（新局没有 CustomData），
--                        且指纹里的 script/grid 变成目标值 ⇒ 换图成功
--     * 读回了旧档     → 标记回来了（内容是存档那一刻的快照）
--   三个判定都只看 Lua.log 里前缀 `[ModMiscTool][CreateGame]` 的行，不需要面板在场。
--
-- 【边界】只读探测（DescribeContext）与写配置（ApplyMapScript）都是安全的；三个
--   「真去建新局 / 退出」的入口（RestartGame / HostGame / ExitToMainMenu）可能让进程
--   挂掉或把当前局顶掉 —— 面板上按风险从低到高排列，且都在调用前先打日志。
--
-- 【公开 API】本 mod 内直接调 ModMiscCreateGame.*
--   DescribeContext()             只读探测：接口可用性 + 当前配置指纹 + 改图路径
--   DescribeFingerprint()         当前局的指纹（turn/script/size/grid/players）
--   ListMapScripts()              可选地图脚本清单（优先查配置库 Maps 表，失败用内置数据表）
--   GetCurrentMapScript()         当前地图脚本（多种读法依次尝试，返回 file, route）
--   ApplyMapScript(file)          改地图配置 + 立即回读（返回 ok, 明细）
--   ArmMarker(action)             写「切换前快照」标记（返回 payload；失败返回 nil, err）
--   ReadMarker()                  读标记（返回 payload 或 nil, err）
--   ClearMarker()                 清标记
--   SaveBeforeSwitch()            切换前存档（Network.SaveGame，异步；SaveComplete 另判）
--   RestartGame()                 Network.RestartGame（引擎自带的对局内重开）
--   HostGame()                    ScenarioSetup.OnStartButton 等价调用（本模块的验证目标）
--   ExitToMainMenu()              Events.ExitToMainMenu（退到前端再建新局，兜底路径）
--   ReportAfterCreateInGame()     开局探针：由 Support_UI.Initialize 调一次
--
-- ⚠️ 本文件**故意不挂任何 Events** —— 它会被多个 context include
-- （Support_UI 与 AutomationTestPanel），各自挂一次就会重复打日志。
-- 开局探针由 Support_UI.Initialize 调一次，与本项目 ModMiscAssetStore 同一套做法。
-- ===========================================================================

local MODMISC_CREATEGAME_BUILD_TAG = "2026-10-05-A"

-- CustomData 键：写的是「调用创建游戏之前的快照」，用来判定调用之后到底进了哪一局
local MODMISC_CREATEGAME_MARKER_KEY = "ModMiscCreateGameMarker"

-- 切换前存档的档名（普通单机档，不占自动/快速存档位）
local MODMISC_CREATEGAME_BACKUP_SAVE_NAME = "ModMiscCreateGame~switch-backup"

-- 地图脚本候选：**内置兜底表**。正常情况下走 ListMapScripts() 查配置库 `Maps` 表
-- （那份才是真正启用的地图，含 DLC/资料片），这里只在查不到时兜底。
-- 名字就是 `MapConfiguration.SetScript` 要的文件名（Base/Assets/Maps/*.lua）。
local MODMISC_CREATEGAME_FALLBACK_MAPS = {
    "Continents.lua",
    "Pangaea.lua",
    "Small_Continents.lua",
    "Fractal.lua",
    "Island_Plates.lua",
    "InlandSea.lua",
    "Lakes.lua",
    "Seven_Seas.lua",
    "Shuffle.lua",
    "Terra.lua",
}

-- 只读探测用的接口清单（数据驱动，加接口只加一行）
local MODMISC_CREATEGAME_API_FLAGS = {
    { Label = "GameConfiguration",                    Owner = "GameConfiguration" },
    { Label = "GameConfiguration.GetValue",           Owner = "GameConfiguration", Member = "GetValue" },
    { Label = "GameConfiguration.SetValue",           Owner = "GameConfiguration", Member = "SetValue" },
    { Label = "GameConfiguration.GetGameState",       Owner = "GameConfiguration", Member = "GetGameState" },
    { Label = "GameConfiguration.IsAnyMultiplayer",   Owner = "GameConfiguration", Member = "IsAnyMultiplayer" },
    { Label = "GameConfiguration.IsWorldBuilderEditor", Owner = "GameConfiguration", Member = "IsWorldBuilderEditor" },
    { Label = "GameConfiguration.GetParticipatingPlayerCount", Owner = "GameConfiguration", Member = "GetParticipatingPlayerCount" },
    { Label = "MapConfiguration",                     Owner = "MapConfiguration" },
    { Label = "MapConfiguration.GetScript",           Owner = "MapConfiguration", Member = "GetScript" },
    { Label = "MapConfiguration.SetScript",           Owner = "MapConfiguration", Member = "SetScript" },
    { Label = "MapConfiguration.GetMapSize",          Owner = "MapConfiguration", Member = "GetMapSize" },
    { Label = "MapConfiguration.SetMapSize",          Owner = "MapConfiguration", Member = "SetMapSize" },
    { Label = "MapConfiguration.GetValue",            Owner = "MapConfiguration", Member = "GetValue" },
    { Label = "MapConfiguration.SetValue",            Owner = "MapConfiguration", Member = "SetValue" },
    { Label = "Network.HostGame",                     Owner = "Network", Member = "HostGame" },
    { Label = "Network.RestartGame",                  Owner = "Network", Member = "RestartGame" },
    { Label = "Network.SaveGame",                     Owner = "Network", Member = "SaveGame" },
    { Label = "Network.LoadGame",                     Owner = "Network", Member = "LoadGame" },
    { Label = "Network.IsGameHost",                   Owner = "Network", Member = "IsGameHost" },
    { Label = "Events.SetGameEntryMethod",            Owner = "Events", Member = "SetGameEntryMethod" },
    { Label = "Events.ExitToMainMenu",                Owner = "Events", Member = "ExitToMainMenu" },
    { Label = "Events.SaveComplete",                  Owner = "Events", Member = "SaveComplete" },
    { Label = "Events.LoadGameViewStateDone",         Owner = "Events", Member = "LoadGameViewStateDone" },
    { Label = "UI.IsInFrontEnd",                      Owner = "UI", Member = "IsInFrontEnd" },
    { Label = "ServerType",                           Owner = "ServerType" },
    { Label = "SlotStatus",                           Owner = "SlotStatus" },
    { Label = "SaveLocations",                        Owner = "SaveLocations" },
    { Label = "SaveTypes",                            Owner = "SaveTypes" },
    { Label = "SaveFileTypes",                        Owner = "SaveFileTypes" },
    { Label = "DB.ConfigurationQuery",                Owner = "DB", Member = "ConfigurationQuery" },
    { Label = "DB.MakeHash",                          Owner = "DB", Member = "MakeHash" },
    { Label = "WorldBuilder.ConfigurationManager",    Owner = "WorldBuilder", Member = "ConfigurationManager" },
}

ModMiscCreateGame = ModMiscCreateGame or {}
local API = ModMiscCreateGame
API.BuildTag = MODMISC_CREATEGAME_BUILD_TAG

local function Log(message)
    print("[ModMiscTool][CreateGame] " .. tostring(message))
end

-- ===========================================================================
-- 通用取值：诊断代码一律不能影响主流程（本项目踩过“诊断把主逻辑带崩”的坑）
-- ===========================================================================

local function TryCall(getter)
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter)
    if not ok then return nil end
    return value
end

-- 单行化：诊断文本里可能出现分隔符，会污染指纹的 "k=v;k=v" 格式
local function Sanitize(text)
    if text == nil then return "" end
    local cleaned = tostring(text):gsub("[;\n\r]", ",")
    return cleaned
end

local function IsAvailable(ownerName, memberName)
    local owner = _G[ownerName]
    if owner == nil then return false end
    if memberName == nil then return true end
    return owner[memberName] ~= nil
end

-- ===========================================================================
-- 指纹：当前这一局的「回合 / 地图 / 尺寸 / 网格 / 玩家数」快照
-- 换图成功的判据就是这里前后两次的 script（以及 grid）不一样。
-- ===========================================================================

-- 地图尺寸：复用 UI/Replacements/Civ6Common.lua 里唯一那份实现
-- （该文件把 local 的 ModMiscToolGetMapSizeKey 导出成全局；没导出就只报 "?"，
--   绝不在这里再写第二份哈希比对逻辑）
local function GetMapSizeKey()
    if ModMiscToolResolveMapSizeKey == nil then
        return nil, "ModMiscToolResolveMapSizeKey 未导出"
    end
    local ok, key, diagnostic = pcall(ModMiscToolResolveMapSizeKey)
    if not ok then return nil, tostring(key) end
    if key == nil then return nil, tostring(diagnostic) end
    return key
end

-- Map.GetGridSize() 返回两个值（宽、高），不能走只取首值的 TryCall
local function GetGridSize()
    if Map == nil or Map.GetGridSize == nil then return "?" end
    local ok, width, height = pcall(Map.GetGridSize)
    if not ok or width == nil or height == nil then return "?" end
    return tostring(width) .. "x" .. tostring(height)
end

function API.DescribeFingerprint()
    local mapScript, mapScriptRoute = API.GetCurrentMapScript()
    local mapSize, mapSizeDiagnostic = GetMapSizeKey()
    local participating = TryCall(function() return GameConfiguration.GetParticipatingPlayerCount() end)
    return string.format("turn=%s;script=%s(%s);size=%s;grid=%s;players=%s",
        tostring(TryCall(function() return Game.GetCurrentGameTurn() end)),
        Sanitize(mapScript), Sanitize(mapScriptRoute),
        Sanitize(mapSize or ("?(" .. tostring(mapSizeDiagnostic or "") .. ")")),
        GetGridSize(),
        tostring(participating))
end

-- ===========================================================================
-- 当前地图脚本：配置库里这个键叫 MAP_SCRIPT（也有 Map / MAP_NAME 之类写法），
-- 所以几种读法都试一遍，并把「哪一种读到的」一并返回（探测结论要用）。
-- ===========================================================================

function API.GetCurrentMapScript()
    local getters = {
        { Route = "MapConfiguration.GetScript", Fn = function()
            if MapConfiguration == nil or MapConfiguration.GetScript == nil then return nil end
            return MapConfiguration.GetScript()
        end },
        { Route = "MapConfiguration.GetValue(MAP_SCRIPT)", Fn = function()
            if MapConfiguration == nil or MapConfiguration.GetValue == nil then return nil end
            return MapConfiguration.GetValue("MAP_SCRIPT")
        end },
        { Route = "MapConfiguration.GetValue(Map)", Fn = function()
            if MapConfiguration == nil or MapConfiguration.GetValue == nil then return nil end
            return MapConfiguration.GetValue("Map")
        end },
        { Route = "GameConfiguration.GetValue(MAP_SCRIPT)", Fn = function()
            if GameConfiguration == nil or GameConfiguration.GetValue == nil then return nil end
            return GameConfiguration.GetValue("MAP_SCRIPT")
        end },
        { Route = "GameConfiguration.GetValue(Map)", Fn = function()
            if GameConfiguration == nil or GameConfiguration.GetValue == nil then return nil end
            return GameConfiguration.GetValue("Map")
        end },
    }
    for _, getter in ipairs(getters) do
        local value = TryCall(getter.Fn)
        if value ~= nil and tostring(value) ~= "" then
            return tostring(value), getter.Route
        end
    end
    return nil, "none"
end

-- ===========================================================================
-- 可选地图脚本清单
--
-- 优先查 Configuration 库的 `Maps` 表（前端地图选择界面就是查它：
-- `SELECT File, Image, StaticMap from Maps where Domain = ?`，见 AdvancedSetup.lua:182），
-- 查不到（对局内 DB.ConfigurationQuery 不可用 / 查询报错）才用内置兜底表。
-- 返回数组：{ { File = "Pangaea.lua", Text = <本地化名或文件名> }, ... }
-- ===========================================================================

local function ListMapScriptsFromDatabase()
    if DB == nil or DB.ConfigurationQuery == nil then return nil end
    local rows = TryCall(function()
        return DB.ConfigurationQuery("SELECT File, Name FROM Maps")
    end)
    if type(rows) ~= "table" or #rows == 0 then return nil end

    local seen, list = {}, {}
    for _, row in ipairs(rows) do
        local file = row.File
        if type(file) == "string" and file ~= "" and not seen[file] then
            seen[file] = true
            local text = file
            if row.Name ~= nil then
                local localized = TryCall(function() return Locale.Lookup(row.Name) end)
                if localized ~= nil and tostring(localized) ~= "" then text = tostring(localized) end
            end
            table.insert(list, { File = file, Text = text })
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return tostring(a.Text) < tostring(b.Text) end)
    return list
end

function API.ListMapScripts()
    local fromDatabase = ListMapScriptsFromDatabase()
    if fromDatabase ~= nil then return fromDatabase, "database" end

    local list = {}
    for _, file in ipairs(MODMISC_CREATEGAME_FALLBACK_MAPS) do
        table.insert(list, { File = file, Text = file })
    end
    return list, "fallback"
end

-- ===========================================================================
-- 改地图配置：把目标地图脚本写进当前配置，然后**立刻回读**。
--
-- 四条路径都试（各自的成功/失败都记进明细），只要回读值变成目标值就算成功
-- （不关心是哪条路径生效的）：
--   ① MapConfiguration.SetScript(file)                —— 引擎 Automation 用的写法
--   ② MapConfiguration.SetValue("MAP_SCRIPT", file)
--   ③ GameConfiguration.SetValue("MAP_SCRIPT", file)  —— 配置对象是同一个就等价
--   ④ WorldBuilder.ConfigurationManager():SetMapValue("MapScript", file)
--      —— 地图编辑器改地图走的就是它；它在 gameplay 侧，经 ExposedMembers 调
-- ===========================================================================

local function AttemptRoute(results, label, fn)
    local ok, err = pcall(fn)
    table.insert(results, label .. "=" .. tostring(ok))
    if not ok then Log("route " .. label .. " 失败 -> " .. tostring(err)) end
end

function API.ApplyMapScript(mapScriptFile)
    if mapScriptFile == nil or tostring(mapScriptFile) == "" then
        return false, "no map script given"
    end
    local target = tostring(mapScriptFile)
    local before, beforeRoute = API.GetCurrentMapScript()
    local results = {}

    AttemptRoute(results, "SetScript", function()
        if MapConfiguration == nil or MapConfiguration.SetScript == nil then
            error("MapConfiguration.SetScript 不可用")
        end
        MapConfiguration.SetScript(target)
    end)
    AttemptRoute(results, "Map.SetValue", function()
        if MapConfiguration == nil or MapConfiguration.SetValue == nil then
            error("MapConfiguration.SetValue 不可用")
        end
        MapConfiguration.SetValue("MAP_SCRIPT", target)
    end)
    AttemptRoute(results, "Game.SetValue", function()
        if GameConfiguration == nil or GameConfiguration.SetValue == nil then
            error("GameConfiguration.SetValue 不可用")
        end
        GameConfiguration.SetValue("MAP_SCRIPT", target)
    end)
    AttemptRoute(results, "WorldBuilder", function()
        local scriptMembers = ExposedMembers ~= nil and ExposedMembers.ModMiscToolScript or nil
        local worldBuilderApi = scriptMembers ~= nil and scriptMembers.WorldBuilderAPI or nil
        if worldBuilderApi == nil or worldBuilderApi.SetMapValue == nil then
            error("ExposedMembers.ModMiscToolScript.WorldBuilderAPI.SetMapValue 不可用")
        end
        worldBuilderApi.SetMapValue("MapScript", target)
    end)

    local after, afterRoute = API.GetCurrentMapScript()
    local applied = after ~= nil and tostring(after) == target
    local detail = string.format("applied=%s target=%s before=%s(%s) after=%s(%s) routes[%s]",
        tostring(applied), target, tostring(before), tostring(beforeRoute),
        tostring(after), tostring(afterRoute), table.concat(results, " "))
    Log("applyMapScript: " .. detail)
    return applied, detail
end

-- ===========================================================================
-- 标记协议（切换前快照）
-- ===========================================================================

function API.ArmMarker(actionName)
    if WriteCustomData == nil then
        Log("ArmMarker 失败：WriteCustomData 不可用（Civ6Common 没 include？）")
        return nil, "WriteCustomData 不可用"
    end
    local payload = string.format("act=%s;nonce=%d;t=%d;%s",
        Sanitize(actionName or "?"), math.random(100000, 999999), os.time(),
        API.DescribeFingerprint())
    local ok, err = pcall(WriteCustomData, MODMISC_CREATEGAME_MARKER_KEY, payload)
    if not ok then
        Log("ArmMarker 失败 -> " .. tostring(err))
        return nil, tostring(err)
    end
    Log("marker armed: [" .. payload .. "]")
    return payload
end

function API.ReadMarker()
    if ReadCustomData == nil then return nil, "ReadCustomData 不可用" end
    local ok, value = pcall(ReadCustomData, MODMISC_CREATEGAME_MARKER_KEY)
    if not ok then return nil, tostring(value) end
    if value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

function API.ClearMarker()
    if WriteCustomData == nil then return false end
    local ok = pcall(WriteCustomData, MODMISC_CREATEGAME_MARKER_KEY, "")
    return ok
end

-- 开局探针：每次进入游戏（新局 / 读档）各跑一次，只打日志。
-- 判定（依据第 21/39 条：CustomData 随局随档、新局不继承）：
--   标记不存在 → 这是个**新建的局**（或从没 arm 过；所以面板每次调用前都会 arm）
--   标记存在   → 不是全新的局：要么调用是空操作（还在原局），要么读回了旧档
function API.ReportAfterCreateInGame()
    local marker, markerError = API.ReadMarker()
    local fingerprint = API.DescribeFingerprint()

    if markerError ~= nil then
        Log("after-create: 读标记失败 -> " .. tostring(markerError) .. "；now: " .. fingerprint)
        return
    end

    if marker == nil then
        Log("after-create: VERDICT=new-game 读不到标记（新局不继承 CustomData）"
            .. "；now: " .. fingerprint)
        return
    end

    -- 标记里有当时的 script=/grid=，和现在的比一比：同一局应当完全一致
    local armedScript = string.match(marker, "script=([^;%(]+)")
    local armedGrid = string.match(marker, "grid=([^;]+)")
    local nowGrid = GetGridSize()
    local mapChanged = "no"
    if armedGrid ~= nil and nowGrid ~= "?" and armedGrid ~= nowGrid then
        mapChanged = "yes"
    end
    Log("after-create: VERDICT=marker-present 读到标记 [" .. marker .. "]"
        .. " ⇒ 这局不是全新的（同一局，或读回了旧档）"
        .. "；armedScript=" .. tostring(armedScript)
        .. "；mapChanged=" .. mapChanged
        .. "；now: " .. fingerprint)
end

-- ===========================================================================
-- 只读探测：接口可用性 + 当前配置指纹 + 改图路径
-- 返回多行文本（调用方负责显示/打日志；这里只给事实，不做文案包装）
-- ===========================================================================

local function BuildApiFlagText()
    local parts = {}
    for _, spec in ipairs(MODMISC_CREATEGAME_API_FLAGS) do
        table.insert(parts, spec.Label .. "=" .. (IsAvailable(spec.Owner, spec.Member) and "y" or "n"))
    end
    return table.concat(parts, " ")
end

local function BuildRouteText()
    local scriptMembers = ExposedMembers ~= nil and ExposedMembers.ModMiscToolScript or nil
    local worldBuilderApi = scriptMembers ~= nil and scriptMembers.WorldBuilderAPI or nil
    return string.format("MapConfiguration=%s GameConfiguration=%s WBApi=%s WBApi.SetMapValue=%s IsGameHost=%s",
        tostring(MapConfiguration ~= nil), tostring(GameConfiguration ~= nil),
        tostring(worldBuilderApi ~= nil),
        tostring(worldBuilderApi ~= nil and worldBuilderApi.SetMapValue ~= nil),
        tostring(TryCall(function() return Network.IsGameHost() end)))
end

function API.DescribeContext()
    local lines = {}
    table.insert(lines, "context: inFrontEnd="
        .. tostring(TryCall(function() return UI.IsInFrontEnd() end))
        .. " localPlayer=" .. tostring(TryCall(function() return Game.GetLocalPlayer() end))
        .. " gameState=" .. tostring(TryCall(function() return GameConfiguration.GetGameState() end))
        .. " anyMultiplayer=" .. tostring(TryCall(function() return GameConfiguration.IsAnyMultiplayer() end))
        .. " worldBuilderEditor=" .. tostring(TryCall(function() return GameConfiguration.IsWorldBuilderEditor() end))
        .. " isSavedGame=" .. tostring(TryCall(function() return GameConfiguration.IsSavedGame() end)))
    table.insert(lines, "now: " .. API.DescribeFingerprint())
    table.insert(lines, "routes: " .. BuildRouteText())
    table.insert(lines, "api: " .. BuildApiFlagText())

    local marker = API.ReadMarker()
    table.insert(lines, "marker: " .. (marker ~= nil and ("[" .. marker .. "]") or "nil"))

    for _, line in ipairs(lines) do
        Log(line)
    end
    return table.concat(lines, "\n")
end

-- ===========================================================================
-- 切换前存档：把当前局完整存成普通单机档（不占自动/快速存档位）
-- 异步：真正落盘看 Events.SaveComplete（一次性监听，日志里能直接读到结果）
-- ===========================================================================

function API.SaveBeforeSwitch()
    if Network == nil or Network.SaveGame == nil then
        return false, "Network.SaveGame 不可用"
    end
    if SaveTypes == nil or SaveLocations == nil then
        return false, "SaveTypes / SaveLocations 枚举不可用"
    end

    local saveFile = {
        Name = MODMISC_CREATEGAME_BACKUP_SAVE_NAME,
        Location = SaveLocations.LOCAL_STORAGE,
        Type = SaveTypes.SINGLE_PLAYER,
        FileType = SaveFileTypes ~= nil and SaveFileTypes.GAME_STATE or nil,
        IsAutosave = false,
        IsQuicksave = false,
    }
    Log("即将调用 Network.SaveGame（切换前存档）name=" .. MODMISC_CREATEGAME_BACKUP_SAVE_NAME)
    local ok, err = pcall(Network.SaveGame, saveFile)
    if not ok then
        Log("Network.SaveGame 调用失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    Log("Network.SaveGame 调用已返回（没卡死），等 SaveComplete")
    return true, MODMISC_CREATEGAME_BACKUP_SAVE_NAME
end

-- ===========================================================================
-- 三个真去「建新局 / 退出」的入口
-- 每个都：先 arm 标记 → 打一行「即将调用」→ 调用 → 打一行「调用已返回」。
-- 日志断在「即将调用」那行 = 引擎挂了；正常返回 = 至少没崩。
-- ===========================================================================

local function CallAfterArmed(actionName, logDetail, call)
    local payload, markerError = API.ArmMarker(actionName)
    if payload == nil then
        return false, "arm 标记失败：" .. tostring(markerError)
    end
    Log("即将调用 " .. logDetail .. "（marker=" .. payload .. "）")
    local ok, err = pcall(call)
    if not ok then
        Log("调用失败（异常）-> " .. tostring(err))
        return false, tostring(err)
    end
    Log("调用已返回（没卡死）；现在是：" .. API.DescribeFingerprint())
    return true, "called"
end

-- 引擎自带的**对局内**重开：InGameTopOptionsMenu.lua:80
function API.RestartGame()
    if Network == nil or Network.RestartGame == nil then
        return false, "Network.RestartGame 不可用"
    end
    return CallAfterArmed("RestartGame", "Network.RestartGame()", function()
        Network.RestartGame()
    end)
end

-- 本模块的验证目标：ScenarioSetup.OnStartButton() 普通分支的等价调用
function API.HostGame()
    if Network == nil or Network.HostGame == nil then
        return false, "Network.HostGame 不可用"
    end
    if ServerType == nil or ServerType.SERVER_TYPE_NONE == nil then
        return false, "ServerType.SERVER_TYPE_NONE 不可用"
    end
    return CallAfterArmed("HostGame",
        "Events.SetGameEntryMethod + Network.HostGame(SERVER_TYPE_NONE)", function()
            -- 与 ScenarioSetup.OnStartButton 一致：先报告进入方式，再 HostGame
            -- （Events 整个表都可能不存在，所以两级都要判）
            if Events ~= nil and Events.SetGameEntryMethod ~= nil then
                Events.SetGameEntryMethod("Scenario Start")
            end
            Network.HostGame(ServerType.SERVER_TYPE_NONE)
        end)
end

function API.ExitToMainMenu()
    if Events == nil or Events.ExitToMainMenu == nil then
        return false, "Events.ExitToMainMenu 不可用"
    end
    return CallAfterArmed("ExitToMainMenu", "Events.ExitToMainMenu()", function()
        Events.ExitToMainMenu()
    end)
end
