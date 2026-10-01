-- LeftSideBar: 透明可折叠左侧工具栏
-- 参照 PartialScreenHooks_PHONE 模式：SlideAnim + AlphaAnim 横向滑动/淡出
-- InfoPanel: TopPanel_PHONE 横栏 + 4列帝国概况网格
-- 其他 mod 通过 ExposedMembers.ModMiscToolUI.RegisterSidebarButton() 注册按钮
-- ===========================================================================

include("InstanceManager")
include("SupportFunctions")
include("GameCapabilities")

-- ===========================================================================
-- CONSTANTS
-- ===========================================================================

local COLUMN_COUNT = 3

-- 与 TopPanel_PHONE 的 YieldStack 保持一致：科研、文化、信仰、金币、旅游
-- TopPanel 中没有“总生产”产出，生产只作用于单个城市，因此不在此显示。
local YIELD_TYPES = {
    { key = "SCIENCE",    icon = "[ICON_ScienceLarge]" },
    { key = "CULTURE",    icon = "[ICON_CultureLarge]" },
    { key = "FAITH",      icon = "[ICON_FaithLarge]" },
    { key = "GOLD",       icon = "[ICON_GoldLarge]" },
    { key = "TOURISM",    icon = "[ICON_TourismLarge]" },
}

-- 支持两种图标参数：
--   "Controls_Info" 之类的纹理名 -> SetTexture
--   "ICON_FORT_LEVEL" 之类的图标定义 -> SetIcon
local function SetIconOrTexture(control, icon)
    if control == nil or icon == nil or icon == "" then return end
    local iconName = tostring(icon)
    if string.sub(iconName, 1, 5) == "ICON_" then
        control:SetIcon(iconName)
    else
        control:SetTexture(iconName)
    end
end

-- Sidebar layout constants (must match UI/LeftSideBar.xml)
local SIDEBAR_BAR_OFFSET_X   = 0
local SIDEBAR_SLIDE_EXTRA    = 32
local SIDEBAR_TEXTURE_EXPAND = "Controls_iOSExpandFlipped"
local SIDEBAR_TEXTURE_COLLAPSE = "Controls_iOSCollapseFlipped"
local SIDEBAR_HIDE_ICON = "ICON_UNITCOMMAND_CANCEL"

-- Sidebar paging constants
local SIDEBAR_MAX_VISIBLE_BUTTONS = 4    -- 单页最多显示的按钮数硬上限（适配按钮偏移后的可用高度）
local SIDEBAR_BUTTON_PITCH        = 104  -- 按钮行高度 96 + StackPadding 8
local SIDEBAR_VERTICAL_RESERVED   = 216  -- 翻页按钮/页码/隐藏按钮/上下留白占用的高度

-- ===========================================================================
-- MEMBERS
-- ===========================================================================
local m_bIsExpanded = false
local m_bIsInfoPanelOpen = false
-- 是否由用户主动隐藏展开键（不写入存档，重进游戏恢复可见）
local m_bHideToggleButton = false

-- Sidebar
local m_SidebarButtonIM = nil
local m_RegisteredButtons = {}
local m_SidebarPage = 1
local m_HideSidebarButtonData = nil

-- InfoPanel 4列 InstanceManager
local m_YieldColumnIMs = {}
local m_ResourceColumnIMs = {}
local m_CustomGridColumnIMs = {}
local m_CustomRowColumnIMs = {}

-- 允许其他 mod 在 LeftSideBar Initialize 之前调用注册 API；
-- 初始化完成后统一 flush。
local m_PendingSidebarButtons = {}
local m_PendingCustomGrids = {}
local m_PendingCustomRows = {}

-- 列索引轮询
local m_YieldColIndex = 0
local m_ResourceColIndex = 0
local m_CustomGridColIndex = 0
local m_CustomRowColIndex = 0

-- 注册数据
local m_RegisteredCustomGrids = {}
local m_RegisteredCustomRows = {}

-- 移动拦截器：其他 mod 注册 predicate，Civ6Common 替换层统一调用。
local m_MovementInterceptors = {}

-- ===========================================================================
-- HELPERS
-- ===========================================================================

function NextColIndex(colIndexRef)
    colIndexRef[0] = colIndexRef[0] + 1
    if colIndexRef[0] > COLUMN_COUNT then
        colIndexRef[0] = 1
    end
    return colIndexRef[0]
end

function ResetAllInfoColumns()
    for i = 1, COLUMN_COUNT do
        if m_YieldColumnIMs[i] then m_YieldColumnIMs[i]:ResetInstances() end
        if m_ResourceColumnIMs[i] then m_ResourceColumnIMs[i]:ResetInstances() end
        if m_CustomGridColumnIMs[i] then m_CustomGridColumnIMs[i]:ResetInstances() end
        if m_CustomRowColumnIMs[i] then m_CustomRowColumnIMs[i]:ResetInstances() end
    end
    m_YieldColIndex = 0
    m_ResourceColIndex = 0
    m_CustomGridColIndex = 0
    m_CustomRowColIndex = 0
end

-- ===========================================================================
-- SIDEBAR COLLAPSE/EXPAND（参照 PartialScreenHooks_PHONE / LaunchBar_PHONE）
-- ===========================================================================

