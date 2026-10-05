-- ===========================================================================
-- Mod Misc Tool: Automation 系接口测试面板
--
-- 入口：左侧栏按钮（与 WorldBuilder 测试面板同一套 RegisterSidebarButton）。
--
-- 重点测试：
--   1. AutoplayManager：切换任意玩家视角 / 观察者模式 / 停止并回本地玩家
--   2. Network.SaveGame / Network.LoadGame：游戏内存档、读档
--   3. CustomData 探针 + 后台存档：验证 ReadCustomData 是否能随存档回来
--   4. AssetPreview：选择资产、放到指定地块、清除地块/全部资产
--   5. 重开与时间线（第 2 页签）：RestartGame 换图、切换前存档、退回主菜单
--      （ScenarioSetup 的 HostGame 已实测对局内不可用；回合 / 年代 / 地图配置的
--        就地改写也实测不生效 —— 试写按钮都已移除，结论见 API_Verification_Status.md 第 12、13 节）
--
-- 所有接口调用都包在 pcall 里；错误显示在“提示信息”小窗，同时 print 到 Lua.log。
-- ===========================================================================

include("InstanceManager")
include("Civ6Common")  -- ReadCustomData / WriteCustomData（本 mod 的 replacement 版本）
include("ModMiscStore")  -- 跨存档存储（存档名编码通道）：本面板的存储读写按钮用它
include("ModMiscModGroupStore")  -- 跨存档存储（模组配置组名字通道，授权者 2026-10-05 提的方向）
include("ModMiscNameStoreProbe")  -- 探针：引擎设置类键值存储（Options.UserOption / UserConfiguration）
include("ModMiscAssetStore")  -- 永久资产放置（记录落 CustomData，读档自动重放）
include("ModMiscCreateGame")  -- 对局内「创建新局 / 换地图」验证（含开局探针的判定逻辑）
print("[ModMiscTool][AutomationTest] panel loading build=" .. tostring(MODMISC_BUILD_TAG))

-- ===========================================================================
-- 常量 / 状态
-- ===========================================================================

local OPTION_ENTRY_WIDTH  = 620
local OPTION_ENTRY_HEIGHT = 48
local OPTION_ENTRY_FONT   = 24
local OPTION_PANEL_GAP    = 4
local OPTION_ENTRY_PADDING = 3

local PLACE_RANGE = 6
local MAX_PLACE_PLOTS = 120
local MAX_ASSET_ENTRIES = 240


local m_Registered = false
local m_SelectedPlayerIndex = nil
local m_SelectedTurns = -1
local m_SelectedAssetCategoryKey = "CITY"
local m_SelectedAssetEntry = nil
local m_OpenSelectorKey = nil
local m_OptionIM = nil
local m_SelectedMapScript = nil    -- 目标地图脚本条目（创建新局 / 换地图用）
local m_MapScriptEntries = nil     -- 地图清单缓存（探测按钮会清掉重查）
local m_MapScriptSource = nil      -- 清单来源：database / fallback（探测结果里显示）
local m_SavePending = false        -- 「切换前存档」的 SaveComplete 监听是否已挂
local m_ActivePage = "main"        -- 当前页签：main（常规）/ timeline（重开与时间线）

local m_Messages = {}
local MESSAGE_HISTORY_MAX = 8

-- ===========================================================================
-- 日志 / 提示
-- ===========================================================================

-- SetStatus 必须定义在 SetOutputDetail / SetOutput 之前 —— 它们都调它，
-- 而 Lua 5.1 里 local function 不前置声明的话，函数体内的引用会被解析成全局（运行时 nil）。
local function SetStatus(text)
    Controls.AutomationTestStatus:SetText(tostring(text or ""))
end

-- 只有详情没有本地化包装时用这个：detailText 直接进消息窗口与日志（可含换行），
-- shortStatus 放状态行（32px 单行标签，长文本会被截断）。
local function SetOutputDetail(detailText, shortStatus, replaceHistory)
    local message = tostring(detailText or "")
    if replaceHistory then
        -- 存储这类“一次性结论”不该和历史混在一起：混了就会看成
        -- “读了两次出现两条”“清空后还留着一条”。每次只显示本次结果。
        m_Messages = {}
    end
    table.insert(m_Messages, message)
    while #m_Messages > MESSAGE_HISTORY_MAX do
        table.remove(m_Messages, 1)
    end
    SetStatus(shortStatus ~= nil and shortStatus or message)
    Controls.AutomationTestMessageText:SetText(table.concat(m_Messages, "\n"))
    print("[ModMiscTool][AutomationTest] " .. message:gsub("\n", " | "))
end

-- shortStatus：状态行只显示这一行（那是个 32px 高的单行标签，长文本会被截断）；
-- 完整内容进消息窗口（多行）与日志。
local function SetOutput(text, shortStatus)
    local message = tostring(text or "")
    table.insert(m_Messages, message)
    while #m_Messages > MESSAGE_HISTORY_MAX do
        table.remove(m_Messages, 1)
    end
    SetStatus(shortStatus ~= nil and shortStatus or message)
    Controls.AutomationTestMessageText:SetText(table.concat(m_Messages, "\n"))
    print("[ModMiscTool][AutomationTest] " .. message)
end

