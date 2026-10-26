-- ===========================================================================
-- 幽灵玩家 debug 面板（2026-10-26 授权者要求）
--
-- 入口：左侧栏按钮 —— **只有本局存在幽灵玩家时才注册**（幽灵池为空就不注册）。
-- 交互：上方滚动栏**只显示信息**；点一行选中该条目（幽灵 + 其余存活玩家），再用底部按钮执行：
--         幽灵：城邦化 / 主流化 / 建城；
--         任何玩家：「杀死」= 名下城市全部 CityManager.TransferCityToFreeCities
--                             转成自由城市（对齐 GrayFox BanPlayer），**不杀单位**；
--         另有「救档」= 一键把**还没见面**的主流幽灵全部转成城邦。
--
-- 职责边界：本文件只负责显示、选中与转发；判定与执行全部在 gameplay 侧
-- （ModTool_GhostPlayers.lua 的 GetPlayerDebugList / ConvertGhostPlayerToCityState
--   / RestoreGhostPlayerAsMajor / FoundCityForGhostPlayer / KillSelectedPlayer
--   / ConvertUnmetMajorGhostsToCityState）。
-- ===========================================================================
include("InstanceManager")

local m_ListIM = nil
local m_bSidebarRegistered = false
local m_bPanelAttached = false

local m_SelectedPlayerID = nil
local m_LastList = {}
local m_Rows = {}

-- ===========================================================================
-- 屏幕缩放（XML 只当设计基准；行按当前 scale 创建）
-- ===========================================================================
local DESIGN_WIDTH, DESIGN_HEIGHT = 900, 840
local SCREEN_MARGIN = 40
local MIN_SCALE = 0.85
local MAX_SCALE = 1.5

local m_Scale = 1.0
local m_BaseLayout = nil
local m_BaseFonts = {}

local GEOMETRY_CONTROLS = {
	"GhostDebugRoot",
	"GhostDebugHeader",
	"GhostDebugTitle",
	"GhostDebugClose",
	"GhostDebugStatus",
	"GhostDebugHint",
	"GhostDebugListFrame",
	"GhostDebugSelection",
	"GhostDebugActionCityState",
	"GhostDebugActionMajor",
	"GhostDebugActionFoundCity",
	"GhostDebugActionRemove",
	"GhostDebugRescue",
	"GhostDebugRefresh",
	"GhostDebugResult",
}

local FONT_CONTROLS = {
	"GhostDebugTitle",
	"GhostDebugStatus",
	"GhostDebugHint",
	"GhostDebugSelection",
	"GhostDebugActionCityState",
	"GhostDebugActionMajor",
	"GhostDebugActionFoundCity",
	"GhostDebugActionRemove",
	"GhostDebugRescue",
	"GhostDebugRefresh",
	"GhostDebugResult",
}

-- 不同控件类型暴露字号的位置不同，这里两种都试一次（取不到就跳过）
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
		if control ~= nil then
			table.insert(m_BaseLayout, {
				control = control,
				sizeX = control:GetSizeX(),
				sizeY = control:GetSizeY(),
				offsetX = control:GetOffsetX(),
				offsetY = control:GetOffsetY(),
			})
		end
	end
	for _, name in ipairs(FONT_CONTROLS) do
		if Controls[name] ~= nil then m_BaseFonts[name] = GetControlFontSize(Controls[name]) end
	end
end

local function GetScreenSize()
	local screenX, screenY = UIManager:GetScreenSizeVal()
	if screenX == nil or screenY == nil or screenX <= 0 or screenY <= 0 then return nil end
	return screenX, screenY
end

local function ComputeScale(screenX, screenY)
	local scaleByHeight = math.min(screenY - SCREEN_MARGIN, DESIGN_HEIGHT * MAX_SCALE) / DESIGN_HEIGHT
	local scaleByWidth = math.min(screenX - SCREEN_MARGIN, DESIGN_WIDTH * MAX_SCALE) / DESIGN_WIDTH
	local scale = math.min(scaleByHeight, scaleByWidth)
	return math.max(MIN_SCALE, math.min(MAX_SCALE, scale))
end

