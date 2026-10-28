-- ===========================================================================
-- Mod Misc Tool: WorldBuilder（地图编辑器）接口测试面板
--
-- 【2026-10-28 授权者：入口关闭】面板本体仍由 modinfo 的 AddUserInterfaces 注册，
-- 但侧栏入口开关 = false（下面 MODMISC_WB_TEST_ENTRY_ENABLED）。
-- 关闭原因：本轮验证的「运行时添加玩家」线路已被实机否掉 ——
-- 补了 InitializePlayer 之后仍然原生闪退在同一符号
-- （GameCore::AI::Diplomatic::GetDiplomaticStateIndex）⇒ 运行时造玩家不可行。
-- 结论见 API_Verification_Status.md §19.37 / #1；要再进来看状态时把开关改回 true。
--
-- 按钮分级（上一轮按实证结论整理）：已实证可用 → Hidden="1"（代码保留）；
-- 实证不能工作 → 删除；「添加玩家」已被实机否掉，同样改成 Hidden="1" 并加了警告注释。
-- 面板功能本身仍然通过 ExposedMembers 暴露给其它 mod 调用
-- （ExposedMembers.ModMiscToolScript.* / ExposedMembers.ModMiscToolUI.*）。
--
-- 通过左侧栏入口打开；在普通对局里直接测试 Gameplay 后端
-- （ModTool_WorldBuilderAPI.lua）提供的 WorldBuilder 接口。
--
--   * 选择器：收起状态是一个按钮（显示当前选择），点击后在本面板内展开选项列表，
--     选中即收起（列表自绘，不依赖引擎下拉弹窗，面板被 reparent 到 /InGame 也能用）
--   * 玩家 / 文明 / 领袖 / 玩家类型（主要文明·城邦）/ 放置范围（2·4·6 格）
--   * 添加玩家（已隐藏，实机否掉）：AddPlayer → SetPlayerSlotStatus → SetPlayerLeader
--     → InitializePlayer 一条龙；补了初始化照样闪退在 AI 外交子系统，别再用
--   * 创建城市 / 创建单位 / 放置开拓者：点按钮后在地图上显示地块按键，
--     点中某个地块按键即在该地块执行（复用 UI/MapButton_UI.lua 的地图按键）
--   * 操作结果与提示放在“提示信息”小窗，主面板不再挤文字
--
-- 接口来自 Gameplay 后端：ModTool_WorldBuilderAPI.lua 由 ModTool.lua include，
-- 再经 ExposedMembers.ModMiscToolScript.WorldBuilderAPI 暴露给本面板。
-- 面板不做任何可用性判定：点击按钮无条件打开，测试功能无条件调用接口，
-- 出错时把原始错误显示在提示信息小窗（同时会进 Lua.log）。
-- ===========================================================================

include("InstanceManager")
print("[ModMiscTool][WorldBuilderTest] panel loading build=" .. tostring(MODMISC_BUILD_TAG))

-- ===========================================================================
-- 常量与状态
-- ===========================================================================

local PLAYER_TYPE_MAJOR = "CIVILIZATION_LEVEL_FULL_CIV"
local PLAYER_TYPE_CITY_STATE = "CIVILIZATION_LEVEL_CITY_STATE"

local UNIT_TYPE_WARRIOR = "UNIT_WARRIOR"
local UNIT_TYPE_SETTLER = "UNIT_SETTLER"

local PLACE_RANGE_OPTIONS = { 2, 4, 6 }   -- 城市 / 单位选点半径（格）
local PLACE_RANGE_DEFAULT = 4
local MAX_PLACE_PLOTS = 60                -- 单次最多生成的地图按键数量（防止实例过多）

local OPTION_ENTRY_WIDTH = 620
local OPTION_ENTRY_HEIGHT = 48
local OPTION_ENTRY_FONT = 24
local OPTION_PANEL_GAP = 4
local OPTION_ENTRY_PADDING = 3

local m_Registered = false
local m_AppliedScale = 1.0
local m_PendingPlayerSelect = nil

local m_SelectedPlayerID = nil
local m_SelectedCivType = nil
local m_SelectedLeaderType = nil
local m_SelectedPlayerTypeLevel = PLAYER_TYPE_MAJOR
local m_PlaceRange = PLACE_RANGE_DEFAULT

-- 玩家类型：主要文明 / 城邦（次选项，决定文明列表与文明等级）
local m_PlayerTypeEntries = {
    { Text = "LOC_MODMISC_WB_TEST_TYPE_MAJOR", LevelType = PLAYER_TYPE_MAJOR },
    { Text = "LOC_MODMISC_WB_TEST_TYPE_CITY_STATE", LevelType = PLAYER_TYPE_CITY_STATE },
}

local m_Messages = {}
local MESSAGE_HISTORY_MAX = 20

local m_CivEntries = {}
local m_LeaderEntries = {}
local m_PlaceRangeEntries = {}

local m_Selectors = {}
local m_SelectorOrder = { "player", "civ", "leader", "playerType", "placeRange" }
local m_OpenSelectorKey = nil
local m_OptionIM = nil

local function GetCurrentScale()
    return m_AppliedScale
end

local function APIModule()
    return ExposedMembers.ModMiscToolScript.WorldBuilderAPI
end

-- ===========================================================================
-- 提示信息小窗
-- ===========================================================================

local function SetStatus(text)
    Controls.WorldBuilderTestStatus:SetText(tostring(text or ""))
end

-- 只往“提示信息”小窗里追加一条，不动顶部状态栏（打开面板时用来塞幽灵池摘要）
local function PushMessage(text)
    local message = tostring(text or "")
    table.insert(m_Messages, message)
    while #m_Messages > MESSAGE_HISTORY_MAX do
        table.remove(m_Messages, 1)
    end
    Controls.WorldBuilderTestMessageText:SetText(table.concat(m_Messages, "\n"))
    return message
end

-- 最新一条显示在顶部状态栏；“提示信息”小窗里保留历史记录（由按钮打开）
local function SetOutput(text)
    local message = PushMessage(text)
    SetStatus(message)
    print("[ModMiscTool][WorldBuilderTest] " .. message)
end

local function SetResult(name, detail)
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_RESULT", name, tostring(detail)))
end

local function SetError(name, err)
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_ERROR", name, tostring(err)))
end

local function ToggleMessageWindow()
    local window = Controls.WorldBuilderTestMessageWindow
    window:SetHide(not window:IsHidden())
end

-- ===========================================================================
-- 数据库候选列表
-- ===========================================================================

local function GetLocalizedCivName(civType)
    if civType == nil or civType == "UNDEFINED" or civType == "RANDOM" then
        return Locale.Lookup("LOC_WORLDBUILDER_UNDEFINED")
    end
    local civRow = GameInfo.Civilizations[civType]
    if civRow == nil or civRow.Name == nil then
        return tostring(civType)
    end
    return Locale.Lookup(civRow.Name)
end

local function GetLocalizedLeaderName(leaderType)
    if leaderType == nil or leaderType == -1 or leaderType == "UNDEFINED" or leaderType == "RANDOM" then
        return Locale.Lookup("LOC_WORLDBUILDER_UNDEFINED")
    end
    local leaderRow = GameInfo.Leaders[leaderType]
    if leaderRow == nil or leaderRow.Name == nil then
        return tostring(leaderType)
    end
    return Locale.Lookup(leaderRow.Name)
end

local function GetCivText(entry)
    if entry == nil then return "" end
    return Locale.Lookup(entry.Text)
end

local function SortEntriesByText(entries)
    table.sort(entries, function(a, b)
        return Locale.Lookup(a.Text) < Locale.Lookup(b.Text)
    end)
end

-- 文明列表 + 各文明的默认领袖（同地图编辑器 SetCivDefaultLeader 的做法）
local function BuildCivEntries()
    if m_CivEntries[1] ~= nil then return end

    local defaultLeaderByCiv = {}
    for civLeaderRow in GameInfo.CivilizationLeaders() do
        if defaultLeaderByCiv[civLeaderRow.CivilizationType] == nil then
            defaultLeaderByCiv[civLeaderRow.CivilizationType] = civLeaderRow.LeaderType
        end
    end

    for civRow in GameInfo.Civilizations() do
        table.insert(m_CivEntries, {
            Text = civRow.Name,
            CivilizationType = civRow.CivilizationType,
            CivilizationLevelType = civRow.StartingCivilizationLevelType or PLAYER_TYPE_MAJOR,
            DefaultLeader = defaultLeaderByCiv[civRow.CivilizationType] or -1,
        })
    end
    SortEntriesByText(m_CivEntries)
