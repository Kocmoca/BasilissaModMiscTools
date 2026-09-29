-- ExtensiveUnitPanel: 扩展建造操作面板
-- 在 StandardActionsStack 添加按钮，点击后打开最大 1200x900（按屏幕自适应）的面板
-- BuildRange > 0 时在地图显示选择按钮（Norn 模式）
-- 2列网格布局，每行放置2个entry
-- ===========================================================================

include("InstanceManager")
include("SupportFunctions")

-- ===========================================================================
-- CONSTANTS
-- ===========================================================================
local COLUMN_COUNT = 2

local PANEL_MAX_WIDTH  = 1200
local PANEL_MAX_HEIGHT = 900
local PANEL_MARGIN_X   = 80
local PANEL_MARGIN_Y   = 80

local MAP_SELECT_LENS_COLOR = UI.GetColorValue(0, 150 / 255, 255 / 255, 120 / 255)

-- ===========================================================================
-- MEMBERS
-- ===========================================================================
local m_bIsPanelOpen = false
local m_SelectedPlayerID = -1
local m_SelectedUnitID = -1

-- 2列 InstanceManager
local m_CaseEntryColumnIMs = {}
local m_CustomButtonColumnIMs = {}
local m_MapSelectIM = nil

-- 列索引轮询
local m_CaseColIndex = 0
local m_CustomColIndex = 0

local m_RegisteredCustomButtons = {}
local m_uiWorldMapTable = {}
local m_ActiveCaseType = nil
local m_MapSelectLensLayer = nil
local m_PhoneButtonResized = false

-- ===========================================================================
-- HELPERS
-- ===========================================================================

function NextColIndex()
    m_CaseColIndex = m_CaseColIndex + 1
    if m_CaseColIndex > COLUMN_COUNT then m_CaseColIndex = 1 end
    return m_CaseColIndex
end

function NextCustomColIndex()
    m_CustomColIndex = m_CustomColIndex + 1
    if m_CustomColIndex > COLUMN_COUNT then m_CustomColIndex = 1 end
    return m_CustomColIndex
end

function ResetAllColumns()
    for i = 1, COLUMN_COUNT do
        if m_CaseEntryColumnIMs[i] then m_CaseEntryColumnIMs[i]:ResetInstances() end
        if m_CustomButtonColumnIMs[i] then m_CustomButtonColumnIMs[i]:ResetInstances() end
    end
    m_CaseColIndex = 0
    m_CustomColIndex = 0
end

-- ===========================================================================
-- 注册控件到父容器
-- ===========================================================================

-- 让小分辨率下也能完整显示面板；同时让全屏容器覆盖屏幕，保证 ClearMapButton 定位正确。
function ResizeUnitPanel()
    if Controls.ExtensiveUnitPanelMain == nil then return end

    local screenX, screenY = UIManager:GetScreenSizeVal()
    if screenX == nil or screenY == nil or screenX <= 0 or screenY <= 0 then return end

    local panelWidth = math.min(PANEL_MAX_WIDTH, screenX - PANEL_MARGIN_X)
    local panelHeight = math.min(PANEL_MAX_HEIGHT, screenY - PANEL_MARGIN_Y)
    if panelWidth < 640 then panelWidth = math.min(screenX, 640) end
    if panelHeight < 480 then panelHeight = math.min(screenY, 480) end

    Controls.ExtensiveUnitPanelMain:SetSizeVal(panelWidth, panelHeight)
    Controls.ExtensiveUnitPanelMain:ReprocessAnchoring()

    if Controls.FullScreenContainer ~= nil then
        Controls.FullScreenContainer:SetSizeVal(screenX, screenY)
        Controls.FullScreenContainer:ReprocessAnchoring()
    end

    RefreshCaseColumnLayout()
end

-- 根据滚动区实际宽度动态分配列宽，避免 2/3 列内容被裁切。
function RefreshCaseColumnLayout()
    if Controls.CaseScrollPanel == nil or Controls.CaseRow == nil then return end

    local scrollWidth = Controls.CaseScrollPanel:GetSizeX() or 0
    if scrollWidth <= 0 then return end

    local colWidth = math.floor((scrollWidth - 24) / COLUMN_COUNT)
    if colWidth <= 0 then return end

    for i = 1, COLUMN_COUNT do
        local col = Controls["CaseColumn" .. i]
        if col ~= nil then
            col:SetSizeX(colWidth)
        end
    end

    Controls.CaseRow:CalculateSize()
    Controls.CaseScrollPanel:CalculateInternalSize()