local function ApplyPanelScale()
	if m_BaseLayout == nil then CaptureBaseLayout() end

	local screenX, screenY = GetScreenSize()
	if screenX == nil then return end

	local scale = ComputeScale(screenX, screenY)
	if scale == m_Scale then return end
	m_Scale = scale

	for _, entry in ipairs(m_BaseLayout) do
		entry.control:SetSizeVal(math.floor(entry.sizeX * scale + 0.5),
			math.floor(entry.sizeY * scale + 0.5))
		entry.control:SetOffsetVal(math.floor(entry.offsetX * scale + 0.5),
			math.floor(entry.offsetY * scale + 0.5))
	end
	for _, name in ipairs(FONT_CONTROLS) do
		local baseFont = m_BaseFonts[name]
		if baseFont ~= nil and Controls[name] ~= nil then
			SetControlFontSize(Controls[name], math.max(12, math.floor(baseFont * scale + 0.5)))
		end
	end
	pcall(function() Controls.GhostDebugStatus:SetWrapWidth(Controls.GhostDebugStatus:GetSizeX()) end)
	pcall(function() Controls.GhostDebugSelection:SetWrapWidth(Controls.GhostDebugSelection:GetSizeX()) end)
	pcall(function() Controls.GhostDebugResult:SetWrapWidth(Controls.GhostDebugResult:GetSizeX()) end)
	Controls.GhostDebugRoot:ReprocessAnchoring()

	-- 行是动态创建的：缩放变了就按新 scale 重建
	if not Controls.GhostDebugRoot:IsHidden() then RefreshGhostDebugList() end

	print("[ModMiscTool][GhostDebug] screen=" .. tostring(screenX) .. "x" .. tostring(screenY)
		.. " scale=" .. tostring(scale))
end

-- ===========================================================================
-- 列表行布局（设计基准；创建/重建时按当前 scale 应用）
-- ===========================================================================
local ROW_LAYOUT = {
	width = 840,
	height = 100,
	title = { x = 14, y = 8, width = 812, height = 28, fontSize = 23 },
	sub = { x = 14, y = 38, width = 812, height = 58, fontSize = 18 },
}

local function ScaleValue(value)
	return math.floor(value * m_Scale + 0.5)
end

local function ApplyRowLayout(instance)
	instance.EntryRoot:SetSizeVal(ScaleValue(ROW_LAYOUT.width), ScaleValue(ROW_LAYOUT.height))
	instance.EntryTitle:SetOffsetVal(ScaleValue(ROW_LAYOUT.title.x), ScaleValue(ROW_LAYOUT.title.y))
	instance.EntryTitle:SetSizeVal(ScaleValue(ROW_LAYOUT.title.width), ScaleValue(ROW_LAYOUT.title.height))
	pcall(function() instance.EntryTitle:SetTruncateWidth(ScaleValue(ROW_LAYOUT.title.width)) end)
	SetControlFontSize(instance.EntryTitle, math.max(12, ScaleValue(ROW_LAYOUT.title.fontSize)))
	instance.EntrySub:SetOffsetVal(ScaleValue(ROW_LAYOUT.sub.x), ScaleValue(ROW_LAYOUT.sub.y))
	instance.EntrySub:SetSizeVal(ScaleValue(ROW_LAYOUT.sub.width), ScaleValue(ROW_LAYOUT.sub.height))
	pcall(function() instance.EntrySub:SetWrapWidth(ScaleValue(ROW_LAYOUT.sub.width)) end)
	SetControlFontSize(instance.EntrySub, math.max(12, ScaleValue(ROW_LAYOUT.sub.fontSize)))
end

-- ===========================================================================
-- 文本（全部走 LOC；数字/坐标/诊断码属于数据，不翻译）
-- ===========================================================================
local function LocalizedTypeName(kind, typeName)
	if typeName == nil or typeName == "" then return "?" end
	local row = nil
	if kind == "civ" then
		row = GameInfo.Civilizations[typeName]
	else
		row = GameInfo.Leaders[typeName]
	end
	if row == nil or row.Name == nil then return tostring(typeName) end
	local localized = Locale.Lookup(row.Name)
	if localized == nil or localized == "" or localized == row.Name then
		return tostring(typeName)
	end
	return localized
end

local function PoolLabel(poolType)
	if poolType == "citystate" then
		return Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_POOL_CITYSTATE")
	end
	if poolType == "player" then
		return Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_POOL_PLAYER")
	end
	return Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_POOL_MAJOR")