end

-- 按玩家类型过滤文明：主要文明 / 城邦
local function GetCivEntriesForType(levelType)
    local entries = {}
    for _, entry in ipairs(m_CivEntries) do
        if entry.CivilizationLevelType == levelType then
            table.insert(entries, entry)
        end
    end
    return entries
end

-- 领袖列表（同地图编辑器：跳过空领袖）
local function BuildLeaderEntries()
    if m_LeaderEntries[1] ~= nil then return end

    for leaderRow in GameInfo.Leaders() do
        if leaderRow.Name ~= nil and leaderRow.Name ~= "LOC_EMPTY" then
            table.insert(m_LeaderEntries, {
                Text = leaderRow.Name,
                LeaderType = leaderRow.LeaderType,
            })
        end
    end
    SortEntriesByText(m_LeaderEntries)
end

-- 放置范围条目（2 / 4 / 6 格）
local function BuildPlaceRangeEntries()
    if m_PlaceRangeEntries[1] ~= nil then return end
    for _, range in ipairs(PLACE_RANGE_OPTIONS) do
        table.insert(m_PlaceRangeEntries, {
            Text = Locale.Lookup("LOC_MODMISC_WB_TEST_RANGE_VALUE", range),
            Range = range,
        })
    end
end

-- 跨上下文调 gameplay 暴露的幽灵 API：一律 pcall，取不到就回落（别让面板自己报错）
local function CallGhostAPI(name, fallback, ...)
    local script = ExposedMembers and ExposedMembers.ModMiscToolScript or nil
    if script == nil or script[name] == nil then return fallback end
    local ok, value = pcall(script[name], ...)
    if not ok or value == nil then return fallback end
    return value
end

-- 幽灵池摘要：两类池各有多少、可用多少、本局**申报上限**是多少
-- （授权者要求“方便查看幽灵玩家数量”；申报上限那一栏就是“没有 mod 申报 ⇒ 0 个”的落地结果）
local function DescribeGhostPlan(plan)
    if plan == nil then return Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_PLAN_UNLIMITED") end
    if tonumber(plan) == nil or tonumber(plan) <= 0 then
        return Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_PLAN_NONE")
    end
    return tostring(math.floor(tonumber(plan)))
end

local function DescribeGhostPool(kindKey, poolAPI, freeAPI, planAPI, logLabel)
    local pool = tonumber(CallGhostAPI(poolAPI, 0)) or 0
    local free = tonumber(CallGhostAPI(freeAPI, 0)) or 0
    local plan = CallGhostAPI(planAPI, nil)
    print("[ModMiscTool][Ghost] pool summary " .. logLabel .. ": pool=" .. tostring(pool)
        .. " free=" .. tostring(free) .. " used=" .. tostring(pool - free)
        .. " declaredPlan=" .. tostring(plan))
    return Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_LINE", Locale.Lookup(kindKey),
        tostring(pool), tostring(free), tostring(pool - free), DescribeGhostPlan(plan))
end

-- 建局侧记下的“玩家自己选的数量”（局内算槽位边界的基数）；老档/取不到就报 n/a
local function ReadSavedChoice(key)
    if DataProtocol == nil or DataProtocol.Load == nil then return "n/a" end
    local ok, value = pcall(function() return DataProtocol.Load(key) end)
    if not ok or value == nil then return "n/a" end
    -- DataProtocol.Load 返回 (值, 来源) 两个值：多包一层括号截断，别把来源当值
    local number = tonumber((tostring(value)))
    if number == nil then return "n/a" end
    return tostring(number)
end

local function ReportGhostPoolSummary()
    local script = ExposedMembers.ModMiscToolScript
    if script == nil or script.GetGhostPlayerCount == nil then
        print("[ModMiscTool][Ghost] pool summary: ModMiscToolScript API 不可用")
        return nil
    end
    local majorLine = DescribeGhostPool("LOC_MODMISC_WB_TEST_GHOST_KIND_MAJOR",
        "GetGhostPlayerCount", "GetAvailableGhostPlayerCount", "GetMajorGhostPoolLimit", "major")
    local cityLine = DescribeGhostPool("LOC_MODMISC_WB_TEST_GHOST_KIND_CITY_STATE",
        "GetCityStateGhostPlayerCount", "GetAvailableCityStateGhostPlayerCount",
        "GetCityStateGhostPoolLimit", "citystate")
    local majorChoice = ReadSavedChoice("ghost_majorplayers")
    local cityChoice = ReadSavedChoice("ghost_citystates")
    print("[ModMiscTool][Ghost] pool summary choice: majorPlayers=" .. majorChoice
        .. " cityStates=" .. cityChoice)
    return majorLine .. "\n" .. cityLine .. "\n"
        .. Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_CHOICE", majorChoice, cityChoice)
end

-- 玩家列表（普通对局：Players[playerID] 不为 nil 即有效，nil 即空槽位）
local function MakePlayerText(playerID)
    local playerConfig = PlayerConfigurations[playerID]
    local kindText = Locale.Lookup("LOC_WORLDBUILDER_AI")
    local playerName = tostring(playerID)
    local civText = Locale.Lookup("LOC_WORLDBUILDER_UNDEFINED")
    if playerConfig ~= nil then
        if playerConfig:IsHuman() then
            kindText = Locale.Lookup("LOC_WORLDBUILDER_HUMAN")
        end
        local rawName = playerConfig:GetPlayerName()
        if rawName ~= nil then
            playerName = Locale.Lookup(rawName)
        end
        civText = GetLocalizedCivName(playerConfig:GetCivilizationTypeName())
    end
    -- 幽灵标记：主流池与城邦池分开显示（旧接口 IsGhostPlayer 只指主流池）
    local ghostText = ""
    local poolType = CallGhostAPI("GetGhostPlayerPoolType", nil, playerID)
    if poolType == "major" then
        ghostText = " · " .. Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_KIND_MAJOR")
    elseif poolType == "citystate" then
        ghostText = " · " .. Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_KIND_CITY_STATE")
    elseif CallGhostAPI("IsGhostPlayer", false, playerID) == true then
        ghostText = " · " .. Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST")
    end
    return string.format("%d · %s · %s · %s%s", playerID, kindText, playerName, civText, ghostText)
end

local function BuildPlayerEntries()
    local entries = {}
    for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
        local player = Players[playerID]
        if player ~= nil and not player:IsBarbarian() then
            table.insert(entries, {
                Text = MakePlayerText(playerID),
                PlayerIndex = playerID,
            })
        end
    end
    return entries
end

-- ===========================================================================
-- 当前选择
-- ===========================================================================

local function FindEntryByKey(entries, key, value)
    for _, entry in ipairs(entries) do
        if entry[key] == value then return entry end
    end
    return nil
end

local function GetSelectedCivEntry()
    return FindEntryByKey(GetCivEntriesForType(m_SelectedPlayerTypeLevel),
        "CivilizationType", m_SelectedCivType)
end

local function GetSelectedLeaderEntry()
    return FindEntryByKey(m_LeaderEntries, "LeaderType", m_SelectedLeaderType)
end

local function GetSelectedTypeEntry()
    return FindEntryByKey(m_PlayerTypeEntries, "LevelType", m_SelectedPlayerTypeLevel)
end

local function GetSelectedRangeEntry()
    return FindEntryByKey(m_PlaceRangeEntries, "Range", m_PlaceRange)
end

local function GetSelectedPlayerEntry()
    return FindEntryByKey(BuildPlayerEntries(), "PlayerIndex", m_SelectedPlayerID)
end

local function GetSelectedPlayerID()
    return m_SelectedPlayerID
end

local function GetSelectedPlayerTypeLevel()
    return m_SelectedPlayerTypeLevel
end

-- 选中文明后，领袖切到该文明的默认领袖
local function SelectDefaultLeaderForCiv(civEntry)
    if civEntry == nil then return end
    if civEntry.DefaultLeader == nil or civEntry.DefaultLeader == -1 then return end
    if FindEntryByKey(m_LeaderEntries, "LeaderType", civEntry.DefaultLeader) == nil then return end
    m_SelectedLeaderType = civEntry.DefaultLeader
end