end

function OnSystemUpdateUI(type)
    if type == SystemUpdateUI.ScreenResize then
        ResizeUnitPanel()
    end
end

function Initialize()
    -- 创建 2列 InstanceManager
    for i = 1, COLUMN_COUNT do
        local colStack = Controls["CaseColumn" .. i]
        if colStack ~= nil then
            m_CaseEntryColumnIMs[i] = InstanceManager:new(
                "CaseEntryInstance", "Entry", colStack)
            m_CustomButtonColumnIMs[i] = InstanceManager:new(
                "CustomButtonInstance", "Entry", colStack)
        end
    end
    m_MapSelectIM = InstanceManager:new("MapSelectInstance", "SelectAnchor", Controls.MapSelectContainer)

    local inGameContext = ContextPtr:LookUpControl("/InGame")
    local worldViewControls = ContextPtr:LookUpControl("/InGame/WorldViewControls")
    local standardActionsStack = ContextPtr:LookUpControl("/InGame/UnitPanel/StandardActionsStack")

    if inGameContext ~= nil then
        Controls.ExtensiveUnitPanelMain:ChangeParent(inGameContext)
        Controls.FullScreenContainer:ChangeParent(inGameContext)
    else
        print("ExtensiveUnitPanel: /InGame control not found")
    end
    if worldViewControls ~= nil then
        Controls.MapSelectContainer:ChangeParent(worldViewControls)
    else
        print("ExtensiveUnitPanel: /InGame/WorldViewControls control not found")
    end
    if standardActionsStack ~= nil then
        Controls.ExtensiveUnitGrid:ChangeParent(standardActionsStack)
    else
        print("ExtensiveUnitPanel: /InGame/UnitPanel/StandardActionsStack control not found")
    end

    Controls.ExtensiveUnitButton:RegisterCallback(Mouse.eLClick, OnPanelToggleButtonClicked)
    Controls.CloseButton:RegisterCallback(Mouse.eLClick, ClosePanel)
    Controls.ClearMapButton:RegisterCallback(Mouse.eLClick, OnClearMapButtonClicked)

    m_MapSelectLensLayer = UILens.CreateLensLayerHash("Hex_Coloring_Movement")
    ResizeUnitPanel()

    Events.UnitSelectionChanged.Add(OnUnitSelectionChanged)
    Events.UnitMoveComplete.Add(OnUnitMoveComplete)
    Events.SystemUpdateUI.Add(OnSystemUpdateUI)

    if not ExposedMembers.ModMiscToolUI then
        ExposedMembers.ModMiscToolUI = {}
    end
    ExposedMembers.ModMiscToolUI.RegisterExtensiveUnitCustomButton = RegisterCustomButton
    ExposedMembers.ModMiscToolUI.OpenExtensiveUnitPanel = OpenPanel
    ExposedMembers.ModMiscToolUI.CloseExtensiveUnitPanel = ClosePanel
    ExposedMembers.ModMiscToolUI.ResizeExtensiveUnitButtonForPhone = ResizeExtensiveUnitButtonForPhone

    -- 通知其他 mod 的 UI：ExtensiveUnitPanel 的扩展按钮注册接口已就绪。
    LuaEvents.ModMiscToolExtensiveUnitPanelReady.Call()

    -- 读档/热加载后如果已经有选中单位，立即补上操作按钮
    local selectedUnit = UI.GetHeadSelectedUnit()
    if selectedUnit ~= nil then
        RefreshButton(selectedUnit:GetOwner(), selectedUnit:GetID())
    else
        Controls.ExtensiveUnitGrid:SetHide(true)
    end

    print("ExtensiveUnitPanel: Initialized")
end
Events.LoadGameViewStateDone.Add(Initialize)

-- ===========================================================================
-- 单位选择/移动 -> 刷新按钮显隐 / 同步面板内容
-- ===========================================================================

