-- ===========================================================================
-- Mod Misc Tool: 存档与换图（成品面板，UI 层）
--
-- 入口：左侧栏按钮（与其它面板同一套 ExposedMembers.ModMiscToolUI.RegisterSidebarButton）。
--
-- 做三件事：
--   1. 「存档」：按固定格式给当前局存一档，主线 / 分支由 mod 自动判（见 ModMiscSaveGraph）；
--   2. 「换图」：先存原档 → 记下“新局是这条线的分支” → Network.RestartGame()
--      —— 换图只能靠重开：对局内换地图脚本 / 改回合 / 改年代实测都不生效
--         （API_Verification_Status.md 第 12、13 节）；
--   3. 关系树：把本 mod 格式的档按主线 / 分支渲染出来，标出「本局」与「父档不在列表」。
--
-- 数据全部来自存档文件名（跨存档唯一可用通道），所以**格式不能改**；
-- 游戏自带存档菜单存的档不带这个格式，不会进这棵树（这是有意的：
-- 玩家为了 SL 随便存多少档都不会污染关系树）。
--
-- 所有调用都包 pcall；失败信息进状态行与详情区，同时 print 到 Lua.log。
-- ===========================================================================

include("InstanceManager")
include("Civ6Common")         -- WriteCustomData / ReadCustomData（**必须**：节点身份随档保存靠它；
                              --  每个 context 各自一份环境，别指望 Support_UI 那边 include 过）
include("ModMiscStore")       -- 跨存档存储：主线头 / 待接分支
include("ModMiscSaveGraph")   -- 存档关系树 + 换图流程
print("[ModMiscTool][SavePanel] panel loading build=" .. tostring(MODMISC_BUILD_TAG))

local m_Registered = false
local m_EntryIM = nil

-- 事件：预设类型（金币 / 单位 / 资源）+ 内容（金额 / 单位类型 / 资源类型）+ 接受回合
local EVENT_TYPE_DEFS = {
    { Key = "GOLD",     Text = "LOC_MODMISC_TURNEVENT_TYPE_GOLD",     DetailKind = "amount" },
    { Key = "UNIT",     Text = "LOC_MODMISC_TURNEVENT_TYPE_UNIT",     DetailKind = "unit" },
    { Key = "RESOURCE", Text = "LOC_MODMISC_TURNEVENT_TYPE_RESOURCE", DetailKind = "resource" },
}
local GOLD_AMOUNTS = { 50, 100, 200, 500 }
local EVENT_TURN_OFFSETS = { 0, 5, 10 }
local EVENT_LIST_MAX = 80

local m_SelectedNode = nil        -- 关系树里选中的节点（发送事件 / 读档 / 删除的目标）

-- 换图（授权者 2026-10-06 定稿）：**“存原档”和“重开”分开占两次点击**。
--
--   ① 点「切换到选中」→ 确认（引擎弹窗；本上下文没有弹窗时退化成“再点一次确认”）。
--      确认下来的这一下**只做两件事**：写交接单 + 存当前档（`PrepareSwitch`），**绝不重开**
--      （存原档放到弹窗回调里是安全的：引擎自己的存档菜单也在弹窗回调里调 Network.SaveGame）。
--   ② 原档在存档列表里**确认落盘后**，再点一次 → **这次点击只调 `Network.RestartGame()`**
--
-- 为什么非要分开：实机证明 `Network.RestartGame()` **只有在按钮回调里直接调**才有效
-- （弹窗回调 / 事件回调 / 按帧回调里调都是“返回了但游戏不重开”，第 42 条），
-- 而且存档还在写的时候重开既可能被引擎直接忽略、也可能把原档截断（异步排队写，第 19.13 条）。
-- 所以重开那一次点击的回调里**不做别的事**——这是唯一被实机验证过的调用形态。
--
-- 实机 2026-10-06 的“切换失败”根因（Lua.log 可查）：面板这个上下文里 `PopupDialogInGame` 是 nil，
-- 走的是“再点一次确认”那条退化成路，而它拿**闭包对象**比相等 —— 每次点击都是新闭包，永远不相等，
-- 于是永远停在“Tap again to confirm”。现在改成用**稳定的键**（目标 id）比。
local m_RestartReady = nil         -- 原档状态已知（确认落盘 / 两次都没确认）⇒ 下一次点击重开
local m_RestartUnverified = false  -- 上面那个状态是“**没确认**落盘”（玩家显式选择强切）
local m_ForceArmed = nil           -- 未确认落盘时玩家又确认过一次（防误触）
local m_SwitchTargetId = nil       -- 本次切换的目标节点（落盘确认后用它标记“可以重开”）
local m_SwitchTickArmed = false    -- 按帧回调（轮询落盘确认）是否已挂上
local m_CheckSaveFrames = 0        -- 距离下一次查存档列表还有几帧（~2 秒查一次）
-- 重开看门狗：`Network.RestartGame()` 有可能“调用返回了但游戏没重开”。真重开的话这个上下文
-- 会被销毁、按帧回调不会再跑；还能跑 ⇒ 说明引擎没理这次调用。到点就把这件事**明确写进日志与状态行**，
-- 不要再让人从“后面还有没有日志”去猜。
local m_RestartWatchdogAt = nil
local m_RestartWatchdogCount = 0
local m_LoadViewStateCount = 0     -- 本上下文见过几次 LoadGameViewStateDone（重开后应重新计）
local m_EventTypeKey = "GOLD"
local m_EventDetailEntry = nil
local m_EventTurnEntry = nil
local m_EventPlayerID = nil
local m_OptionIM = nil
local m_OpenSelectorKey = nil