local function SetResult(name, detail)
    SetOutput(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_RESULT", name, tostring(detail)))
end

local function SetError(name, err)
    SetOutput(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_ERROR", name, tostring(err)))
end

local function ToggleMessageWindow()
    local window = Controls.AutomationTestMessageWindow
    window:SetHide(not window:IsHidden())
end

-- ===========================================================================
-- 通用工具
-- ===========================================================================

local function SafeCall(name, fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        SetError(name, a)
        return false, a
    end
    return true, a, b, c
end

local function GetLocalPlayerSafe()
    local playerID = Game.GetLocalPlayer()
    if playerID == nil or playerID < 0 then return 0 end
    return playerID
end

local function IsPlayerSpecial(playerID)
    return playerID == PlayerTypes.OBSERVER or playerID == PlayerTypes.NONE
end

local function GetPlayerDisplayName(playerID)
    if playerID == PlayerTypes.OBSERVER then
        return Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_OBSERVER")
    end
    if playerID == PlayerTypes.NONE then
        return Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NO_PLAYER")
    end
    local playerConfig = PlayerConfigurations[playerID]
    if playerConfig == nil then return tostring(playerID) end
    local name = playerConfig:GetPlayerName()
    if name == nil or name == "" then
        name = tostring(playerID)
    else
        name = Locale.Lookup(name)
    end
    local civ = playerConfig:GetCivilizationShortDescription()
    if civ == nil or civ == "" then
        civ = playerConfig:GetCivilizationTypeName() or ""
    end
    return string.format("%d · %s · %s", playerID, name, civ)
end

local function GetCapitalPlot(playerID)
    if playerID == nil or IsPlayerSpecial(playerID) then return nil end
    local player = Players[playerID]
    if player == nil then return nil end
    local cities = player:GetCities()
    if cities == nil then return nil end
    local capital = cities:GetCapitalCity()
    if capital == nil then return nil end
    return Map.GetPlot(capital:GetX(), capital:GetY())
end

local function GetAnchorPlot(playerID)
    local anchorPlot = GetCapitalPlot(playerID)
    if anchorPlot ~= nil then return anchorPlot end

    anchorPlot = GetCapitalPlot(GetLocalPlayerSafe())
    if anchorPlot ~= nil then return anchorPlot end

    local gridWidth, gridHeight = Map.GetGridSize()
    return Map.GetPlot(math.floor(gridWidth / 2), math.floor(gridHeight / 2))
end

local function BuildPlacementPlots(playerID)
    local anchorPlot = GetAnchorPlot(playerID)
    if anchorPlot == nil then return {} end

    local anchorX, anchorY = anchorPlot:GetX(), anchorPlot:GetY()
    local plotIndexes = {}
    if ExposedMembers ~= nil and ExposedMembers.ModMiscToolScript ~= nil
        and ExposedMembers.ModMiscToolScript.GetPlotsInRange ~= nil then
        plotIndexes = ExposedMembers.ModMiscToolScript.GetPlotsInRange(anchorX, anchorY, PLACE_RANGE)
    else
        -- 兜底：简单的方形范围，避免面板完全不能用
        for dy = -PLACE_RANGE, PLACE_RANGE do
            for dx = -PLACE_RANGE, PLACE_RANGE do
                local plot = Map.GetPlot(anchorX + dx, anchorY + dy)
                if plot ~= nil then
                    table.insert(plotIndexes, plot:GetIndex())
                end
            end
        end
    end

    local candidates = {}
    for _, plotIndex in ipairs(plotIndexes) do
        local plot = Map.GetPlotByIndex(plotIndex)
        if plot ~= nil and not plot:IsWater() then
            local deltaX = plot:GetX() - anchorX
            local deltaY = plot:GetY() - anchorY
            table.insert(candidates, {
                PlotIndex = plotIndex,
                Distance = deltaX * deltaX + deltaY * deltaY,
            })
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

-- 在地图上显示地块按键；点中后执行 onPlotChosen，然后重新打开面板
local function StartPlotSelection(actionName, icon, tooltipKey, onPlotChosen)
    local playerID = m_SelectedPlayerIndex
    local plotIndexes = BuildPlacementPlots(playerID)
    if #plotIndexes == 0 then
        SetOutput(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NO_PLOT"))
        return
    end

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
                OpenAutomationTestPanel()
            end,
        })
    end

    Controls.AutomationTestRoot:SetHide(true)
    ExposedMembers.ModMiscToolUI.ShowMapButtons({
        playerID = GetLocalPlayerSafe(),
        buttons = buttons,
        icon = icon,
        tooltip = Locale.Lookup(tooltipKey),
        closeTooltip = "LOC_HUD_CLOSE",
        onClose = function()
            ExposedMembers.ModMiscToolUI.HideMapButtons()
            OpenAutomationTestPanel()
        end,
    })
    local anchorPlot = GetAnchorPlot(playerID)
    if anchorPlot ~= nil then
        UI.LookAtPlot(anchorPlot:GetX(), anchorPlot:GetY())
    end
    SetOutput(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_PICK_PLOT", Locale.Lookup(tooltipKey)))
end

-- ===========================================================================
-- 玩家列表 / 回合列表
-- ===========================================================================

local function BuildPlayerEntries()
    local entries = {
        { PlayerIndex = PlayerTypes.OBSERVER, Text = Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_OBSERVER") },
        { PlayerIndex = PlayerTypes.NONE, Text = Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NO_PLAYER") },
    }
    for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
        if Players[playerID] ~= nil then
            table.insert(entries, {
                PlayerIndex = playerID,
                Text = GetPlayerDisplayName(playerID),
            })
        end
    end
    return entries
end

local TURN_OPTIONS = { -1, 1, 5, 10, 25 }
local function GetTurnsText(turns)
    if turns == -1 then
        return Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_TURNS_UNLIMITED")
    end
    return tostring(turns)
end

local function BuildTurnsEntries()
    local entries = {}
    for _, turns in ipairs(TURN_OPTIONS) do
        table.insert(entries, { Turns = turns, Text = GetTurnsText(turns) })
    end
    return entries
end

local function FindEntry(entries, key, value)
    for _, entry in ipairs(entries) do
        if entry[key] == value then return entry end
    end
    return nil
end

-- ===========================================================================
-- Asset 资产列表
-- ===========================================================================

local ASSET_CATEGORIES = {
    { Key = "CITY",          Text = "LOC_MODMISC_AUTOMATION_TEST_ASSET_CITY" },
    { Key = "DISTRICT_BASE", Text = "LOC_MODMISC_AUTOMATION_TEST_ASSET_DISTRICT_BASE" },
    { Key = "BUILDING",      Text = "LOC_MODMISC_AUTOMATION_TEST_ASSET_BUILDING" },
    { Key = "LANDMARK",      Text = "LOC_MODMISC_AUTOMATION_TEST_ASSET_LANDMARK" },
    { Key = "UNIT",          Text = "LOC_MODMISC_AUTOMATION_TEST_ASSET_UNIT" },
}

local function BuildAssetCategoryEntries()
    local entries = {}
    for _, category in ipairs(ASSET_CATEGORIES) do
        table.insert(entries, { Key = category.Key, Text = Locale.Lookup(category.Text) })
    end
    return entries
end

local function GetSelectedPlayerEraIndex()
    local playerID = m_SelectedPlayerIndex
    if playerID == nil or IsPlayerSpecial(playerID) then
        playerID = GetLocalPlayerSafe()
    end
    local player = Players[playerID]
    if player == nil then return 0 end
    local era = player:GetEra()
    if era == nil then return 0 end
    return era
end

local function BuildCityAssetEntries()
    local entries = {}
    local eraIndex = GetSelectedPlayerEraIndex()
    for civ in GameInfo.Civilizations() do
        if civ.Index ~= nil then
            table.insert(entries, {
                Key = "CITY",
                CivIndex = civ.Index,
                EraIndex = eraIndex,
                Text = Locale.Lookup(civ.Name) .. " / " .. tostring(civ.CivilizationType),
            })
        end
        if #entries >= MAX_ASSET_ENTRIES then break end
    end
    return entries
end

local function AssetCall(name, ...)
    if AssetPreview == nil or AssetPreview[name] == nil then
        return false, "AssetPreview." .. tostring(name) .. " is nil"
    end
    return pcall(AssetPreview[name], ...)
end

local function BuildDistrictBaseAssetEntries()
    local entries = {}
    local ok, count = AssetCall("GetDistrictCount")
    if not ok or count == nil then count = 0 end
    for index = 0, count - 1 do
        local nameOk, name = AssetCall("GetDistrictName", index)
        table.insert(entries, {
            Key = "DISTRICT_BASE",
            DistrictIndex = index,
            Text = string.format("[%d] %s", index, tostring(nameOk and name or "?")),
        })
        if #entries >= MAX_ASSET_ENTRIES then break end
    end
    return entries
end

local function BuildBuildingAssetEntries()
    local entries = {}
    local ok, districtCount = AssetCall("GetDistrictCount")
    if not ok or districtCount == nil then districtCount = 0 end
    for districtIndex = 0, math.min(districtCount - 1, 19) do
        local nameOk, districtName = AssetCall("GetDistrictName", districtIndex)
        local listOk, list = AssetCall("GetDistrictBuildingList", districtIndex)
        if listOk and list ~= nil then
            for buildingName, props in pairs(list) do
                table.insert(entries, {
                    Key = "BUILDING",
                    DistrictIndex = districtIndex,
                    BuildingHash = props.bldg,
                    Props = props,
                    Text = string.format("[%s] %s", tostring(nameOk and districtName or districtIndex), tostring(buildingName)),
                })
                if #entries >= MAX_ASSET_ENTRIES then return entries end
            end
        end
    end
    return entries
end

local function BuildLandmarkAssetEntries()
    local entries = {}
    local ok, count = AssetCall("GetLandmarkCount")
    if not ok or count == nil then count = 0 end
    for index = 0, count - 1 do
        local nameOk, name = AssetCall("GetLandmarkName", index)
        table.insert(entries, {
            Key = "LANDMARK",
            LandmarkIndex = index,
            Text = string.format("[%d] %s", index, tostring(nameOk and name or "?")),
        })
        if #entries >= MAX_ASSET_ENTRIES then break end
    end
    return entries
end

local function BuildUnitAssetEntries()
    local entries = {}
    local ok, list = AssetCall("GetUnitList")
    if not ok or list == nil then return entries end
    local names = {}
    for name in pairs(list) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local props = list[name]
        local cultureHash = nil
        if props ~= nil and props.cultures ~= nil then
            for _, hash in pairs(props.cultures) do
                cultureHash = hash
                break
            end
        end
        table.insert(entries, {
            Key = "UNIT",
            UnitHash = props ~= nil and props.hash or nil,
            CultureHash = cultureHash,
            Text = tostring(name),
        })
        if #entries >= MAX_ASSET_ENTRIES then break end
    end
    return entries
end

local function BuildAssetEntries(categoryKey)
    if categoryKey == "CITY" then return BuildCityAssetEntries() end
    if categoryKey == "DISTRICT_BASE" then return BuildDistrictBaseAssetEntries() end
    if categoryKey == "BUILDING" then return BuildBuildingAssetEntries() end
    if categoryKey == "LANDMARK" then return BuildLandmarkAssetEntries() end
    if categoryKey == "UNIT" then return BuildUnitAssetEntries() end
    return {}
end

-- ===========================================================================
-- 目标地图清单（创建新局 / 换地图用）
--
-- 清单来自 ModMiscCreateGame.ListMapScripts()：优先查配置库的 Maps 表（含 DLC/资料片），
-- 查不到才用模块内置的兜底表。这里缓存一份，点「探测」会清掉重查。
-- ===========================================================================

local function BuildMapScriptEntries()
    if m_MapScriptEntries == nil then
        if ModMiscCreateGame == nil then return {} end
        local entries, source = ModMiscCreateGame.ListMapScripts()
        m_MapScriptEntries = entries
        m_MapScriptSource = source
    end
    return m_MapScriptEntries
end

-- 按文件名找回清单里的那一条（注意定义顺序：RefreshMapScriptEntries 会用它，
-- Lua 5.1 里 local function 不前置声明的话，函数体内的引用会被解析成全局 nil）
local function FindMapScriptEntry(mapFile)
    if mapFile == nil then return nil end
    for _, entry in ipairs(BuildMapScriptEntries()) do
        if entry.File == mapFile then return entry end
    end
    return nil
end

-- 重新查一遍清单，并把当前选中的那条重新指到新表里（换过 DLC 之后点「探测」用）
local function RefreshMapScriptEntries()
    local previousFile = m_SelectedMapScript ~= nil and m_SelectedMapScript.File or nil
    m_MapScriptEntries = nil
    m_MapScriptSource = nil
    local entries = BuildMapScriptEntries()
    m_SelectedMapScript = FindMapScriptEntry(previousFile)
    return entries
end

-- 默认选“当前这一局用的地图脚本”；读不到就退到清单第一项
local function SelectFirstMapScriptIfNeeded()
    if m_SelectedMapScript ~= nil then return end
    local entries = BuildMapScriptEntries()
    if entries == nil or #entries == 0 then return end

    local current = nil
    if ModMiscCreateGame ~= nil then
        current = ModMiscCreateGame.GetCurrentMapScript()
    end
    m_SelectedMapScript = FindMapScriptEntry(current)
    if m_SelectedMapScript == nil then
        m_SelectedMapScript = entries[1]
    end
end

-- ===========================================================================
-- 选择器：点击按钮 → 面板内展开列表 → 选中收起
-- ===========================================================================

local m_Selectors = {}
local m_SelectorOrder = { "player", "turns", "assetCategory", "assetIndex", "mapScript",
    "modGroupSize", "modGroupChunkSize" }

local function CloseOptionList()
    Controls.AutomationTestOptionPanel:SetHide(true)
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
    if entries == nil or #entries == 0 then
        SetOutput(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NO_OPTIONS"))
        return
    end

    m_OptionIM:ResetInstances()
    for _, entry in ipairs(entries) do
        local instance = m_OptionIM:GetInstance()
        instance.EntryButton:SetSizeVal(OPTION_ENTRY_WIDTH, OPTION_ENTRY_HEIGHT)
        instance.EntryLabel:SetFontSize(OPTION_ENTRY_FONT)
        instance.EntryLabel:SetTruncateWidth(OPTION_ENTRY_WIDTH - 28)
        instance.EntryLabel:SetText(selector.getEntryText(entry))
        instance.EntryButton:SetSelected(selector.isSelected(entry))
        instance.EntryButton:ClearCallback(Mouse.eLClick)
        instance.EntryButton:RegisterCallback(Mouse.eLClick, function()
            selector.onSelect(entry)
            RefreshSelectorButtons()
            CloseOptionList()
        end)
    end

    local button = selector.button
    local optionX = button:GetOffsetX()
    local buttonY = button:GetOffsetY()
    local optionWidth = button:GetSizeX()
    -- 下方放不下就改向上展开（面板底部的选择器，例如「目标地图」，下方只剩一两行）
    local roomBelow = Controls.AutomationTestRoot:GetSizeY() - (buttonY + button:GetSizeY()) - 20
    local roomAbove = buttonY - OPTION_PANEL_GAP - 10
    local wanted = #entries * (OPTION_ENTRY_HEIGHT + OPTION_ENTRY_PADDING) + 16
    local openUpward = (roomBelow < wanted) and (roomAbove > roomBelow)
    local room = openUpward and roomAbove or roomBelow
    local optionHeight = math.min(wanted, math.max(100, room))
    local optionY = buttonY + button:GetSizeY() + OPTION_PANEL_GAP
    if openUpward then
        optionY = buttonY - optionHeight - OPTION_PANEL_GAP
    end
    if optionY < 10 then optionY = 10 end

    local optionPanel = Controls.AutomationTestOptionPanel
    optionPanel:SetSizeVal(optionWidth, optionHeight)
    optionPanel:SetOffsetVal(optionX, optionY)
    optionPanel:SetHide(false)

    Controls.AutomationTestOptionScroll:CalculateSize()
    Controls.AutomationTestOptionScroll:CalculateInternalSize()
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

local function GetSelectedPlayerEntry()
    return FindEntry(BuildPlayerEntries(), "PlayerIndex", m_SelectedPlayerIndex)
end

local function GetSelectedTurnsEntry()
    return FindEntry(BuildTurnsEntries(), "Turns", m_SelectedTurns)
end

local function GetSelectedAssetCategoryEntry()
    return FindEntry(BuildAssetCategoryEntries(), "Key", m_SelectedAssetCategoryKey)
end

-- 可测尺寸：从小往大；越往后越要小心（值最终落在用户选项文件里）
-- 设置存储（通道 F/G）已实测不可用，面板上不再给它尺寸选择器，固定 4 KB 便于复现结论
local NAMESTORE_PROBE_SIZE = 4096
-- 配置组通道（目前唯一还没被证否的跨存档通道）：尺寸阶梯用来摸上限
local MODGROUP_SIZE_STEPS = { 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576 }
local m_ModGroupSize = 4096

local function FormatByteSize(size)
    if size >= 1048576 and size % 1048576 == 0 then
        return tostring(size / 1048576) .. " MB"
    end
    if size >= 1024 and size % 1024 == 0 then
        return tostring(size / 1024) .. " KB"
    end
    return tostring(size) .. " B"
end

local function BuildModGroupSizeEntries()
    local entries = {}
    for _, size in ipairs(MODGROUP_SIZE_STEPS) do
        table.insert(entries, { Size = size, Text = FormatByteSize(size) })
    end
    return entries
end

local function GetSelectedModGroupSizeEntry()
    return FindEntry(BuildModGroupSizeEntries(), "Size", m_ModGroupSize)
end

local function SelectFirstPlayerIfNeeded()
    if m_SelectedPlayerIndex ~= nil then return end

    -- 默认选本地玩家；本地玩家无效时再退到列表第一项
    local localPlayer = GetLocalPlayerSafe()
    if Players[localPlayer] ~= nil then
        m_SelectedPlayerIndex = localPlayer
        return
    end

    local entries = BuildPlayerEntries()
    if entries[1] ~= nil then
        m_SelectedPlayerIndex = entries[1].PlayerIndex
    end
end

local function BuildSelectors()
    m_Selectors = {
        player = {
            button = Controls.AutomationTestPlayerButton,
            getEntries = BuildPlayerEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = GetSelectedPlayerEntry()
                return entry ~= nil and entry.Text or ""
            end,
            isSelected = function(entry) return entry.PlayerIndex == m_SelectedPlayerIndex end,
            onSelect = function(entry) m_SelectedPlayerIndex = entry.PlayerIndex end,
        },
        turns = {
            button = Controls.AutomationTestTurnsButton,
            getEntries = BuildTurnsEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = GetSelectedTurnsEntry()
                return entry ~= nil and entry.Text or GetTurnsText(m_SelectedTurns)
            end,
            isSelected = function(entry) return entry.Turns == m_SelectedTurns end,
            onSelect = function(entry) m_SelectedTurns = entry.Turns end,
        },
        modGroupChunkSize = {
            button = Controls.AutomationTestModGroupChunkSize,
            getEntries = BuildModGroupChunkEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = GetSelectedModGroupChunkEntry()
                return entry ~= nil and entry.Text or FormatByteSize(m_ModGroupChunkBytes)
            end,
            isSelected = function(entry) return entry.Bytes == m_ModGroupChunkBytes end,
            onSelect = function(entry)
                m_ModGroupChunkBytes = entry.Bytes
                ApplyModGroupChunkBytes()
            end,
        },
        modGroupSize = {
            button = Controls.AutomationTestModGroupSize,
            getEntries = BuildModGroupSizeEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = GetSelectedModGroupSizeEntry()
                return entry ~= nil and entry.Text or FormatByteSize(m_ModGroupSize)
            end,
            isSelected = function(entry) return entry.Size == m_ModGroupSize end,
            onSelect = function(entry) m_ModGroupSize = entry.Size end,
        },
        assetCategory = {
            button = Controls.AutomationTestAssetCategoryButton,
            getEntries = BuildAssetCategoryEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = GetSelectedAssetCategoryEntry()
                return entry ~= nil and entry.Text or ""
            end,
            isSelected = function(entry) return entry.Key == m_SelectedAssetCategoryKey end,
            onSelect = function(entry)
                m_SelectedAssetCategoryKey = entry.Key
                m_SelectedAssetEntry = nil
            end,
        },
        assetIndex = {
            button = Controls.AutomationTestAssetIndexButton,
            getEntries = function() return BuildAssetEntries(m_SelectedAssetCategoryKey) end,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                if m_SelectedAssetEntry ~= nil then
                    return m_SelectedAssetEntry.Text
                end
                return Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_ASSET_NOT_SELECTED")
            end,
            isSelected = function(entry) return entry == m_SelectedAssetEntry end,
            onSelect = function(entry) m_SelectedAssetEntry = entry end,
        },
        mapScript = {
            button = Controls.AutomationCreateGameMapButton,
            getEntries = BuildMapScriptEntries,
            getEntryText = function(entry)
                -- 配置库给的是本地化名时把文件名一起显示出来（SetScript 要的是文件名）
                if entry.Text == nil or entry.Text == entry.File then return entry.File end
                return entry.Text .. " (" .. entry.File .. ")"
            end,
            getLabel = function()
                if m_SelectedMapScript == nil then
                    return Locale.Lookup("LOC_MODMISC_CREATEGAME_MAP_NOT_SELECTED")
                end
                return m_SelectedMapScript.Text
            end,
            isSelected = function(entry)
                return m_SelectedMapScript ~= nil and entry.File == m_SelectedMapScript.File
            end,
            onSelect = function(entry) m_SelectedMapScript = entry end,
        },
    }
end

-- ===========================================================================
-- 视角切换：AutoplayManager
-- ===========================================================================

local function FormatAutoplayState()
    local parts = {}
    if AutoplayManager ~= nil then
        local ok, active = pcall(AutoplayManager.IsActive)
        if ok then table.insert(parts, "active=" .. tostring(active)) end
        local ok2, observe = pcall(AutoplayManager.GetObserveAsPlayer)
        if ok2 then table.insert(parts, "observe=" .. tostring(observe)) end
        local ok3, returnAs = pcall(AutoplayManager.GetReturnAsPlayer)
        if ok3 then table.insert(parts, "return=" .. tostring(returnAs)) end
        local ok4, turns = pcall(AutoplayManager.GetTurns)
        if ok4 then table.insert(parts, "turns=" .. tostring(turns)) end
    end
    return table.concat(parts, " ")
end

local function ApplyAutoplayView(observeAs, actionName)
    if AutoplayManager == nil then
        SetError(actionName, "AutoplayManager is nil")
        return
    end

    local ok, err = pcall(function()
        local returnAs = GetLocalPlayerSafe()
        AutoplayManager.SetActive(false)
        AutoplayManager.SetTurns(m_SelectedTurns)
        AutoplayManager.SetReturnAsPlayer(returnAs)
        AutoplayManager.SetObserveAsPlayer(observeAs)
        AutoplayManager.SetActive(true)
    end)
    if not ok then
        SetError(actionName, err)
        return
    end

    SetResult(actionName, FormatAutoplayState())
end

local function ViewSelectedPlayer()
    local playerID = m_SelectedPlayerIndex
    if playerID == nil then
        SetError("ViewSelectedPlayer", "no player selected")
        return
    end
    if playerID == PlayerTypes.OBSERVER then
        ApplyAutoplayView(PlayerTypes.OBSERVER, "ViewObserver")
    elseif playerID == PlayerTypes.NONE then
        ApplyAutoplayView(PlayerTypes.NONE, "ViewNone")
    else
        ApplyAutoplayView(playerID, "ViewPlayer " .. tostring(playerID))
    end
end

local function ViewObserverMode()
    ApplyAutoplayView(PlayerTypes.OBSERVER, "ViewObserver")
end

local function StopAutoplayAndReturn()
    if AutoplayManager == nil then
        SetError("StopAutoplay", "AutoplayManager is nil")
        return
    end
    local ok, err = pcall(function()
        local localPlayer = GetLocalPlayerSafe()
        AutoplayManager.SetActive(false)
        AutoplayManager.SetObserveAsPlayer(localPlayer)
        AutoplayManager.SetReturnAsPlayer(localPlayer)
    end)
    if not ok then
        SetError("StopAutoplay", err)
        return
    end
    SetResult("StopAutoplay", FormatAutoplayState())
end

local function LookAtSelectedCapital()
    local playerID = m_SelectedPlayerIndex
    if IsPlayerSpecial(playerID) then
        playerID = GetLocalPlayerSafe()
    end
    local plot = GetCapitalPlot(playerID)
    if plot == nil then
        SetError("LookAtCapital", "no capital plot")
        return
    end
    local ok, err = pcall(UI.LookAtPlot, plot:GetX(), plot:GetY())
    if not ok then
        SetError("LookAtCapital", err)
    else
        SetResult("LookAtCapital", playerID)
    end
end

-- ===========================================================================
-- 旧实验的存/读档与 CustomData 探针已全部移除（见下方 [已移除] 说明）
-- ===========================================================================

-- ===========================================================================
-- [已移除] 对局内的存/读档入口（2026-10-04，授权者决定：这些旧实验按键会干扰后续测试）
--   * 读配置档（FileType=GAME_CONFIGURATION）：**直接卡死**，见 API_Verification_Status.md 第 36 条。
--   * 读普通存档（SaveTypes.SINGLE_PLAYER）：能读（LoadScreen + 整局重载），但属于**显式读档**、
--     会把当前局顶掉 —— 要读档走游戏自己的「载入游戏」菜单。
--   * 后台存档 / 探针存档 / 探针读写：CustomData 那批实验已经收尾（第 21、39 条），一并撤掉。
-- 跨存档数据现在只走 UI/ModMiscStore.lua（存档名编码通道，已实机验证）。
-- 需要复现旧实验时从 git 历史取（本文件在提交 b3b1b2a / 本提交 都有完整版本）。
-- ===========================================================================

-- ===========================================================================
-- 恢复 UI：等价于原版调试热键 Shift+Alt+B（安卓没键盘）
--
-- 切视角（AutoplayManager）后点城市 banner，偶尔会让引擎那套引用计数的 BulkHide
-- 卡在“隐藏”态 —— 五大组一起消失。原版留了 Shift+Alt+B 兜底，这里给它一个按钮。
-- 实现放在 UI/Support_UI.lua 并挂到 ExposedMembers，其他 mod 也能直接用。
-- ===========================================================================
local function RestoreInGameUI()
    local api = ExposedMembers ~= nil and ExposedMembers.ModMiscToolUI or nil
    if api == nil or api.RestoreInGameUI == nil then
        SetError("RestoreUI", "ExposedMembers.ModMiscToolUI.RestoreInGameUI 不可用")
        return
    end
    local ok, restored = pcall(api.RestoreInGameUI)
    if not ok then
        SetError("RestoreUI", restored)
        return
    end
    local listing = "(没有隐藏的组)"
    if restored ~= nil and #restored > 0 then
        listing = table.concat(restored, ", ")
    end
    SetResult("RestoreUI", listing)
end

-- ===========================================================================
-- 跨存档存储：写 / 读 / 清（用 ModMiscStore 那套「存档名编码」通道）
--
-- 读是异步的（扫存档列表 → LuaEvents 回结果），所以结果在 OnDataReady 回调里输出。
-- 写入的 payload 带 t/r，跨进程重启后能凭这串判断“读回来的是不是上一轮写的那份”。
-- ===========================================================================
local STORE_PANEL_KEY = "panel"
local STORE_TEST_PAYLOAD_PREFIX = "panel=1"

-- 键值清单：每条一行（消息窗口会换行显示，比一长串逗号好读得多）。
-- 分隔符别用 "|"：实测 Locale.Lookup 的参数里出现 "|" 会把后面整段吃掉。
local function FormatStoreContents()
    local pairs_text = {}
    for key, value in pairs(ModMiscStore.GetAll()) do
        table.insert(pairs_text, "  " .. tostring(key) .. " = " .. tostring(value))
    end
    table.sort(pairs_text)
    return table.concat(pairs_text, "\n")
end

local function CountStoreKeys()
    local count = 0
    for _ in pairs(ModMiscStore.GetAll()) do count = count + 1 end
    return count
end

local function StoreWrite()
    if ModMiscStore == nil then
        SetError("StoreWrite", "ModMiscStore 模块没加载")
        return
    end
    local payload = STORE_TEST_PAYLOAD_PREFIX .. ";t=" .. tostring(os.time())
        .. ";r=" .. tostring(math.random(100000, 999999))
    if not ModMiscStore.Save(STORE_PANEL_KEY, payload) then return end

    -- 只显示“刚写进去的那一条”，格式与读取清单里的行完全一致（都是 "key = value"），
    -- 这样写入与下一次读取可以直接逐行对照。
    local detail = "  " .. STORE_PANEL_KEY .. " = " .. payload
    print("[ModMiscTool][AutomationTest] StoreWrite raw: " .. STORE_PANEL_KEY .. " = " .. payload)
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_STORE_WRITTEN", detail),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_STORE_WRITE_SUMMARY", STORE_PANEL_KEY),
        true)
end

local function ShowStoreContents(actionName)
    local contents = FormatStoreContents()
    local keyCount = CountStoreKeys()
    local header = Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_STORE_HEADER", keyCount)
    SetOutputDetail(header .. (keyCount > 0 and ("\n" .. contents) or "\n  (空)"),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_STORE_SUMMARY", actionName, keyCount),
        true)
end

local function StoreRead()
    if ModMiscStore == nil then
        SetError("StoreRead", "ModMiscStore 模块没加载")
        return
    end
    -- 用 Refresh(onDone)：扫完这一遍再显示。
    -- （别用 OnReady + Refresh —— 已就绪时 OnReady 会立刻回调，显示的是上一次的旧数据）
    ModMiscStore.Refresh(function()
        ShowStoreContents("StoreRead")
    end)
end

local function StoreClear()
    if ModMiscStore == nil then
        SetError("StoreClear", "ModMiscStore 模块没加载")
        return
    end
    -- 「存储清空」= 清空整张存储（不只是 panel 那个键）——
    -- 之前只删 panel，剩下的 ingame/selftest 会让人以为“清空没生效”
    ModMiscStore.RemoveAll()
    -- 删完立刻重扫一遍再显示：否则面板上看到的还是删之前的内容
    ModMiscStore.Refresh(function()
        ShowStoreContents("StoreClear")
    end)
end

-- ===========================================================================
-- ModGroup 存储（把数据写进「模组配置组」的名字）
--
-- 通道来源与安全规矩见 UI/ModMiscModGroupStore.lua 顶部注释（数据库里 Name 是自由文本、
-- 没有改名接口所以改值=删旧建新、只碰自己前缀、永不删当前选中的组）。
-- 这里的按钮只做“调用 + 把结果摊开给人看”，真正的读写都在那个模块里。
-- ===========================================================================
local MODGROUP_PANEL_KEY = "panel"
local MODGROUP_TEST_PAYLOAD_PREFIX = "panel=1"

local function DescribeModGroupInfo(info)
    if info == nil then return "info=nil" end
    local lines = {}
    table.insert(lines, "available=" .. tostring(info.Available)
        .. " build=" .. tostring(info.Tag))
    if info.Error ~= nil then
        table.insert(lines, "error=" .. tostring(info.Error))
        return table.concat(lines, "\n")
    end
    table.insert(lines, "groups=" .. tostring(info.Total)
        .. "  ours=" .. tostring(info.Ours)
        .. "  longestName=" .. tostring(info.MaxNameLength) .. " chars"
        .. "  repeats=" .. tostring(info.Duplicates))
    table.insert(lines, "currentGroup=" .. tostring(info.CurrentHandle)
        .. "  name=" .. tostring(info.CurrentName)
        .. "  isOurs=" .. tostring(info.CurrentIsOurs))
    local ours = ModMiscModGroupStore.ListOurs() or {}
    for index, group in ipairs(ours) do
        if index > 8 then
            table.insert(lines, "  … 还有 " .. tostring(#ours - 8) .. " 条")
            break
        end
        table.insert(lines, "  [" .. tostring(index) .. "] " .. tostring(group.Key)
            .. " #" .. tostring(group.Index) .. " nameLen=" .. tostring(#group.Name))
    end
    return table.concat(lines, "\n")
end

-- 诊断：这个上下文里 Modding 组接口能不能用、现在有几条我们的组、当前选中的是哪个
local function ModGroupInfo()
    if ModMiscModGroupStore == nil then
        SetError("ModGroupInfo", "ModMiscModGroupStore 模块没加载")
        return
    end
    local info = ModMiscModGroupStore.GetInfo()
    local detail = DescribeModGroupInfo(info)
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_INFO_TEXT", detail),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_INFO_SUMMARY",
            tostring(info.Available), tostring(info.Total or "-"), tostring(info.Ours or "-")),
        true)
end

-- 写入：按「配置组尺寸」写一份**长度等于所选尺寸**的数据，并**保留**（不清）。
-- 值里带 os.time()：杀进程重开后点「读取」，看 t= 是不是这一轮那个数字。
-- 面板底部日志会打出「最长名字长度」——名字被截断的话那里会看出来。
local function ModGroupWrite()
    if ModMiscModGroupStore == nil then
        SetError("ModGroupWrite", "ModMiscModGroupStore 模块没加载")
        return
    end
    local size = m_ModGroupSize or 4096
    local head = MODGROUP_TEST_PAYLOAD_PREFIX .. ";t=" .. tostring(os.time())
        .. ";r=" .. tostring(math.random(100000, 999999)) .. ";"
    local payload
    if ModMiscModGroupStore.BuildPayload ~= nil then
        -- 模块的载荷是 "<size>AAA…</e>"；这里要带我们的时间戳，所以自己拼、长度对齐到 size
        payload = head .. string.rep("M", math.max(0, size - #head))
    else
        payload = head
    end
    local ok, chunks, bytes = ModMiscModGroupStore.Save(MODGROUP_PANEL_KEY, payload,
        m_ModGroupChunkBytes)
    if not ok then
        SetError("ModGroupWrite", tostring(chunks))
        return
    end
    -- 写完立刻读回比一遍（同一次运行内），并报出各片的名字长度
    local readBack, readChunks = ModMiscModGroupStore.Load(MODGROUP_PANEL_KEY)
    local matched = (readBack == payload)
    local info = ModMiscModGroupStore.GetInfo()
    local detail = "  写入 " .. tostring(bytes) .. "B / " .. tostring(chunks) .. " 片（每片 "
        .. FormatByteSize(m_ModGroupChunkBytes) .. "），读回 "
        .. tostring(readBack ~= nil and #readBack or 0) .. "B 一致=" .. tostring(matched)
        .. "\n  longestName=" .. tostring(info.MaxNameLength) .. " chars  repeats="
        .. tostring(info.Duplicates) .. "  currentIsOurs=" .. tostring(info.CurrentIsOurs)
        .. "\n  （值已保留：杀进程重开后再点「配置组读取」看 t= 是否还在）"
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_WRITTEN", detail),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_WRITE_SUMMARY",
            FormatByteSize(size), tostring(chunks)),
        true)
end

-- 读取：读回来跟“现在应该是什么”对照（上一轮的 t/r 会明显不同 ⇒ 一眼看出是不是同一轮写的）
local function ModGroupRead()
    if ModMiscModGroupStore == nil then
        SetError("ModGroupRead", "ModMiscModGroupStore 模块没加载")
        return
    end
    local text, chunks = ModMiscModGroupStore.Load(MODGROUP_PANEL_KEY)
    if text == nil then
        SetError("ModGroupRead", tostring(chunks))
        return
    end
    local lines = { "  " .. MODGROUP_PANEL_KEY .. " = " .. text:sub(1, 120)
            .. (#text > 120 and ("…(共 " .. tostring(#text) .. "B)") or ""),
        "  chunks=" .. tostring(chunks) .. " bytes=" .. tostring(#text) }
    -- 顺手列一下现有的数据组（名字长度是判断“有没有被截断”的关键指标）
    local ours = ModMiscModGroupStore.ListOurs() or {}
    for index, group in ipairs(ours) do
        if index > 6 then
            table.insert(lines, "  … 还有 " .. tostring(#ours - 6) .. " 条")
            break
        end
        table.insert(lines, "  [" .. tostring(index) .. "] " .. tostring(group.Key)
            .. " #" .. tostring(group.Index) .. " nameLen=" .. tostring(#group.Name))
    end
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_READ_TEXT",
            table.concat(lines, "\n")),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_READ_SUMMARY",
            MODGROUP_PANEL_KEY, tostring(#text)),
        true)
end

-- 自检：尺寸阶梯 8B→64B→256B→1KB→4KB→16KB，逐级“写-读-比对”，
-- 第一个不一致的尺寸就是上限；跑完自动清理并核对“当前选中的组没被动过”。
local function ModGroupSelfTest()
    if ModMiscModGroupStore == nil then
        SetError("ModGroupSelfTest", "ModMiscModGroupStore 模块没加载")
        return
    end
    local report = ModMiscModGroupStore.SelfTest(nil, m_ModGroupChunkBytes)
    if report.Error ~= nil then
        SetError("ModGroupSelfTest", tostring(report.Error))
        return
    end
    local lines = { "  build=" .. tostring(report.Tag) }
    for _, step in ipairs(report.Steps or {}) do
        table.insert(lines, "  " .. tostring(step.Size) .. "B(payload "
            .. tostring(step.PayloadBytes) .. "B) -> ok=" .. tostring(step.Ok)
            .. " chunks=" .. tostring(step.Chunks)
            .. " read=" .. tostring(step.ReadBytes)
            .. " match=" .. tostring(step.Match)
            .. (step.Error ~= nil and ("  (" .. tostring(step.Error) .. ")") or ""))
    end
    table.insert(lines, "  清理 " .. tostring(report.CleanupRemoved) .. " 条"
        .. "（失败 " .. tostring(report.CleanupFailed) .. " 条）"
        .. "  选中组未被改动=" .. tostring(report.CurrentGroupUnchanged))
    local largest = report.LastSuccess ~= nil and tostring(report.LastSuccess.Size) or "无"
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_SELFTEST_TEXT",
            table.concat(lines, "\n")),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_SELFTEST_SUMMARY",
            largest, tostring(report.CleanupRemoved)),
        true)
end

-- 名字上限：逐级加大**单个组名**，量引擎实际能存多长（回答“modgroupname 能到多大”）
local function ModGroupNameCeiling()
    if ModMiscModGroupStore == nil then
        SetError("ModGroupNameCeiling", "ModMiscModGroupStore 模块没加载")
        return
    end
    if ModMiscModGroupStore.ProbeNameCeiling == nil then
        SetError("ModGroupNameCeiling", "这个模块版本没有 ProbeNameCeiling")
        return
    end
    local report = ModMiscModGroupStore.ProbeNameCeiling()
    if report.Error ~= nil then
        SetError("ModGroupNameCeiling", tostring(report.Error))
        return
    end
    local lines = { "  build=" .. tostring(report.Tag) }
    for _, step in ipairs(report.Steps or {}) do
        table.insert(lines, "  载荷 " .. tostring(step.Payload) .. "B -> 名字 "
            .. tostring(step.NameLength) .. " 字符，读回 " .. tostring(step.ReadNameLength)
            .. " 字符 一致=" .. tostring(step.Match)
            .. (step.Error ~= nil and ("  (" .. tostring(step.Error) .. ")") or ""))
    end
    table.insert(lines, "  清理 " .. tostring(report.CleanupRemoved) .. " 条，选中组未变="
        .. tostring(report.CurrentGroupUnchanged))
    local okName = report.LastSuccess ~= nil and tostring(report.LastSuccess.NameLength) or "无"
    local okPayload = report.LastSuccess ~= nil and tostring(report.LastSuccess.Payload) or "无"
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_NAMECEIL_TEXT",
            table.concat(lines, "\n")),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_NAMECEIL_SUMMARY", okName, okPayload),
        true)
end

-- 清理：删掉本 mod 写在模组配置组里的所有数据（不碰选中组、不碰别人的组）
local function ModGroupClear()
    if ModMiscModGroupStore == nil then
        SetError("ModGroupClear", "ModMiscModGroupStore 模块没加载")
        return
    end
    -- 第 2 个返回值现在是“失败条数”，第 3 个是诊断表（选中组有没有恢复等）
    local removed, reason, failed, info = ModMiscModGroupStore.ClearAll()
    if removed == nil then
        SetError("ModGroupClear", tostring(reason))
        return
    end
    local detail = "  删除 " .. tostring(removed) .. " 条，失败 " .. tostring(failed) .. " 条"
    if info ~= nil then
        detail = detail .. "\n  选中组恢复=" .. tostring(info.CurrentRestored)
            .. "  当前句柄=" .. tostring(info.CurrentHandle)
    end
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_CLEARED", detail),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_MODGROUP_CLEAR_SUMMARY", tostring(removed)),
        true)
end

-- ===========================================================================
-- 引擎设置类键值存储探针（Options.SetUserOption / UserConfiguration.SetValue）
--
-- 本轮（授权者 2026-10-05）先测这两个**玩家界面看不见**的通道；
-- 尺寸可选 + 「写入」会**保留**值，方便“杀进程重开 → 点读取”验证跨进程持久化。
--
-- 详见 UI/ModMiscNameStoreProbe.lua 顶部注释：这两处都是引擎自己会持久化的键值存储，
-- 玩家界面上看不见；本轮只回答“能不能当跨存档通道”。
-- 「读取」按钮是给跨进程验证用的：写完 → 杀进程重开 → 点它看值还在不在（值里带 os.time()）。
-- ===========================================================================
-- 「写入（保留）」：按选中尺寸给两个通道各写一份**长度恰好等于所选尺寸**的载荷。
-- 写进去**不清**，值里带 os.time() —— 杀进程重开后点「读取」，看 t= 是不是这一轮的数字。
local function NameStoreWrite()
    if ModMiscNameStoreProbe == nil then
        SetError("NameStoreWrite", "ModMiscNameStoreProbe 模块没加载")
        return
    end
    local size = NAMESTORE_PROBE_SIZE
    local lines = {}
    local okCount = 0
    for _, channel in ipairs(ModMiscNameStoreProbe.GetChannels()) do
        if not channel.Available then
            table.insert(lines, "  " .. tostring(channel.Id) .. "：不可用")
        else
            local payload = ModMiscNameStoreProbe.BuildPayload(size, channel.Id)
            local ok, err = ModMiscNameStoreProbe.Write(channel.Id, nil, payload)
            if not ok then
                table.insert(lines, "  " .. tostring(channel.Id) .. " 写失败：" .. tostring(err))
            else
                local value, reason = ModMiscNameStoreProbe.Read(channel.Id)
                local matched = (value == payload)
                if matched then okCount = okCount + 1 end
                table.insert(lines, "  " .. tostring(channel.Id) .. " 写入 " .. tostring(#payload)
                    .. "B -> 读回 " .. tostring(value ~= nil and #value or 0) .. "B 一致="
                    .. tostring(matched) .. (reason ~= nil and (" [" .. tostring(reason) .. "]") or ""))
            end
        end
    end
    table.insert(lines, "  （值已保留：杀进程重开后再点「读取」看 t= 是否还在）")
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_WRITTEN_TEXT",
            table.concat(lines, "\n")),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_WRITTEN_SUMMARY",
            FormatByteSize(size), tostring(okCount)),
        true)
end

local function DescribeNameStoreReport(report)
    local lines = { "  " .. tostring(report.Id) .. "（" .. tostring(report.Describe) .. "）" }
    if report.Error ~= nil then
        table.insert(lines, "  error=" .. tostring(report.Error))
        return table.concat(lines, "\n")
    end
    for _, step in ipairs(report.Steps or {}) do
        table.insert(lines, "  " .. tostring(step.Size) .. "B -> ok=" .. tostring(step.Ok)
            .. " read=" .. tostring(step.Read) .. "(" .. tostring(step.Type) .. ")"
            .. " match=" .. tostring(step.Match)
            .. (step.Error ~= nil and ("  (" .. tostring(step.Error) .. ")") or ""))
    end
    table.insert(lines, "  清理探针键=" .. tostring(report.Cleared))
    return table.concat(lines, "\n")
end

local function NameStoreSelfTest()
    if ModMiscNameStoreProbe == nil then
        SetError("NameStoreSelfTest", "ModMiscNameStoreProbe 模块没加载")
        return
    end
    local blocks = {}
    local summary = {}
    for _, channel in ipairs(ModMiscNameStoreProbe.GetChannels()) do
        local report = ModMiscNameStoreProbe.SelfTest(channel.Id)
        table.insert(blocks, DescribeNameStoreReport(report))
        local largest = report.LastSuccess ~= nil and tostring(report.LastSuccess.Size) or "无"
        table.insert(summary, tostring(channel.Id) .. "=" .. largest .. "B")
    end
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_SELFTEST_TEXT",
            table.concat(blocks, "\n")),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_SELFTEST_SUMMARY",
            table.concat(summary, " ")),
        true)
end

-- 读取：两个通道的探针键现在是什么（跨进程验证就看这一条）
local function NameStoreRead()
    if ModMiscNameStoreProbe == nil then
        SetError("NameStoreRead", "ModMiscNameStoreProbe 模块没加载")
        return
    end
    local info = ModMiscNameStoreProbe.GetInfo()
    local lines = {}
    for _, channel in ipairs(info.Channels) do
        if not channel.Available then
            table.insert(lines, "  " .. tostring(channel.Id) .. "：不可用")
        else
            table.insert(lines, "  " .. tostring(channel.Id) .. " = "
                .. tostring(channel.Value) .. (channel.Reason ~= nil and (" [" .. tostring(channel.Reason) .. "]") or ""))
        end
    end
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_READ_TEXT",
            table.concat(lines, "\n")),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_READ_SUMMARY"), true)
end

local function NameStoreClear()
    if ModMiscNameStoreProbe == nil then
        SetError("NameStoreClear", "ModMiscNameStoreProbe 模块没加载")
        return
    end
    local lines = {}
    for _, channel in ipairs(ModMiscNameStoreProbe.GetChannels()) do
        local ok, err = ModMiscNameStoreProbe.Clear(channel.Id)
        table.insert(lines, "  " .. tostring(channel.Id) .. " -> " .. tostring(ok)
            .. (err ~= nil and (" [" .. tostring(err) .. "]") or ""))
    end
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_CLEARED_TEXT",
            table.concat(lines, "\n")),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_NAMESTORE_CLEAR_SUMMARY"), true)
