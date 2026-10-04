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
    local pendingText = Locale.Lookup("LOC_MODMISC_SAVEPANEL_NONE")
    if pending ~= nil then
        pendingText = tostring(pending.Parent) .. " → " .. tostring(pending.Kind)
    end
    Controls.ModMiscSaveInfo:SetText(Locale.Lookup("LOC_MODMISC_SAVEPANEL_INFO",
        DescribeId(current), DescribeId(head), pendingText))
end

-- 一条关系档的显示文本：缩进 + [M/B] + id + T回合 + 地图 + 时间 + 标记
local function BuildEntryText(line)
    local node = line.Node
    local indent = string.rep("    ", line.Depth)
    local marks = {}
    if node.IsCurrent then table.insert(marks, Locale.Lookup("LOC_MODMISC_SAVEPANEL_CURRENT")) end
    if node.Orphan then table.insert(marks, Locale.Lookup("LOC_MODMISC_SAVEPANEL_ORPHAN")) end
    local markText = (#marks > 0) and ("  · " .. table.concat(marks, " · ")) or ""
    return string.format("%s[%s] %s  T%s  %s  %s%s", indent, tostring(node.Kind), tostring(node.Id),
        tostring(node.Turn or "?"), tostring(node.Map), tostring(node.Stamp), markText)
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
        instance.EntryButton:RegisterCallback(Mouse.eLClick, function()
            local node = line.Node
            SetDetail(Locale.Lookup("LOC_MODMISC_SAVEPANEL_NODE_DETAIL",
                tostring(node.Id), tostring(node.Parent or ModMiscSaveGraph.Prefix .. "-root"),
                tostring(node.Kind), tostring(node.Turn or "?"), tostring(node.Map),
                tostring(node.Stamp), tostring(node.RawName)))
        end)
    end
    Controls.ModMiscSaveList:CalculateSize()
    Controls.ModMiscSaveList:ReprocessAnchoring()
end

local function RefreshAll(onDone)
    UpdateInfoLine()
    ModMiscSaveGraph.Refresh(function(nodes)
        RenderTree()
        UpdateInfoLine()
        local count = nodes ~= nil and #nodes or 0
        SetStatus(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SCANNED", count))
        if onDone ~= nil then pcall(onDone, count) end
    end)
end

-- ===========================================================================
-- 按钮动作
-- ===========================================================================

local function DoSave()
    local ok, nameOrErr = ModMiscSaveGraph.SaveCurrentGame({
        Reason = "manual",
        OnSaved = function(found, node)
            Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVED", tostring(node.Id),
                    Locale.Lookup(found and "LOC_MODMISC_SAVEPANEL_SAVED_ON_DISK"
                        or "LOC_MODMISC_SAVEPANEL_SAVED_UNCONFIRMED")),
                tostring(node.RawName or ""))
            RefreshAll()
        end,
    })
    if not ok then
        ReportError("Save", nameOrErr)
        return
    end
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SAVING", tostring(nameOrErr)), tostring(nameOrErr))
end

local function DoSwitchMap()
    local ok, nameOrErr = ModMiscSaveGraph.SwitchMap()
    if not ok then
        ReportError("SwitchMap", nameOrErr)
        return
    end
    -- 换图是链式的：存原档 → 落盘确认 → 重开。面板只需把“正在做什么”讲清楚。
    Report(Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCHING", tostring(nameOrErr)),
        Locale.Lookup("LOC_MODMISC_SAVEPANEL_SWITCHING_DETAIL"))
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
    RefreshAll()
    Log("面板已打开")
end

function CloseModMiscSavePanel()
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

    Controls.ModMiscSaveClose:RegisterCallback(Mouse.eLClick, CloseModMiscSavePanel)
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