-- 换图按钮的三段式状态在文件顶部有说明（①确认 ②存原档 ③只重开）。

-- ===========================================================================
-- 输出
-- ===========================================================================

local function SetStatus(text)
    Controls.ModMiscSaveStatus:SetText(tostring(text or ""))
end

local function SetDetail(text)
    Controls.ModMiscSaveDetail:SetText(tostring(text or ""))
end

local function Log(message)
    print("[ModMiscTool][SavePanel] " .. tostring(message))
end

local function Report(shortStatus, detail)
    SetStatus(shortStatus)
    if detail ~= nil then SetDetail(detail) end
    Log(tostring(shortStatus) .. (detail ~= nil and (" | " .. tostring(detail):gsub("\n", " / ")) or ""))
end

local function ReportError(actionName, err)
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_ERROR", actionName), tostring(err))
end

local function SafeCall(name, fn, ...)
    local ok, a = pcall(fn, ...)
    if not ok then
        ReportError(name, a)
        return false, a
    end
    return true, a
end

-- ===========================================================================
-- 信息行 / 关系树渲染
-- ===========================================================================

local function DescribeId(id)
    if id == nil or tostring(id) == "" then
        return Locale.Lookup("LOC_MODMISC_SAVEPANEL_NONE")
    end
    return tostring(id)
end

local function UpdateInfoLine()
    local current = ModMiscSaveGraph.GetCurrentNodeId()
    local head = ModMiscSaveGraph.GetMainlineHeadId()
    local pending = ModMiscSaveGraph.GetPendingBranch()
    local incoming = ModMiscSaveGraph.GetIncomingBranch()
    local noneText = Locale.Lookup("LOC_MODMISC_SAVEPANEL_NONE")

    -- 本局来源：换图重开后开局探针固化下来的“我挂在谁下面、算什么”
    local incomingText = noneText
    if incoming ~= nil then
        incomingText = tostring(incoming.Parent) .. " → " .. tostring(incoming.Kind)
    end
    local pendingText = noneText
    if pending ~= nil then
        pendingText = tostring(pending.Parent) .. " → " .. tostring(pending.Kind)
    end
    -- 回合同步（纯逻辑）：逻辑回合 = 引擎回合 + 偏移
    local logicalTurn, engineTurn, offset = nil, nil, nil
    if ModMiscSaveGraph.GetLogicalTurnInfo ~= nil then
        logicalTurn, engineTurn, offset = ModMiscSaveGraph.GetLogicalTurnInfo()
    end
    local logicalText = Locale.Lookup("LOC_MODMISC_SAVEPANEL_NONE")
    if logicalTurn ~= nil then
        logicalText = Locale.Lookup("LOC_MODMISC_SAVEPANEL_LOGICAL",
            tostring(logicalTurn), tostring(engineTurn), tostring(offset or 0))
    end

    Controls.ModMiscSaveInfo:SetText(Locale.Lookup("LOC_MODMISC_SAVEPANEL_INFO",
        DescribeId(current), incomingText, logicalText, DescribeId(head), pendingText))
end

-- 一条关系档的显示文本：缩进 + [M/B] + id + T回合 + 地图 + 时间 + 标记
local function BuildEntryText(line)
    local node = line.Node
    local indent = string.rep("    ", line.Depth)
    local marks = {}
    if node.IsCurrent then table.insert(marks, Locale.Lookup("LOC_MODMISC_SAVEPANEL_CURRENT")) end
    if node.Orphan then table.insert(marks, Locale.Lookup("LOC_MODMISC_SAVEPANEL_ORPHAN")) end
    if m_SelectedNode ~= nil and m_SelectedNode.Id == node.Id then
        table.insert(marks, Locale.Lookup("LOC_MODMISC_SAVEPANEL_SELECTED_MARK"))
    end
    local markText = (#marks > 0) and ("  · " .. table.concat(marks, " · ")) or ""
    -- T = 引擎回合；L = 逻辑回合（回合同步，纯逻辑；老档没有记 → 显示 -）
    return string.format("%s[%s] %s  T%s/L%s  %s  %s%s", indent, tostring(node.Kind), tostring(node.Id),
        tostring(node.Turn or "?"), tostring(node.Logical or "-"),
        tostring(node.Map), tostring(node.Stamp), markText)
end

local function RenderTree()
    if m_EntryIM == nil then return end
    m_EntryIM:ResetInstances()
    local lines = ModMiscSaveGraph.BuildTreeLines()
    if #lines == 0 then
        local instance = m_EntryIM:GetInstance()
        instance.EntryLabel:SetText(Locale.Lookup("LOC_MODMISC_SAVEPANEL_EMPTY"))
        instance.EntryButton:SetDisabled(true)
        return
    end
    for _, line in ipairs(lines) do
        local instance = m_EntryIM:GetInstance()
        instance.EntryLabel:SetText(BuildEntryText(line))
        instance.EntryButton:SetDisabled(false)
        instance.EntryButton:ClearCallback(Mouse.eLClick)
        local currentNode = line.Node
        instance.EntryButton:RegisterCallback(Mouse.eLClick, function()
            -- 点一条 = 选中它（发送事件 / 读档都作用于选中的这条）
            m_SelectedNode = currentNode
            local logicalText = currentNode.Logical ~= nil and tostring(currentNode.Logical) or "-"
            SetDetail(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NODE_DETAIL",
                tostring(currentNode.Id), tostring(currentNode.Parent or ModMiscSaveGraph.Prefix .. "-root"),
                tostring(currentNode.Kind), tostring(currentNode.Turn or "?"), logicalText,
                tostring(currentNode.Map), tostring(currentNode.Stamp), tostring(currentNode.RawName)))
            SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SELECTED", tostring(currentNode.Id), logicalText))
            RenderTree()
        end)
    end
    Controls.ModMiscSaveList:CalculateSize()
    Controls.ModMiscSaveList:ReprocessAnchoring()