end

-- ===========================================================================
-- AssetPreview：摆放 / 清除
-- ===========================================================================

-- 把“选中的资产”解析成一次具体的 AssetPreview 调用：{ fn = 函数名, args = {…} }
-- 之所以解析完再记（而不是记“选了哪个资产”），是为了读档重放时不必再查资产库，
-- 也就不会因为索引变化放错东西。
local function BuildSelectedAssetCall(plotIndex)
    if m_SelectedAssetEntry == nil then return nil, nil, "no asset selected" end
    local plot = Map.GetPlotByIndex(plotIndex)
    if plot == nil then return nil, nil, "plot is nil" end

    local x, y = plot:GetX(), plot:GetY()
    local entry = m_SelectedAssetEntry
    local category = entry.Key

    if category == "CITY" then
        return "SpoofCityAt", { x, y, entry.CivIndex, entry.EraIndex, 22 }

    elseif category == "DISTRICT_BASE" then
        local listOk, list = AssetCall("GetDistrictBaseList", entry.DistrictIndex)
        local props = nil
        if listOk and list ~= nil then
            for _, value in pairs(list) do props = value; break end
        end
        if props == nil then return nil, nil, "no district base props" end
        return "SpoofDistrictBaseAt",
            { x, y, props.civ, props.era, props.appeal, 0, "Worked", entry.DistrictIndex, props.index }

    elseif category == "BUILDING" then
        local props = entry.Props
        if props == nil then return nil, nil, "no building props" end
        return "SpoofBuildingAt",
            { x, y, props.civ, props.era, props.appeal, "Worked", entry.DistrictIndex, entry.BuildingHash }

    elseif category == "LANDMARK" then
        local listOk, list = AssetCall("GetLandmarkAssetList", entry.LandmarkIndex)
        local props, resourceHash = nil, nil
        if listOk and list ~= nil then
            for _, value in pairs(list) do
                props = value
                if props.resources ~= nil then
                    for hash in pairs(props.resources) do resourceHash = hash; break end
                end
                break
            end
        end
        if props == nil then return nil, nil, "no landmark props" end
        -- nil 换成 0：记录要序列化成一行字符串，数组里不能有空洞；
        -- 0 表示“没有资源”，与原调用语义一致
        return "SpoofLandmarkAt",
            { x, y, props.civ, props.era, props.appeal, resourceHash or 0, "Worked",
              entry.LandmarkIndex, props.variant or 0 }

    elseif category == "UNIT" then
        if entry.UnitHash == nil then return nil, nil, "no unit hash" end
        return "SpoofUnitAt", { x, y, entry.CultureHash or 0, entry.UnitHash }
    end

    return nil, nil, "unknown asset category " .. tostring(category)