-- 根据当前 ButtonStack 的实际宽度计算 SlideAnim 的收起终点，
-- 使按钮栏能够完整滑出屏幕，同时保留 ToggleButton 在左边缘。
function UpdateSidebarSlideEnd()
    if Controls.ButtonStack == nil or Controls.SidebarSlide == nil then return end

    Controls.ButtonStack:CalculateSize()
    local barWidth = Controls.ButtonStack:GetSizeX()
    if barWidth <= 0 then
        barWidth = 96
    end

    Controls.SidebarSlide:SetRelativeEndVal(
        -(SIDEBAR_BAR_OFFSET_X + barWidth + SIDEBAR_SLIDE_EXTRA), 0)
end

function ApplySidebarToggleVisuals()
    if Controls.ToggleButton == nil then return end

    if m_bIsExpanded then
        Controls.ToggleButton:SetTexture(SIDEBAR_TEXTURE_COLLAPSE)
        Controls.ToggleButton:SetToolTipString(Locale.Lookup("LOC_MODMISC_COLLAPSE_SIDEBAR"))
    else
        Controls.ToggleButton:SetTexture(SIDEBAR_TEXTURE_EXPAND)
        Controls.ToggleButton:SetToolTipString(Locale.Lookup("LOC_MODMISC_TOGGLE_SIDEBAR"))
    end

    -- 用户主动隐藏后：
    -- 折叠状态保持完全透明；再次点击展开键时临时恢复可见，折叠后继续透明。
    if m_bHideToggleButton and not m_bIsExpanded then
        Controls.ToggleButton:SetAlpha(0)
    else
        Controls.ToggleButton:SetAlpha(1)
    end
end

function SetSidebarButtonsEnabled(bEnabled)
    for _, data in ipairs(m_RegisteredButtons) do
        local button = data.button
        if button ~= nil then
            button:SetDisabled(not bEnabled)
        end
    end
    UpdateSidebarPageButtons()
end

-- 计算当前分辨率下每页可显示的按钮数量，并受硬上限约束。
function GetSidebarMaxVisibleButtons()
    local _, screenY = UIManager:GetScreenSizeVal()
    if screenY == nil or screenY <= 0 then
        screenY = 1080
    end

    local fitCount = math.floor((screenY - SIDEBAR_VERTICAL_RESERVED) / SIDEBAR_BUTTON_PITCH)
    if fitCount < 1 then
        fitCount = 1
    end

    return math.min(SIDEBAR_MAX_VISIBLE_BUTTONS, fitCount)
end