end

-- ===========================================================================
-- 选择器（事件的目标玩家 / 类型 / 内容 / 接受回合）
--
-- 引擎的 SimplePullDown 在 reparent 过的面板里点不开（本项目踩过），所以自绘：
-- 一个 GridButton 显示当前选择，点开在它下方（或上方）铺列表，选中即收起。
-- ===========================================================================

local function BuildEventPlayerEntries()
    local entries = {}
    for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
        if Players[playerID] ~= nil then
            local config = PlayerConfigurations[playerID]
            local name = tostring(playerID)
            local civ = ""
            if config ~= nil then
                local ok, value = pcall(function() return config:GetPlayerName() end)
                if ok and value ~= nil and value ~= "" then name = Locale.Lookup(value) end
                local ok2, value2 = pcall(function() return config:GetCivilizationShortDescription() end)
                if ok2 and value2 ~= nil then civ = value2 end
            end
            table.insert(entries, {
                PlayerID = playerID,
                Text = string.format("%d · %s · %s", playerID, name, civ),
            })
        end
    end
    return entries
end

local function BuildEventTypeEntries()
    local entries = {}
    for _, def in ipairs(EVENT_TYPE_DEFS) do
        table.insert(entries, { Key = def.Key, DetailKind = def.DetailKind, Text = Locale.Lookup(def.Text) })
    end
    return entries
end

-- 内容列表随事件类型变：金币给金额档位，单位/资源从 GameInfo 取（数据驱动）
local function BuildEventDetailEntries()
    local entries = {}
    local eventType = m_EventTypeKey or "GOLD"
    if eventType == "GOLD" then
        for _, amount in ipairs(GOLD_AMOUNTS) do
            table.insert(entries, { Key = tostring(amount), Amount = amount, Text = tostring(amount) })
        end
        return entries
    end

    local rows = {}
    if eventType == "UNIT" then
        for row in GameInfo.Units() do
            if row.Domain == "DOMAIN_LAND" then
                table.insert(rows, { Key = row.UnitType, Text = Locale.Lookup(row.Name) .. " (" .. tostring(row.UnitType) .. ")" })
            end
        end
    else
        for row in GameInfo.Resources() do
            table.insert(rows, { Key = row.ResourceType, Text = Locale.Lookup(row.Name) .. " (" .. tostring(row.ResourceType) .. ")" })
        end
    end
    table.sort(rows, function(a, b) return tostring(a.Text) < tostring(b.Text) end)
    for _, row in ipairs(rows) do
        row.Amount = 1
        table.insert(entries, row)
        if #entries >= EVENT_LIST_MAX then break end
    end
    return entries
end

local function BuildEventTurnEntries()
    local logicalTurn = ModMiscSaveGraph ~= nil and ModMiscSaveGraph.GetLogicalTurn() or 1
    local entries = {}
    for _, turnOffset in ipairs(EVENT_TURN_OFFSETS) do
        local targetTurn = logicalTurn + turnOffset
        local text = Locale.Lookup("LOC_MODMISC_SAVEPANEL_TURN_NOW", tostring(targetTurn))
        if turnOffset > 0 then
            text = Locale.Lookup("LOC_MODMISC_SAVEPANEL_TURN_PLUS", tostring(targetTurn), tostring(turnOffset))
        end
        table.insert(entries, {
            Key = tostring(turnOffset), TurnOffset = turnOffset, Turn = targetTurn, Text = text,
        })
    end
    return entries
end

local function FindSelected(entries, isSelected)
    for _, entry in ipairs(entries) do
        if isSelected(entry) then return entry end
    end
    return nil
end

local m_Selectors = {}
local m_SelectorOrder = { "eventPlayer", "eventType", "eventDetail", "eventTurn" }

local function RefreshSelectorButtons()
    for _, key in ipairs(m_SelectorOrder) do
        local selector = m_Selectors[key]
        if selector ~= nil and selector.button ~= nil then
            selector.button:SetText(selector.getLabel())
        end
    end
end

local function CloseOptionList()
    Controls.ModMiscSaveOptionPanel:SetHide(true)
    m_OpenSelectorKey = nil
end