-- 手机尺寸下，SetIcon 后需要重新应用图标/按钮尺寸。
local function ApplyPhoneButtonSizeIfNeeded()
    if not m_PhoneButtonResized then return end
    if Controls.ExtensiveUnitGrid == nil or Controls.ExtensiveUnitButton == nil then return end

    Controls.ExtensiveUnitGrid:SetSizeX(112)
    Controls.ExtensiveUnitGrid:SetSizeY(135)
    Controls.ExtensiveUnitButton:SetSizeX(112)
    Controls.ExtensiveUnitButton:SetSizeY(135)

    if Controls.ExtensiveUnitButtonIcon ~= nil then
        Controls.ExtensiveUnitButtonIcon:SetSizeX(97)
        Controls.ExtensiveUnitButtonIcon:SetSizeY(97)
        Controls.ExtensiveUnitButtonIcon:SetOffsetY(-5)
    end

    Controls.ExtensiveUnitGrid:CalculateSize()
    Controls.ExtensiveUnitGrid:ReprocessAnchoring()
end

-- 将单位操作入口按钮的图标替换为当前单位 portrait。
function UpdateExtensiveUnitButtonIcon(unit)
    if Controls.ExtensiveUnitButtonIcon == nil then return end

    if unit == nil then
        Controls.ExtensiveUnitButtonIcon:SetIcon("ICON_UNITOPERATION_BUILD_IMPROVEMENT")
        ApplyPhoneButtonSizeIfNeeded()
        return
    end

    local unitInfo = GameInfo.Units[unit:GetType()]
    if unitInfo == nil or unitInfo.UnitType == nil or unitInfo.UnitType == "" then
        Controls.ExtensiveUnitButtonIcon:SetIcon("ICON_UNITOPERATION_BUILD_IMPROVEMENT")
        ApplyPhoneButtonSizeIfNeeded()
        return
    end

    local portraitIcon = "ICON_" .. unitInfo.UnitType .. "_PORTRAIT"
    local textureOffsetX, textureOffsetY, textureSheet =
        IconManager:FindIconAtlasNearestSize(portraitIcon, 38, true)
    if textureOffsetX == nil then
        portraitIcon = "ICON_" .. unitInfo.UnitType
        textureOffsetX, textureOffsetY, textureSheet =
            IconManager:FindIconAtlasNearestSize(portraitIcon, 38, true)
    end

    if textureOffsetX ~= nil then
        Controls.ExtensiveUnitButtonIcon:SetIcon(portraitIcon)
    else
        Controls.ExtensiveUnitButtonIcon:SetIcon("ICON_UNITOPERATION_BUILD_IMPROVEMENT")
    end
    ApplyPhoneButtonSizeIfNeeded()
end

-- 从当前选中的单位刷新面板记录的玩家/单位信息。
function UpdatePanelSelectionFromHead()
    local playerID = Game.GetLocalPlayer()
    local unit = UI.GetHeadSelectedUnit()

    if playerID == -1 or unit == nil or unit:GetOwner() ~= playerID then
        m_SelectedPlayerID = -1
        m_SelectedUnitID = -1
        Controls.UnitNameLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_UNIT"))
        Controls.UnitPortrait:SetTexture("Controls_Blank")
        UpdateExtensiveUnitButtonIcon(nil)
        return
    end

    m_SelectedPlayerID = playerID
    m_SelectedUnitID = unit:GetID()
    UpdateExtensiveUnitButtonIcon(unit)

    local unitInfo = GameInfo.Units[unit:GetType()]
    if unitInfo ~= nil then
        if unitInfo.Name ~= nil then
            Controls.UnitNameLabel:SetText(Locale.Lookup(unitInfo.Name))
        else
            Controls.UnitNameLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_UNIT"))
        end

        local textureOffsetX, textureOffsetY, textureSheet = nil, nil, nil
        if unitInfo.UnitType ~= nil and unitInfo.UnitType ~= "" then
            textureOffsetX, textureOffsetY, textureSheet =
                IconManager:FindIconAtlas("ICON_" .. unitInfo.UnitType, 44)
        end
        if textureOffsetX ~= nil then
            Controls.UnitPortrait:SetTexture(textureOffsetX, textureOffsetY, textureSheet)
        else
            Controls.UnitPortrait:SetTexture("Controls_Blank")
        end
    else
        Controls.UnitNameLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_UNIT"))
        Controls.UnitPortrait:SetTexture("Controls_Blank")
    end