-- 玩家类型变化后：当前文明若不属于该类型，则改用该类型第一个文明
local function RefreshCivSelectionForType()
    local entries = GetCivEntriesForType(m_SelectedPlayerTypeLevel)
    local civEntry = FindEntryByKey(entries, "CivilizationType", m_SelectedCivType)
    if civEntry == nil then
        civEntry = entries[1]
    end
    m_SelectedCivType = civEntry ~= nil and civEntry.CivilizationType or nil
    if civEntry ~= nil then
        SelectDefaultLeaderForCiv(civEntry)
    end
end

-- ===========================================================================
-- 选择器：点击按钮 → 在按钮下方展开选项列表 → 选中即收起
-- ===========================================================================

local function CloseOptionList()
    Controls.WorldBuilderTestOptionPanel:SetHide(true)
    m_OpenSelectorKey = nil
end

local function GetSelectorLabel(key)
    local selector = m_Selectors[key]
    if selector == nil then return "" end
    return selector.getLabel()
end

local function RefreshSelectorButtons()
    for _, key in ipairs(m_SelectorOrder) do
        local selector = m_Selectors[key]
        if selector ~= nil and selector.button ~= nil then
            selector.button:SetText(GetSelectorLabel(key))
        end
    end
end

local function OpenOptionList(key)
    local selector = m_Selectors[key]
    if selector == nil then return end

    local entries = selector.getEntries()
    if #entries == 0 then return end

    local scale = GetCurrentScale()
    local entryHeight = math.floor(OPTION_ENTRY_HEIGHT * scale + 0.5)
    local entryPadding = math.max(1, math.floor(OPTION_ENTRY_PADDING * scale + 0.5))
    local innerPadding = math.floor(16 * scale + 0.5)

    m_OptionIM:ResetInstances()
    for _, entry in ipairs(entries) do
        local instance = m_OptionIM:GetInstance()
        instance.EntryButton:SetSizeVal(math.floor(OPTION_ENTRY_WIDTH * scale + 0.5), entryHeight)
        instance.EntryLabel:SetFontSize(math.max(12, math.floor(OPTION_ENTRY_FONT * scale + 0.5)))
        instance.EntryLabel:SetTruncateWidth(math.floor((OPTION_ENTRY_WIDTH - 28) * scale + 0.5))
        instance.EntryLabel:SetText(selector.getEntryText(entry))
        instance.EntryButton:SetSelected(selector.isSelected(entry))
        instance.EntryButton:ClearCallback(Mouse.eLClick)
        instance.EntryButton:RegisterCallback(Mouse.eLClick, function()
            selector.onSelect(entry)
            RefreshSelectorButtons()
            CloseOptionList()
        end)
    end

    -- 定位到选择器按钮正下方，高度不超过面板剩余空间
    local button = selector.button
    local optionX = button:GetOffsetX()
    local optionY = button:GetOffsetY() + button:GetSizeY()
        + math.floor(OPTION_PANEL_GAP * scale + 0.5)
    local optionWidth = button:GetSizeX()
    local available = Controls.WorldBuilderTestRoot:GetSizeY() - optionY - math.floor(20 * scale)
    local wanted = #entries * (entryHeight + entryPadding) + innerPadding
    local optionHeight = math.min(wanted, available)

    local optionPanel = Controls.WorldBuilderTestOptionPanel
    optionPanel:SetSizeVal(optionWidth, optionHeight)
    optionPanel:SetOffsetVal(optionX, optionY)
    optionPanel:SetHide(false)

    Controls.WorldBuilderTestOptionScroll:CalculateSize()
    Controls.WorldBuilderTestOptionScroll:CalculateInternalSize()
    m_OpenSelectorKey = key
end

local function ToggleOptionList(key)
    if m_OpenSelectorKey == key then
        CloseOptionList()
    else
        CloseOptionList()
        OpenOptionList(key)
    end
end

local function BuildSelectors()
    m_Selectors = {
        player = {
            button = Controls.WorldBuilderTestPlayerButton,
            getEntries = BuildPlayerEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = GetSelectedPlayerEntry()
                return entry ~= nil and entry.Text or ""
            end,
            isSelected = function(entry) return entry.PlayerIndex == m_SelectedPlayerID end,
            onSelect = function(entry)
                m_SelectedPlayerID = entry.PlayerIndex
                ShowPlayerInfo(entry.PlayerIndex)
            end,
        },
        civ = {
            button = Controls.WorldBuilderTestCivButton,
            getEntries = function() return GetCivEntriesForType(m_SelectedPlayerTypeLevel) end,
            getEntryText = function(entry) return Locale.Lookup(entry.Text) end,
            getLabel = function()
                local entry = GetSelectedCivEntry()
                return entry ~= nil and Locale.Lookup(entry.Text) or ""
            end,
            isSelected = function(entry) return entry.CivilizationType == m_SelectedCivType end,
            onSelect = function(entry)
                m_SelectedCivType = entry.CivilizationType
                SelectDefaultLeaderForCiv(entry)
            end,
        },
        leader = {
            button = Controls.WorldBuilderTestLeaderButton,
            getEntries = function() return m_LeaderEntries end,
            getEntryText = function(entry) return Locale.Lookup(entry.Text) end,
            getLabel = function()
                local entry = GetSelectedLeaderEntry()
                return entry ~= nil and Locale.Lookup(entry.Text) or ""
            end,
            isSelected = function(entry) return entry.LeaderType == m_SelectedLeaderType end,
            onSelect = function(entry)
                m_SelectedLeaderType = entry.LeaderType
            end,
        },
        playerType = {
            button = Controls.WorldBuilderTestTypeButton,
            getEntries = function() return m_PlayerTypeEntries end,
            getEntryText = function(entry) return Locale.Lookup(entry.Text) end,
            getLabel = function()
                local entry = GetSelectedTypeEntry()
                return entry ~= nil and Locale.Lookup(entry.Text) or ""
            end,
            isSelected = function(entry) return entry.LevelType == m_SelectedPlayerTypeLevel end,
            onSelect = function(entry)
                m_SelectedPlayerTypeLevel = entry.LevelType
                RefreshCivSelectionForType()
            end,
        },
        placeRange = {
            button = Controls.WorldBuilderTestRangeButton,
            getEntries = function() return m_PlaceRangeEntries end,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = GetSelectedRangeEntry()
                return entry ~= nil and entry.Text or ""
            end,
            isSelected = function(entry) return entry.Range == m_PlaceRange end,
            onSelect = function(entry)
                m_PlaceRange = entry.Range
            end,
        },
    }
end

-- 按钮动作统一入口：先收起展开的选项列表，动作本身无条件执行，
-- 仅把执行中抛出的错误显示到提示信息小窗。
local function OnAction(name, action)
    return function()
        CloseOptionList()
        local ok, err = pcall(action)
        if not ok then
            SetError(name, err)
        end
    end
end

-- ===========================================================================
-- 玩家信息
-- ===========================================================================

function ShowPlayerInfo(playerID)
    if playerID == nil then return end

    local api = APIModule()
    local playerConfig = PlayerConfigurations[playerID]
    local parts = {}
    if playerConfig ~= nil then
        table.insert(parts, playerConfig:IsHuman()
            and Locale.Lookup("LOC_WORLDBUILDER_HUMAN")
            or Locale.Lookup("LOC_WORLDBUILDER_AI"))
        table.insert(parts, GetLocalizedCivName(playerConfig:GetCivilizationTypeName()))
        table.insert(parts, GetLocalizedLeaderName(playerConfig:GetLeaderTypeName()))
    else
        table.insert(parts, tostring(playerID))
    end

    local initializedOk, initialized = pcall(api.IsPlayerInitialized, playerID)
    if initializedOk then
        table.insert(parts, initialized == true
            and Locale.Lookup("LOC_MODMISC_WB_TEST_INITIALIZED")
            or Locale.Lookup("LOC_MODMISC_WB_TEST_NOT_INITIALIZED"))
    else
        table.insert(parts, tostring(initialized))
    end

    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_INFO", playerID, table.concat(parts, " · ")))
end