end

local function PlaceSelectedAsset(plotIndex)
    local fnName, args, err = BuildSelectedAssetCall(plotIndex)
    if fnName == nil then
        SetError("PlaceAsset", err)
        return
    end

    -- 永久放置：摆出来的同时把这次调用记进 CustomData（随存档保存），
    -- 读档时 ModMiscAssetStore 会自动重放（见 UI/ModMiscAssetStore.lua）。
    local ok, placeErr = ModMiscAssetStore.PlaceAndRecord(fnName, args)
    if not ok then
        SetError("PlaceAsset", placeErr)
        return
    end
    SetResult("PlaceAsset", fnName .. " @plot " .. tostring(plotIndex)
        .. "（已记录 " .. tostring(ModMiscAssetStore.GetCount()) .. " 条）")
end

local function PlaceAsset()
    if AssetPreview == nil then
        SetError("PlaceAsset", "AssetPreview is nil")
        return
    end
    StartPlotSelection("PlaceAsset", "ICON_UNITOPERATION_FOUND_CITY",
        "LOC_MODMISC_AUTOMATION_TEST_PICK_ASSET_PLOT", PlaceSelectedAsset)
end

local function ClearPlotAssetAt(plotIndex)
    local plot = Map.GetPlotByIndex(plotIndex)
    if plot == nil then
        SetError("ClearPlotAsset", "plot is nil")
        return
    end
    local x, y = plot:GetX(), plot:GetY()
    local results = {}

    local ok1, err1 = pcall(AssetPreview.ClearLandmarkAt, x, y)
    table.insert(results, "ClearLandmarkAt=" .. tostring(ok1))
    if not ok1 then print("[ModMiscTool][AutomationTest] ClearLandmarkAt error: " .. tostring(err1)) end

    if AssetPreview.DestroyAt ~= nil then
        local ok2, err2 = pcall(AssetPreview.DestroyAt, x, y)
        table.insert(results, "DestroyAt=" .. tostring(ok2))
        if not ok2 then print("[ModMiscTool][AutomationTest] DestroyAt error: " .. tostring(err2)) end
    end

    -- 记录也要删，否则读档重放会把它又摆回来
    local removed = ModMiscAssetStore ~= nil and ModMiscAssetStore.RemoveAt(x, y) or 0
    table.insert(results, "records=" .. tostring(removed))
    SetResult("ClearPlotAsset", table.concat(results, " "))