local function OpenOptionList(key)
    local selector = m_Selectors[key]
    if selector == nil then return end
    local entries = selector.getEntries()
    if entries == nil or #entries == 0 then
        SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_OPTIONS"))
        return
    end

    m_OptionIM:ResetInstances()
    for _, entry in ipairs(entries) do
        local instance = m_OptionIM:GetInstance()
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
    local wanted = #entries * 50 + 16
    local roomBelow = Controls.ModMiscSaveRoot:GetSizeY() - (buttonY + button:GetSizeY()) - 20
    local roomAbove = buttonY - 14
    local openUpward = (roomBelow < wanted) and (roomAbove > roomBelow)
    local optionHeight = math.min(wanted, math.max(100, openUpward and roomAbove or roomBelow))
    local optionY = buttonY + button:GetSizeY() + 4
    if openUpward then optionY = buttonY - optionHeight - 4 end
    if optionY < 10 then optionY = 10 end

    local panel = Controls.ModMiscSaveOptionPanel
    panel:SetSizeVal(button:GetSizeX(), optionHeight)
    panel:SetOffsetVal(optionX, optionY)
    panel:SetHide(false)
    Controls.ModMiscSaveOptionScroll:CalculateSize()
    Controls.ModMiscSaveOptionScroll:CalculateInternalSize()
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

local function GetEventDetailLabel()
    if m_EventDetailEntry == nil then
        return Locale.Lookup("LOC_MODMISC_SAVEPANEL_EVENT_DETAIL_NONE")
    end
    return m_EventDetailEntry.Text
end

local function GetEventTurnLabel()
    if m_EventTurnEntry == nil then
        return Locale.Lookup("LOC_MODMISC_SAVEPANEL_EVENT_TURN_NONE")
    end
    return m_EventTurnEntry.Text
end

local function BuildSelectors()
    m_Selectors = {
        eventPlayer = {
            button = Controls.ModMiscSaveEventPlayerButton,
            getEntries = BuildEventPlayerEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = FindSelected(BuildEventPlayerEntries(), function(e) return e.PlayerID == m_EventPlayerID end)
                if entry ~= nil then return entry.Text end
                return Locale.Lookup("LOC_MODMISC_SAVEPANEL_EVENT_PLAYER_NONE")
            end,
            isSelected = function(entry) return entry.PlayerID == m_EventPlayerID end,
            onSelect = function(entry) m_EventPlayerID = entry.PlayerID end,
        },
        eventType = {
            button = Controls.ModMiscSaveEventTypeButton,
            getEntries = BuildEventTypeEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = function()
                local entry = FindSelected(BuildEventTypeEntries(), function(e) return e.Key == m_EventTypeKey end)
                return entry ~= nil and entry.Text or tostring(m_EventTypeKey)
            end,
            isSelected = function(entry) return entry.Key == m_EventTypeKey end,
            onSelect = function(entry)
                m_EventTypeKey = entry.Key
                m_EventDetailEntry = nil      -- 换类型就重选内容
            end,
        },
        eventDetail = {
            button = Controls.ModMiscSaveEventDetailButton,
            getEntries = BuildEventDetailEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = GetEventDetailLabel,
            isSelected = function(entry) return entry == m_EventDetailEntry end,
            onSelect = function(entry) m_EventDetailEntry = entry end,
        },
        eventTurn = {
            button = Controls.ModMiscSaveEventTurnButton,
            getEntries = BuildEventTurnEntries,
            getEntryText = function(entry) return entry.Text end,
            getLabel = GetEventTurnLabel,
            isSelected = function(entry) return m_EventTurnEntry ~= nil and entry.Key == m_EventTurnEntry.Key end,
            onSelect = function(entry) m_EventTurnEntry = entry end,
        },
    }
end

local function SelectEventDefaultsIfNeeded()
    if m_EventPlayerID == nil then
        local localPlayer = Game.GetLocalPlayer()
        m_EventPlayerID = (localPlayer ~= nil and localPlayer >= 0) and localPlayer or 0
    end
    if m_EventDetailEntry == nil then
        local entries = BuildEventDetailEntries()
        if #entries > 0 then m_EventDetailEntry = entries[1] end
    end
    if m_EventTurnEntry == nil then
        local entries = BuildEventTurnEntries()
        if #entries > 0 then m_EventTurnEntry = entries[1] end
    end
end

local function DoSendEvent()
    if m_SelectedNode == nil then
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION"),
            Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION_DETAIL"))
        return
    end
    SelectEventDefaultsIfNeeded()

    local detailEntry = m_EventDetailEntry
    local turnEntry = m_EventTurnEntry
    local event = {
        Type = m_EventTypeKey or "GOLD",
        Detail = detailEntry ~= nil and tostring(detailEntry.Key) or "",
        Amount = detailEntry ~= nil and (tonumber(detailEntry.Amount) or 1) or 1,
        AcceptTurn = turnEntry ~= nil and tonumber(turnEntry.Turn) or ModMiscSaveGraph.GetLogicalTurn(),
        TargetPlayerID = m_EventPlayerID,
    }
    local ok, keyOrErr = ModMiscSaveGraph.SendEvent(m_SelectedNode.Id, event)
    if not ok then
        ReportError("SendEvent", keyOrErr)
        return
    end
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_EVENT_SENT",
            tostring(m_SelectedNode.Id), tostring(event.Type),
            tostring(event.Detail ~= "" and event.Detail or event.Amount),
            tostring(event.AcceptTurn)),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_EVENT_SENT_DETAIL", tostring(keyOrErr)))
end

