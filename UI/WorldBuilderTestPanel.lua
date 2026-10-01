-- ===========================================================================
-- Mod Misc Tool: WorldBuilder（地图编辑器）接口测试面板
--
-- 通过左侧栏入口打开；在普通对局里直接测试 Gameplay 后端
-- （ModTool_WorldBuilderAPI.lua）提供的 WorldBuilder 接口。
--
--   * 选择器：收起状态是一个按钮（显示当前选择），点击后在本面板内展开选项列表，
--     选中即收起（列表自绘，不依赖引擎下拉弹窗，面板被 reparent 到 /InGame 也能用）
--   * 玩家 / 文明 / 领袖 / 玩家类型（主要文明·城邦）/ 放置范围（2·4·6 格）
--   * 创建城市 / 创建单位 / 放置开拓者：点按钮后在地图上显示地块按键，
--     点中某个地块按键即在该地块执行（复用 UI/MapButton_UI.lua 的地图按键）
--   * 新建玩家后自动进入“放置开拓者”流程
--   * 操作结果与提示放在“提示信息”小窗，主面板不再挤文字
--
-- 接口来自 Gameplay 后端：ModTool_WorldBuilderAPI.lua 由 ModTool.lua include，
-- 再经 ExposedMembers.ModMiscToolScript.WorldBuilderAPI 暴露给本面板。
-- 面板不做任何可用性判定：点击按钮无条件打开，测试功能无条件调用接口，
-- 出错时把原始错误显示在提示信息小窗（同时会进 Lua.log）。
-- ===========================================================================

include("InstanceManager")

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

-- 最新一条显示在顶部状态栏；“提示信息”小窗里保留历史记录（由按钮打开）
local function SetOutput(text)
    local message = tostring(text or "")
    table.insert(m_Messages, message)
    while #m_Messages > MESSAGE_HISTORY_MAX do
        table.remove(m_Messages, 1)
    end
    SetStatus(message)
    Controls.WorldBuilderTestMessageText:SetText(table.concat(m_Messages, "\n"))
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
    local ghostText = ""
    if ExposedMembers.ModMiscToolScript.IsGhostPlayer(playerID) then
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

-- 运行时补建一个幽灵槽位（EXera 路径：空槽位 + PlayerConfigurations + StartCityState）
-- 用于验证“重复文明拦截只在 UI 层、引擎层允许”的假设，不依赖复制数据库
-- 补建失败时把“卡在哪一步”直接显示到消息窗，省得每次都要拉 Lua.log。
-- 注意：跨 context 调用不依赖多返回值，失败原因统一用 getter 取。
local function ReportGhostCreateResult(action, playerID)
    if playerID == nil then
        local reason = "unknown"
        if ExposedMembers.ModMiscToolScript.GetLastGhostCreateDiagnostics ~= nil then
            reason = tostring(ExposedMembers.ModMiscToolScript.GetLastGhostCreateDiagnostics())
        end
        print("[ModMiscTool][WorldBuilderTest] " .. action .. " failed: " .. reason)
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_CREATE_FAILED", reason))
        return
    end
    m_SelectedPlayerID = playerID
    m_PendingPlayerSelect = playerID
    RefreshSelectorButtons()
    print("[ModMiscTool][WorldBuilderTest] " .. action .. " ok: player=" .. tostring(playerID))
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_GHOST_CREATED", playerID))
end

-- 把池子里所有仍是主要文明的幽灵一次性城邦化（开局自动做会导致加载失败，只能进游戏后手动）
local function ConvertAllGhostsToCityState()
    if ExposedMembers.ModMiscToolScript.ConvertAllGhostMajorPlayersToCityState == nil then
        SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_NOT_READY"))
        return
    end
    local converted, total = ExposedMembers.ModMiscToolScript.ConvertAllGhostMajorPlayersToCityState()
    RefreshSelectorButtons()
    print("[ModMiscTool][WorldBuilderTest] ConvertAllGhosts: " .. tostring(converted)
        .. "/" .. tostring(total))
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_CONVERT_ALL_RESULT",
        tostring(converted), tostring(total)))
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

-- 统计当前槽位：引擎建了多少主要文明/城邦、还剩多少空槽位、幽灵池里有多少可用
local function ShowPlayerSlotStats()
    local summary = "n/a"
    if ExposedMembers.ModMiscToolScript.GetPlayerSlotSummary ~= nil then
        summary = tostring(ExposedMembers.ModMiscToolScript.GetPlayerSlotSummary())
    end
    print("[ModMiscTool][WorldBuilderTest] PlayerSlots: " .. summary)
    SetOutput(Locale.Lookup("LOC_MODMISC_WB_TEST_PLAYER_STATS_RESULT", summary))
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

local function SetPlayerEra()
    APIModule().SetPlayerEra(GetSelectedPlayerID(), "ERA_ANCIENT")
    SetResult("SetPlayerEra", "ERA_ANCIENT")
end

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
-- XML 里的尺寸/字号是设计基准（900x860）；打开面板与屏幕尺寸变化时，按实际
-- 屏幕尺寸等比缩放所有控件尺寸、偏移与字号；展开列表的条目按当前缩放创建。
-- ===========================================================================

local DESIGN_WIDTH  = 900
local DESIGN_HEIGHT = 930
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
    "WorldBuilderTestActivateGhost",
    "WorldBuilderTestRecycleGhost",
    "WorldBuilderTestRemove",
    "WorldBuilderTestApply",
    "WorldBuilderTestCreateCity",
    "WorldBuilderTestCreateUnit",
    "WorldBuilderTestPlaceSettler",
    "WorldBuilderTestClearStart",
    "WorldBuilderTestSetEra",
    "WorldBuilderTestGold",
    "WorldBuilderTestFaith",
    "WorldBuilderTestReveal",
    "WorldBuilderTestConvertAllGhosts",
    "WorldBuilderTestConvertCityState",
    "WorldBuilderTestPlayerStats",
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
    "WorldBuilderTestActivateGhost",
    "WorldBuilderTestRecycleGhost",
    "WorldBuilderTestRemove",
    "WorldBuilderTestApply",
    "WorldBuilderTestCreateCity",
    "WorldBuilderTestCreateUnit",
    "WorldBuilderTestPlaceSettler",
    "WorldBuilderTestClearStart",
    "WorldBuilderTestSetEra",
    "WorldBuilderTestGold",
    "WorldBuilderTestFaith",
    "WorldBuilderTestReveal",
    "WorldBuilderTestConvertAllGhosts",
    "WorldBuilderTestPlayerStats",
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
    SetStatus(Locale.Lookup("LOC_MODMISC_WB_TEST_READY"))

    print("[ModMiscTool][WorldBuilderTest] panel state: hidden=" .. tostring(panelRoot:IsHidden())
        .. " size=" .. tostring(panelRoot:GetSizeX()) .. "x" .. tostring(panelRoot:GetSizeY()))
end

function CloseWorldBuilderTestPanel()
    Controls.WorldBuilderTestMessageWindow:SetHide(true)
    Controls.WorldBuilderTestOptionPanel:SetHide(true)
    Controls.WorldBuilderTestRoot:SetHide(true)
end

function TryRegisterWorldBuilderTestButton()
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
    Controls.WorldBuilderTestConvertAllGhosts:RegisterCallback(Mouse.eLClick,
        OnAction("ConvertAllGhosts", ConvertAllGhostsToCityState))
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
    Controls.WorldBuilderTestSetEra:RegisterCallback(Mouse.eLClick, OnAction("SetPlayerEra", SetPlayerEra))
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
