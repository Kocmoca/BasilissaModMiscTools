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

-- 自动换图：原档落盘确认后开始倒计时，到点自己重开（授权者 2026-10-05 要求“自动进行”）。
-- 倒计时期间随时可以按「换图」立刻重开（那条路是实机验证过的按钮回调）。
-- 自动那次若没生效（我们的代码还活着），10 秒后再给一次机会，两次都不行就交回手动。
local SWITCH_AUTO_DELAY = 8
local SWITCH_AUTO_RETRY_DELAY = 10
local SWITCH_AUTO_MAX_TRIES = 2
local m_AutoRestartAt = nil
local m_AutoRestartTries = 0
local m_SwitchTickArmed = false
local m_EventTypeKey = "GOLD"
local m_EventDetailEntry = nil
local m_EventTurnEntry = nil
local m_EventPlayerID = nil
local m_OptionIM = nil
local m_OpenSelectorKey = nil

-- 换图 = **两步式**（不依赖引擎事件、不依赖按帧回调、不依赖时钟）：
--   第一次点「换图」：写待接分支 + 存原档（异步）→ 状态行提示“再点一次就切换”
--   第二次点「换图」：在**按钮回调里直接 Network.RestartGame()** —— 完全复刻唯一被实机
--     证明可行的调用方式（Automation 面板那次，第 42 条）。
-- 之前三版把重开挂在 SaveComplete 事件 / 按帧回调状态机上，都出现过“点了不跳转”。

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

local function DoLoadSelected()
    if m_SelectedNode == nil then
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION"),
            Locale.Lookup("LOC_MODMISC_SAVEPANEL_NO_SELECTION_DETAIL"))
        return
    end
    local node = m_SelectedNode
    local text = Locale.Lookup("LOC_MODMISC_SAVEPANEL_LOAD_CONFIRM", tostring(node.RawName or node.Id))
    local ok, err = pcall(function()
        local popup = PopupDialogInGame:new("UnitPanelPopup")
        popup:ShowOkCancelDialog(text, function()
            local loadOk, loadErr = ModMiscSaveGraph.LoadNode(node.Id)
            if not loadOk then ReportError("LoadNode", loadErr) end
        end)
    end)
    if not ok then ReportError("LoadConfirm", err) end
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

-- 换图按钮：第一次 = 存原档，第二次 = 直接重开
-- 按帧推进：倒计时显示 + 到点自动重开
-- 前置声明：ArmAutoRestart 要用它把按帧回调挂上（Lua 5.1 必须先声明再使用）
local EnsureSwitchTick = nil

-- 倒计时：**只在确认落盘后**调用（ArmAutoRestart 必须先于 TickAutoSwitch 声明 ——
-- Lua 5.1 里 local function 不前置声明的话，函数体里的引用会被解析成全局 nil）
local function ArmAutoRestart(delaySeconds)
    if m_AutoRestartAt ~= nil then return end       -- 已经排上了
    local now = os.time()
    if now == nil then return end
    m_AutoRestartAt = now + (tonumber(delaySeconds) or SWITCH_AUTO_DELAY)
    EnsureSwitchTick()
    Log("自动换图：原档已确认落盘，倒计时开始（" .. tostring(delaySeconds or SWITCH_AUTO_DELAY) .. " 秒）")
end