end

local function ClearPlotAsset()
    if AssetPreview == nil then
        SetError("ClearPlotAsset", "AssetPreview is nil")
        return
    end
    StartPlotSelection("ClearPlotAsset", "ICON_UNITCOMMAND_CANCEL",
        "LOC_MODMISC_AUTOMATION_TEST_PICK_CLEAR_PLOT", ClearPlotAssetAt)
end

local function ClearAllAssets()
    if AssetPreview == nil then
        SetError("ClearAllAssets", "AssetPreview is nil")
        return
    end
    local results = {}
    local actions = {
        { "ClearLandmarkSystem", function() AssetPreview.ClearLandmarkSystem() end },
        { "ClearUnitSystem", function() AssetPreview.ClearUnitSystem() end },
        { "DestroyAll", function() AssetPreview.DestroyAll() end },
    }
    for _, action in ipairs(actions) do
        local ok, err = pcall(action[2])
        table.insert(results, action[1] .. "=" .. tostring(ok))
        if not ok then print("[ModMiscTool][AutomationTest] " .. action[1] .. " error: " .. tostring(err)) end
    end
    -- 记录一并清空，否则读档时会被重放回来
    if ModMiscAssetStore ~= nil then
        table.insert(results, "records=" .. tostring(ModMiscAssetStore.ClearAllRecords()))
    end
    SetResult("ClearAllAssets", table.concat(results, " "))