-- ===========================================================================
-- 确认：**动作永远由按钮这次点击执行，弹窗回调里只改状态**
-- （弹窗回调里调 Network.RestartGame / LoadGame 这类重调用实机不可靠）
--
-- ⚠️ 退化路径（本上下文里 PopupDialogInGame 是 nil）的判据是 **armKey 这个稳定字符串**，
-- 不能拿闭包比相等：每点一次按钮都会新建一个闭包，`旧闭包 == 新闭包` 永远为假
-- ⇒ 实机表现就是一直打印“再点一次确认”、怎么点都不动（Lua.log 里连打四行，就是这个 bug）。
--
-- 声明位置：必须在**所有调用它的函数之前**（Lua 5.1 的 local 作用域；放晚了，前面的函数
-- 里调到的其实是全局 nil —— 静态检查 fwdcheck 抓过一次）。
-- ===========================================================================
local m_ArmedConfirmKey = nil
local function AskConfirm(confirmText, onConfirmed, armKey)
    if PopupDialogInGame ~= nil then
        local ok = pcall(function()
            local popup = PopupDialogInGame:new("UnitPanelPopup")
            -- 弹窗回调里**只改状态**（不能在这里重开：弹窗回调里调 RestartGame 实机无效）
            popup:ShowOkCancelDialog(confirmText, function() pcall(onConfirmed) end)
        end)
        if ok then return true end
        Log("弹窗不可用，退化成“点两次确认”")
    end
    local key = tostring(armKey or confirmText)
    if m_ArmedConfirmKey == key then
        m_ArmedConfirmKey = nil
        pcall(onConfirmed)
        return true
    end
    m_ArmedConfirmKey = key
    Report(confirmText, Locale.Lookup("LOC_MODMISC_SAVEPANEL_CONFIRM_AGAIN"))
    return false
end

-- 载入：第一次点击确认（有弹窗弹窗，没有就“再点一次”），确认下来那一下才真的载入。
-- 之所以允许确认回调里直接调 Network.LoadGame：引擎自己就是这么干的
-- （Base/Assets/UI/FrontEnd/LoadGameMenu.lua 的 OnLoadYes —— 弹窗 Yes 回调里调 Network.LoadGame）。
local function DoLoadSelected()
    if m_SelectedNode == nil then
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION"),
            Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION_DETAIL"))
        return
    end
    local node = m_SelectedNode
    -- 【实机 2026-10-06】原来这里直接 `PopupDialogInGame:new(...)`，而本上下文里它是 nil
    -- ⇒ 只打一行 “attempt to index a nil value”，载入永远做不成。统一走 AskConfirm。
    AskConfirm(Locale.Lookup("LOC_MODMISC_SAVEPANEL_LOAD_CONFIRM", tostring(node.RawName or node.Id)),
        function()
            local loadOk, loadErr = ModMiscSaveGraph.LoadNode(node.Id)
            if not loadOk then ReportError("LoadNode", loadErr) end
        end, "load:" .. tostring(node.Id))
end

local function RefreshAll(onDone)
    UpdateInfoLine()
    -- ① 先把**跨存档存储**读起来：本 context 的内存表可能是空的（换图重开后的新上下文
    --    就是），不扫就读不到主线头 / 待接分支 —— 那会让新档把自己当树根。
    if ModMiscStore ~= nil and ModMiscStore.Refresh ~= nil then
        ModMiscStore.Refresh(function() UpdateInfoLine() end)
    end
    -- ② 再扫存档列表，渲染关系树
    ModMiscSaveGraph.Refresh(function(nodes)
        RenderTree()
        UpdateInfoLine()
        SelectEventDefaultsIfNeeded()
        RefreshSelectorButtons()
        local count = nodes ~= nil and #nodes or 0
        SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SCANNED", count))
        if onDone ~= nil then pcall(onDone, count) end
    end)
end

-- ===========================================================================
-- 按钮动作
-- ===========================================================================

-- 创建分支（授权者 2026-10-06 新逻辑）：把当前局存成一个**逻辑分支档**，不重开、不切换
local function DoCreateBranch()
    local ok, idOrErr = ModMiscSaveGraph.CreateBranchNode()
    if not ok then
        ReportError("CreateBranch", idOrErr)
        return
    end
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_BRANCH_CREATED", tostring(idOrErr)),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_BRANCH_CREATED"))
    RefreshAll()
end

local function DoSave()
    local ok, err = ModMiscSaveGraph.SaveCurrentGame({
        Reason = "manual",
        -- ① SaveComplete 回执（立刻）：只报“已回执”，落盘复查是下一步
        OnSaved = function(found, node)
            if node == nil then
                ReportError("Save", "存档未完成")
                return
            end
            Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVED", tostring(node.Id),
                    Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVED_ACKED")),
                tostring(node.RawName or ""))
        end,
        -- ② 存档列表复查（异步，可能不来）：来了就把最终结论换上并刷新关系树
        OnChecked = function(found, node)
            if node == nil then return end
            Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVED", tostring(node.Id),
                    Locale.Lookup(found and "LOC_MODMISC_SAVEPANEL_SAVED_ON_DISK"
                        or "LOC_MODMISC_SAVEPANEL_SAVED_UNCONFIRMED")),
                tostring(node.RawName or ""))
            RefreshAll()
        end,
    })
    if not ok then
        ReportError("Save", err)
        return
    end
    -- 请求已受理：真正开写前会先等跨存档存储就绪（新 context 的内存表是空的）
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVING"),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVING_DETAIL"))
end