function GetSidebarPageCount()
    return math.max(1, math.ceil(#m_RegisteredButtons / GetSidebarMaxVisibleButtons()))
end

function UpdateSidebarPageButtons()
    if Controls.PageUpButton == nil or Controls.PageDownButton == nil
        or Controls.PageLabel == nil then
        return
    end

    local pageCount = GetSidebarPageCount()
    local bShowPager = pageCount > 1
    Controls.PageUpButton:SetHide(not bShowPager)
    Controls.PageDownButton:SetHide(not bShowPager)
    Controls.PageLabel:SetHide(not bShowPager)

    local bCanPageUp = m_bIsExpanded and m_SidebarPage > 1
    local bCanPageDown = m_bIsExpanded and m_SidebarPage < pageCount
    Controls.PageUpButton:SetDisabled(not bCanPageUp)
    Controls.PageDownButton:SetDisabled(not bCanPageDown)

    Controls.PageLabel:SetText(m_SidebarPage .. "/" .. pageCount)
end

-- 根据 m_SidebarPage 显示当前页按钮，隐藏其它页按钮。
function UpdateSidebarPaging()
    if Controls.ButtonStack == nil then return end

    local pageCount = GetSidebarPageCount()
    if m_SidebarPage > pageCount then
        m_SidebarPage = pageCount
    elseif m_SidebarPage < 1 then
        m_SidebarPage = 1
    end

    local maxVisible = GetSidebarMaxVisibleButtons()
    local firstIndex = (m_SidebarPage - 1) * maxVisible + 1
    local lastIndex = math.min(#m_RegisteredButtons, firstIndex + maxVisible - 1)

    for i, data in ipairs(m_RegisteredButtons) do
        local row = data.row or data.button
        if row ~= nil then
            row:SetHide(i < firstIndex or i > lastIndex)
        end
    end

    UpdateSidebarPageButtons()
    Controls.ButtonStack:CalculateSize()
    if Controls.SidebarContentStack ~= nil then
        Controls.SidebarContentStack:CalculateSize()
    end
    UpdateSidebarSlideEnd()
end

function SetSidebarPage(page)
    local pageCount = GetSidebarPageCount()
    page = math.max(1, math.min(page, pageCount))
    if page == m_SidebarPage then return end

    m_SidebarPage = page
    UI.PlaySound("Main_Menu_Mouse_Over")
    UpdateSidebarPaging()
    RefreshSidebarLayout()
end

function OnSidebarPageUp()
    SetSidebarPage(m_SidebarPage - 1)
end

function OnSidebarPageDown()
    SetSidebarPage(m_SidebarPage + 1)
end

-- 内容或屏幕尺寸改变后，重新计算滑动距离并同步到当前展开状态。
function RefreshSidebarLayout()
    if Controls.ButtonStack == nil or Controls.SidebarSlide == nil then return end

    Controls.SidebarSlide:Stop()
    Controls.SidebarAlphaAnim:Stop()

    Controls.ButtonStack:CalculateSize()
    if Controls.SidebarContentStack ~= nil then
        Controls.SidebarContentStack:CalculateSize()
    end
    UpdateSidebarSlideEnd()

    if m_bIsExpanded then
        Controls.SidebarSlide:SetToBeginning()
        Controls.SidebarAlphaAnim:SetToBeginning()
    else
        Controls.SidebarSlide:SetToEnd()
        Controls.SidebarAlphaAnim:SetToEnd()
    end
end

-- 没有任何注册按钮时隐藏展开/收起按钮，避免留下空工具栏。
function UpdateSidebarVisibility()
    if Controls.ButtonStack == nil or Controls.ToggleButton == nil then return end

    local count = #m_RegisteredButtons
    Controls.ToggleButton:SetHide(count == 0)

    if count == 0 and m_bIsExpanded then
        m_bIsExpanded = false
        SetSidebarButtonsEnabled(false)
        RefreshSidebarLayout()
    end

    ApplySidebarToggleVisuals()
    UpdateSidebarPageButtons()
end

function ExpandSidebar(bInstant)
    if m_bIsExpanded then return end
    m_bIsExpanded = true

    Controls.SidebarSlide:Stop()
    Controls.SidebarAlphaAnim:Stop()

    UpdateSidebarSlideEnd()
    ApplySidebarToggleVisuals()
    SetSidebarButtonsEnabled(true)

    if bInstant then
        Controls.SidebarSlide:SetToBeginning()
        Controls.SidebarAlphaAnim:SetToBeginning()
    else
        Controls.SidebarSlide:SetToEnd()
        Controls.SidebarAlphaAnim:SetToEnd()
        Controls.SidebarSlide:Reverse()
        Controls.SidebarAlphaAnim:Reverse()
    end

    UI.PlaySound("Main_Menu_Mouse_Over")

    LuaEvents.ModMiscToolSidebarExpanded.Call()
end

function CollapseSidebar(bInstant)
    if not m_bIsExpanded then return end
    m_bIsExpanded = false

    ApplySidebarToggleVisuals()
    SetSidebarButtonsEnabled(false)

    if m_bIsInfoPanelOpen then
        CloseInfoPanel()
    end

    Controls.SidebarSlide:Stop()
    Controls.SidebarAlphaAnim:Stop()

    if bInstant then
        Controls.SidebarSlide:SetToEnd()
        Controls.SidebarAlphaAnim:SetToEnd()
    else
        Controls.SidebarSlide:SetToBeginning()
        Controls.SidebarAlphaAnim:SetToBeginning()
        Controls.SidebarSlide:Play()
        Controls.SidebarAlphaAnim:Play()
    end

    UI.PlaySound("Main_Menu_Mouse_Over")

    LuaEvents.ModMiscToolSidebarCollapsed.Call()
end

function ToggleSidebar()
    if m_bIsExpanded then
        CollapseSidebar(false)
    else
        ExpandSidebar(false)
    end
end

function UpdateHideSidebarButtonVisuals()
    if m_HideSidebarButtonData == nil then return end
    local instance = m_HideSidebarButtonData.instance
    if instance == nil then return end

    local labelTag = "LOC_MODMISC_HIDE_SIDEBAR"
    local tooltipTag = "LOC_MODMISC_HIDE_SIDEBAR_TOOLTIP"
    if m_bHideToggleButton then
        labelTag = "LOC_MODMISC_CANCEL_HIDE_SIDEBAR"
        tooltipTag = "LOC_MODMISC_CANCEL_HIDE_SIDEBAR_TOOLTIP"
    end

    if instance.ButtonIcon ~= nil then
        SetIconOrTexture(instance.ButtonIcon, SIDEBAR_HIDE_ICON)
    end
    if instance.ButtonLabel ~= nil then
        instance.ButtonLabel:SetText(Locale.Lookup(labelTag))
    end
    if m_HideSidebarButtonData.button ~= nil then
        m_HideSidebarButtonData.button:SetToolTipString(Locale.Lookup(tooltipTag))
    end
    m_HideSidebarButtonData.icon = SIDEBAR_HIDE_ICON
    m_HideSidebarButtonData.label = Locale.Lookup(labelTag)
    m_HideSidebarButtonData.tooltip = Locale.Lookup(tooltipTag)
end

function HideSidebar()
    if m_bHideToggleButton then
        -- 已处于隐藏状态：该按键变为“取消隐藏”
        m_bHideToggleButton = false
        UpdateHideSidebarButtonVisuals()
        ApplySidebarToggleVisuals()
    else
        m_bHideToggleButton = true
        UpdateHideSidebarButtonVisuals()
        if m_bIsExpanded then
            CollapseSidebar(false)
        else
            ApplySidebarToggleVisuals()
        end
    end
end

-- ===========================================================================
-- INFO PANEL TOP BAR（参照 TopPanel_PHONE）
-- ===========================================================================

function FormatPerTurnValue(value)
    if value == 0 then
        return Locale.ToNumber(value)
    else
        return Locale.Lookup("{1: number +#,###.#;-#,###.#}", value)
    end
end

-- 与 TopPanel_PHONE 的 RefreshYields 条件保持一致：
-- 需要 CAPABILITY_DISPLAY_TOP_PANEL_YIELDS，以及对应产出的能力。
local function CanDisplayTopPanelYield(specificCapability)
    return GameCapabilities.HasCapability("CAPABILITY_DISPLAY_TOP_PANEL_YIELDS")
        and GameCapabilities.HasCapability(specificCapability)
end

function RefreshInfoTopBar()
    local ePlayer = Game.GetLocalPlayer()
    if ePlayer == -1 then return end
    local localPlayer = Players[ePlayer]
    if localPlayer == nil then return end

    local bDisplayYields = GameCapabilities.HasCapability("CAPABILITY_DISPLAY_TOP_PANEL_YIELDS")

    -- Science
    local bShowScience = bDisplayYields and GameCapabilities.HasCapability("CAPABILITY_SCIENCE")
    Controls.InfoScienceLabel:SetHide(not bShowScience)
    if bShowScience then
        Controls.InfoScienceLabel:SetText("[ICON_ScienceLarge] "
            .. FormatPerTurnValue(localPlayer:GetTechs():GetScienceYield()))
    end

    -- Culture
    local bShowCulture = bDisplayYields and GameCapabilities.HasCapability("CAPABILITY_CULTURE")
    Controls.InfoCultureLabel:SetHide(not bShowCulture)
    if bShowCulture then
        Controls.InfoCultureLabel:SetText("[ICON_CultureLarge] "
            .. FormatPerTurnValue(localPlayer:GetCulture():GetCultureYield()))
    end

    -- Faith (balance + per turn)
    local bShowFaith = bDisplayYields and GameCapabilities.HasCapability("CAPABILITY_FAITH")
    Controls.InfoFaithLabel:SetHide(not bShowFaith)
    if bShowFaith then
        local playerReligion = localPlayer:GetReligion()
        Controls.InfoFaithLabel:SetText("[ICON_FaithLarge] "
            .. Locale.ToNumber(playerReligion:GetFaithBalance(), "#,###.#")
            .. "  " .. FormatPerTurnValue(playerReligion:GetFaithYield()))
    end

    -- Gold (balance + per turn)
    local bShowGold = bDisplayYields and GameCapabilities.HasCapability("CAPABILITY_GOLD")
    Controls.InfoGoldLabel:SetHide(not bShowGold)
    if bShowGold then
        local playerTreasury = localPlayer:GetTreasury()
        local goldBalance = math.floor(playerTreasury:GetGoldBalance())
        local goldYield = playerTreasury:GetGoldYield() - playerTreasury:GetTotalMaintenance()
        Controls.InfoGoldLabel:SetText("[ICON_GoldLarge] "
            .. Locale.ToNumber(goldBalance, "#,###.#")
            .. "  " .. FormatPerTurnValue(goldYield))
    end

    -- Tourism（TopPanel 仅在 tourismRate > 0 时显示）
    local bShowTourism = bDisplayYields and GameCapabilities.HasCapability("CAPABILITY_TOURISM")
    if bShowTourism then
        local tourismRate = Round(localPlayer:GetStats():GetTourism(), 1)
        bShowTourism = tourismRate > 0
        if bShowTourism then
            Controls.InfoTourismLabel:SetText("[ICON_TourismLarge] "
                .. Locale.ToNumber(tourismRate, "#,###.#"))
        end
    end
    Controls.InfoTourismLabel:SetHide(not bShowTourism)

    -- Trade Routes
    local bShowTrade = GameCapabilities.HasCapability("CAPABILITY_TRADE")
    Controls.InfoTradeLabel:SetHide(not bShowTrade)
    if bShowTrade then
        local playerTrade = localPlayer:GetTrade()
        local routesActive = playerTrade:GetNumOutgoingRoutes()
        local routesCapacity = playerTrade:GetOutgoingRouteCapacity()
        Controls.InfoTradeLabel:SetText("[ICON_TradeRouteLarge] " .. routesActive .. "/" .. routesCapacity)
    end

    -- Envoys
    local bShowEnvoy = GameCapabilities.HasCapability("CAPABILITY_TOP_PANEL_ENVOYS")
    Controls.InfoEnvoyLabel:SetHide(not bShowEnvoy)
    if bShowEnvoy then
        local playerInfluence = localPlayer:GetInfluence()
        Controls.InfoEnvoyLabel:SetText("[ICON_Envoy] " .. tostring(playerInfluence:GetTokensToGive()))
    end

    local bShowAnyYield = bShowScience or bShowCulture or bShowFaith or bShowGold or bShowTourism
    local bShowAnyStatic = bShowTrade or bShowEnvoy
    Controls.InfoYieldDivider:SetHide(not bShowAnyYield)
    Controls.InfoStaticDivider:SetHide(not (bShowAnyYield and bShowAnyStatic))

    -- Turn / Date
    local turn = Game.GetCurrentGameTurn()
    if GameCapabilities.HasCapability("CAPABILITY_DISPLAY_NORMALIZED_TURN") then
        turn = (turn - GameConfiguration.GetStartTurn()) + 1
    end
    local endTurn = Game.GetGameEndTurn()
    local turnText
    if endTurn > 0 then
        turnText = tostring(turn) .. "/" .. tostring(endTurn - 1)
    else
        turnText = tostring(turn)
    end
    Controls.InfoTurnLabel:SetText(turnText)
    Controls.InfoDateLabel:SetText(Calendar.MakeYearStr(turn))
end

-- ===========================================================================
-- INFO PANEL 4-COLUMN CONTENT
-- ===========================================================================

function RefreshYieldsDisplay()
    m_YieldColIndex = 0

    local ePlayer = Game.GetLocalPlayer()
    if ePlayer == -1 then return end
    local localPlayer = Players[ePlayer]
    if localPlayer == nil then return end

    for _, yieldDef in ipairs(YIELD_TYPES) do
        local yieldType = yieldDef.key
        local valueText = nil

        if yieldType == "SCIENCE" and CanDisplayTopPanelYield("CAPABILITY_SCIENCE") then
            valueText = FormatPerTurnValue(localPlayer:GetTechs():GetScienceYield())
        elseif yieldType == "CULTURE" and CanDisplayTopPanelYield("CAPABILITY_CULTURE") then
            valueText = FormatPerTurnValue(localPlayer:GetCulture():GetCultureYield())
        elseif yieldType == "FAITH" and CanDisplayTopPanelYield("CAPABILITY_FAITH") then
            valueText = FormatPerTurnValue(localPlayer:GetReligion():GetFaithYield())
        elseif yieldType == "GOLD" and CanDisplayTopPanelYield("CAPABILITY_GOLD") then
            local playerTreasury = localPlayer:GetTreasury()
            valueText = FormatPerTurnValue(playerTreasury:GetGoldYield() - playerTreasury:GetTotalMaintenance())
        elseif yieldType == "TOURISM" and CanDisplayTopPanelYield("CAPABILITY_TOURISM") then
            local tourismRate = Round(localPlayer:GetStats():GetTourism(), 1)
            if tourismRate > 0 then
                valueText = Locale.ToNumber(tourismRate, "#,###.#")
            end
        end

        if valueText ~= nil then
            local colIdx = NextColIndex({[0] = m_YieldColIndex})
            m_YieldColIndex = colIdx
            local instance = m_YieldColumnIMs[colIdx]:GetInstance()
            instance.IconLabel:SetText(yieldDef.icon)
            instance.IconLabel:SetColor(UI.GetColorValueFromHexLiteral(0xffcccccc))
            instance.ValueLabel:SetText(valueText)
            instance.NameLabel:SetText(Locale.Lookup("LOC_MODMISC_YIELD_" .. yieldType))
        end
    end
end

function RefreshResourcesDisplay()
    -- 所有资源显示已从 InfoPanel 移除。
    m_ResourceColIndex = 0
end

function RefreshCustomGrids()
    m_CustomGridColIndex = 0
    m_CustomRowColIndex = 0

    for _, gridData in ipairs(m_RegisteredCustomGrids) do
        if gridData.manager ~= nil then
            gridData.instance = gridData.manager:GetInstance()
        end
        if gridData.refreshFunc ~= nil then
            local icon, text = gridData.refreshFunc()
            if icon ~= nil then
                SetIconOrTexture(gridData.instance.CustomIcon, icon)
            end
            if text ~= nil then
                gridData.instance.CustomLabel:SetText(text)
            end
        end
    end

    for _, rowData in ipairs(m_RegisteredCustomRows) do
        if rowData.manager ~= nil then
            rowData.instance = rowData.manager:GetInstance()
        end
        if rowData.refreshFunc ~= nil then
            local icon, label, value = rowData.refreshFunc()
            local topControl = rowData.instance:GetTopControl()
            print("[ModMiscDebug] RefreshCustomRow:", tostring(label), tostring(value),
                "root="..tostring(topControl and topControl:GetSizeX()).."x"..tostring(topControl and topControl:GetSizeY()),
                "hidden="..tostring(topControl and topControl:IsHidden()))
            if icon ~= nil then
                SetIconOrTexture(rowData.instance.CustomIcon, icon)
            end
            if label ~= nil then
                rowData.instance.CustomLabel:SetText(label)
            end
            if value ~= nil then
                rowData.instance.CustomValue:SetText(value)
            end
        end
    end
end

-- ===========================================================================
-- INFO PANEL OPEN / CLOSE
-- ===========================================================================

function RefreshInfoPanelLayout()
    if Controls.InfoContentRow == nil then return end

    -- 先计算 4 列自身高度，再计算内容行/滚动区，保证 Stack 自动尺寸正确。
    local maxColumnHeight = 0
    for i = 1, COLUMN_COUNT do
        local colStack = Controls["InfoColumn" .. i]
        if colStack ~= nil then
            colStack:CalculateSize()
            maxColumnHeight = math.max(maxColumnHeight, colStack:GetSizeY())
        end
    end

    for i = 1, COLUMN_COUNT do
        local colStack = Controls["InfoColumn" .. i]
        if colStack ~= nil then
            print("[ModMiscDebug] InfoColumn"..i.." size="..tostring(colStack:GetSizeX()).."x"..tostring(colStack:GetSizeY())
                .." offsetX="..tostring(colStack:GetOffsetX()))
        end
    end

    if Controls.InfoContentScrollPanel ~= nil then
        Controls.InfoContentRow:SetSizeX(Controls.InfoContentScrollPanel:GetSizeX())
    end
    Controls.InfoContentRow:SetSizeY(maxColumnHeight)
    print("[ModMiscDebug] InfoContentRow size="..tostring(Controls.InfoContentRow:GetSizeX()).."x"..tostring(Controls.InfoContentRow:GetSizeY()))

    if Controls.InfoContentScrollPanel ~= nil then
        Controls.InfoContentScrollPanel:CalculateSize()
        Controls.InfoContentScrollPanel:CalculateInternalSize()
    end
end

function OpenInfoPanel()
    m_bIsInfoPanelOpen = true

    ResetAllInfoColumns()
    RefreshInfoTopBar()
    -- 自定义行先刷新，避免被大量产出/资源行挤到最底部而看不见。
    RefreshCustomGrids()
    RefreshResourcesDisplay()
    RefreshInfoPanelLayout()

    Controls.InfoPanel:SetHide(false)
    Controls.InfoPanelSlide:Stop()
    Controls.InfoPanelSlide:SetToEnd()
    Controls.InfoPanelSlide:Reverse()

    UI.PlaySound("UI_Screen_Open")

	LuaEvents.ModMiscToolInfoPanelOpened.Call()
end

function CloseInfoPanel()
    m_bIsInfoPanelOpen = false
    Controls.InfoPanelSlide:Stop()
    Controls.InfoPanel:SetHide(true)

    LuaEvents.ModMiscToolInfoPanelClosed.Call()
end

function RefreshInfoPanel()
    if m_bIsInfoPanelOpen then
        RefreshInfoTopBar()
        ResetAllInfoColumns()
        RefreshCustomGrids()
        RefreshResourcesDisplay()
        RefreshInfoPanelLayout()
    end
end

function OnPresetInfoButtonClick()
    OpenInfoPanel()
end

-- ===========================================================================
-- SIDEBAR BUTTON REGISTRATION
-- ===========================================================================

function RegisterSidebarButton(icon, label, tooltip, callback)
    -- tooltip 参数保留以兼容旧调用；按钮右侧已有文字，当前不再设置 tooltip。
    if m_SidebarButtonIM == nil then
        table.insert(m_PendingSidebarButtons, {icon, label, tooltip, callback})
        print("[ModMiscDebug] RegisterSidebarButton queued:", tostring(label))
        return nil
    end

    local instance = m_SidebarButtonIM:GetInstance()
    local button = instance.SidebarActionButton

    -- InstanceManager 返回的 instance 表中包含实例内所有命名控件；
    -- 对于嵌套子控件，必须从 instance 表访问，不能从根控件再索引。
    local iconControl = instance.ButtonIcon
    local labelControl = instance.ButtonLabel

    if icon ~= nil and icon ~= "" and iconControl ~= nil then
        SetIconOrTexture(iconControl, icon)
    end
    if labelControl ~= nil then
        labelControl:SetText(label)
    end
    button:SetDisabled(not m_bIsExpanded)
    if callback ~= nil then
        button:RegisterCallback(Mouse.eLClick, callback)
    end

    local buttonData = {
        instance = instance, button = button,
        icon = icon, label = label, tooltip = tooltip, callback = callback,
    }
    table.insert(m_RegisteredButtons, buttonData)

    UpdateSidebarPaging()
    RefreshSidebarLayout()
    UpdateSidebarVisibility()
    return button, buttonData
end

function ClearSidebarButtons()
    if m_SidebarButtonIM == nil then return end

    m_SidebarButtonIM:ResetInstances()
    if Controls.InfoButton ~= nil then
        Controls.InfoButton:SetHide(true)
    end
    m_RegisteredButtons = {}
    m_SidebarPage = 1

    UpdateSidebarPaging()
    RefreshSidebarLayout()
    UpdateSidebarVisibility()
end

function RegisterCustomGrid(iconTexture, defaultText, refreshFunc)
    if m_CustomGridColumnIMs[1] == nil then
        table.insert(m_PendingCustomGrids, {iconTexture, defaultText, refreshFunc})
        print("[ModMiscDebug] RegisterCustomGrid queued:", tostring(defaultText))
        return nil
    end

    local colIdx = NextColIndex({[0] = m_CustomGridColIndex})
    m_CustomGridColIndex = colIdx
    local instance = m_CustomGridColumnIMs[colIdx]:GetInstance()
    if iconTexture ~= nil then
        SetIconOrTexture(instance.CustomIcon, iconTexture)
    end
    instance.CustomLabel:SetText(defaultText or "---")

    local gridData = {
        instance = instance,
        manager = m_CustomGridColumnIMs[colIdx],
        iconTexture = iconTexture,
        defaultText = defaultText,
        refreshFunc = refreshFunc,
    }
    table.insert(m_RegisteredCustomGrids, gridData)
    return instance
end

function RegisterCustomRow(iconTexture, defaultLabel, defaultValue, refreshFunc)
    if m_CustomRowColumnIMs[1] == nil then
        table.insert(m_PendingCustomRows, {iconTexture, defaultLabel, defaultValue, refreshFunc})
        print("[ModMiscDebug] RegisterCustomRow queued:", tostring(defaultLabel))
        return nil
    end

    local colIdx = NextColIndex({[0] = m_CustomRowColIndex})
    m_CustomRowColIndex = colIdx
    local instance = m_CustomRowColumnIMs[colIdx]:GetInstance()
    if iconTexture ~= nil then
        SetIconOrTexture(instance.CustomIcon, iconTexture)
    end
    instance.CustomLabel:SetText(defaultLabel or "???")
    instance.CustomValue:SetText(defaultValue or "---")

    local rowData = {
        instance = instance,
        manager = m_CustomRowColumnIMs[colIdx],
        iconTexture = iconTexture,
        defaultLabel = defaultLabel,
        defaultValue = defaultValue,
        refreshFunc = refreshFunc,
    }
    table.insert(m_RegisteredCustomRows, rowData)
    print("[ModMiscDebug] RegisterCustomRow registered:", tostring(defaultLabel), "col="..tostring(colIdx), "count="..#m_RegisteredCustomRows)
    return instance
end

-- ===========================================================================
-- MOVEMENT INTERCEPTOR REGISTRATION
--
-- Other mods can register a predicate:
--   function(moverID, ownerID) -> true / false
-- Return true only when the move is explicitly allowed by that mod's own
-- rule set. The Civ6Common replacement bypasses the UI war interception only
-- when at least one registered interceptor returns true.
-- ===========================================================================

function RegisterMovementInterceptor(interceptor)
    if type(interceptor) ~= "function" then
        return false, "INVALID_INTERCEPTOR"
    end
    table.insert(m_MovementInterceptors, interceptor)
    print("[ModMiscDebug] RegisterMovementInterceptor registered: count="
        .. tostring(#m_MovementInterceptors))
    return true
end

function ShouldInterceptMovement(moverID, ownerID)
    local result = false
    for _, interceptor in ipairs(m_MovementInterceptors) do
        if interceptor(moverID, ownerID) == true then
            result = true
            break
        end
    end
    print("[ModMiscDebug] ShouldInterceptMovement mover=" .. tostring(moverID)
        .. " owner=" .. tostring(ownerID)
        .. " registered=" .. tostring(#m_MovementInterceptors)
        .. " result=" .. tostring(result))
    return result
end

-- ===========================================================================
-- EVENTS
-- ===========================================================================

function OnLocalPlayerChanged(playerID)
    if playerID ~= -1 then
        if m_bIsInfoPanelOpen then
            OpenInfoPanel()
        end
    end
end

function OnTurnBegin()
    if m_bIsInfoPanelOpen then
        RefreshInfoPanel()
    end
end

-- ===========================================================================
-- INITIALIZATION
-- ===========================================================================

function FlushPendingModMiscRegistrations()
    print("[ModMiscDebug] Flush pending: sidebar="..#m_PendingSidebarButtons.." grids="..#m_PendingCustomGrids.." rows="..#m_PendingCustomRows)
    if #m_PendingCustomGrids > 0 then
        local pending = m_PendingCustomGrids
        m_PendingCustomGrids = {}
        for _, data in ipairs(pending) do
            RegisterCustomGrid(data[1], data[2], data[3])
        end
    end

    if #m_PendingCustomRows > 0 then
        local pending = m_PendingCustomRows
        m_PendingCustomRows = {}
        for _, data in ipairs(pending) do
            RegisterCustomRow(data[1], data[2], data[3], data[4])
        end
    end

    if #m_PendingSidebarButtons > 0 then
        local pending = m_PendingSidebarButtons
        m_PendingSidebarButtons = {}
        for _, data in ipairs(pending) do
            RegisterSidebarButton(data[1], data[2], data[3], data[4])
        end
    end
end

-- 屏幕尺寸变化时保持根容器与屏幕一致，并重新计算滑动距离。
function OnSystemUpdateUI(type)
    if type == SystemUpdateUI.ScreenResize then
        local screenX, screenY = UIManager:GetScreenSizeVal()
        Controls.LeftSideBarRoot:SetSizeVal(screenX, screenY)
        Controls.LeftSideBarRoot:ReprocessAnchoring()
        UpdateSidebarPaging()
        RefreshSidebarLayout()
    end
end

function Initialize()
    print("LeftSideBar Init: ButtonStack=", Controls.ButtonStack,
        "InfoColumn1=", Controls.InfoColumn1)

    -- 将整个侧栏挂载到游戏主界面
    Controls.LeftSideBarRoot:ChangeParent(ContextPtr:LookUpControl("/InGame"))

    -- 根容器撑满屏幕，保证 L,C / C,C 锚点基于整个屏幕计算
    local screenX, screenY = UIManager:GetScreenSizeVal()
    Controls.LeftSideBarRoot:SetSizeVal(screenX, screenY)
    Controls.LeftSideBarRoot:ReprocessAnchoring()

    -- 侧栏按钮 InstanceManager
    if Controls.ButtonStack ~= nil then
        m_SidebarButtonIM = InstanceManager:new(
            "SidebarButtonInstance", "SidebarActionButton", Controls.ButtonStack)
    end

    -- InfoPanel 4列 InstanceManager
    for i = 1, COLUMN_COUNT do
        local colStack = Controls["InfoColumn" .. i]
        if colStack ~= nil then
            m_YieldColumnIMs[i] = InstanceManager:new(
                "YieldGridInstance", "Grid", colStack)
            m_ResourceColumnIMs[i] = InstanceManager:new(
                "ResourceRowInstance", "Row", colStack)
            m_CustomGridColumnIMs[i] = InstanceManager:new(
                "CustomGridInstance", "Grid", colStack)
            m_CustomRowColumnIMs[i] = InstanceManager:new(
                "CustomRowInstance", "Row", colStack)
        end
    end

    -- 按钮回调
    Controls.ToggleButton:RegisterCallback(Mouse.eLClick, ToggleSidebar)
    Controls.InfoCloseButton:RegisterCallback(Mouse.eLClick, CloseInfoPanel)
    Controls.PageUpButton:RegisterCallback(Mouse.eLClick, OnSidebarPageUp)
    Controls.PageDownButton:RegisterCallback(Mouse.eLClick, OnSidebarPageDown)

    -- 初始状态：折叠；隐藏状态不持久化，每次重新进入游戏都恢复展开键透明度
    m_bIsExpanded = false
    m_bHideToggleButton = false
    ApplySidebarToggleVisuals()
    SetSidebarButtonsEnabled(false)

    -- 注册预设按钮（固定写在 XML 的 InfoButton，方便人工检查）
    local infoButton = Controls.InfoButton
    if infoButton ~= nil then
        if Controls.InfoIcon ~= nil then
            Controls.InfoIcon:SetTexture("Controls_Info")
        end
        if Controls.InfoLabel ~= nil then
            Controls.InfoLabel:SetText(Locale.Lookup("LOC_MODMISC_PRESET_BUTTON"))
        end
        infoButton:SetDisabled(true)
        infoButton:RegisterCallback(Mouse.eLClick, OnPresetInfoButtonClick)

        table.insert(m_RegisteredButtons, {
            button = infoButton,
            icon = "Controls_Info",
            label = Locale.Lookup("LOC_MODMISC_PRESET_BUTTON"),
            callback = OnPresetInfoButtonClick,
        })
    end

    -- 隐藏侧栏按钮：通过 InstanceManager 创建真实实例，避免直接 XML 控件缺失或布局异常
    local _, hideButtonData = RegisterSidebarButton(
        SIDEBAR_HIDE_ICON,
        Locale.Lookup("LOC_MODMISC_HIDE_SIDEBAR"),
        Locale.Lookup("LOC_MODMISC_HIDE_SIDEBAR_TOOLTIP"),
        HideSidebar)
    m_HideSidebarButtonData = hideButtonData
    UpdateHideSidebarButtonVisuals()

    -- 处理其他 mod 在初始化前提交的注册请求
    print("[ModMiscDebug] Initialize before flush: rows="..#m_RegisteredCustomRows)
    FlushPendingModMiscRegistrations()
    print("[ModMiscDebug] Initialize after flush: rows="..#m_RegisteredCustomRows)

    -- 首次布局：分页 + 计算滑动终点并同步到折叠状态
    UpdateSidebarPaging()
    RefreshSidebarLayout()
    UpdateSidebarVisibility()

    -- 事件
    Events.LocalPlayerChanged.Add(OnLocalPlayerChanged)
    Events.TurnBegin.Add(OnTurnBegin)
    Events.SystemUpdateUI.Add(OnSystemUpdateUI)

    -- 暴露 API
    if not ExposedMembers.ModMiscToolUI then
        ExposedMembers.ModMiscToolUI = {}
    end
    ExposedMembers.ModMiscToolUI.RegisterSidebarButton = RegisterSidebarButton
    ExposedMembers.ModMiscToolUI.ClearSidebarButtons = ClearSidebarButtons
    ExposedMembers.ModMiscToolUI.ToggleSidebar = ToggleSidebar
    ExposedMembers.ModMiscToolUI.ExpandSidebar = ExpandSidebar
    ExposedMembers.ModMiscToolUI.CollapseSidebar = CollapseSidebar
    ExposedMembers.ModMiscToolUI.HideSidebar = HideSidebar
    ExposedMembers.ModMiscToolUI.OpenInfoPanel = OpenInfoPanel
    ExposedMembers.ModMiscToolUI.CloseInfoPanel = CloseInfoPanel
    ExposedMembers.ModMiscToolUI.RefreshInfoPanel = RefreshInfoPanel
    ExposedMembers.ModMiscToolUI.RegisterCustomGrid = RegisterCustomGrid
    ExposedMembers.ModMiscToolUI.RegisterCustomRow = RegisterCustomRow
    ExposedMembers.ModMiscToolUI.RegisterMovementInterceptor = RegisterMovementInterceptor
    ExposedMembers.ModMiscToolUI.ShouldInterceptMovement = ShouldInterceptMovement

    -- 其他 mod 的 UI 可能先于本 UI 初始化并提交了注册；初始化完成后广播一次。
    LuaEvents.ModMiscToolUIReady.Call()

    print("LeftSideBar: Initialized")
end
-- 提前暴露注册 API：即使其他 mod 的 UI 先加载，也可以先提交注册，
-- 等 LeftSideBar 初始化完成后由 FlushPendingModMiscRegistrations() 统一处理。
if not ExposedMembers.ModMiscToolUI then
    ExposedMembers.ModMiscToolUI = {}
end
ExposedMembers.ModMiscToolUI.RegisterSidebarButton = RegisterSidebarButton
ExposedMembers.ModMiscToolUI.RegisterCustomGrid = RegisterCustomGrid
ExposedMembers.ModMiscToolUI.RegisterCustomRow = RegisterCustomRow
ExposedMembers.ModMiscToolUI.RegisterMovementInterceptor = RegisterMovementInterceptor
ExposedMembers.ModMiscToolUI.ShouldInterceptMovement = ShouldInterceptMovement

Events.LoadGameViewStateDone.Add(Initialize)