-- 面板打开时初始化数据库候选列表与默认选中项
local function InitializeData()
    BuildCivEntries()
    BuildLeaderEntries()
    BuildPlaceRangeEntries()

    RefreshCivSelectionForType()

    if m_SelectedLeaderType == nil then
        local leaderEntry = m_LeaderEntries[1]
        m_SelectedLeaderType = leaderEntry ~= nil and leaderEntry.LeaderType or nil
    end
    if m_SelectedPlayerID == nil then
        local playerEntry = BuildPlayerEntries()[1]
        m_SelectedPlayerID = playerEntry ~= nil and playerEntry.PlayerIndex or nil
    end

    RefreshSelectorButtons()
end

-- 选中玩家（找不到时退回列表第一个）
local function SelectPlayerByID(playerID)
    local entries = BuildPlayerEntries()
    local entry = FindEntryByKey(entries, "PlayerIndex", playerID)
    if entry == nil then
        entry = entries[1]
    end
    m_SelectedPlayerID = entry ~= nil and entry.PlayerIndex or nil
    RefreshSelectorButtons()
end

-- ===========================================================================
-- 地图放置流程（复用 UI/MapButton_UI.lua 的地图按键）
-- ===========================================================================

local function GetCapitalPlot(playerID)
    local player = Players[playerID]
    if player == nil then return nil end
    local cities = player:GetCities()
    if cities == nil then return nil end
    local capital = cities:GetCapitalCity()
    if capital == nil then return nil end
    return Map.GetPlot(capital:GetX(), capital:GetY())
end

-- 锚点：选中玩家的首都 → 本地玩家首都（新玩家还没有城市时）→ 地图中心
local function GetAnchorPlot(playerID)
    local anchorPlot = GetCapitalPlot(playerID)
    if anchorPlot ~= nil then return anchorPlot end

    anchorPlot = GetCapitalPlot(Game.GetLocalPlayer())
    if anchorPlot ~= nil then return anchorPlot end

    local gridWidth, gridHeight = Map.GetGridSize()
    return Map.GetPlot(math.floor(gridWidth / 2), math.floor(gridHeight / 2))
end

-- 候选地块：锚点周围 m_PlaceRange 格（六边形范围，由 gameplay 的 GetPlotsInRange 计算），
-- 只保留陆地；建城时再排除已有城市的地块；按离锚点由近到远排序后截断到 MAX_PLACE_PLOTS，
-- 避免一次生成过多地图按键（实例过多在手机上容易崩）
local function BuildPlacementPlots(playerID, needEmptyCityPlot)
    local anchorPlot = GetAnchorPlot(playerID)
    if anchorPlot == nil then return {} end

    local anchorX, anchorY = anchorPlot:GetX(), anchorPlot:GetY()
    local plotIndexes = ExposedMembers.ModMiscToolScript.GetPlotsInRange(
        anchorX, anchorY, m_PlaceRange)

    local candidates = {}
    for _, plotIndex in ipairs(plotIndexes) do
        local plot = Map.GetPlotByIndex(plotIndex)
        if plot ~= nil and not plot:IsWater() then
            if not needEmptyCityPlot or CityManager.GetCityAt(plot) == nil then
                local deltaX = plot:GetX() - anchorX
                local deltaY = plot:GetY() - anchorY
                table.insert(candidates, {
                    PlotIndex = plotIndex,
                    Distance = deltaX * deltaX + deltaY * deltaY,
                })
            end
        end
    end

    table.sort(candidates, function(a, b) return a.Distance < b.Distance end)

    local result = {}
    for _, candidate in ipairs(candidates) do
        table.insert(result, candidate.PlotIndex)
        if #result >= MAX_PLACE_PLOTS then break end
    end
    return result
end

-- 在指定地块创建单位（unitType 为数据库类型，如 UNIT_SETTLER）
local function CreateUnitAtPlot(playerID, unitType, plotIndex)
    print("[ModMiscTool][WorldBuilderTest] CreateUnit: type=" .. tostring(unitType)
        .. " player=" .. tostring(playerID) .. " plot=" .. tostring(plotIndex))

    if playerID == nil or Players[playerID] == nil then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_NOT_READY"))
        return
    end
    local plot = Map.GetPlotByIndex(plotIndex)
    local unitRow = GameInfo.Units[unitType]
    if plot == nil or unitRow == nil then
        SetError("CreateUnit", "plot or unit type is nil")
        return
    end

    APIModule().CreateUnit(unitRow.Index, playerID, plot)
    SetResult("CreateUnit", unitType .. " @" .. tostring(plotIndex))
end

-- 在地图上显示地块按键；点中后执行 onPlotChosen，然后重新打开面板
local function StartPlotSelection(actionName, icon, tooltipKey, needEmptyCityPlot, onPlotChosen)
    local playerID = GetSelectedPlayerID()
    local plotIndexes = BuildPlacementPlots(playerID, needEmptyCityPlot)
    if #plotIndexes == 0 then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_NO_PLOT"))
        return
    end

    print("[ModMiscTool][WorldBuilderTest] StartPlotSelection: action=" .. tostring(actionName)
        .. " player=" .. tostring(playerID) .. " range=" .. tostring(m_PlaceRange)
        .. " candidates=" .. tostring(#plotIndexes))

    local buttons = {}
    for _, plotIndex in ipairs(plotIndexes) do
        table.insert(buttons, {
            plotIndex = plotIndex,
            icon = icon,
            tooltip = Locale.Lookup(tooltipKey),
            callback = function(chosenPlotIndex)
                ExposedMembers.ModMiscToolUI.HideMapButtons()
                local ok, err = pcall(onPlotChosen, chosenPlotIndex)
                if not ok then
                    SetError(actionName, err)
                end
                OpenWorldBuilderTestPanel()
            end,
        })
    end

    -- 让出地图：先收起面板，再显示地块按键
    Controls.WorldBuilderTestRoot:SetHide(true)
    ExposedMembers.ModMiscToolUI.ShowMapButtons({
        playerID = playerID,
        buttons = buttons,
        icon = icon,
        tooltip = Locale.Lookup(tooltipKey),
        closeTooltip = "LOC_HUD_CLOSE",
        onClose = function()
            ExposedMembers.ModMiscToolUI.HideMapButtons()
            OpenWorldBuilderTestPanel()
        end,
    })
    -- 把镜头移到候选区域：地图按键挂在世界上，不移动镜头玩家可能完全看不到
    local anchorPlot = GetAnchorPlot(playerID)
    if anchorPlot ~= nil then
        UI.LookAtPlot(anchorPlot:GetX(), anchorPlot:GetY())
    end

    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PICK_PLOT", Locale.Lookup(tooltipKey)))
end

-- ===========================================================================
-- 操作：玩家管理
-- ===========================================================================

-- 启用幽灵玩家：把幽灵带回地图（自动进入放置开拓者）。
-- 文明/领袖用它**自己**的（幽灵本来就是某个城邦玩家），不从面板的文明/领袖选项读取；
-- 需要改文明/领袖时再用「更改文明 / 领袖」按钮，避免激活时“夹带”一次 SetPlayerLeader。
local function GetActivateTargetGhostID()
    local playerID = GetSelectedPlayerID()
    if playerID ~= nil and ExposedMembers.ModMiscToolScript.IsGhostPlayer(playerID) then
        return playerID
    end
    local ghosts = ExposedMembers.ModMiscToolScript.GetGhostPlayers()
    return ghosts[1]
end

local function ActivateGhostPlayer()
    local playerID = GetActivateTargetGhostID()
    if playerID == nil then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_NO_GHOST"))
        return
    end

    local playerConfig = PlayerConfigurations[playerID]
    local civType = playerConfig ~= nil and playerConfig:GetCivilizationTypeName() or nil
    local leaderType = playerConfig ~= nil and playerConfig:GetLeaderTypeName() or nil
    print("[ModMiscTool][WorldBuilderTest] ActivateGhost: player=" .. tostring(playerID)
        .. " (own civ=" .. tostring(civType) .. " leader=" .. tostring(leaderType) .. ")")

    m_SelectedPlayerID = playerID
    m_PendingPlayerSelect = playerID
    RefreshSelectorButtons()
    ShowPlayerInfo(playerID)
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_ACTIVATED", playerID,
        GetLocalizedCivName(civType)))

    -- 启用后自动要求放置开拓者
    StartPlotSelection("PlaceSettler", "ICON_UNIT_SETTLER", "LOC_MODMISC_WB_TEST_PLACE_SETTLER", false,
        function(plotIndex)
            CreateUnitAtPlot(playerID, UNIT_TYPE_SETTLER, plotIndex)
        end)
end