end

-- 手动重放（读档时已自动重放一次；这个是给“想立刻再看一眼”用的）
local function ReplayAssets()
    if ModMiscAssetStore == nil then
        SetError("ReplayAssets", "ModMiscAssetStore 模块没加载")
        return
    end
    ModMiscAssetStore.Load()
    local placed = ModMiscAssetStore.RestoreAll()
    SetResult("ReplayAssets", Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_REPLAY_ASSETS_DONE",
        placed, ModMiscAssetStore.GetCount()))
end


-- ===========================================================================
-- 创建新局 / 换地图（对局内）—— 第 2 页签「重开与时间线」
--
-- 2026-10-05 实机结论（授权者）：
--   * `Network.RestartGame()` **可用** —— 对局内重开一局，地图重新生成（换种子），
--     但地图脚本不变（对局内写的 MAP_SCRIPT 不被采纳）。**这就是目前的换图手段。**
--   * `Events.SetGameEntryMethod` + `Network.HostGame(SERVER_TYPE_NONE)`
--     （ScenarioSetup.OnStartButton 的普通分支）**不可用** —— 调用返回、不崩、不建新局。
--     按钮与 ExposedMembers 导出都已移除，只在 UI/ModMiscCreateGame.lua 里留档。
--
-- 接口、判定协议（CustomData 标记）与风险说明见 UI/ModMiscCreateGame.lua；
-- 本面板把入口按风险从低到高摆出来，并在调用前先把「即将调用 …」写进消息窗口与
-- Lua.log —— 进程要是没了，日志最后一行就是它。
-- ===========================================================================