end

local function StateLabel(isMajor)
	if isMajor == true then return Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_STATE_MAJOR") end
	if isMajor == false then return Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_STATE_CITYSTATE") end
	return Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_STATE_UNKNOWN")
end

local function BuildRowTitle(entry)
	return Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_ROW_TITLE",
		tostring(entry.playerID), PoolLabel(entry.pool), StateLabel(entry.isMajor))
end

local function BuildRowSub(entry)
	local identityLine = LocalizedTypeName("civ", entry.civType) .. " / "
		.. LocalizedTypeName("leader", entry.leaderType)
	if entry.originalCivType ~= nil and entry.originalCivType ~= entry.civType then
		identityLine = identityLine .. " · " .. Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_ORIGINAL",
			LocalizedTypeName("civ", entry.originalCivType))
	end

	local flags = {}
	if entry.met then table.insert(flags, Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_FLAG_MET")) end
	-- 「可用 / 使用中 / 已预约」只对幽灵池条目有意义，普通玩家不显示
	if entry.isGhost == true then
		if entry.available then
			table.insert(flags, Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_FLAG_AVAILABLE"))
		else
			table.insert(flags, Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_FLAG_IN_USE"))
		end
		if entry.claimed then table.insert(flags, Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_FLAG_CLAIMED")) end
	end
	if entry.hasCity then table.insert(flags, Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_FLAG_HAS_CITY")) end
	if entry.hasOnMapUnit then
		table.insert(flags, Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_FLAG_ON_MAP_UNIT"))
	end

	-- Civ6 的文本换行用 [NEWLINE] 标记
	return identityLine .. "[NEWLINE]" .. table.concat(flags, ", ")
end

local function UpdateStatusLine(list)
	local majorCount, cityStateCount, availableCount, claimedCount, playerCount = 0, 0, 0, 0, 0
	for _, entry in ipairs(list) do
		if entry.isGhost == true then
			if entry.pool == "citystate" then
				cityStateCount = cityStateCount + 1
			else
				majorCount = majorCount + 1
			end
			if entry.available then availableCount = availableCount + 1 end
			if entry.claimed then claimedCount = claimedCount + 1 end
		else
			playerCount = playerCount + 1
		end
	end
	Controls.GhostDebugStatus:SetText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_STATUS",
		tostring(majorCount), tostring(cityStateCount),
		tostring(availableCount), tostring(claimedCount), tostring(playerCount)))
end

-- ===========================================================================
-- 数据来源：gameplay 侧唯一入口（UI 不直接读存档属性）
-- ===========================================================================
-- 列表来源：优先 GetPlayerDebugList（幽灵 + 全部存活玩家）；老版本退回 GetGhostPlayerDebugList
local function GetDebugList()
	if ExposedMembers == nil or ExposedMembers.ModMiscToolScript == nil then return nil end
	local api = ExposedMembers.ModMiscToolScript
	local list = nil
	if api.GetPlayerDebugList ~= nil then
		local ok, result = pcall(api.GetPlayerDebugList)
		if ok and type(result) == "table" then
			list = result
		else
			print("[ModMiscTool][GhostDebug] GetPlayerDebugList 失败：" .. tostring(result))
		end
	end
	if list == nil and api.GetGhostPlayerDebugList ~= nil then
		local ok, result = pcall(api.GetGhostPlayerDebugList)
		if ok and type(result) == "table" then
			list = result
		else
			print("[ModMiscTool][GhostDebug] GetGhostPlayerDebugList 失败：" .. tostring(result))
		end
	end
	return list
end

local function FindEntry(playerID)
	for _, entry in ipairs(m_LastList) do
		if entry.playerID == playerID then return entry end
	end
	return nil
end

-- ===========================================================================
-- 选中态
-- ===========================================================================
local SELECTED_TITLE_COLOR = { 1.0, 0.86, 0.45, 1.0 }
local NORMAL_TITLE_COLOR = { 0.92, 0.92, 0.92, 1.0 }

local function ApplyRowContent(instance, entry)
	local selected = (entry.playerID == m_SelectedPlayerID)
	instance.EntryTitle:SetText((selected and "> " or "") .. BuildRowTitle(entry))
	instance.EntrySub:SetText(BuildRowSub(entry))
	local color = selected and SELECTED_TITLE_COLOR or NORMAL_TITLE_COLOR
	pcall(function()
		instance.EntryTitle:SetColor(color[1], color[2], color[3], color[4])
	end)
end

local function BindRowCallbacks(instance)
	if instance.mmtRowBound == true then return end
	instance.mmtRowBound = true
	instance.EntryRoot:RegisterCallback(Mouse.eLClick, function()
		SelectGhost(instance.playerID)
	end)
end

local function UpdateSelectionLabel()
	local entry = nil
	if m_SelectedPlayerID ~= nil then entry = FindEntry(m_SelectedPlayerID) end
	if entry == nil then
		Controls.GhostDebugSelection:SetText(
			Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_SELECTED_NONE"))
		return
	end
	Controls.GhostDebugSelection:SetText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_SELECTED",
		tostring(entry.playerID), PoolLabel(entry.pool), StateLabel(entry.isMajor),
		LocalizedTypeName("civ", entry.civType)))
end

local function SetButtonDisabled(button, disabled)
	if button == nil then return end
	pcall(function() button:SetDisabled(disabled == true) end)
end

local function CountUnmetMajorCandidates()
	local count = 0
	for _, entry in ipairs(m_LastList) do
		if entry.pool == "major" and entry.met ~= true and entry.available == true
			and entry.hasCity ~= true then
			count = count + 1
		end
	end
	return count
end

local function UpdateActionButtons()
	local entry = nil
	if m_SelectedPlayerID ~= nil then entry = FindEntry(m_SelectedPlayerID) end
	local hasSelection = (entry ~= nil)
	-- 城邦化 / 主流化 / 建城只对幽灵池条目有意义；「杀死」对任何选中玩家都可用
	local isGhost = hasSelection and entry.isGhost == true
	SetButtonDisabled(Controls.GhostDebugActionCityState, not isGhost)
	SetButtonDisabled(Controls.GhostDebugActionMajor, not isGhost)
	SetButtonDisabled(Controls.GhostDebugActionFoundCity, not isGhost)
	SetButtonDisabled(Controls.GhostDebugActionRemove, not hasSelection)
	SetButtonDisabled(Controls.GhostDebugRescue, CountUnmetMajorCandidates() <= 0)
end

function SelectGhost(playerID)
	if playerID == nil then return end
	if m_SelectedPlayerID == playerID then return end
	m_SelectedPlayerID = playerID
	for _, row in ipairs(m_Rows) do
		ApplyRowContent(row.instance, row.entry)
	end
	UpdateSelectionLabel()
	UpdateActionButtons()
end

-- ===========================================================================
-- 操作：全部转发 gameplay；这里只负责显示结果
-- ===========================================================================
local ACTION_LABEL_KEYS = {
	citystate = "LOC_MODMISC_GHOST_DEBUG_ACTION_CITYSTATE",
	major = "LOC_MODMISC_GHOST_DEBUG_ACTION_MAJOR",
	found_city = "LOC_MODMISC_GHOST_DEBUG_ACTION_FOUND_CITY",
	remove = "LOC_MODMISC_GHOST_DEBUG_ACTION_REMOVE",
}

local function SetResultText(text)
	Controls.GhostDebugResult:SetText(text)
end

local function DoAction(playerID, action)
	if playerID == nil then return end
	if ExposedMembers == nil or ExposedMembers.ModMiscToolScript == nil then return end
	local api = ExposedMembers.ModMiscToolScript
	local actionLabel = Locale.Lookup(ACTION_LABEL_KEYS[action] or "")

	local ok, success, detail, countA, countB, countC = pcall(function()
		if action == "citystate" then
			return api.ConvertGhostPlayerToCityState(playerID, nil, "debug_panel")
		elseif action == "major" then
			return api.RestoreGhostPlayerAsMajor(playerID)
		elseif action == "found_city" then
			return api.FoundCityForGhostPlayer(playerID)
		elseif action == "remove" then
			-- 杀死任意选中玩家：有城市 ⇒ 全部转自由城市；**不杀单位**（见 gameplay 侧注释）
			local killPlayer = api.KillSelectedPlayer or api.RemoveGhostPlayerByKillingUnits
			if killPlayer == nil then return false, "no_api" end
			return killPlayer(playerID)
		end
		return false, "unknown_action"
	end)

	if not ok then
		SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_FAIL",
			tostring(playerID), actionLabel, tostring(success)))
	elseif success == true then
		if action == "found_city" and countA ~= nil then
			SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_CITY",
				tostring(playerID), tostring(countA), tostring(countB)))
		elseif action == "remove" and detail == "no_city" then
			SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_REMOVE_NO_CITY",
				tostring(playerID), tostring(countC or 0)))
		elseif action == "remove" then
			SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_REMOVE",
				tostring(playerID), tostring(countA or 0), tostring(countB or 0),
				tostring(countC or 0)))
		else
			SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_OK",
				tostring(playerID), actionLabel))
		end
	else
		SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_FAIL",
			tostring(playerID), actionLabel, tostring(detail)))
	end

	RefreshGhostDebugList()