-- 看门狗日志用的引擎回合（取不到就写 ?，不能因为读不到回合把看门狗本身弄炸）
local function TryCallTurn()
    local ok, value = pcall(function() return Game.GetCurrentGameTurn() end)
    if ok and value ~= nil then return value end
    return "?"
end

-- 换图按钮：① 确认 → ② 存原档（不重开）→ ③ 只重开
-- 按帧推进只干一件事：**轮询存档列表，确认原档真的落盘**（唯一的判据，见第 19.13 条）。
-- 前置声明：MarkRestartReady / PerformSwitch 都要用它把按帧回调挂上（Lua 5.1 必须先声明再使用）
local EnsureSwitchTick = nil

-- 原档状态确定（确认落盘 / 两次都没确认）⇒ 标记“可以重开了”。
-- 注意：这里**只改状态、把提示打在状态行**，绝不在这里重开 —— 按帧回调里调 Network.RestartGame()
-- 是实机证明“返回了但不重开”的形态之一，重开必须留给玩家那次按钮点击。
local function MarkRestartReady(reason, unverified)
    local target = m_SwitchTargetId
    if target == nil then return end
    m_RestartReady = target
    m_RestartUnverified = unverified == true
    m_ForceArmed = nil
    EnsureSwitchTick()
    Log("换图：进入“可重开”状态（" .. tostring(reason) .. "，目标=" .. tostring(target)
        .. (m_RestartUnverified and "，**原档未确认落盘**" or "，原档已确认落盘")
        .. "）——等玩家点一次「切换到选中」，那一次只做重开")
end

-- 换图状态机（只剩两件事：轮询确认落盘 → 标记可重开）
--   为什么要等确认：SaveComplete 认不出是哪一份存档（换图前刚好写了交接单那个小配置档），
--   之前靠它 + 一个盲倒计时“猜”原档写完了，实机结果就是“面板说存好了、存档列表里却没有”。
--   现在唯一的判据是**存档列表里查得到**；超时只重发一次，再不行就老实说失败，交给玩家显式决定。
local function TickAutoSwitch(delta)
    -- 看门狗：调过重开之后还能跑到这里 ⇒ 引擎没真的重开
    if m_RestartWatchdogAt ~= nil then
        local now = os.time()
        if now == nil or now >= m_RestartWatchdogAt then
            m_RestartWatchdogAt = nil
            Log("**引擎没有重开**：Network.RestartGame() 已返回但游戏仍在运行（第 "
                .. tostring(m_RestartWatchdogCount) .. " 次）—— 本上下文还活着，"
                .. "LoadGameViewStateDone 见过 " .. tostring(m_LoadViewStateCount) .. " 次，"
                .. "引擎回合=" .. tostring(TryCallTurn()) .. "。"
                .. "真重开过的话日志里会出现新的 `panel loading build=…` 并重新走一遍开局探针。")
            SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_RESTART_IGNORED"))
            SetDetail(Locale.Lookup("LOC_MODMISC_SAVEPANEL_RESTART_IGNORED_DETAIL",
                tostring(m_RestartWatchdogCount)))
        end
    end
    local state = ModMiscSaveGraph.GetSaveState ~= nil and ModMiscSaveGraph.GetSaveState() or nil
    if state ~= nil and state.Verified ~= true and state.Failed ~= true then
        m_CheckSaveFrames = (m_CheckSaveFrames or 0) + 1
        -- 先写“正在确认”，**再**查列表：查到之后回调里的“已确认 / 可重开”才不会被这一行盖掉
        SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_VERIFYING",
            tostring(state.Name or "?"), tostring(math.floor((state.Elapsed or 0)))))
        -- 每 ~2 秒查一次列表（帧率按 30 估）
        if m_CheckSaveFrames >= 60 then
            m_CheckSaveFrames = 0
            ModMiscSaveGraph.VerifySaveNow(function(found)
                if found then
                    SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_VERIFIED"))
                    MarkRestartReady("落盘确认回调")
                end
            end)
        end
        -- 等太久（40 秒）⇒ 重发一次；再等 40 秒还没有 ⇒ 老实报错，改由玩家显式决定
        if (state.Elapsed or 0) > 40 then
            if (state.Attempts or 1) < 2 then
                m_CheckSaveFrames = 0
                Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_RESAVE", "2"),
                    Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_PREPARED_DETAIL"))
                ModMiscSaveGraph.RetrySave(function(found)
                    if found then
                        SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_VERIFIED"))
                        MarkRestartReady("重发后落盘确认回调")
                    end
                end)
            else
                Log("换图：原档两次都没能确认落盘；不自动重开，等玩家显式决定")
                SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_FAILED"))
                ModMiscSaveGraph.MarkSaveFailed()
                MarkRestartReady("两次都没确认落盘（玩家可显式强切）", true)
            end
        end
    end
    ContextPtr:RequestRefresh()
end

EnsureSwitchTick = function()
    if m_SwitchTickArmed then return end
    m_SwitchTickArmed = true
    ContextPtr:SetRefreshHandler(TickAutoSwitch)
    ContextPtr:RequestRefresh()
    Log("落盘确认轮询（按帧回调）已挂上")
end