-- 回收到地图外：清掉地图上的单位，只留地图外开拓者，槽位重新变回幽灵
local function RecycleGhostPlayer()
    local playerID = GetSelectedPlayerID()
    if playerID == nil then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_NOT_READY"))
        return
    end
    -- 已经建城的玩家不能回收成幽灵：移除全部城市会让玩家直接死亡（开拓者也救不回来），
    -- 所以 gameplay 侧会直接拒绝，这里把拒绝原因显示出来。
    local moved = ExposedMembers.ModMiscToolScript.MovePlayerOffMap(playerID)
    if moved == false then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_RECYCLE_BLOCKED", playerID))
        return
    end
    RefreshSelectorButtons()
    SetResult("MovePlayerOffMap", playerID)
end

-- 幽灵搬移删除方式切换（排障，2026-10-13）：
--   true  = SetDamage(100) + Kill（授权者定的唯一路线，默认）
--   false = 仅 Kill（旧行为）—— 用来复现/排除 teardown 期的
--           GameCore::AI::BehaviorTree::Manager::Reset() 闪退
local function ToggleGhostKillMode()
    local script = ExposedMembers ~= nil and ExposedMembers.ModMiscToolScript or nil
    if script == nil or script.SetGhostDamageBeforeKill == nil then
        SetOutput("ModMiscToolScript.SetGhostDamageBeforeKill 不可用")
        return
    end
    local current = script.GetGhostDamageBeforeKill ~= nil and script.GetGhostDamageBeforeKill()
    local now = script.SetGhostDamageBeforeKill(current ~= true)
    SetOutput("幽灵搬移删除方式：" .. (now and "SetDamage(100) + Kill（默认）" or "仅 Kill（旧行为）"))
end

local function RemovePlayer()
    local playerID = GetSelectedPlayerID()
    if playerID == nil or Players[playerID] == nil then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_NOT_READY"))
        return
    end
    APIModule().RemovePlayer(playerID)
    SelectPlayerByID(nil)
    SetResult("RemovePlayer", playerID)
end

-- 添加玩家：AddPlayer → SetPlayerSlotStatus → SetPlayerLeader → InitializePlayer
-- 一次做完（gameplay 侧的 AddPlayerAndInitialize 负责执行顺序，这里只给身份）。
--
-- ⚠️ **实机结论（2026-10-28）：这条路不可行** —— 补了 InitializePlayer 之后点按钮
--    仍然原生闪退在 GameCore::AI::Diplomatic::GetDiplomaticStateIndex，说明运行时新增
--    玩家缺的不是「玩家对象初始化」，而是引擎在**开局建玩家时**才构造的 AI 外交子系统，
--    Lua 侧没有接口能补。按钮已改 Hidden="1"（XML），入口也已关闭。
--    细节与判定依据见 API_Verification_Status.md §19.37 / #1。
--
-- 保留这个处理函数的原因：代码本身没写错（顺序与防护都对，桩测试 37 项过），
-- 换成别的思路（例如只加人类玩家、先 SetHasMet 再初始化）复测时可以直接复用。
local function AddPlayerWithInitialization()
    local script = ExposedMembers.ModMiscToolScript
    local worldBuilderAPI = script ~= nil and script.WorldBuilderAPI or nil
    if worldBuilderAPI == nil or worldBuilderAPI.AddPlayerAndInitialize == nil then
        SetError("AddPlayer", "WorldBuilderAPI.AddPlayerAndInitialize 不可用")
        return
    end

    local civEntry = GetSelectedCivEntry()
    local leaderEntry = GetSelectedLeaderEntry()
    if civEntry == nil or leaderEntry == nil then
        SetError("AddPlayer", "没有可用的文明/领袖条目")
        return
    end

    -- 决策层（面板）给身份：玩家类型决定文明等级，AI 是本次要验的崩溃路径
    local civLevel = GetSelectedPlayerTypeLevel()
    local isAI = true
    local called, result = pcall(worldBuilderAPI.AddPlayerAndInitialize,
        isAI, leaderEntry.LeaderType, civEntry.CivilizationType, civLevel, true)
    if not called then
        SetError("AddPlayer", result)
        return
    end
    if type(result) ~= "table" then
        SetError("AddPlayer", "返回值不是表：" .. tostring(result))
        return
    end

    local playerID = result.playerID
    print("[ModMiscTool][WorldBuilderTest] AddPlayer: player=" .. tostring(playerID)
        .. " ai=" .. tostring(isAI)
        .. " civ=" .. tostring(civEntry.CivilizationType)
        .. " leader=" .. tostring(leaderEntry.LeaderType)
        .. " level=" .. tostring(civLevel)
        .. " ok=" .. tostring(result.ok)
        .. " wbInit=" .. tostring(result.wbInitialized)
        .. " engineInit=" .. tostring(result.engineInitialized)
        .. " met=" .. tostring(result.metCount)
        .. " reason=" .. tostring(result.reason))

    if playerID == nil or playerID == -1 then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_ADD_PLAYER_FAILED", tostring(result.reason)))
        return
    end

    m_SelectedPlayerID = playerID
    m_PendingPlayerSelect = playerID
    RefreshSelectorButtons()
    ShowPlayerInfo(playerID)

    if not result.ok then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_ADD_PLAYER_FAILED", tostring(result.reason)))
        return
    end

    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_ADD_PLAYER_RESULT",
        tostring(playerID), tostring(result.wbInitialized), tostring(result.engineInitialized),
        tostring(result.metCount)))

    -- 初始化成功 ⇒ 玩家已有运行期对象。立刻放一个开拓者，免得下回合被判“无单位/无城市”而死亡。
    StartPlotSelection("PlaceSettlerForNewPlayer", "ICON_UNIT_SETTLER",
        "LOC_MODMISC_WB_TEST_PLACE_SETTLER", false,
        function(plotIndex)
            CreateUnitAtPlot(playerID, UNIT_TYPE_SETTLER, plotIndex)
        end)
end

-- 把选中的主要文明就地城邦化（验证“给已存在的玩家换身份”这条路）
-- 一次只处理一个玩家，方便一旦出问题能定位到具体是哪一步。
local function ConvertSelectedToCityState()
    local playerID = GetSelectedPlayerID()
    if playerID == nil then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_NOT_READY"))
        return
    end
    local blockReason = nil
    if ExposedMembers.ModMiscToolScript.GetGhostifyBlockReason ~= nil then
        blockReason = ExposedMembers.ModMiscToolScript.GetGhostifyBlockReason(playerID)
    end
    print("[ModMiscTool][WorldBuilderTest] ConvertToCityState: player=" .. tostring(playerID)
        .. " block=" .. tostring(blockReason))
    if blockReason ~= nil then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_RECYCLE_BLOCKED", playerID))
        return
    end
    local converted = ExposedMembers.ModMiscToolScript.ConvertGhostPlayerToCityState(playerID)
    RefreshSelectorButtons()
    print("[ModMiscTool][WorldBuilderTest] ConvertToCityState result=" .. tostring(converted))
    if converted then
        SetResult("ConvertToCityState(ok)", playerID)
    else
        SetResult("ConvertToCityState(failed)", playerID)
    end
end

-- 一键：把所有主流幽灵城邦化（压测“城邦化之后”的行为）
-- 注意 pcall 的返回值错位：pcall(f) -> ok, f返回值1, f返回值2, f返回值3 …
-- ConvertAllGhostMajorPlayersToCityState 返回 (converted, failed, skipped)。
local function ConvertAllGhostsToCityState()
    local api = ExposedMembers.ModMiscToolScript
    if api == nil or api.ConvertAllGhostMajorPlayersToCityState == nil then
        SetError("ConvertAllCityState", "ConvertAllGhostMajorPlayersToCityState 不可用")
        return
    end
    local called, converted, failed, skipped = pcall(api.ConvertAllGhostMajorPlayersToCityState)
    if not called then
        SetError("ConvertAllCityState", converted)
        return
    end
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_CONVERT_ALL_RESULT",
        tostring(converted or 0), tostring(failed or 0), tostring(skipped or 0)))
    RefreshSelectorButtons()
end