end

function OnUnitSelectionChanged(playerID, unitID, plotX, plotY, plotZ, bSelected, bEditable)
    Controls.ExtensiveUnitGrid:SetHide(true)

    -- 切换单位/取消选择时取消未完成的地图落点选择
    if m_ActiveCaseType ~= nil then
        ClearMapSelectors()
    end

    if playerID ~= Game.GetLocalPlayer() then
        if m_bIsPanelOpen then
            UpdatePanelSelectionFromHead()
            RefreshPanelContent()
        end
        return
    end

    if bSelected then
        RefreshButton(playerID, unitID)
    end

    if m_bIsPanelOpen then
        if not bSelected then
            -- 取消选择时立即清空面板中的单位信息，避免继续显示已经取消的单位
            m_SelectedPlayerID = -1
            m_SelectedUnitID = -1
            Controls.UnitNameLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_UNIT"))
            Controls.UnitPortrait:SetTexture("Controls_Blank")
        else
            UpdatePanelSelectionFromHead()
        end
        RefreshPanelContent()
    end
end

function OnUnitMoveComplete(playerID, unitID, iX, iY)
    Controls.ExtensiveUnitGrid:SetHide(true)
    if playerID ~= Game.GetLocalPlayer() then return end

    -- 单位移动后原落点可能已失效，取消未完成的地图落点选择
    if m_ActiveCaseType ~= nil then
        ClearMapSelectors()
    end

    RefreshButton(playerID, unitID)

    if m_bIsPanelOpen then
        UpdatePanelSelectionFromHead()
        RefreshPanelContent()
    end
end

function RefreshButton(playerID, unitID)
    if playerID == nil or playerID ~= Game.GetLocalPlayer() then
        Controls.ExtensiveUnitGrid:SetHide(true)
        UpdateExtensiveUnitButtonIcon(nil)
        return
    end

    local unit = nil
    if unitID ~= nil then
        unit = UnitManager.GetUnit(playerID, unitID)
    end
    if unit == nil then
        unit = UI.GetHeadSelectedUnit()
    end
    if unit == nil or unit:GetOwner() ~= Game.GetLocalPlayer() then
        Controls.ExtensiveUnitGrid:SetHide(true)
        UpdateExtensiveUnitButtonIcon(nil)
        return
    end

    Controls.ExtensiveUnitGrid:SetHide(false)
    UpdateExtensiveUnitButtonIcon(unit)
end

-- ===========================================================================
-- 面板开关
-- ===========================================================================

function OnPanelToggleButtonClicked()
    if m_bIsPanelOpen then
        ClosePanel()
    else
        OpenPanel()
    end
end

function OnPanelSlideOutFinished()
    Controls.PanelSlide:ClearEndCallback()
    if not m_bIsPanelOpen then
        Controls.ExtensiveUnitPanelMain:SetHide(true)
    end
end

function OpenPanel()
    if m_bIsPanelOpen then return end
    m_bIsPanelOpen = true

    if m_ActiveCaseType ~= nil then
        ClearMapSelectors()
    end

    Controls.ExtensiveUnitPanelMain:SetHide(false)
    Controls.ExtensiveUnitPanelMain:ReprocessAnchoring()
    RefreshCaseColumnLayout()

    UpdatePanelSelectionFromHead()
    RefreshPanelContent()

    Controls.PanelSlide:Stop()
    Controls.PanelSlide:ClearEndCallback()
    Controls.PanelSlide:SetToBeginning()
    Controls.PanelSlide:Play()

    LuaEvents.ModMiscToolExtensivePanelOpened.Call(m_SelectedPlayerID, m_SelectedUnitID)
end

function ClosePanel()
    if not m_bIsPanelOpen then return end
    m_bIsPanelOpen = false

    ClearMapSelectors()

    Controls.PanelSlide:Stop()
    Controls.PanelSlide:ClearEndCallback()
    Controls.PanelSlide:SetToEnd()
    Controls.PanelSlide:RegisterEndCallback(OnPanelSlideOutFinished)
    Controls.PanelSlide:Reverse()

    LuaEvents.ModMiscToolExtensivePanelClosed.Call()