-- 切换（授权者 2026-10-06 定稿）：**重开单独占一次点击**，见文件顶部说明。
--   ① 确认（AskConfirm：弹窗或“再点一次”）→ 确认下来这一下**只存原档**（本函数）；
--   ② 原档确认落盘后再点一次 → 只重开（PerformRestart）。
local function PerformSwitch(targetId)
    -- 先把上一次没走完的存档状态复位：否则新请求会被“上一笔还在等回执”挡回去，
    -- 表现就是“点切换没反应”（实机 2026-10-06）。
    if ModMiscSaveGraph.ResetSaveState ~= nil then
        ModMiscSaveGraph.ResetSaveState("开始切换")
    end
    m_SwitchTargetId = tostring(targetId)
    m_RestartReady = nil
    m_RestartUnverified = false
    m_ForceArmed = nil
    m_CheckSaveFrames = 59            -- 下一帧就去查一次存档列表
    -- 【实机 2026-10-06 抓到的坑】落盘轮询跑在按帧回调里，而按帧回调只有 EnsureSwitchTick 会挂。
    -- 早前只有 MarkRestartReady 调它，可 MarkRestartReady 又只在轮询回调里被调到 ⇒ 自锁：
    -- 轮询根本没开始过，“落盘确认”那几行日志一行都不会出现。现在开切就挂上。
    EnsureSwitchTick()
    local ok, idOrErr = ModMiscSaveGraph.PrepareSwitch({
        TargetNodeId = targetId,
        OnVerified = function(found)
            if found then
                SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_VERIFIED"))
                MarkRestartReady("落盘确认回调（PrepareSwitch）")
            end
        end,
    })
    if not ok then
        ReportError("PrepareSwitch", idOrErr)
        return
    end
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_PREPARED", tostring(idOrErr)),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_PREPARED_DETAIL"))
end

-- ③ 重开：**这个按钮回调里只做重开这一件事**（唯一被实机证明有效的形态）。
-- 原档确认落盘才允许切；两次都没确认时，玩家要**再确认一次**才强切（Force）。
local function PerformRestart(targetId)
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_NOW"),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_NOW_DETAIL"))
    local ok, err = ModMiscSaveGraph.SwitchNow({
        Reason = "按钮回调（重开专用）",
        Force = m_RestartUnverified == true,
    })
    if not ok then
        ReportError("SwitchNow", err)
        return
    end
    -- 调用返回了，但这**不等于**重开了：真重开的话本上下文会被销毁、按帧回调不会再跑。
    -- 所以这里上表看门狗，5 秒后如果还能跑，就把“引擎没重开”明确写出来（不再靠人猜）。
    m_RestartReady = nil
    m_ForceArmed = nil
    m_RestartWatchdogCount = m_RestartWatchdogCount + 1
    m_RestartWatchdogAt = (os.time() or 0) + 5
    EnsureSwitchTick()
    Log("重开看门狗已上表：5 秒后如果本上下文还活着，就说明引擎没理这次 RestartGame")
end

local function DoSwitchMap()
    local selected = m_SelectedNode
    if selected == nil then
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION"),
            Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_NEED_SELECTION"))
        return
    end
    local targetId = tostring(selected.Id)

    -- ③ 原档状态已知（确认落盘 / 两次都没确认）⇒ 这一次点击**只重开**
    if m_RestartReady == targetId then
        if m_RestartUnverified and m_ForceArmed ~= targetId then
            -- 原档没确认落盘：把警告写在状态行，**再点一次**就是玩家的显式选择（这里不重开：
            -- 重开只能在按钮回调里做；警告本身就已经是“确认”这一步了，不再套一层确认）
            m_ForceArmed = targetId
            Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_UNVERIFIED_WARN"),
                Locale.Lookup("LOC_MODMISC_SAVEPANEL_CONFIRM_AGAIN"))
            return
        end
        PerformRestart(targetId)
        return
    end

    -- ① + ② 确认：有弹窗就弹窗，没有就“再点一次确认”。**确认下来这一下只存原档、不重开。**
    AskConfirm(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_CONFIRM",
            tostring(selected.RawName or targetId)),
        function()
            m_RestartReady = nil
            m_RestartUnverified = false
            PerformSwitch(targetId)
        end, "switch:" .. targetId)
end

-- 收件：把发给本局节点的事件拉进回合事件列表（开局会自动跑一次，这里是手动入口）
local function DoIntakeEvents()
    if ModMiscSaveGraph.IntakeEvents == nil then
        ReportError("IntakeEvents", "模块没加载")
        return
    end
    ModMiscSaveGraph.IntakeEvents(function(added, how)
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_INTAKE_DONE", tostring(added), tostring(how)),
            Locale.Lookup("LOC_MODMISC_SAVEPANEL_INTAKE_DETAIL"))
    end)
end