-- 见面的幽灵转回主流（授权者 2026-10-15 定位：见面后转城邦 ⇒ 官方城邦面板取不到关系数据 ⇒
-- 面板打不开，而城邦面板是“给城邦派使者”这个回合拦截项的出口 ⇒ 回合卡死）。
-- Api 返回 (恢复数, 本来就是主流数, 失败数)；改完身份按流程存档重读。
local function RestoreMetGhostsAsMajor()
    local api = ExposedMembers.ModMiscToolScript
    if api == nil or api.RestoreMetGhostsAsMajorPlayers == nil then
        SetError("RestoreMetGhosts", "RestoreMetGhostsAsMajorPlayers 不可用")
        return
    end
    local called, restored, skipped, failed = pcall(api.RestoreMetGhostsAsMajorPlayers)
    if not called then
        SetError("RestoreMetGhosts", restored)
        return
    end
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_RESTORE_MET_GHOSTS_RESULT",
        tostring(restored or 0), tostring(skipped or 0), tostring(failed or 0)))
    RefreshSelectorButtons()
end

-- 城邦身份自检/修复：把“城邦玩家 + 主流领袖”这类半成品身份修好
-- 为什么：官方城邦面板用领袖原型取加成文本，取不到会拼接 nil 直接报错 ⇒ 面板打不开。
-- Api 返回 (合规数, 修复数, 失败数) —— 注意 pcall 会在最前面多塞一个成功标志。
local function RepairCityStateIdentity()
    local api = ExposedMembers.ModMiscToolScript
    if api == nil or api.RepairCityStatePlayerIdentities == nil then
        SetError("RepairCityStateIdentity", "RepairCityStatePlayerIdentities 不可用")
        return
    end
    local called, okCount, repaired, failed = pcall(api.RepairCityStatePlayerIdentities)
    if not called then
        SetError("RepairCityStateIdentity", okCount)
        return
    end
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_REPAIR_CITY_STATE_RESULT",
        tostring(okCount or 0), tostring(repaired or 0), tostring(failed or 0)))
    RefreshSelectorButtons()
end

-- 外交压制自检：把两类幽灵池里每个玩家的“压制判定”逐条打出来（压测用）
-- 注：2026-10-15 起城邦幽灵退役（申报 0），默认只有主流池；城邦池只在别的 mod 申报时才有货。
local function CheckDiplomacyGhostSuppression()
    local script = ExposedMembers.ModMiscToolScript
    if script == nil or script.GetGhostPlayers == nil then
        SetError("DiploGhostCheck", "ModMiscToolScript API 不可用")
        return
    end
    local pools = {
        { Kind = "major", Getter = script.GetGhostPlayers },
        { Kind = "citystate", Getter = script.GetCityStateGhostPlayers },
    }
    local lines = {}
    local majorCount, cityCount, suppressed = 0, 0, 0
    for _, pool in ipairs(pools) do
        if pool.Getter ~= nil then
            local ok, ids = pcall(pool.Getter)
            if ok and type(ids) == "table" then
                for _, playerID in ipairs(ids) do
                    -- 压制判定用与外交 UI 完全同一个入口（ExposedMembers.ModMiscToolUI）
                    local isSuppressed = nil
                    local uiMembers = ExposedMembers.ModMiscToolUI
                    if uiMembers ~= nil and uiMembers.IsDiplomacyGhostPlayerUI ~= nil then
                        local okCall, value = pcall(uiMembers.IsDiplomacyGhostPlayerUI, playerID)
                        if okCall then isSuppressed = value end
                    end
                    local available = CallGhostAPI("IsGhostPlayerAvailable", false, playerID)
                    local hasCity = CallGhostAPI("PlayerOwnsCity", false, playerID)
                    if pool.Kind == "major" then majorCount = majorCount + 1
                    else cityCount = cityCount + 1 end
                    if isSuppressed == true then suppressed = suppressed + 1 end
                    table.insert(lines, Locale.Lookup("LOC_MODMISC_WB_TEST_DIPLO_GHOST_CHECK_LINE",
                        tostring(playerID), pool.Kind, tostring(isSuppressed),
                        tostring(available), tostring(hasCity)))
                end
            end
        end
    end
    print("[ModMiscTool][WorldBuilderTest] DiploGhostCheck: major=" .. tostring(majorCount)
        .. " citystate=" .. tostring(cityCount) .. " suppressed=" .. tostring(suppressed))
    local text = Locale.Lookup("LOC_MODMISC_WB_TEST_DIPLO_GHOST_CHECK_RESULT",
        tostring(majorCount), tostring(cityCount), tostring(suppressed))
    if #lines > 0 then text = text .. "\n" .. table.concat(lines, "\n") end
    SetOutput(text)
end

-- 统计当前槽位：引擎建了多少主要文明/城邦、还剩多少空槽位、两类幽灵池里各有多少可用
local function ShowPlayerSlotStats()
    local summary = "n/a"
    if ExposedMembers.ModMiscToolScript.GetPlayerSlotSummary ~= nil then
        summary = tostring(ExposedMembers.ModMiscToolScript.GetPlayerSlotSummary())
    end
    local ghostSummary = ReportGhostPoolSummary()
    print("[ModMiscTool][WorldBuilderTest] PlayerSlots: " .. summary)
    local text = Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_STATS_RESULT", summary)
    if ghostSummary ~= nil then text = text .. "\n" .. ghostSummary end
    SetOutput(text)
end

-- ===========================================================================
-- 操作：文明 / 领袖 / 时代 / 金币 / 信仰 / 可见度
-- ===========================================================================

local function ApplyCivLeader()
    local playerID = GetSelectedPlayerID()
    local civEntry = GetSelectedCivEntry()
    local leaderEntry = GetSelectedLeaderEntry()
    APIModule().SetPlayerLeader(playerID, leaderEntry.LeaderType,
        civEntry.CivilizationType, GetSelectedPlayerTypeLevel())
    ShowPlayerInfo(playerID)
end

-- 设时代按钮已删除（2026-10-28）：WorldBuilderAPI.SetPlayerEra 通道本身可用，
-- 但普通对局里改了不生效 —— API_Verification_Status.md #48，别再加回来。
local function SetPlayerGold()
    APIModule().SetPlayerGold(GetSelectedPlayerID(), 1000)
    SetResult("SetPlayerGold", 1000)
end

local function SetPlayerFaith()
    APIModule().SetPlayerFaith(GetSelectedPlayerID(), 1000)
    SetResult("SetPlayerFaith", 1000)
end

local function SetAllRevealed()
    local playerID = GetSelectedPlayerID()
    APIModule().SetAllRevealed(true, playerID)
    SetResult("SetAllRevealed", playerID)
end

local function ClearPlayerStartingPosition()
    local playerID = GetSelectedPlayerID()
    APIModule().ClearPlayerStartingPosition(playerID)
    SetResult("ClearPlayerStartingPosition", playerID)
end

-- ===========================================================================
-- 操作：地图放置（城市 / 单位）
-- ===========================================================================

local function CreateCity()
    local playerID = GetSelectedPlayerID()
    StartPlotSelection("CreateCity", "ICON_UNITOPERATION_FOUND_CITY", "LOC_MODMISC_WB_TEST_CREATE_CITY", true,
        function(plotIndex)
            print("[ModMiscTool][WorldBuilderTest] CreateCity: player=" .. tostring(playerID)
                .. " plot=" .. tostring(plotIndex))
            if playerID == nil or Players[playerID] == nil then
                SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_NOT_READY"))
                return
            end
            local plot = Map.GetPlotByIndex(plotIndex)
            if plot == nil then
                SetError("CreateCity", "plot is nil")
                return
            end
            APIModule().CreateCity(playerID, plot)
            SetResult("CreateCity", plotIndex)
        end)
end

local function CreateUnit()
    local playerID = GetSelectedPlayerID()
    StartPlotSelection("CreateUnit", "ICON_UNIT_WARRIOR", "LOC_MODMISC_WB_TEST_CREATE_UNIT", false,
        function(plotIndex)
            CreateUnitAtPlot(playerID, UNIT_TYPE_WARRIOR, plotIndex)
        end)
end

local function PlaceSettler()
    local playerID = GetSelectedPlayerID()
    StartPlotSelection("PlaceSettler", "ICON_UNIT_SETTLER", "LOC_MODMISC_WB_TEST_PLACE_SETTLER", false,
        function(plotIndex)
            CreateUnitAtPlot(playerID, UNIT_TYPE_SETTLER, plotIndex)
        end)
end