end

-- ===========================================================================
-- 刷新面板内容（2列轮询分配）
-- ===========================================================================

function RefreshPanelContent()
    ResetAllColumns()
    RefreshCaseColumnLayout()

    if m_SelectedPlayerID == -1 or m_SelectedUnitID == -1 then
        Controls.UnitPortrait:SetTexture("Controls_Blank")
        Controls.EmptyLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_UNIT"))
        Controls.EmptyLabel:SetHide(false)
        return
    end

    -- 单位可能在面板打开期间死亡/被移除，这里做一次有效性检查
    local selectedUnit = UnitManager.GetUnit(m_SelectedPlayerID, m_SelectedUnitID)
    if selectedUnit == nil then
        m_SelectedPlayerID = -1
        m_SelectedUnitID = -1
        Controls.UnitNameLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_UNIT"))
        Controls.UnitPortrait:SetTexture("Controls_Blank")
        Controls.EmptyLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_UNIT"))
        Controls.EmptyLabel:SetHide(false)
        return
    end

    -- 自定义按钮
    local hasCustomButtons = false
    for _, btnData in ipairs(m_RegisteredCustomButtons) do
        local bVisible = true
        if btnData.visibleFunc ~= nil then
            bVisible = btnData.visibleFunc(selectedUnit) and true or false
        end

        if bVisible then
            hasCustomButtons = true
            local colIdx = NextCustomColIndex()
            local instance = m_CustomButtonColumnIMs[colIdx]:GetInstance()
            if btnData.icon ~= nil then
                if string.sub(btnData.icon, 1, 5) == "ICON_" then
                    local textureOffsetX, textureOffsetY, textureSheet =
                        IconManager:FindIconAtlasNearestSize(btnData.icon, 64, true)
                    if textureOffsetX ~= nil then
                        instance.ButtonIcon:SetTexture(textureOffsetX, textureOffsetY, textureSheet)
                    else
                        instance.ButtonIcon:SetIcon(btnData.icon)
                    end
                else
                    instance.ButtonIcon:SetTexture(btnData.icon)
                end
            end
            instance.ButtonName:SetText(btnData.name or "")
            instance.ButtonDescription:SetText(btnData.description or "")
            if btnData.callback ~= nil then
                instance.ActionButton:ClearCallback(Mouse.eLClick)
                instance.ActionButton:RegisterCallback(Mouse.eLClick, btnData.callback)
            end
        end
    end

    -- 建造案例
    local hasCases = false
    local buildCases = GameInfo.Kocmoca_Build_Cases
    if buildCases ~= nil then
        -- 当前单位所在地块，用于校验 BuildRange=0 案例的地块要求
        local unitPlotIndex = nil
        local unitPlot = Map.GetPlot(selectedUnit:GetX(), selectedUnit:GetY())
        if unitPlot ~= nil then
            unitPlotIndex = unitPlot:GetIndex()
        end

        for caseRow in buildCases() do
            local caseType = caseRow.CaseType
            local buildRange = caseRow.BuildRange or 0

            local unitMatch = true
            local playerMatch = true
            if ExposedMembers.ModMiscToolScript then
                if ExposedMembers.ModMiscToolScript.IsUnitMatchRequirement then
                    unitMatch = ExposedMembers.ModMiscToolScript.IsUnitMatchRequirement(
                        m_SelectedUnitID, caseType, m_SelectedPlayerID)
                end
                if ExposedMembers.ModMiscToolScript.IsPlayerMatchRequirement then
                    playerMatch = ExposedMembers.ModMiscToolScript.IsPlayerMatchRequirement(
                        caseType, m_SelectedPlayerID)
                end
            end

            -- BuildRange=0：目标就是单位所在格，可直接过滤掉不满足地块要求的案例。
            local plotMatch = true
            if buildRange <= 0 and unitPlotIndex ~= nil
                and ExposedMembers.ModMiscToolScript
                and ExposedMembers.ModMiscToolScript.IsPlotMatchRequirement then
                plotMatch = ExposedMembers.ModMiscToolScript.IsPlotMatchRequirement(
                    unitPlotIndex, caseType, m_SelectedPlayerID)
            end

            if unitMatch and playerMatch and plotMatch then
                hasCases = true
                local colIdx = NextColIndex()
                local instance = m_CaseEntryColumnIMs[colIdx]:GetInstance()

                -- Icon: 优先使用 caseRow.Icon，未指定则 fallback 到 "ICON_"..CaseType
                local iconString
                if caseRow.Icon ~= nil and caseRow.Icon ~= "" then
                    iconString = caseRow.Icon
                else
                    iconString = "ICON_" .. caseType
                end

                local textureOffsetX, textureOffsetY, textureSheet =
                    IconManager:FindIconAtlasNearestSize(iconString, 64, true)
                if textureOffsetX == nil then
                    -- 找不到对应图标时，退回通用建造图标
                    textureOffsetX, textureOffsetY, textureSheet =
                        IconManager:FindIconAtlasNearestSize("ICON_UNITOPERATION_BUILD_IMPROVEMENT", 64, true)
                end
                if textureOffsetX ~= nil then
                    instance.ItemIcon:SetTexture(textureOffsetX, textureOffsetY, textureSheet)
                else
                    instance.ItemIcon:SetTexture("Controls_Blank")
                end

                -- Name: 优先使用 caseRow.Name，未指定则 fallback 到 Description 或 CaseType
                local itemName
                if caseRow.Name ~= nil and caseRow.Name ~= "" then
                    itemName = Locale.Lookup(caseRow.Name)
                else
                    itemName = Locale.Lookup(caseRow.Description or caseType)
                end
                instance.ItemName:SetText(itemName)

                local costText = BuildCostDescription(caseType)
                local descText = Locale.Lookup(caseRow.Description or "")
                if costText ~= "" and descText ~= "" then
                    instance.ItemDescription:SetText(costText .. "[NEWLINE]" .. descText)
                elseif costText ~= "" then
                    instance.ItemDescription:SetText(costText)
                else
                    instance.ItemDescription:SetText(descText)
                end

                instance.ActionButton:ClearCallback(Mouse.eLClick)
                instance.ActionButton:RegisterCallback(Mouse.eLClick, function()
                    if buildRange > 0 then
                        ClosePanel()
                        m_ActiveCaseType = caseType
                        ShowMapSelectors(m_SelectedPlayerID, m_SelectedUnitID, caseType, buildRange)
                    else
                        OnCaseActionConfirmed(caseType, nil)
                    end
                end)
            end
        end
    end

    -- 自定义按钮也算面板内容，否则会在没有任何建造案例时错误提示“无可用建造方案”
    if hasCases or hasCustomButtons then
        Controls.EmptyLabel:SetHide(true)
    else
        Controls.EmptyLabel:SetText(Locale.Lookup("LOC_EXTENSIVEUNIT_NO_CASES"))
        Controls.EmptyLabel:SetHide(false)
    end