local function RequireCreateGameModule(actionName)
    if ModMiscCreateGame == nil then
        SetError(actionName, "ModMiscCreateGame 模块没加载（ImportFiles 里缺 UI/ModMiscCreateGame.lua？）")
        return false
    end
    return true
end

local function ProbeCreateGame()
    if not RequireCreateGameModule("CreateGameProbe") then return end
    local ok, report = pcall(ModMiscCreateGame.DescribeContext)
    if not ok then
        SetError("CreateGameProbe", report)
        return
    end

    -- 探测是唯一会重新查地图清单的地方（换了 DLC 之后点一下就能刷新）
    local maps = RefreshMapScriptEntries()

    local detail = Locale.Lookup("LOC_MODMISC_CREATEGAME_PROBE_HEADER") .. "\n"
        .. tostring(report) .. "\n"
        .. Locale.Lookup("LOC_MODMISC_CREATEGAME_PROBE_MAPS", #maps, tostring(m_MapScriptSource))
    SetOutputDetail(detail, Locale.Lookup("LOC_MODMISC_CREATEGAME_PROBE_SHORT"), true)
end

local function ArmCreateGameMarker()
    if not RequireCreateGameModule("ArmMarker") then return end
    local ok, payload, err = pcall(ModMiscCreateGame.ArmMarker, "manual")
    if not ok then
        SetError("ArmMarker", payload)
        return
    end
    if payload == nil then
        SetError("ArmMarker", err)
        return
    end
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_CREATEGAME_ARMED") .. "\n  " .. tostring(payload),
        Locale.Lookup("LOC_MODMISC_CREATEGAME_ARMED_SHORT"), true)
end

local function ApplySelectedMapScript()
    if not RequireCreateGameModule("ApplyMapScript") then return end
    local mapFile = m_SelectedMapScript ~= nil and m_SelectedMapScript.File or nil
    if mapFile == nil then
        mapFile = ModMiscCreateGame.GetCurrentMapScript()
    end
    if mapFile == nil then
        SetError("ApplyMapScript", "no map script selected")
        return
    end

    local ok, applied, detail = pcall(ModMiscCreateGame.ApplyMapScript, mapFile)
    if not ok then
        SetError("ApplyMapScript", applied)
        return
    end
    local headerKey = applied and "LOC_MODMISC_CREATEGAME_APPLY_OK" or "LOC_MODMISC_CREATEGAME_APPLY_FAIL"
    local shortKey = applied and "LOC_MODMISC_CREATEGAME_APPLY_SHORT_OK" or "LOC_MODMISC_CREATEGAME_APPLY_SHORT_FAIL"
    SetOutputDetail(Locale.Lookup(headerKey) .. "\n" .. tostring(detail),
        Locale.Lookup(shortKey), true)
end

-- 注意：这是**调试用**的裸存档（固定档名、不带关系）。成品路径是左侧栏「存档与换图」面板
-- 的「存档」按钮（MMT 格式 + 主线/分支关系，见 UI/ModMiscSaveGraph.lua）。
local function SaveBeforeSwitch()
    if not RequireCreateGameModule("SaveBeforeSwitch") then return end
    local ok, saved, detail = pcall(ModMiscCreateGame.SaveBeforeSwitch)
    if not ok then
        SetError("SaveBeforeSwitch", saved)
        return
    end
    if not saved then
        SetError("SaveBeforeSwitch", detail)
        return
    end

    -- 落盘是异步的：挂一次性监听，SaveComplete 回来后把回执写进消息窗口
    if not m_SavePending and Events.SaveComplete ~= nil then
        m_SavePending = true
        local handler = nil
        handler = function(...)
            Events.SaveComplete.Remove(handler)
            m_SavePending = false
            local saveResult = ...
            SetOutputDetail(Locale.Lookup("LOC_MODMISC_CREATEGAME_SAVE_DONE", tostring(saveResult)),
                Locale.Lookup("LOC_MODMISC_CREATEGAME_SAVE_DONE_SHORT"), true)
        end
        Events.SaveComplete.Add(handler)
    end

    SetOutputDetail(Locale.Lookup("LOC_MODMISC_CREATEGAME_SAVE_ISSUED", tostring(detail)),
        Locale.Lookup("LOC_MODMISC_CREATEGAME_SAVE_ISSUED_SHORT"), true)
end

local function RunCreateGameAction(actionName, label, call)
    if not RequireCreateGameModule(actionName) then return end

    -- 先打「即将调用」：调用要是把进程干掉了，面板与 Lua.log 的最后一行就是这条
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_CREATEGAME_CALLING", label),
        Locale.Lookup("LOC_MODMISC_CREATEGAME_CALLING_SHORT"), true)

    local ok, called, detail = pcall(call)
    if not ok then
        SetError(actionName, called)
        return
    end
    if not called then
        SetError(actionName, detail)
        return
    end
    SetOutputDetail(Locale.Lookup("LOC_MODMISC_CREATEGAME_RETURNED", label) .. "\n" .. tostring(detail),
        Locale.Lookup("LOC_MODMISC_CREATEGAME_RETURNED_SHORT"), true)
end

-- ===========================================================================
-- 页签切换
--
-- 面板内容分两页（控件都在同一个 Box 里、绝对定位，靠显隐切换）：
--   main     常规：玩家/回合选择器、视角、镜头、存储、资产
--   timeline 重开与时间线：创建新局 / 换地图 + 回合 / 年代
-- 共享不切换的：头部（含页签）、状态行、提示信息按钮。
-- ===========================================================================

local PAGE_MAIN_CONTROLS = {
    "AutomationTestViewPlayer", "AutomationTestViewObserver", "AutomationTestStopView",
    "AutomationTestLookAtCapital", "AutomationTestRestoreUI", "AutomationTestReplayAssets",
    "AutomationTestStoreWrite", "AutomationTestStoreRead", "AutomationTestStoreClear",
    "AutomationTestAssetCategoryLabel", "AutomationTestAssetCategoryButton",
    "AutomationTestAssetIndexLabel", "AutomationTestAssetIndexButton",
    "AutomationTestPlaceAsset", "AutomationTestClearPlotAsset", "AutomationTestClearAllAssets",
    -- ModGroup 存储（模组配置组名字通道）
    "AutomationTestModGroupLabel", "AutomationTestModGroupSelfTest", "AutomationTestModGroupWrite",
    "AutomationTestModGroupRead", "AutomationTestModGroupInfo", "AutomationTestModGroupClear",
    "AutomationTestModGroupSize", "AutomationTestModGroupNameCeiling", "AutomationTestModGroupChunkSize",
    -- 引擎设置类键值存储探针（Options.SetUserOption / UserConfiguration）
    "AutomationTestNameStoreLabel", "AutomationTestNameStoreWrite",
    "AutomationTestNameStoreSelfTest", "AutomationTestNameStoreRead", "AutomationTestNameStoreClear",
}