end

local function RunSelectedAction(action)
	local entry = nil
	if m_SelectedPlayerID ~= nil then entry = FindEntry(m_SelectedPlayerID) end
	if entry == nil then
		SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_SELECTED_NONE"))
		return
	end
	DoAction(entry.playerID, action)
end

-- 救档：一键把未见面主流幽灵转成城邦
local function DoRescue()
	if ExposedMembers == nil or ExposedMembers.ModMiscToolScript == nil then return end
	local api = ExposedMembers.ModMiscToolScript
	if api.ConvertUnmetMajorGhostsToCityState == nil then return end

	local ok, converted, failed, skipped = pcall(api.ConvertUnmetMajorGhostsToCityState)
	if not ok then
		SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_FAIL",
			"?", Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_ACTION_RESCUE"),
			tostring(converted)))
	else
		SetResultText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_RESULT_RESCUE",
			tostring(converted or 0), tostring(failed or 0), tostring(skipped or 0)))
	end
	RefreshGhostDebugList()
end

-- ===========================================================================
-- 刷新
-- ===========================================================================
function RefreshGhostDebugList()
	if m_ListIM == nil then return end
	local list = GetDebugList()
	m_LastList = list or {}
	m_Rows = {}
	m_ListIM:ResetInstances()

	if #m_LastList == 0 then
		m_SelectedPlayerID = nil
		Controls.GhostDebugStatus:SetText(Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_EMPTY"))
	else
		UpdateStatusLine(m_LastList)
		-- 选中的玩家已经不在列表里（被移除 / 建城出池）⇒ 清选择
		if m_SelectedPlayerID ~= nil and FindEntry(m_SelectedPlayerID) == nil then
			m_SelectedPlayerID = nil
		end
		for _, entry in ipairs(m_LastList) do
			local instance = m_ListIM:GetInstance()
			instance.playerID = entry.playerID
			BindRowCallbacks(instance)
			ApplyRowLayout(instance)
			ApplyRowContent(instance, entry)
			table.insert(m_Rows, { instance = instance, entry = entry })
		end
	end

	Controls.GhostDebugList:CalculateSize()
	pcall(function() Controls.GhostDebugScroll:CalculateInternalSize() end)
	UpdateSelectionLabel()
	UpdateActionButtons()
end

-- ===========================================================================
-- 面板打开 / 关闭 / 挂载
-- ===========================================================================
local function AttachPanelToInGame()
	if m_bPanelAttached then return Controls.GhostDebugRoot end
	local panelRoot = Controls.GhostDebugRoot
	local inGameRoot = ContextPtr:LookUpControl("/InGame")
	if inGameRoot ~= nil then
		panelRoot:ChangeParent(inGameRoot)
		panelRoot:ReprocessAnchoring()
		m_bPanelAttached = true
	end
	return panelRoot
end

function OpenGhostDebugPanel()
	AttachPanelToInGame()
	Controls.GhostDebugRoot:SetHide(false)
	ApplyPanelScale()
	Controls.GhostDebugRoot:ReprocessAnchoring()
	SetResultText("")
	RefreshGhostDebugList()
	print("[ModMiscTool][GhostDebug] 面板已打开 hidden="
		.. tostring(Controls.GhostDebugRoot:IsHidden()))
end

function CloseGhostDebugPanel()
	Controls.GhostDebugRoot:SetHide(true)
end

function ToggleGhostDebugPanel()
	if Controls.GhostDebugRoot:IsHidden() then
		OpenGhostDebugPanel()
	else
		CloseGhostDebugPanel()
	end
end

-- ===========================================================================
-- 左侧栏入口：**只有本局存在幽灵玩家时才注册**
-- 幽灵池在 LoadGameViewStateDone 才建好，UI 初始化顺序不保证，所以多挂几个时机重试。
-- ===========================================================================
local function TryRegisterSidebarButton()
	if m_bSidebarRegistered then return end
	if ExposedMembers == nil or ExposedMembers.ModMiscToolUI == nil then return end
	if ExposedMembers.ModMiscToolUI.RegisterSidebarButton == nil then return end

	local list = GetDebugList()
	if list == nil then return end
	-- 入口注册条件保持不变：本局必须有幽灵；列表里的普通玩家只是“杀死”的可选目标
	local ghostCount = 0
	for _, entry in ipairs(list) do
		if entry.isGhost == true then ghostCount = ghostCount + 1 end
	end
	if ghostCount == 0 then return end

	ExposedMembers.ModMiscToolUI.RegisterSidebarButton(
		"ICON_UNITOPERATION_FOUND_CITY",
		Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_TITLE"),
		Locale.Lookup("LOC_MODMISC_GHOST_DEBUG_TOOLTIP"),
		OpenGhostDebugPanel)
	m_bSidebarRegistered = true
	print("[ModMiscTool][GhostDebug] 左侧栏入口已注册（幽灵 " .. tostring(ghostCount)
		.. " 个，可杀死玩家 " .. tostring(#list) .. " 个）")
end

-- ===========================================================================
-- 初始化与事件
-- ===========================================================================
function OnGhostDebugSystemUpdateUI(updateType)
	if updateType == SystemUpdateUI.ScreenResize then
		ApplyPanelScale()
	end
end

function OnInit()
	Controls.GhostDebugRoot:SetHide(true)
	CaptureBaseLayout()

	m_ListIM = InstanceManager:new("GhostDebugEntry", "EntryRoot", Controls.GhostDebugList)

	Controls.GhostDebugClose:RegisterCallback(Mouse.eLClick, CloseGhostDebugPanel)
	Controls.GhostDebugActionCityState:RegisterCallback(Mouse.eLClick, function()
		RunSelectedAction("citystate")
	end)
	Controls.GhostDebugActionMajor:RegisterCallback(Mouse.eLClick, function()
		RunSelectedAction("major")
	end)
	Controls.GhostDebugActionFoundCity:RegisterCallback(Mouse.eLClick, function()
		RunSelectedAction("found_city")
	end)
	Controls.GhostDebugActionRemove:RegisterCallback(Mouse.eLClick, function()
		RunSelectedAction("remove")
	end)
	Controls.GhostDebugRescue:RegisterCallback(Mouse.eLClick, DoRescue)
	Controls.GhostDebugRefresh:RegisterCallback(Mouse.eLClick, function()
		RefreshGhostDebugList()
	end)

	if Events.SystemUpdateUI ~= nil then
		Events.SystemUpdateUI.Add(OnGhostDebugSystemUpdateUI)
	end
	UpdateSelectionLabel()
	UpdateActionButtons()
end

-- 其他 mod / 本 mod 的 UI 工具可主动打开（排障用）
if ExposedMembers ~= nil then
	ExposedMembers.ModMiscToolUI = ExposedMembers.ModMiscToolUI or {}
	ExposedMembers.ModMiscToolUI.OpenGhostDebugPanel = OpenGhostDebugPanel
	ExposedMembers.ModMiscToolUI.CloseGhostDebugPanel = CloseGhostDebugPanel
	ExposedMembers.ModMiscToolUI.ToggleGhostDebugPanel = ToggleGhostDebugPanel
end

Events.LoadGameViewStateDone.Add(function()
	AttachPanelToInGame()
	TryRegisterSidebarButton()
end)
Events.LocalPlayerTurnBegin.Add(TryRegisterSidebarButton)
if Events.LocalPlayerChanged ~= nil then
	Events.LocalPlayerChanged.Add(TryRegisterSidebarButton)
end
LuaEvents.ModMiscToolUIReady.Add(TryRegisterSidebarButton)
ContextPtr:SetInitHandler(OnInit)