end

-- ===========================================================================
-- 花费描述
-- ===========================================================================

function BuildCostDescription(caseType)
    local buildCases = GameInfo.Kocmoca_Build_Cases
    if buildCases == nil then return "" end

    local caseRow = buildCases[caseType]
    if caseRow == nil then return "" end

    local costModels = GameInfo.Kocmoca_Build_CostModels
    if costModels == nil or caseRow.CostModel == nil then return "" end

    local costRow = costModels[caseRow.CostModel]
    if costRow == nil then return "" end

    local parts = {}
    if costRow.BuildCharge ~= nil and costRow.BuildCharge ~= 0 then
        table.insert(parts, "[ICON_Charges_Large] " .. tostring(costRow.BuildCharge))
    end
    if costRow.GoldAmount ~= nil and costRow.GoldAmount ~= 0 then
        table.insert(parts, "[ICON_Gold] " .. Locale.ToNumber(costRow.GoldAmount))
    end
    if costRow.FaithAmount ~= nil and costRow.FaithAmount ~= 0 then
        table.insert(parts, "[ICON_Faith] " .. Locale.ToNumber(costRow.FaithAmount))
    end

    local resourceRow
    if costRow.ResourceType ~= nil then
        resourceRow = GameInfo.Resources[costRow.ResourceType]
    end
    if resourceRow ~= nil and costRow.ResourceAmount ~= nil and costRow.ResourceAmount ~= 0 then
        local resourceName = ""
        if resourceRow.Name ~= nil then
            resourceName = " " .. Locale.Lookup(resourceRow.Name)
        end
        local resourceIcon = ""
        if costRow.ResourceType ~= nil and costRow.ResourceType ~= "" then
            -- 资源图标定义名需要双 ICON_ 前缀：ICON_ + ICON_RESOURCE_XXX
            resourceIcon = "[ICON_ICON_" .. costRow.ResourceType .. "] "
        end
        table.insert(parts, resourceIcon .. tostring(costRow.ResourceAmount) .. resourceName)
    end

    if #parts <= 0 then return "" end
    return "[COLOR:ResGoldLabelCS]" .. table.concat(parts, "  ") .. "[ENDCOLOR]"