local PAGE_TIMELINE_CONTROLS = {
    "AutomationCreateGameMapLabel", "AutomationCreateGameMapButton",
    "AutomationCreateGameProbe", "AutomationCreateGameApplyMap", "AutomationCreateGameArmMarker",
    "AutomationCreateGameSave", "AutomationCreateGameRestart", "AutomationCreateGameExit",
}

local function SetControlGroupHidden(names, hidden)
    for _, name in ipairs(names) do
        local control = Controls[name]
        if control ~= nil then
            control:SetHide(hidden)
        else
            print("[ModMiscTool][AutomationTest] 页签控件缺失: " .. tostring(name))
        end
    end
end

function ShowAutomationPage(pageKey)
    if pageKey ~= "timeline" then pageKey = "main" end
    m_ActivePage = pageKey
    CloseOptionList()

    local showMain = (pageKey == "main")
    SetControlGroupHidden(PAGE_MAIN_CONTROLS, not showMain)
    SetControlGroupHidden(PAGE_TIMELINE_CONTROLS, showMain)
    Controls.AutomationTestTabMain:SetSelected(showMain)
    Controls.AutomationTestTabTimeline:SetSelected(not showMain)
end


-- ===========================================================================
-- 面板打开 / 关闭 / 侧栏入口
-- ===========================================================================

local function AttachPanelToInGame()
    local panelRoot = Controls.AutomationTestRoot
    local inGameRoot = ContextPtr:LookUpControl("/InGame")
    if inGameRoot ~= nil then
        panelRoot:ChangeParent(inGameRoot)
        panelRoot:ReprocessAnchoring()
    end
    return panelRoot
end

function OpenAutomationTestPanel()
    ApplyModGroupChunkBytes()      -- 把面板上的分片大小同步给存储模块
    local panelRoot = AttachPanelToInGame()
    SelectFirstPlayerIfNeeded()
    SelectFirstMapScriptIfNeeded()
    RefreshSelectorButtons()
    ShowAutomationPage(m_ActivePage)
    panelRoot:SetHide(false)
    CloseOptionList()
    SetStatus(Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_READY"))
    print("[ModMiscTool][AutomationTest] panel opened; hidden=" .. tostring(panelRoot:IsHidden()))
end

function CloseAutomationTestPanel()
    Controls.AutomationTestMessageWindow:SetHide(true)
    Controls.AutomationTestOptionPanel:SetHide(true)
    Controls.AutomationTestRoot:SetHide(true)
end

local function TryRegisterAutomationTestButton()
    if m_Registered then return end
    if ExposedMembers == nil or ExposedMembers.ModMiscToolUI == nil then return end
    if ExposedMembers.ModMiscToolUI.RegisterSidebarButton == nil then return end

    ExposedMembers.ModMiscToolUI.RegisterSidebarButton(
        "ICON_TECH_ECONOMICS",
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_TITLE"),
        Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_TOOLTIP"),
        OpenAutomationTestPanel)
    m_Registered = true
    print("[ModMiscTool][AutomationTest] sidebar button registered")
end

function OnInit()
    Controls.AutomationTestRoot:SetHide(true)
    Controls.AutomationTestMessageWindow:SetHide(true)
    Controls.AutomationTestOptionPanel:SetHide(true)

    m_OptionIM = InstanceManager:new("AutomationTestOptionEntry", "EntryButton",
        Controls.AutomationTestOptionList)

    Controls.AutomationTestCloseButton:RegisterCallback(Mouse.eLClick, CloseAutomationTestPanel)
    Controls.AutomationTestMessageClose:RegisterCallback(Mouse.eLClick, ToggleMessageWindow)
    Controls.AutomationTestMessages:RegisterCallback(Mouse.eLClick, ToggleMessageWindow)

    BuildSelectors()
    Controls.AutomationTestPlayerButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("player") end)
    Controls.AutomationTestTurnsButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("turns") end)
    Controls.AutomationTestAssetCategoryButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("assetCategory") end)
    Controls.AutomationTestAssetIndexButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("assetIndex") end)

    Controls.AutomationTestViewPlayer:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ViewSelectedPlayer", ViewSelectedPlayer) end)
    Controls.AutomationTestViewObserver:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ViewObserver", ViewObserverMode) end)
    Controls.AutomationTestStopView:RegisterCallback(Mouse.eLClick,
        function() SafeCall("StopAutoplay", StopAutoplayAndReturn) end)
    Controls.AutomationTestLookAtCapital:RegisterCallback(Mouse.eLClick,
        function() SafeCall("LookAtCapital", LookAtSelectedCapital) end)

    Controls.AutomationTestReplayAssets:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ReplayAssets", ReplayAssets) end)

    Controls.AutomationTestRestoreUI:RegisterCallback(Mouse.eLClick,
        function() SafeCall("RestoreUI", RestoreInGameUI) end)

    Controls.AutomationTestStoreWrite:RegisterCallback(Mouse.eLClick,
        function() SafeCall("StoreWrite", StoreWrite) end)
    Controls.AutomationTestStoreRead:RegisterCallback(Mouse.eLClick,
        function() SafeCall("StoreRead", StoreRead) end)
    Controls.AutomationTestModGroupNameCeiling:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupNameCeiling", ModGroupNameCeiling) end)
    Controls.AutomationTestModGroupChunkSize:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupChunkSize", function() ToggleOptionList("modGroupChunkSize") end) end)
    Controls.AutomationTestModGroupSize:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupSize", function() ToggleOptionList("modGroupSize") end) end)
    Controls.AutomationTestNameStoreWrite:RegisterCallback(Mouse.eLClick,
        function() SafeCall("NameStoreWrite", NameStoreWrite) end)
    Controls.AutomationTestNameStoreSelfTest:RegisterCallback(Mouse.eLClick,
        function() SafeCall("NameStoreSelfTest", NameStoreSelfTest) end)
    Controls.AutomationTestNameStoreRead:RegisterCallback(Mouse.eLClick,
        function() SafeCall("NameStoreRead", NameStoreRead) end)
    Controls.AutomationTestNameStoreClear:RegisterCallback(Mouse.eLClick,
        function() SafeCall("NameStoreClear", NameStoreClear) end)
    Controls.AutomationTestModGroupInfo:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupInfo", ModGroupInfo) end)
    Controls.AutomationTestModGroupSelfTest:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupSelfTest", ModGroupSelfTest) end)
    Controls.AutomationTestModGroupWrite:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupWrite", ModGroupWrite) end)
    Controls.AutomationTestModGroupRead:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupRead", ModGroupRead) end)
    Controls.AutomationTestModGroupClear:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ModGroupClear", ModGroupClear) end)
    Controls.AutomationTestStoreClear:RegisterCallback(Mouse.eLClick,
        function() SafeCall("StoreClear", StoreClear) end)

    -- 旧的存/读档与 CustomData 探针按钮已全部移除（原因见上方 [已移除] 注释）
    Controls.AutomationTestPlaceAsset:RegisterCallback(Mouse.eLClick,
        function() SafeCall("PlaceAsset", PlaceAsset) end)
    Controls.AutomationTestClearPlotAsset:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ClearPlotAsset", ClearPlotAsset) end)
    Controls.AutomationTestClearAllAssets:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ClearAllAssets", ClearAllAssets) end)

    -- 创建新局 / 换地图：按风险从低到高
    Controls.AutomationCreateGameMapButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("mapScript") end)
    Controls.AutomationCreateGameProbe:RegisterCallback(Mouse.eLClick,
        function() SafeCall("CreateGameProbe", ProbeCreateGame) end)
    Controls.AutomationCreateGameApplyMap:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ApplyMapScript", ApplySelectedMapScript) end)
    Controls.AutomationCreateGameArmMarker:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ArmMarker", ArmCreateGameMarker) end)
    Controls.AutomationCreateGameSave:RegisterCallback(Mouse.eLClick,
        function() SafeCall("SaveBeforeSwitch", SaveBeforeSwitch) end)
    Controls.AutomationCreateGameRestart:RegisterCallback(Mouse.eLClick,
        function() SafeCall("RestartGameInGame", function()
            RunCreateGameAction("RestartGameInGame", "Network.RestartGame()", function()
                return ModMiscCreateGame.RestartGame()
            end)
        end) end)
    -- HostGame 按钮已移除：2026-10-05 实机结论 —— 对局内调用是静默空操作（第 43 条）
    Controls.AutomationTestTabMain:RegisterCallback(Mouse.eLClick,
        function() SafeCall("TabMain", function() ShowAutomationPage("main") end) end)
    Controls.AutomationTestTabTimeline:RegisterCallback(Mouse.eLClick,
        function() SafeCall("TabTimeline", function() ShowAutomationPage("timeline") end) end)
    Controls.AutomationCreateGameExit:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ExitToMainMenu", function()
            RunCreateGameAction("ExitToMainMenu", "Events.ExitToMainMenu()", function()
                return ModMiscCreateGame.ExitToMainMenu()
            end)
        end) end)
end

function OnLoadGameViewStateDone()
    AttachPanelToInGame()
    TryRegisterAutomationTestButton()
end

Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
Events.LocalPlayerTurnBegin.Add(TryRegisterAutomationTestButton)
LuaEvents.ModMiscToolUIReady.Add(TryRegisterAutomationTestButton)
ContextPtr:SetInitHandler(OnInit)