-- ===========================================================================
-- 屏幕适配（安卓设备默认字号偏小）
--
-- XML 里的尺寸/字号是设计基准（900x760）；打开面板与屏幕尺寸变化时，按实际
-- 屏幕尺寸等比缩放所有控件尺寸、偏移与字号；展开列表的条目按当前缩放创建。
-- ===========================================================================

local DESIGN_WIDTH  = 900
local DESIGN_HEIGHT = 760
local SCREEN_MARGIN = 40
local MIN_SCALE     = 0.85
local MAX_SCALE     = 1.6

local GEOMETRY_CONTROLS = {
    "WorldBuilderTestRoot",
    "WorldBuilderTestHeader",
    "WorldBuilderTestTitle",
    "WorldBuilderTestCloseButton",
    "WorldBuilderTestStatus",
    "WorldBuilderTestPlayerLabel",
    "WorldBuilderTestPlayerButton",
    "WorldBuilderTestCivLabel",
    "WorldBuilderTestCivButton",
    "WorldBuilderTestLeaderLabel",
    "WorldBuilderTestLeaderButton",
    "WorldBuilderTestTypeLabel",
    "WorldBuilderTestTypeButton",
    "WorldBuilderTestRangeLabel",
    "WorldBuilderTestRangeButton",
    "WorldBuilderTestAddPlayer",
    "WorldBuilderTestActivateGhost",
    "WorldBuilderTestRecycleGhost",
    "WorldBuilderTestRemove",
    "WorldBuilderTestApply",
    "WorldBuilderTestCreateCity",
    "WorldBuilderTestCreateUnit",
    "WorldBuilderTestPlaceSettler",
    "WorldBuilderTestClearStart",
    "WorldBuilderTestGold",
    "WorldBuilderTestFaith",
    "WorldBuilderTestReveal",
    "WorldBuilderTestGhostKillMode",
    "WorldBuilderTestDiploGhostCheck",
    "WorldBuilderTestConvertCityState",
    "WorldBuilderTestPlayerStats",
    "WorldBuilderTestConvertAllCityState",
    "WorldBuilderTestRepairCityState",
    "WorldBuilderTestRestoreMetGhosts",
    "WorldBuilderTestMessages",
    "WorldBuilderTestMessageWindow",
    "WorldBuilderTestMessageHeader",
    "WorldBuilderTestMessageTitle",
    "WorldBuilderTestMessageClose",
    "WorldBuilderTestMessageText",
}

local FONT_CONTROLS = {
    "WorldBuilderTestTitle",
    "WorldBuilderTestStatus",
    "WorldBuilderTestPlayerLabel",
    "WorldBuilderTestPlayerButton",
    "WorldBuilderTestCivLabel",
    "WorldBuilderTestCivButton",
    "WorldBuilderTestLeaderLabel",
    "WorldBuilderTestLeaderButton",
    "WorldBuilderTestTypeLabel",
    "WorldBuilderTestTypeButton",
    "WorldBuilderTestRangeLabel",
    "WorldBuilderTestRangeButton",
    "WorldBuilderTestAddPlayer",
    "WorldBuilderTestActivateGhost",
    "WorldBuilderTestRecycleGhost",
    "WorldBuilderTestRemove",
    "WorldBuilderTestApply",
    "WorldBuilderTestCreateCity",
    "WorldBuilderTestCreateUnit",
    "WorldBuilderTestPlaceSettler",
    "WorldBuilderTestClearStart",
    "WorldBuilderTestGold",
    "WorldBuilderTestFaith",
    "WorldBuilderTestReveal",
    "WorldBuilderTestGhostKillMode",
    "WorldBuilderTestDiploGhostCheck",
    "WorldBuilderTestPlayerStats",
    "WorldBuilderTestConvertAllCityState",
    "WorldBuilderTestRepairCityState",
    "WorldBuilderTestRestoreMetGhosts",
    "WorldBuilderTestMessages",
    "WorldBuilderTestMessageTitle",
    "WorldBuilderTestMessageText",
}

local m_BaseLayout = nil
local m_BaseFonts = {}

-- 不同控件类型暴露字号的位置不同，这里两种都试一次（取不到就跳过，不影响其它缩放）
local function GetControlFontSize(control)
    local ok, fontSize = pcall(function() return control:GetFontSize() end)
    if ok and fontSize ~= nil then return fontSize end
    local childOk, childFontSize = pcall(function() return control:GetTextControl():GetFontSize() end)
    if childOk then return childFontSize end
    return nil
end

local function SetControlFontSize(control, fontSize)
    if fontSize == nil or fontSize <= 0 then return end
    local ok = pcall(function() control:SetFontSize(fontSize) end)
    if ok then return end
    pcall(function() control:GetTextControl():SetFontSize(fontSize) end)
end

local function CaptureBaseLayout()
    m_BaseLayout = {}
    m_BaseFonts = {}
    for _, name in ipairs(GEOMETRY_CONTROLS) do
        local control = Controls[name]
        table.insert(m_BaseLayout, {
            control = control,
            sizeX = control:GetSizeX(),
            sizeY = control:GetSizeY(),
            offsetX = control:GetOffsetX(),
            offsetY = control:GetOffsetY(),
        })
    end
    for _, name in ipairs(FONT_CONTROLS) do
        m_BaseFonts[name] = GetControlFontSize(Controls[name])
    end
end

local function GetScreenSize()
    local screenX, screenY = UIManager:GetScreenSizeVal()
    if screenX == nil or screenY == nil or screenX <= 0 or screenY <= 0 then return nil end
    return screenX, screenY
end

-- 以设计基准为 1.0，按“屏幕可用高度/宽度”等比放大，并限制上限避免过度放大
local function ComputeScale(screenX, screenY)
    local scaleByHeight = math.min(screenY - SCREEN_MARGIN, DESIGN_HEIGHT * MAX_SCALE) / DESIGN_HEIGHT
    local scaleByWidth  = math.min(screenX - SCREEN_MARGIN, DESIGN_WIDTH * MAX_SCALE) / DESIGN_WIDTH
    local scale = math.min(scaleByHeight, scaleByWidth)
    return math.max(MIN_SCALE, math.min(MAX_SCALE, scale))
end

local function ApplyScreenScale()
    if m_BaseLayout == nil then CaptureBaseLayout() end

    local screenX, screenY = GetScreenSize()
    if screenX == nil then return end

    local scale = ComputeScale(screenX, screenY)
    if scale == m_AppliedScale then return end
    m_AppliedScale = scale

    for _, entry in ipairs(m_BaseLayout) do
        entry.control:SetSizeVal(math.floor(entry.sizeX * scale + 0.5),
            math.floor(entry.sizeY * scale + 0.5))
        entry.control:SetOffsetVal(math.floor(entry.offsetX * scale + 0.5),
            math.floor(entry.offsetY * scale + 0.5))
    end

    for _, name in ipairs(FONT_CONTROLS) do
        local baseFont = m_BaseFonts[name]
        if baseFont ~= nil then
            SetControlFontSize(Controls[name], math.max(12, math.floor(baseFont * scale + 0.5)))
        end
    end

    Controls.WorldBuilderTestStatus:SetWrapWidth(Controls.WorldBuilderTestStatus:GetSizeX())
    Controls.WorldBuilderTestMessageText:SetWrapWidth(Controls.WorldBuilderTestMessageText:GetSizeX())

    Controls.WorldBuilderTestRoot:ReprocessAnchoring()
    print("[ModMiscTool][WorldBuilderTest] screen=" .. tostring(screenX) .. "x" .. tostring(screenY)
        .. " scale=" .. tostring(scale))
end

function OnWorldBuilderTestSystemUpdateUI(updateType)
    if updateType == SystemUpdateUI.ScreenResize then
        ApplyScreenScale()
    end
end

-- ===========================================================================
-- 面板打开 / 关闭 / 侧栏入口
-- ===========================================================================

-- AddUserInterfaces 载入的子上下文默认隐藏，面板容器挂到 /InGame 下才会显示
-- （与 ExtensiveUnitPanel / MapButton_UI / LeftSideBar 的做法一致），无条件执行。
local function AttachPanelToInGame()
    local panelRoot = Controls.WorldBuilderTestRoot
    local inGameRoot = ContextPtr:LookUpControl("/InGame")
    print("[ModMiscTool][WorldBuilderTest] attach: root=" .. tostring(panelRoot)
        .. " inGameRoot=" .. tostring(inGameRoot))
    panelRoot:ChangeParent(inGameRoot)
    panelRoot:ReprocessAnchoring()
    return panelRoot