end

-- ===========================================================================
-- BuildRange > 0 : 在地图显示选择按钮
-- ===========================================================================

-- 校验最终目标地块是否满足案例的地块要求
function IsBuildPlotValid(caseType, plotIndex)
    if plotIndex == nil then return false end

    if ExposedMembers.ModMiscToolScript
        and ExposedMembers.ModMiscToolScript.IsPlotMatchRequirement then
        return ExposedMembers.ModMiscToolScript.IsPlotMatchRequirement(
            plotIndex, caseType, m_SelectedPlayerID)
    end

    return true
end

function ShowMapSelectors(playerID, unitID, caseType, buildRange)
    -- 先清理上一次可能残留的选择器/高亮层，避免回调重复
    ClearMapSelectors()
    m_ActiveCaseType = caseType

    -- UI 环境没有 Map.GetNeighborPlots，交给 gameplay 侧筛选可用地块
    local plotIndexes = nil
    if ExposedMembers.ModMiscToolScript
        and ExposedMembers.ModMiscToolScript.GetBuildableNeighborPlotIndexes then
        plotIndexes = ExposedMembers.ModMiscToolScript.GetBuildableNeighborPlotIndexes(
            playerID, unitID, caseType, buildRange)
    end
    if plotIndexes == nil then
        OpenPanel()
        return
    end

    for _, plotIndex in ipairs(plotIndexes) do
        local instance = GetOrCreateMapSelector(plotIndex)
        instance.SelectButton:ClearCallback(Mouse.eLClick)
        instance.SelectButton:RegisterCallback(Mouse.eLClick, function()
            OnCaseActionConfirmed(caseType, plotIndex)
        end)
        instance.SelectButton:SetHide(false)
        instance.SelectIcon:SetHide(false)
        instance.SelectHighlight:SetHide(false)
    end

    if #plotIndexes <= 0 then
        -- 没有合法落点时返回面板，让玩家重新选择建造方案
        OpenPanel()
        return
    end

    if m_MapSelectLensLayer == nil then
        m_MapSelectLensLayer = UILens.CreateLensLayerHash("Hex_Coloring_Movement")
    end
    UILens.ClearLayerHexes(m_MapSelectLensLayer)
    UILens.SetLayerHexesArea(m_MapSelectLensLayer, playerID, plotIndexes, MAP_SELECT_LENS_COLOR)
    UILens.ToggleLayerOn(m_MapSelectLensLayer)
    Controls.ClearMapButton:SetHide(false)
end

function GetOrCreateMapSelector(plotIndex)
    local instance = m_uiWorldMapTable[plotIndex]
    if instance == nil then
        instance = m_MapSelectIM:GetInstance()
        m_uiWorldMapTable[plotIndex] = instance
        local worldX, worldY = UI.GridToWorld(plotIndex)
        instance.SelectAnchor:SetWorldPositionVal(worldX, worldY, 0)
    end
    instance.SelectAnchor:SetHide(false)
    return instance
end

function ClearMapSelectors()
    if m_MapSelectLensLayer ~= nil then
        UILens.ClearLayerHexes(m_MapSelectLensLayer)
        if UILens.IsLayerOn(m_MapSelectLensLayer) then
            UILens.ToggleLayerOff(m_MapSelectLensLayer)
        end
    end

    for plotIndex, instance in pairs(m_uiWorldMapTable) do
        instance.SelectAnchor:SetHide(true)
        m_MapSelectIM:ReleaseInstance(instance)
        m_uiWorldMapTable[plotIndex] = nil
    end

    if Controls.ClearMapButton ~= nil then
        Controls.ClearMapButton:SetHide(true)
    end

    m_ActiveCaseType = nil