-- 删除选中存档
local function DoDeleteSelected()
    if m_SelectedNode == nil then
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION"),
            Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION_DETAIL"))
        return
    end
    local node = m_SelectedNode
    local text = Locale.Lookup("LOC_MODMISC_SAVEPANEL_DELETE_CONFIRM", tostring(node.RawName or node.Id))
    -- 【实机 2026-10-06】这里原来直接 `PopupDialogInGame:new(...)`，而面板这个上下文里
    -- `PopupDialogInGame` 是 nil ⇒ pcall 接住后只打一行 “attempt to index a nil value”，删除永远做不成。
    -- 改用统一的 AskConfirm（引擎弹窗优先，退化成“再点一次确认”，判据是稳定的键）。
    -- 删除放在弹窗回调里是安全的：引擎自己删档也是在确认弹窗的 OnYes 里调 UI.DeleteSavedGame
    -- （Base/Assets/UI/Menus/SaveGameMenu.lua 的 OnYes）。
    AskConfirm(text, function()
        local delOk, delErr = ModMiscSaveGraph.DeleteNode(node.Id)
        if not delOk then
            ReportError("DeleteNode", delErr)
            return
        end
        m_SelectedNode = nil
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_DELETED", tostring(delErr)), nil)
        RefreshAll()
    end, "delete:" .. tostring(node.Id))
end

-- ===========================================================================
-- 面板打开 / 关闭 / 侧栏入口
-- ===========================================================================

local function AttachPanelToInGame()
    local panelRoot = Controls.ModMiscSaveRoot
    local inGameRoot = ContextPtr:LookUpControl("/InGame")
    if inGameRoot ~= nil then
        panelRoot:ChangeParent(inGameRoot)
        panelRoot:ReprocessAnchoring()
    end
    return panelRoot
end

function OpenModMiscSavePanel()
    local panelRoot = AttachPanelToInGame()
    panelRoot:SetHide(false)
    SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_READY"))
    CloseOptionList()
    SelectEventDefaultsIfNeeded()
    RefreshSelectorButtons()
    RefreshAll()   -- 内含跨存档存储扫描：新 context 必须先读起来才知道主线头 / 待接分支
    -- 顺手拉一次信箱：开局那次探针可能因为“还没有节点身份”而跳过，存档之后就有了
    pcall(function() ModMiscSaveGraph.IntakeEvents() end)
    Log("面板已打开")
end

function CloseModMiscSavePanel()
    CloseOptionList()
    Controls.ModMiscSaveRoot:SetHide(true)
end

local function TryRegisterSidebarButton()
    if m_Registered then return end
    if ExposedMembers == nil or ExposedMembers.ModMiscToolUI == nil then return end
    if ExposedMembers.ModMiscToolUI.RegisterSidebarButton == nil then return end

    ExposedMembers.ModMiscToolUI.RegisterSidebarButton(
        "ICON_UNITOPERATION_FOUND_CITY",
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_TITLE"),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_TOOLTIP"),
        OpenModMiscSavePanel)
    m_Registered = true
    Log("左侧栏入口已注册")
end

function OnInit()
    Controls.ModMiscSaveRoot:SetHide(true)
    m_EntryIM = InstanceManager:new("ModMiscSaveEntry", "EntryButton", Controls.ModMiscSaveList)

    m_OptionIM = InstanceManager:new("ModMiscSaveOptionEntry", "EntryButton",
        Controls.ModMiscSaveOptionList)
    BuildSelectors()
    SelectEventDefaultsIfNeeded()
    RefreshSelectorButtons()

    Controls.ModMiscSaveClose:RegisterCallback(Mouse.eLClick, CloseModMiscSavePanel)
    Controls.ModMiscSaveEventPlayerButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("eventPlayer") end)
    Controls.ModMiscSaveEventTypeButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("eventType") end)
    Controls.ModMiscSaveEventDetailButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("eventDetail") end)
    Controls.ModMiscSaveEventTurnButton:RegisterCallback(Mouse.eLClick,
        function() ToggleOptionList("eventTurn") end)
    Controls.ModMiscSaveEventSend:RegisterCallback(Mouse.eLClick,
        function() SafeCall("SendEvent", DoSendEvent) end)
    Controls.ModMiscSaveLoadSelected:RegisterCallback(Mouse.eLClick,
        function() SafeCall("LoadSelected", DoLoadSelected) end)
    Controls.ModMiscSaveIntake:RegisterCallback(Mouse.eLClick,
        function() SafeCall("IntakeEvents", DoIntakeEvents) end)
    Controls.ModMiscSaveDelete:RegisterCallback(Mouse.eLClick,
        function() SafeCall("DeleteSelected", DoDeleteSelected) end)
    Controls.ModMiscSaveCurrent:RegisterCallback(Mouse.eLClick,
        function() SafeCall("Save", DoSave) end)
    Controls.ModMiscSaveCreateBranch:RegisterCallback(Mouse.eLClick,
        function() SafeCall("CreateBranch", DoCreateBranch) end)
    Controls.ModMiscSaveSwitchMap:RegisterCallback(Mouse.eLClick,
        function() SafeCall("SwitchMap", DoSwitchMap) end)
    Controls.ModMiscSaveRefresh:RegisterCallback(Mouse.eLClick,
        function() SafeCall("Refresh", function() RefreshAll() end) end)

    UpdateInfoLine()
end

function OnLoadGameViewStateDone()
    m_LoadViewStateCount = m_LoadViewStateCount + 1
    AttachPanelToInGame()
    TryRegisterSidebarButton()
    UpdateInfoLine()
end

Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
Events.LocalPlayerTurnBegin.Add(TryRegisterSidebarButton)
LuaEvents.ModMiscToolUIReady.Add(TryRegisterSidebarButton)
ContextPtr:SetInitHandler(OnInit)
