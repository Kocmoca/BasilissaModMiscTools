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
--
-- 所有接口调用都包在 pcall 里；错误显示在“提示信息”小窗，同时 print 到 Lua.log。
-- ===========================================================================

include("InstanceManager")
include("Civ6Common")  -- ReadCustomData / WriteCustomData（本 mod 的 replacement 版本）
include("ModMiscStore")  -- 跨存档存储（存档名编码通道）：本面板的存储读写按钮用它
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

local m_Messages = {}
local MESSAGE_HISTORY_MAX = 30

-- ===========================================================================
-- 日志 / 提示
-- ===========================================================================

local function SetStatus(text)
    Controls.AutomationTestStatus:SetText(tostring(text or ""))
end

local function SetOutput(text)
    local message = tostring(text or "")
    table.insert(m_Messages, message)
    while #m_Messages > MESSAGE_HISTORY_MAX do
        table.remove(m_Messages, 1)
    end
    SetStatus(message)
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
-- 选择器：点击按钮 → 面板内展开列表 → 选中收起
-- ===========================================================================

local m_Selectors = {}
local m_SelectorOrder = { "player", "turns", "assetCategory", "assetIndex" }

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
    local optionY = button:GetOffsetY() + button:GetSizeY() + OPTION_PANEL_GAP
    local optionWidth = button:GetSizeX()
    local available = Controls.AutomationTestRoot:GetSizeY() - optionY - 20
    local wanted = #entries * (OPTION_ENTRY_HEIGHT + OPTION_ENTRY_PADDING) + 16
    local optionHeight = math.min(wanted, math.max(100, available))

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
-- 跨存档存储：写 / 读 / 清（用 ModMiscStore 那套「存档名编码」通道）
--
-- 读是异步的（扫存档列表 → LuaEvents 回结果），所以结果在 OnDataReady 回调里输出。
-- 写入的 payload 带 t/r，跨进程重启后能凭这串判断“读回来的是不是上一轮写的那份”。
-- ===========================================================================
local STORE_PANEL_KEY = "panel"
local STORE_TEST_PAYLOAD_PREFIX = "panel=1"

local function FormatStoreContents()
    local pairs_text = {}
    for key, value in pairs(ModMiscStore.GetAll()) do
        table.insert(pairs_text, tostring(key) .. "=" .. tostring(value))
    end
    table.sort(pairs_text)
    if #pairs_text == 0 then return "(空)" end
    return table.concat(pairs_text, " | ")
end

local function StoreWrite()
    if ModMiscStore == nil then
        SetError("StoreWrite", "ModMiscStore 模块没加载")
        return
    end
    local payload = STORE_TEST_PAYLOAD_PREFIX .. ";t=" .. tostring(os.time())
        .. ";r=" .. tostring(math.random(100000, 999999))
    if ModMiscStore.Save(STORE_PANEL_KEY, payload) then
        SetResult("StoreWrite", STORE_PANEL_KEY .. "=" .. payload)
    end
end

local function StoreRead()
    if ModMiscStore == nil then
        SetError("StoreRead", "ModMiscStore 模块没加载")
        return
    end
    ModMiscStore.OnReady(function()
        SetResult("StoreRead", Locale.Lookup("LOC_MODMISC_AUTOMATION_TEST_STORE_CONTENT",
            FormatStoreContents()))
    end)
    ModMiscStore.Refresh()
end

local function StoreClear()
    if ModMiscStore == nil then
        SetError("StoreClear", "ModMiscStore 模块没加载")
        return
    end
    ModMiscStore.Remove(STORE_PANEL_KEY)
    SetResult("StoreClear", STORE_PANEL_KEY)
end

-- ===========================================================================
-- AssetPreview：摆放 / 清除
-- ===========================================================================

local function PlaceSelectedAsset(plotIndex)
    if m_SelectedAssetEntry == nil then
        SetError("PlaceAsset", "no asset selected")
        return
    end
    local plot = Map.GetPlotByIndex(plotIndex)
    if plot == nil then
        SetError("PlaceAsset", "plot is nil")
        return
    end
    local x, y = plot:GetX(), plot:GetY()
    local entry = m_SelectedAssetEntry
    local category = entry.Key
    local ok, err

    if category == "CITY" then
        ok, err = pcall(AssetPreview.SpoofCityAt, x, y, entry.CivIndex, entry.EraIndex, 22)
    elseif category == "DISTRICT_BASE" then
        local listOk, list = AssetCall("GetDistrictBaseList", entry.DistrictIndex)
        local props = nil
        if listOk and list ~= nil then
            for _, value in pairs(list) do props = value; break end
        end
        if props == nil then
            SetError("PlaceAsset", "no district base props")
            return
        end
        ok, err = pcall(AssetPreview.SpoofDistrictBaseAt, x, y,
            props.civ, props.era, props.appeal, 0, "Worked", entry.DistrictIndex, props.index)
    elseif category == "BUILDING" then
        local props = entry.Props
        if props == nil then
            SetError("PlaceAsset", "no building props")
            return
        end
        ok, err = pcall(AssetPreview.SpoofBuildingAt, x, y,
            props.civ, props.era, props.appeal, "Worked", entry.DistrictIndex, entry.BuildingHash)
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
        if props == nil then
            SetError("PlaceAsset", "no landmark props")
            return
        end
        ok, err = pcall(AssetPreview.SpoofLandmarkAt, x, y,
            props.civ, props.era, props.appeal, resourceHash, "Worked", entry.LandmarkIndex, props.variant)
    elseif category == "UNIT" then
        local unitHash = entry.UnitHash
        local cultureHash = entry.CultureHash or 0
        if unitHash == nil then
            SetError("PlaceAsset", "no unit hash")
            return
        end
        ok, err = pcall(AssetPreview.SpoofUnitAt, x, y, cultureHash, unitHash)
    else
        SetError("PlaceAsset", "unknown asset category " .. tostring(category))
        return
    end

    if not ok then
        SetError("PlaceAsset", err)
    else
        SetResult("PlaceAsset", category .. " @" .. tostring(plotIndex))
    end
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
    SetResult("ClearAllAssets", table.concat(results, " "))
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
    local panelRoot = AttachPanelToInGame()
    SelectFirstPlayerIfNeeded()
    RefreshSelectorButtons()
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

    Controls.AutomationTestStoreWrite:RegisterCallback(Mouse.eLClick,
        function() SafeCall("StoreWrite", StoreWrite) end)
    Controls.AutomationTestStoreRead:RegisterCallback(Mouse.eLClick,
        function() SafeCall("StoreRead", StoreRead) end)
    Controls.AutomationTestStoreClear:RegisterCallback(Mouse.eLClick,
        function() SafeCall("StoreClear", StoreClear) end)

    -- 旧的存/读档与 CustomData 探针按钮已全部移除（原因见上方 [已移除] 注释）
    Controls.AutomationTestPlaceAsset:RegisterCallback(Mouse.eLClick,
        function() SafeCall("PlaceAsset", PlaceAsset) end)
    Controls.AutomationTestClearPlotAsset:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ClearPlotAsset", ClearPlotAsset) end)
    Controls.AutomationTestClearAllAssets:RegisterCallback(Mouse.eLClick,
        function() SafeCall("ClearAllAssets", ClearAllAssets) end)
end

function OnLoadGameViewStateDone()
    AttachPanelToInGame()
    TryRegisterAutomationTestButton()
end

Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
Events.LocalPlayerTurnBegin.Add(TryRegisterAutomationTestButton)
LuaEvents.ModMiscToolUIReady.Add(TryRegisterAutomationTestButton)
ContextPtr:SetInitHandler(OnInit)