end


function OpenWorldBuilderTestPanel()
    local panelRoot = AttachPanelToInGame()
    panelRoot:SetHide(false)
    ApplyScreenScale()
    panelRoot:ReprocessAnchoring()

    InitializeData()
    CloseOptionList()
    local ghostSummary = ReportGhostPoolSummary()
    if ghostSummary ~= nil then PushMessage(ghostSummary) end
    SetStatus(Locale.Lookup("LOC_MODMISC_WB_TEST_READY"))

    print("[ModMiscTool][WorldBuilderTest] panel state: hidden=" .. tostring(panelRoot:IsHidden())
        .. " size=" .. tostring(panelRoot:GetSizeX()) .. "x" .. tostring(panelRoot:GetSizeY()))
end

function CloseWorldBuilderTestPanel()
    Controls.WorldBuilderTestMessageWindow:SetHide(true)
    Controls.WorldBuilderTestOptionPanel:SetHide(true)
    Controls.WorldBuilderTestRoot:SetHide(true)
end

-- 【2026-10-28 授权者：线路关闭】测试面板入口重新关闭。
-- 原因：补了 InitializePlayer 之后，运行时「添加玩家」**仍然原生闪退**在同一符号
--   signal 11 SIGSEGV … GameCore::AI::Diplomatic::GetDiplomaticStateIndex
-- ⇒ InitializePlayer 这条路补不上 AI 外交子系统，运行时造玩家不可行。
-- 面板本体照旧注册（modinfo 的 AddUserInterfaces 不动），只是没有侧栏入口；
-- 要再进来看状态：把这里改回 true。结论见 API_Verification_Status.md §19.37 与 #1。
local MODMISC_WB_TEST_ENTRY_ENABLED = false

function TryRegisterWorldBuilderTestButton()
    if not MODMISC_WB_TEST_ENTRY_ENABLED then return end
    if m_Registered then return end
    if ExposedMembers == nil or ExposedMembers.ModMiscToolUI == nil then return end
    if ExposedMembers.ModMiscToolUI.RegisterSidebarButton == nil then return end

    ExposedMembers.ModMiscToolUI.RegisterSidebarButton(
        "ICON_TECH_ECONOMICS",
        Locale.Lookup("LOC_MODMISC_WB_TEST_TITLE"),
        Locale.Lookup("LOC_MODMISC_WB_TEST_TOOLTIP"),
        OpenWorldBuilderTestPanel)
    m_Registered = true
    print("[ModMiscTool][WorldBuilderTest] sidebar button registered")
end

function OnInit()
    Controls.WorldBuilderTestRoot:SetHide(true)
    Controls.WorldBuilderTestMessageWindow:SetHide(true)
    Controls.WorldBuilderTestOptionPanel:SetHide(true)

    m_OptionIM = InstanceManager:new("WorldBuilderTestOptionEntry", "EntryButton",
        Controls.WorldBuilderTestOptionList)

    Controls.WorldBuilderTestCloseButton:RegisterCallback(Mouse.eLClick, CloseWorldBuilderTestPanel)
    Controls.WorldBuilderTestMessageClose:RegisterCallback(Mouse.eLClick, ToggleMessageWindow)
    Controls.WorldBuilderTestMessages:RegisterCallback(Mouse.eLClick, ToggleMessageWindow)

    BuildSelectors()
    Controls.WorldBuilderTestPlayerButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("player") end)
    Controls.WorldBuilderTestCivButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("civ") end)
    Controls.WorldBuilderTestLeaderButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("leader") end)
    Controls.WorldBuilderTestTypeButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("playerType") end)
    Controls.WorldBuilderTestRangeButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("placeRange") end)

    Controls.WorldBuilderTestActivateGhost:RegisterCallback(Mouse.eLClick,
        OnAction("ActivateGhost", ActivateGhostPlayer))
    Controls.WorldBuilderTestRecycleGhost:RegisterCallback(Mouse.eLClick,
        OnAction("MovePlayerOffMap", RecycleGhostPlayer))
    Controls.WorldBuilderTestRemove:RegisterCallback(Mouse.eLClick, OnAction("RemovePlayer", RemovePlayer))
    Controls.WorldBuilderTestConvertAllCityState:RegisterCallback(Mouse.eLClick,
        OnAction("ConvertAllCityState", ConvertAllGhostsToCityState))
    Controls.WorldBuilderTestDiploGhostCheck:RegisterCallback(Mouse.eLClick,
        OnAction("DiploGhostCheck", CheckDiplomacyGhostSuppression))
    Controls.WorldBuilderTestRepairCityState:RegisterCallback(Mouse.eLClick,
        OnAction("RepairCityStateIdentity", RepairCityStateIdentity))
    Controls.WorldBuilderTestRestoreMetGhosts:RegisterCallback(Mouse.eLClick,
        OnAction("RestoreMetGhosts", RestoreMetGhostsAsMajor))
    if Controls.WorldBuilderTestGhostKillMode ~= nil then
        Controls.WorldBuilderTestGhostKillMode:RegisterCallback(Mouse.eLClick,
            OnAction("GhostKillMode", ToggleGhostKillMode))
    end
    Controls.WorldBuilderTestAddPlayer:RegisterCallback(Mouse.eLClick,
        OnAction("AddPlayer", AddPlayerWithInitialization))
    Controls.WorldBuilderTestConvertCityState:RegisterCallback(Mouse.eLClick,
        OnAction("ConvertToCityState", ConvertSelectedToCityState))
    Controls.WorldBuilderTestPlayerStats:RegisterCallback(Mouse.eLClick,
        OnAction("PlayerSlotStats", ShowPlayerSlotStats))
    Controls.WorldBuilderTestApply:RegisterCallback(Mouse.eLClick, OnAction("SetPlayerLeader", ApplyCivLeader))
    Controls.WorldBuilderTestCreateCity:RegisterCallback(Mouse.eLClick, OnAction("CreateCity", CreateCity))
    Controls.WorldBuilderTestCreateUnit:RegisterCallback(Mouse.eLClick, OnAction("CreateUnit", CreateUnit))
    Controls.WorldBuilderTestPlaceSettler:RegisterCallback(Mouse.eLClick, OnAction("PlaceSettler", PlaceSettler))
    Controls.WorldBuilderTestClearStart:RegisterCallback(Mouse.eLClick,
        OnAction("ClearPlayerStartingPosition", ClearPlayerStartingPosition))
    Controls.WorldBuilderTestGold:RegisterCallback(Mouse.eLClick, OnAction("SetPlayerGold", SetPlayerGold))
    Controls.WorldBuilderTestFaith:RegisterCallback(Mouse.eLClick, OnAction("SetPlayerFaith", SetPlayerFaith))
    Controls.WorldBuilderTestReveal:RegisterCallback(Mouse.eLClick, OnAction("SetAllRevealed", SetAllRevealed))
end

-- 新玩家可能要等引擎下一帧才进入 Players，届时补一次刷新并选中它
local function OnUIIdle()
    if m_PendingPlayerSelect == nil then return end
    local playerID = m_PendingPlayerSelect
    m_PendingPlayerSelect = nil
    SelectPlayerByID(playerID)
end

function OnLoadGameViewStateDone()
    AttachPanelToInGame()
    TryRegisterWorldBuilderTestButton()
end

function OnLocalPlayerTurnBegin()
    TryRegisterWorldBuilderTestButton()
end

-- 地图编辑器里增删玩家后，保持玩家列表同步（与地图编辑器监听的事件一致）。
function OnWorldBuilderPlayerChanged()
    if Controls.WorldBuilderTestRoot:IsHidden() then return end
    SelectPlayerByID(GetSelectedPlayerID())
end

ContextPtr:SetInitHandler(OnInit)
Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
Events.LocalPlayerTurnBegin.Add(OnLocalPlayerTurnBegin)
Events.UIIdle.Add(OnUIIdle)
Events.SystemUpdateUI.Add(OnWorldBuilderTestSystemUpdateUI)
LuaEvents.WorldBuilder_PlayerAdded.Add(OnWorldBuilderPlayerChanged)
LuaEvents.WorldBuilder_PlayerRemoved.Add(OnWorldBuilderPlayerChanged)
LuaEvents.ModMiscToolUIReady.Add(TryRegisterWorldBuilderTestButton)