-- 换图状态机（**简化后只剩三件事**：等确认 → 确认了倒计时 → 到点重开）
--   为什么要等确认：SaveComplete 认不出是哪一份存档（换图前刚好写了交接单那个小配置档），
--   之前靠它 + 一个盲倒计时“猜”原档写完了，实机结果就是“面板说存好了、存档列表里却没有”。
--   现在唯一的判据是**存档列表里查得到**；超时只重发一次，再不行就老实说失败。
local function TickAutoSwitch(delta)
    local state = ModMiscSaveGraph.GetSaveState ~= nil and ModMiscSaveGraph.GetSaveState() or nil
    if state ~= nil and state.Verified ~= true and state.Failed ~= true then
        m_SaveWaitFrames = (m_SaveWaitFrames or 0) + 1
        m_CheckSaveFrames = (m_CheckSaveFrames or 0) + 1
        -- 每 ~2 秒查一次列表（帧率按 30 估）
        if m_CheckSaveFrames >= 60 then
            m_CheckSaveFrames = 0
            ModMiscSaveGraph.VerifySaveNow(function(found)
                if found then
                    m_SaveWaitFrames = 0
                    SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_VERIFIED"))
                    ArmAutoRestart(SWITCH_AUTO_DELAY)
                end
            end)
        end
        SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_VERIFYING",
            tostring(state.Name or "?"), tostring(math.floor((state.Elapsed or 0)))))
        -- 等太久（40 秒）⇒ 重发一次；再等 40 秒还没有 ⇒ 老实报错，不再盲切
        if (state.Elapsed or 0) > 40 then
            if (state.Attempts or 1) < 2 then
                m_SaveWaitFrames = 0
                ModMiscSaveGraph.RetrySave(function(found)
                    if found then ArmAutoRestart(SWITCH_AUTO_DELAY) end
                end)
            else
                Log("换图：原档两次都没能确认落盘，停止自动切换（等玩家手动重试）")
                SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVE_FAILED"))
                m_SaveWaitFrames = nil
                ModMiscSaveGraph.MarkSaveFailed()
            end
        end
    elseif m_AutoRestartAt ~= nil then
        local now = os.time()
        if now == nil then
            m_AutoRestartAt = nil
        elseif now >= m_AutoRestartAt then
            m_AutoRestartAt = nil
            Log("自动换图：原档已确认落盘，发出重开")
            SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_AUTO_RESTART"))
            local ok, err = ModMiscSaveGraph.SwitchNow("自动（确认落盘后倒计时结束）")
            if not ok then
                Log("自动换图：重开被拒 -> " .. tostring(err) .. "（等玩家手动点）")
                SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_AUTO_FAILED"))
            end
        else
            SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_AUTO_COUNTDOWN",
                tostring(m_AutoRestartAt - now)))
        end
    end
    ContextPtr:RequestRefresh()
end

EnsureSwitchTick = function()
    if m_SwitchTickArmed then return end
    m_SwitchTickArmed = true
    ContextPtr:SetRefreshHandler(TickAutoSwitch)
    ContextPtr:RequestRefresh()
    Log("自动换图倒计时回调已挂")
end

local function DoSwitchMap()
    -- 第二步：原档已存好 → 在按钮回调里直接重开
    if ModMiscSaveGraph.HasPendingSwitch() then
        local state = ModMiscSaveGraph.GetSaveState ~= nil and ModMiscSaveGraph.GetSaveState() or nil
        if state ~= nil and state.Verified ~= true then
            -- 原档还没确认落盘：先别重开（免得切过去却丢档）
            Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_WAIT_SAVE"),
                Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_WAIT_SAVE_DETAIL"))
            return
        end
        Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_NOW"),
            Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_NOW_DETAIL"))
        local ok, err = ModMiscSaveGraph.SwitchNow("面板按钮（第二次点击）")
        if not ok then ReportError("SwitchNow", err) end
        return
    end

    -- 第一步：记交接单 + 发存档；**倒计时只在“列表里确认到了”之后才开始**（见 TickAutoSwitch）
    m_AutoRestartTries = 0
    m_SaveWaitFrames = 0
    m_CheckSaveFrames = 59        -- 下一帧就去查一次
    local ok, idOrErr = ModMiscSaveGraph.PrepareSwitch({
        OnVerified = function(found)
            if found then ArmAutoRestart(SWITCH_AUTO_DELAY) end
        end,
    })
    if not ok then
        ReportError("PrepareSwitch", idOrErr)
        return
    end
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_PREPARED", tostring(idOrErr)),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCH_PREPARED_DETAIL"))
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
    local ok, err = pcall(function()
        local popup = PopupDialogInGame:new("UnitPanelPopup")
        popup:ShowOkCancelDialog(text, function()
            local delOk, delErr = ModMiscSaveGraph.DeleteNode(node.Id)
            if not delOk then
                ReportError("DeleteNode", delErr)
                return
            end
            m_SelectedNode = nil
            Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_DELETED", tostring(delErr)), nil)
            RefreshAll()
        end)
    end)
    if not ok then ReportError("DeleteConfirm", err) end
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
    Controls.ModMiscSaveSwitchMap:RegisterCallback(Mouse.eLClick,
        function() SafeCall("SwitchMap", DoSwitchMap) end)
    Controls.ModMiscSaveRefresh:RegisterCallback(Mouse.eLClick,
        function() SafeCall("Refresh", function() RefreshAll() end) end)

    UpdateInfoLine()
end

function OnLoadGameViewStateDone()
    AttachPanelToInGame()
    TryRegisterSidebarButton()
    UpdateInfoLine()
end

Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
Events.LocalPlayerTurnBegin.Add(TryRegisterSidebarButton)
LuaEvents.ModMiscToolUIReady.Add(TryRegisterSidebarButton)
ContextPtr:SetInitHandler(OnInit)