end

function OnClearMapButtonClicked()
    local wasPanelOpen = m_bIsPanelOpen
    ClearMapSelectors()
    if not wasPanelOpen then
        OpenPanel()
    end
end

-- ===========================================================================
-- 确认执行建造
-- ===========================================================================

function OnCaseActionConfirmed(caseType, plotIndex)
    local buildCases = GameInfo.Kocmoca_Build_Cases
    if buildCases == nil then
        ClearMapSelectors()
        return
    end

    local caseRow = buildCases[caseType]
    if caseRow == nil then
        ClearMapSelectors()
        return
    end

    if m_SelectedPlayerID == -1 or m_SelectedUnitID == -1 then
        ClearMapSelectors()
        return
    end

    -- 若无指定地块（BuildRange=0），使用单位所在位置
    local buildPlotIndex = plotIndex
    if buildPlotIndex == nil and m_SelectedUnitID ~= -1 then
        local unit = UnitManager.GetUnit(m_SelectedPlayerID, m_SelectedUnitID)
        if unit ~= nil then
            local plot = Map.GetPlot(unit:GetX(), unit:GetY())
            if plot ~= nil then
                buildPlotIndex = plot:GetIndex()
            end
        end
    end

    -- 最终校验，避免地块不满足要求时仍然建造
    local bValid = IsBuildPlotValid(caseType, buildPlotIndex)
    ClearMapSelectors()

    if not bValid then
        if not m_bIsPanelOpen then
            OpenPanel()
        end
        return
    end

    local itemType = caseRow.ItemType
    local itemCatagory = caseRow.ItemCatagory
    local costModel = caseRow.CostModel

    if ExposedMembers.ModMiscToolScript and ExposedMembers.ModMiscToolScript.BuildItemOnMap then
        ExposedMembers.ModMiscToolScript.BuildItemOnMap(
            m_SelectedPlayerID, m_SelectedUnitID, buildPlotIndex,
            itemType, itemCatagory, costModel)
    end

    if m_bIsPanelOpen then
        RefreshPanelContent()
    end
end

-- ===========================================================================
-- 扩展接口
-- ===========================================================================

function RegisterCustomButton(icon, name, description, callback, visibleFunc)
    table.insert(m_RegisteredCustomButtons, {
        icon = icon, name = name, description = description, callback = callback,
        visibleFunc = visibleFunc,
    })
    if m_bIsPanelOpen then RefreshPanelContent() end
end

-- Phone-only: resize the unit-panel entry button in its owning UI context.
-- ButtonAdjust_PHONE.lua calls this through ExposedMembers so the control
-- methods run in the same context as Controls.
function ResizeExtensiveUnitButtonForPhone()
    if Controls.ExtensiveUnitGrid == nil or Controls.ExtensiveUnitButton == nil then
        return false
    end

    m_PhoneButtonResized = true

    Controls.ExtensiveUnitGrid:SetTexture("UnitPanel_ActionButton")
    Controls.ExtensiveUnitButton:SetTexture("UnitPanel_ActionButton")
    Controls.ExtensiveUnitButton:SetStretchMode("Fill")
    Controls.ExtensiveUnitButton:SetStateOffsetIncrement(0, 159)
    Controls.ExtensiveUnitButton:SetSingleStateTextureHeight(159)
    Controls.ExtensiveUnitButton:SetIgnorePressAfterTime(1)

    ApplyPhoneButtonSizeIfNeeded()

    -- Ensure the grid itself recalculates after the child button is resized.
    Controls.ExtensiveUnitGrid:CalculateSize()
    Controls.ExtensiveUnitGrid:ReprocessAnchoring()

    local standardStack = ContextPtr:LookUpControl("/InGame/UnitPanel/StandardActionsStack")
    if standardStack ~= nil then
        standardStack:CalculateSize()
        standardStack:ReprocessAnchoring()
    end

    local actionsStack = ContextPtr:LookUpControl("/InGame/UnitPanel/ActionsStack")
    if actionsStack ~= nil then
        actionsStack:CalculateSize()
        actionsStack:ReprocessAnchoring()
    end

    return true
end
