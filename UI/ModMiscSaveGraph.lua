-- ===========================================================================
-- Mod Misc Tool: 存档关系树（主线 / 分支）+ 换图存档（UI 层，成品功能）
--
-- 【要解决什么】“切换地图”只能靠 `Network.RestartGame()`（已验证可用）：它会用**同一个
-- 地图脚本**重新生成一张图（换种子）。也就是说，换图 = 丢掉当前世界重新开一局 ——
-- 所以必须**先把原档存下来**，并且让玩家看得见“哪一档是本线的最新进度、哪一档是从哪分出来的”。
--
-- 【为什么靠文件名】本项目的跨存档通道只有一条是实测可用的：**存档文件名**
-- （`Network.SaveGame{Name=…}` 写、`UI.QuerySaveGameList` 读，见 API_Verification_Status.md
-- 通道表 C）。CustomData 不跨新局、配置档不带它、io 库不存在 ⇒ 关系信息只能写在档名里。
--
-- 【档名格式】（授权者 2026-10-05 定：机器字段在前）
--     MMT~<id>~<parent>~<kind>~T<turn>~<map>~<stamp>
--   例：MMT~m4k2x1az~0~M~T042~Pangaea~20261005-1432
--     id      本次存档的编号（base36 时间戳 + 2 位随机；唯一、可排序）
--     parent  父存档 id；`0` = 树根（第一档 / 接手没有记录的局）
--     kind    `M` 主线（延续当前主线头）/ `B` 分支（从非主线头分叉，SL 试验与换图后的新局）
--     turn    存这一档时的回合数（给人看）
--     map     地图脚本名（去掉 .lua，禁字符已替换成 _）
--     stamp   YYYYMMDD-HHMM
--   文件名禁用字符（`% " < > | / \ * ? :` 与控制字符）以及分隔符 `~` 一律替换成 `_`。
--
-- 【主线 / 分支怎么自动判】（授权者定：只给一个存档按钮，主/分由 mod 判）
--   * 当前节点 == 主线头（`sg_head`）→ **M**：这是本线的最新进度；
--   * 当前节点不是主线头（例如读了一档旧档继续玩 = SL）→ **B**：它从主线分叉出去；
--   * 没有当前节点（新局第一次存档）→ 接“待接分支”（换图后）或当树根（M）。
--   每次写出 M 档就把主线头推进到它；B 档不动主线头。
--
-- 【换图流程】（一个按钮：先存原档 → 记关系 → 重开）
--   ① 存原档：按上面的规则自动判 M/B（在主线上就是 M），档名带好父子关系；
--   ② 写“待接分支”到跨存档存储（`sg_pending` = `<原档id>|B|<stamp>`）—— 因为重开后
--      CustomData 不继承，只有存储通道能把关系带过去；
--   ③ `Network.RestartGame()`；
--   ④ 新局进游戏 → 开局探针读到“待接分支”：本局第一次存档自动挂到那个原档下、算**分支**，
--      之后在这一局里继续存就是这条分支的延续。
--
-- 【当前节点怎么知道】（关键）**随档保存**：存档前把节点身份写进 CustomData
--   （`ModMiscSaveGraph_*`），CustomData 随普通存档序列化、读档原样还原（第 21 条）
--   ⇒ 读档进游戏后就能知道“我在哪个节点”，之后存的档自然接在它下面。新局没有 CustomData，
--   所以走上面第 ④ 条的“待接分支”。
--
-- 【公开 API】本 mod 内直接调 ModMiscSaveGraph.*
--   DescribeContext()                 只读：格式说明 + 当前节点 / 主线头 / 待接分支 + 扫描状态
--   BuildSaveName(node) / ParseSaveName(rawName)   档名 ↔ 节点（外部工具/测试也用）
--   Refresh(onDone)                   扫存档列表（只收 MMT~ 前缀的档）
--   GetNodes()                        已解析的节点副本
--   BuildTreeLines()                  深度优先的 { { Node, Depth }, … }（面板渲染用）
--   DescribeTree()                    关系树文本（日志/面板都能用）
--   GetCurrentNodeId() / GetMainlineHeadId() / GetPendingBranch()
--   SaveCurrentGame(options)          options = { Reason = "manual"|"switch", OnSaved = fn }
--   SwitchMap()                       存原档 → 记待接分支 → Network.RestartGame()
--   ReportAfterLoad()                 开局探针（由 Support_UI.Initialize 调一次）
--
-- ⚠️ 本文件**不挂 Events**（会被多个 context include）；`Events.SaveComplete` 只在
--    真正发起存档时挂一次性监听。
-- ===========================================================================

local MODMISC_SAVEGRAPH_BUILD_TAG = "2026-10-05-A"

local MODMISC_SAVE_PREFIX = "MMT"
local MODMISC_SAVE_SEP = "~"
local MODMISC_SAVE_ROOT_PARENT = "0"
local MODMISC_KIND_MAINLINE = "M"
local MODMISC_KIND_BRANCH = "B"

-- 跨存档存储（ModMiscStore，通道 C）里的键
local MODMISC_STORE_KEY_MAINLINE_HEAD = "sg_head"
local MODMISC_STORE_KEY_PENDING = "sg_pending"

-- CustomData 键前缀：随档保存，读档后就知道“我在哪个节点”
local MODMISC_CD_PREFIX = "ModMiscSaveGraph_"

local BASE36_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

ModMiscSaveGraph = ModMiscSaveGraph or {}
local API = ModMiscSaveGraph
API.BuildTag = MODMISC_SAVEGRAPH_BUILD_TAG
API.Prefix = MODMISC_SAVE_PREFIX
API.KindMainline = MODMISC_KIND_MAINLINE
API.KindBranch = MODMISC_KIND_BRANCH

local function Log(message)
    print("[ModMiscTool][SaveGraph] " .. tostring(message))
end

-- 诊断/工具函数一律不能影响主流程
local function TryCall(getter)
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter)
    if not ok then return nil end
    return value
end

-- ===========================================================================
-- 档名：构造与解析
-- ===========================================================================

local function ToBase36(number)
    local value = math.floor(tonumber(number) or 0)
    if value <= 0 then return "0" end
    local digits = {}
    while value > 0 do
        local remainder = value % 36
        table.insert(digits, 1, BASE36_DIGITS:sub(remainder + 1, remainder + 1))
        value = math.floor(value / 36)
    end
    return table.concat(digits)
end

-- 文件名禁用字符 + 分隔符，一律换成下划线
local function SanitizeToken(text)
    if text == nil then return "_" end
    local cleaned = tostring(text):gsub("[%%\"<>|/\\*%?:~\r\n\t]", "_")
    cleaned = cleaned:gsub("%s+", "_")
    if cleaned == "" then return "_" end
    return cleaned
end

local function BuildNodeId()
    local stamp = "0"
    local ok, value = pcall(os.time)
    if ok and value ~= nil then stamp = ToBase36(value) end
    return stamp .. ToBase36(math.random(0, 1295))
end

local function BuildStamp()
    local ok, text = pcall(function() return os.date("%Y%m%d-%H%M") end)
    if ok and text ~= nil and tostring(text) ~= "" then return SanitizeToken(text) end
    return ToBase36(TryCall(function() return os.time() end) or 0)
end

-- node = { Id, Parent, Kind, Turn, Map, Stamp }（Parent 为 nil 时写成 0）
function API.BuildSaveName(node)
    if node == nil or node.Id == nil then return nil end
    local parent = node.Parent
    if parent == nil or tostring(parent) == "" then parent = MODMISC_SAVE_ROOT_PARENT end
    local kind = tostring(node.Kind or MODMISC_KIND_BRANCH)
    local turn = tonumber(node.Turn) or 0
    return table.concat({
        MODMISC_SAVE_PREFIX,
        SanitizeToken(node.Id),
        SanitizeToken(parent),
        SanitizeToken(kind),
        "T" .. string.format("%03d", turn),
        SanitizeToken(node.Map),
        SanitizeToken(node.Stamp),
    }, MODMISC_SAVE_SEP)
end

-- 存档列表里的 Name 带扩展名（普通档是 xxx.Civ6Save），比对/解析前先剥掉。
-- ⚠️ 不能按“最后一个点”盲剥：我们的档名里本来就可能带点（地图脚本名、时间戳），
-- 盲剥会把 `..._lua_.` 这种残缺串留下来（实测踩过），所以只认已知后缀。
local function StripExtension(name)
    if name == nil then return nil end
    local text = tostring(name)
    text = text:gsub("%.Civ6Save$", "")
    text = text:gsub("%.Civ6Cfg$", "")
    text = text:gsub("%.Civ6Map$", "")
    return text
end

-- 不是本 mod 的档（或格式不符）→ nil, 原因
function API.ParseSaveName(rawName)
    local name = StripExtension(rawName)
    if name == nil or name == "" then return nil, "空档名" end
    if name:sub(1, #MODMISC_SAVE_PREFIX) ~= MODMISC_SAVE_PREFIX then
        return nil, "不是本 mod 的档"
    end
    local id, parent, kind, turnText, map, stamp = name:match(
        "^" .. MODMISC_SAVE_PREFIX .. MODMISC_SAVE_SEP .. "([^" .. MODMISC_SAVE_SEP .. "]+)"
        .. MODMISC_SAVE_SEP .. "([^" .. MODMISC_SAVE_SEP .. "]+)"
        .. MODMISC_SAVE_SEP .. "([^" .. MODMISC_SAVE_SEP .. "]+)"
        .. MODMISC_SAVE_SEP .. "T(%d+)"
        .. MODMISC_SAVE_SEP .. "([^" .. MODMISC_SAVE_SEP .. "]+)"
        .. MODMISC_SAVE_SEP .. "([^" .. MODMISC_SAVE_SEP .. "]+)$")
    if id == nil then return nil, "格式不符" end

    local node = {
        Id = id,
        Parent = (parent ~= MODMISC_SAVE_ROOT_PARENT) and parent or nil,
        Kind = kind,
        Turn = tonumber(turnText),
        Map = map,
        Stamp = stamp,
        RawName = name,
        Depth = 0,
        Children = {},
    }
    return node
end

-- ===========================================================================
-- 当前节点 / 主线头 / 待接分支
-- ===========================================================================

local function ReadCustomDataValue(key)
    local reader = ReadCustomData
    if reader == nil then return nil end
    local ok, value = pcall(reader, MODMISC_CD_PREFIX .. key)
    if not ok or value == nil then return nil end
    local text = tostring(value)
    if text == "" then return nil end
    return text
end

local function WriteCustomDataValue(key, value)
    local writer = WriteCustomData
    if writer == nil then return false end
    local ok = pcall(writer, MODMISC_CD_PREFIX .. key, tostring(value or ""))
    return ok
end

function API.GetCurrentNodeId()
    return ReadCustomDataValue("NodeId")
end

-- “本局来源”：换图重开后，开局探针把待接分支固化到 CustomData 里（随档保存），
-- 于是本局第一次存档就知道自己挂在谁下面、算分支 —— 而且不依赖“存储此刻还读不读得到”。
function API.GetIncomingBranch()
    local parent = ReadCustomDataValue("PendingParent")
    if parent == nil or parent == "" then return nil end
    return {
        Parent = (parent ~= MODMISC_SAVE_ROOT_PARENT) and parent or nil,
        Kind = ReadCustomDataValue("PendingKind") or MODMISC_KIND_BRANCH,
    }
end

local function GetStore()
    return ModMiscStore
end

function API.GetMainlineHeadId()
    local store = GetStore()
    if store == nil or store.Get == nil then return nil end
    local value = store.Get(MODMISC_STORE_KEY_MAINLINE_HEAD)
    if value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

-- 待接分支：`<原档id>|<kind>|<stamp>`（换图重开前写入，新局第一次存档消费掉）
function API.GetPendingBranch()
    local store = GetStore()
    if store == nil or store.Get == nil then return nil end
    local value = store.Get(MODMISC_STORE_KEY_PENDING)
    if value == nil or tostring(value) == "" then return nil end
    local parent, kind, stamp = tostring(value):match("^([^|]+)|([^|]*)|(.*)$")
    if parent == nil then return nil end
    return {
        Parent = (parent ~= MODMISC_SAVE_ROOT_PARENT) and parent or nil,
        Kind = (kind ~= nil and kind ~= "") and kind or MODMISC_KIND_BRANCH,
        Stamp = stamp,
    }
end

local function SetPendingBranch(parentId, kind, stamp)
    local store = GetStore()
    if store == nil or store.Save == nil then return false end
    local parent = parentId
    if parent == nil or tostring(parent) == "" then parent = MODMISC_SAVE_ROOT_PARENT end
    local payload = tostring(parent) .. "|" .. tostring(kind or MODMISC_KIND_BRANCH)
        .. "|" .. tostring(stamp or "")
    return store.Save(MODMISC_STORE_KEY_PENDING, payload)
end

local function ClearPendingBranch()
    local store = GetStore()
    if store == nil then return false end
    if store.Remove ~= nil then return store.Remove(MODMISC_STORE_KEY_PENDING) end
    if store.Save ~= nil then return store.Save(MODMISC_STORE_KEY_PENDING, "") end
    return false
end

local function SetMainlineHead(nodeId)
    local store = GetStore()
    if store == nil or store.Save == nil or nodeId == nil then return false end
    return store.Save(MODMISC_STORE_KEY_MAINLINE_HEAD, tostring(nodeId))
end

-- ===========================================================================
-- 跨存档存储的就绪门（**这是踩过的坑，别绕过**）
--
-- `ModMiscStore` 的内存表是**每个 UI context 各一份**：换图重开之后，新起的
-- AutomationTestPanel / ModMiscSavePanel 上下文里那张表**是空的**，不先 Refresh 一遍
-- 就读不到 `sg_head` / `sg_pending` ⇒ 新局会把自己当成树根，**分支不知道自己是谁**
-- （授权者 2026-10-05 实测：分支创建成功，但新档没标成分支）。
--
-- 所以凡是“要依据主线头/待接分支做决定”的动作，一律先过这道门：
--   * 已就绪        → 立刻回调；
--   * 还没就绪      → 挂 OnReady + 触发 Refresh，扫完再回调（期间动作排队，不会拿旧数据决定）；
--   * 存储用不了    → 回调 notReady，调用方自己决定“带警告继续”还是“取消”。
-- ===========================================================================
local function EnsureStoreReady(callback)
    local store = GetStore()
    if store == nil then callback(false, "存储模块没加载"); return end
    if store.IsReady == nil or store.IsReady() then callback(true, "ready"); return end
    if store.OnReady == nil then callback(false, "存储模块没有 OnReady"); return end

    local done = false
    local function Finish(ready, reason)
        if done then return end
        done = true
        callback(ready, reason)
    end

    store.OnReady(function() Finish(true, "ready") end)
    local started = true
    if store.Refresh ~= nil then started = store.Refresh() end
    -- Refresh 返回 false 且当前没有扫描在跑 = 扫描根本起不来（依赖缺失），别把动作挂死
    if not started and store.IsRefreshing ~= nil and not store.IsRefreshing() then
        Finish(false, "扫描起不来")
    end
end

-- 这次存档算不算“延续主线”：主线头没记录时按延续处理（宁可当主线，也别把正常进度标成分支）
local function IsMainlineHead(nodeId)
    if nodeId == nil then return true end
    local head = API.GetMainlineHeadId()
    if head == nil then return true end
    return head == tostring(nodeId)
end

-- ===========================================================================
-- 扫存档列表（只收本 mod 格式的档）
-- ===========================================================================

local m_Nodes = {}
local m_NodeById = {}
local m_RefreshRequestId = nil
local m_Refreshing = false
local m_RefreshCallbacks = {}

local function BuildGameSaveFile()
    if SaveLocations == nil or SaveTypes == nil then return nil end
    local saveFile = {
        Location = SaveLocations.LOCAL_STORAGE,
        Type = SaveTypes.SINGLE_PLAYER,
        FileType = SaveFileTypes ~= nil and SaveFileTypes.GAME_STATE or nil,
    }
    if SaveDirectories ~= nil then saveFile.Directory = SaveDirectories.DEFAULT end
    return saveFile
end

local function OnSaveGraphQueryResults(fileList, requestId)
    -- LuaEvents.FileListQueryResults 是全局广播（游戏自己的存档菜单也会发）—— 严格对号请求号
    if m_RefreshRequestId == nil or requestId ~= m_RefreshRequestId then return end
    m_RefreshRequestId = nil
    m_Refreshing = false
    if LuaEvents ~= nil and LuaEvents.FileListQueryResults ~= nil then
        LuaEvents.FileListQueryResults.Remove(OnSaveGraphQueryResults)
    end

    m_Nodes = {}
    m_NodeById = {}
    local total = 0
    if type(fileList) == "table" then
        for _, entry in ipairs(fileList) do
            total = total + 1
            local name = entry ~= nil and entry.Name or nil
            local node = API.ParseSaveName(name)
            if node ~= nil then
                table.insert(m_Nodes, node)
                m_NodeById[node.Id] = node
            end
        end
    end
    -- 按 id 排序（id 是 base36 时间戳 + 随机 → 近似创建顺序）
    table.sort(m_Nodes, function(a, b) return tostring(a.Id) < tostring(b.Id) end)
    API.LinkTree()
    Log("扫描完成：列表 " .. tostring(total) .. " 档，其中本 mod 关系档 "
        .. tostring(#m_Nodes) .. " 档")

    local callbacks = m_RefreshCallbacks
    m_RefreshCallbacks = {}
    for _, callback in ipairs(callbacks) do
        pcall(callback, m_Nodes)
    end
end

function API.Refresh(onDone)
    if onDone ~= nil then table.insert(m_RefreshCallbacks, onDone) end
    if m_Refreshing then return false end
    if UI == nil or UI.QuerySaveGameList == nil or LuaEvents == nil
        or LuaEvents.FileListQueryResults == nil or SaveLocationOptions == nil then
        Log("扫描不可用（QuerySaveGameList / SaveLocationOptions 缺失）")
        return false
    end
    local saveFile = BuildGameSaveFile()
    if saveFile == nil then
        Log("扫描不可用：存档表构建不了")
        return false
    end
    local options = SaveLocationOptions.NORMAL + SaveLocationOptions.QUICKSAVE
        + SaveLocationOptions.LOAD_METADATA
    LuaEvents.FileListQueryResults.Add(OnSaveGraphQueryResults)
    m_Refreshing = true
    m_RefreshRequestId = UI.QuerySaveGameList(saveFile.Location, saveFile.Type,
        options, saveFile.FileType, nil)
    Log("已发出存档列表扫描（找 " .. MODMISC_SAVE_PREFIX .. " 前缀的档）")
    return true
end

function API.GetNodes()
    local copy = {}
    for index, node in ipairs(m_Nodes) do
        copy[index] = node
    end
    return copy
end

-- ===========================================================================
-- 关系树：连父子、算深度、摊平成面板能直接渲染的列表
-- ===========================================================================

function API.LinkTree()
    local currentId = API.GetCurrentNodeId()
    for _, node in ipairs(m_Nodes) do
        node.Depth = 0
        node.Children = {}
        node.Orphan = false
        node.IsCurrent = (currentId ~= nil and node.Id == currentId)
    end
    for _, node in ipairs(m_Nodes) do
        local parent = (node.Parent ~= nil) and m_NodeById[node.Parent] or nil
        if node.Parent == nil then
            -- 树根
        elseif parent ~= nil then
            table.insert(parent.Children, node)
        else
            -- 父档不在列表里（被删了 / 只留了分支）→ 当孤儿根显示
            node.Orphan = true
        end
    end
end

local function CollectTreeLines(node, depth, lines, visited)
    if node == nil or visited[node.Id] then return end
    visited[node.Id] = true
    table.insert(lines, { Node = node, Depth = depth })
    -- 子节点按 id 排序，保证每次渲染顺序一致
    table.sort(node.Children, function(a, b) return tostring(a.Id) < tostring(b.Id) end)
    for _, child in ipairs(node.Children) do
        CollectTreeLines(child, depth + 1, lines, visited)
    end
end

function API.BuildTreeLines()
    API.LinkTree()
    local lines = {}
    local visited = {}
    -- 先渲染没有父（或父不在列表里）的，再渲染剩下没访问到的（防环）
    for _, node in ipairs(m_Nodes) do
        if node.Parent == nil or node.Orphan then
            CollectTreeLines(node, 0, lines, visited)
        end
    end
    for _, node in ipairs(m_Nodes) do
        if not visited[node.Id] then
            CollectTreeLines(node, 0, lines, visited)
        end
    end
    return lines
end

function API.DescribeTree()
    local lines = API.BuildTreeLines()
    if #lines == 0 then return "(没有本 mod 的关系档)" end
    local out = {}
    for _, line in ipairs(lines) do
        local node = line.Node
        table.insert(out, string.format("%s[%s] %s T%s %s %s%s",
            string.rep("    ", line.Depth), tostring(node.Kind), tostring(node.Id),
            tostring(node.Turn or "?"), tostring(node.Map), tostring(node.Stamp),
            node.IsCurrent and "  <= 本局" or (node.Orphan and "  (父档不在列表)" or "")))
    end
    return table.concat(out, "\n")
end

-- ===========================================================================
-- 只读探测
-- ===========================================================================

function API.DescribeContext()
    local lines = {}
    table.insert(lines, "format: " .. MODMISC_SAVE_PREFIX .. MODMISC_SAVE_SEP .. "<id>"
        .. MODMISC_SAVE_SEP .. "<parent>" .. MODMISC_SAVE_SEP .. "<M|B>"
        .. MODMISC_SAVE_SEP .. "T<turn>" .. MODMISC_SAVE_SEP .. "<map>"
        .. MODMISC_SAVE_SEP .. "<stamp>")
    table.insert(lines, "current=" .. tostring(API.GetCurrentNodeId())
        .. " head=" .. tostring(API.GetMainlineHeadId()))

    local pending = API.GetPendingBranch()
    table.insert(lines, "pending=" .. (pending ~= nil
        and (tostring(pending.Parent) .. "|" .. tostring(pending.Kind)) or "nil"))

    local store = GetStore()
    table.insert(lines, "store=" .. tostring(store ~= nil)
        .. " storeReady=" .. tostring(store ~= nil and store.IsReady ~= nil and store.IsReady())
        .. " nodes=" .. tostring(#m_Nodes))
    for _, line in ipairs(lines) do
        Log(line)
    end
    return table.concat(lines, "\n")
end

-- ===========================================================================
-- 存档：算父子与主/分 → 写 CustomData 身份 → Network.SaveGame → 等 SaveComplete
-- ===========================================================================

local function GetTurnNumber()
    local turn = TryCall(function() return Game.GetCurrentGameTurn() end)
    return tonumber(turn) or 0
end

-- 地图脚本名（去掉 .lua）；读不到就写 unknown
local function GetMapToken()
    local mapScript = nil
    if ModMiscCreateGame ~= nil and ModMiscCreateGame.GetCurrentMapScript ~= nil then
        mapScript = TryCall(function() return (ModMiscCreateGame.GetCurrentMapScript()) end)
    end
    if mapScript == nil then
        mapScript = TryCall(function() return MapConfiguration.GetScript() end)
    end
    if mapScript == nil then return "unknown" end
    local text = tostring(mapScript)
    text = text:gsub("%.lua$", "")
    text = text:gsub(".*[/\\]", "")
    return SanitizeToken(text)
end

-- 这次存档接在谁下面、算什么类型
local function ResolveNewSaveParent()
    local currentId = API.GetCurrentNodeId()
    if currentId ~= nil then
        -- 本局已经有节点（本局存过 / 读的是本 mod 的档）→ 接它
        return currentId, nil, "current"
    end
    -- 换图重开后的新局：开局探针已经把待接分支固化成“本局来源”
    local incoming = API.GetIncomingBranch()
    if incoming ~= nil and incoming.Parent ~= nil then
        return incoming.Parent, incoming.Kind or MODMISC_KIND_BRANCH, "incoming"
    end
    -- 兜底：存储里的待接分支（理论上开局就该被固化，这里防“探针没跑到”）
    local pending = API.GetPendingBranch()
    if pending ~= nil and pending.Parent ~= nil then
        return pending.Parent, pending.Kind or MODMISC_KIND_BRANCH, "pending"
    end
    -- 什么都没有（第一次用 / 读的是老档或非本 mod 档）→ 无父，当树根
    return nil, MODMISC_KIND_MAINLINE, "root"
end

-- 本次要写的节点：Parent / Kind / Id / Turn / Map / Stamp 全定下来
local function BuildNextNode()
    local currentId = API.GetCurrentNodeId()
    local headId = API.GetMainlineHeadId()
    local pending = API.GetPendingBranch()

    local incoming = API.GetIncomingBranch()
    local parentId, forcedKind, parentSource = ResolveNewSaveParent()
    local kind = forcedKind
    if kind == nil then
        kind = IsMainlineHead(parentId) and MODMISC_KIND_MAINLINE or MODMISC_KIND_BRANCH
    end
    -- 父来自“待接分支 / 本局来源” ⇒ 这是换图后新局的第一次存档，要消费掉存储里的 pending
    local consumedPending = (currentId == nil and parentSource ~= "root")
    Log("判定：current=" .. tostring(currentId)
        .. " incoming=" .. (incoming ~= nil and tostring(incoming.Parent) or "nil")
        .. " head=" .. tostring(headId)
        .. " pending=" .. (pending ~= nil and tostring(pending.Parent) or "nil")
        .. " 来源=" .. tostring(parentSource)
        .. " => parent=" .. tostring(parentId) .. " kind=" .. tostring(kind)
        .. " consumePending=" .. tostring(consumedPending))
    return {
        Id = BuildNodeId(),
        Parent = parentId,
        Kind = kind,
        Turn = GetTurnNumber(),
        Map = GetMapToken(),
        Stamp = BuildStamp(),
        ConsumedPending = consumedPending,
    }
end

local m_SavePending = nil

local function OnSaveGraphSaveComplete(...)
    if m_SavePending == nil then return end
    local pending = m_SavePending
    m_SavePending = nil
    if Events ~= nil and Events.SaveComplete ~= nil then
        Events.SaveComplete.Remove(OnSaveGraphSaveComplete)
    end
    local saveResult = ...
    Log("SaveComplete 回执：" .. tostring(saveResult)
        .. "（节点 " .. tostring(pending.Node.Id) .. "）")

    -- 主线头推进 / 待接分支消费
    -- ⚠️ 只有“父来自待接分支”的那次存档才清 pending。换图时存的是**原档**（父是当前节点），
    -- 它绝不能把刚写好的 pending 清掉 —— 新局还等着它接关系（这里是踩过的坑）。
    if pending.Node.Kind == MODMISC_KIND_MAINLINE then
        SetMainlineHead(pending.Node.Id)
    end
    if pending.Node.ConsumedPending then
        Log("已消费待接分支（本局第一次存档，父=" .. tostring(pending.Node.Parent) .. "）")
        ClearPendingBranch()
    end

    -- 复查列表：文件真的落盘了才会出现在里面（UI.QuerySaveGameList 是 [已验证可用] 接口）
    API.Refresh(function(nodes)
        local found = false
        for _, node in ipairs(nodes) do
            if node.Id == pending.Node.Id then found = true break end
        end
        Log("落盘复查：节点 " .. tostring(pending.Node.Id)
            .. (found and " 已在存档列表里" or " 没在列表里（可能还没写完 / 写失败）"))
        if pending.OnSaved ~= nil then
            pcall(pending.OnSaved, found, pending.Node)
        end
    end)
end

-- 按既定节点写一档：写 CustomData 身份 → Network.SaveGame → 等 SaveComplete → 复查落盘
-- opts = { Reason = "manual"|"switch", OnSaved = function(found, node) end }
local function SaveNode(node, opts)
    local options = opts or {}
    if Network == nil or Network.SaveGame == nil then
        Log("存档失败：Network.SaveGame 不可用")
        return false, "Network.SaveGame 不可用"
    end
    if m_SavePending ~= nil then
        Log("存档失败：上一笔存档还在等 SaveComplete")
        return false, "上一笔存档还没回执"
    end

    local name = API.BuildSaveName(node)
    if name == nil then
        Log("存档失败：档名构造失败")
        return false, "档名构造失败"
    end

    -- ① 节点身份写进 CustomData（随这一档保存；读档后就知道“我在哪个节点”）
    WriteCustomDataValue("NodeId", node.Id)
    WriteCustomDataValue("ParentId", node.Parent or MODMISC_SAVE_ROOT_PARENT)
    WriteCustomDataValue("Kind", node.Kind)
    WriteCustomDataValue("Stamp", node.Stamp)

    local saveFile = BuildGameSaveFile()
    if saveFile == nil then
        Log("存档失败：存档表构建不了（SaveLocations / SaveTypes / SaveFileTypes 缺失）")
        return false, "存档表构建不了"
    end
    saveFile.Name = name
    saveFile.IsAutosave = false
    saveFile.IsQuicksave = false

    m_SavePending = { Node = node, OnSaved = options.OnSaved, Reason = options.Reason }
    if Events ~= nil and Events.SaveComplete ~= nil then
        Events.SaveComplete.Add(OnSaveGraphSaveComplete)
    else
        Log("警告：Events.SaveComplete 不可用，落盘复查会缺失")
    end
    Log("即将调用 Network.SaveGame（" .. tostring(options.Reason or "manual") .. "）"
        .. " name=" .. name
        .. "（parent=" .. tostring(node.Parent or MODMISC_SAVE_ROOT_PARENT)
        .. " kind=" .. tostring(node.Kind) .. " turn=" .. tostring(node.Turn) .. "）")
    local ok, err = pcall(Network.SaveGame, saveFile)
    if not ok then
        m_SavePending = nil
        Log("Network.SaveGame 调用失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    Log("Network.SaveGame 调用已返回（没卡死），等 SaveComplete")
    return true, name
end

-- options = { Reason = "manual"|"switch", OnSaved = function(found, node) end }
-- 返回 (true, nil) = 请求已受理（真正开写前会先等跨存档存储就绪）；
-- 真正写完看 options.OnSaved(found, node)。
function API.SaveCurrentGame(options)
    local opts = options or {}
    if Network == nil or Network.SaveGame == nil then
        Log("存档失败：Network.SaveGame 不可用")
        return false, "Network.SaveGame 不可用"
    end
    EnsureStoreReady(function(ready, reason)
        if not ready then
            -- 存储用不了就**别拦玩家**：照样存，只是关系可能判错（日志会写明）
            Log("警告：跨存档存储不可用（" .. tostring(reason) .. "），存档照旧但关系可能判错")
        end
        SaveNode(BuildNextNode(), opts)
    end)
    return true, nil
end

-- ===========================================================================
-- 换图：先存原档 → 记待接分支 → RestartGame
-- ===========================================================================

local function DoRestart(node, reason)
    Log("换图：" .. tostring(reason) .. "；即将调用 Network.RestartGame()（原档 "
        .. tostring(node ~= nil and node.Id or "?") .. "）")
    local ok, err = pcall(function() return Network.RestartGame() end)
    if not ok then
        Log("Network.RestartGame 调用失败 -> " .. tostring(err))
        return false
    end
    Log("Network.RestartGame 调用已返回（没卡死）")
    return true
end

-- 重开前确认「待接分支」真的落到磁盘上（Refresh 会把磁盘上的档重新解进内存表，
-- 扫描后还能读到 pending ⇒ 文件在盘上）。两次都读不到就记日志并照样重开：
-- 玩家要的是换图，关系丢一条边不会损坏任何档。
local function VerifyPendingThenRestart(node, attempt)
    local store = GetStore()
    if store == nil or store.Refresh == nil then
        DoRestart(node, "跨存档存储不可用，关系未确认")
        return
    end
    local started = store.Refresh(function()
        local pending = API.GetPendingBranch()
        if pending ~= nil and tostring(pending.Parent) == tostring(node.Id) then
            DoRestart(node, "待接分支已确认落盘")
        elseif attempt < 1 then
            Log("存储里还没看到待接分支，再扫一次…")
            VerifyPendingThenRestart(node, attempt + 1)
        else
            DoRestart(node, "待接分支两次都没确认（原档已保存，关系可能丢）")
        end
    end)

    -- Refresh 返回 false 有两种含义：扫描已在跑（我们的回调会被调用，别重复动作），
    -- 或依赖缺失（回调永远不来）。只有后者才用内存值兜底，否则会重开两次。
    if not started then
        local alreadyRunning = store.IsRefreshing ~= nil and store.IsRefreshing()
        if not alreadyRunning then
            local pending = API.GetPendingBranch()
            if pending ~= nil and tostring(pending.Parent) == tostring(node.Id) then
                DoRestart(node, "存储扫描起不来，按内存里的待接分支继续")
            else
                DoRestart(node, "存储扫描起不来，内存里也没有待接分支")
            end
        end
    end
end

function API.SwitchMap()
    if Network == nil or Network.RestartGame == nil then
        return false, "Network.RestartGame 不可用（换图只能靠它，见第 42 条）"
    end
    if m_SavePending ~= nil then
        return false, "上一笔存档还在等回执，稍后再试"
    end

    EnsureStoreReady(function(ready, reason)
        if not ready then
            Log("警告：跨存档存储不可用（" .. tostring(reason)
                .. "），换图照旧但新局可能接不上关系")
        end
        -- ① 先把节点算出来（id 先生成好），**先写待接分支** —— 重开后只有跨存档存储能过去，
        --    先写就给了它足够时间落盘（游戏存档要慢得多）；
        local node = BuildNextNode()
        SetPendingBranch(node.Id, MODMISC_KIND_BRANCH, node.Stamp)
        Log("换图：待接分支已写入存储（parent=" .. tostring(node.Id) .. "，新局算分支）")

        -- ② 存原档；③ 落盘后再确认待接分支 → 重开（顺序不能反：原档没落盘就重开 = 原档丢失）
        SaveNode(node, {
            Reason = "switch",
            OnSaved = function(found, savedNode)
                Log("原档 " .. tostring(savedNode.Id)
                    .. (found and " 已在存档列表里" or " 未在列表里（可能还没写完）")
                    .. "，准备换图")
                VerifyPendingThenRestart(savedNode, 0)
            end,
        })
    end)
    return true, nil
end

-- ===========================================================================
-- 开局探针：每次进游戏报一次现状（由 Support_UI.Initialize 调一次）
-- ===========================================================================

function API.ReportAfterLoad()
    -- ⚠️ 新 context 的存储内存表是空的：不等它读起来，pending/head 一定读成 nil
    -- （“分支不知道自己是分支”就是这么来的）。所以探针先触发存储扫描，扫完再打权威那行。
    EnsureStoreReady(function(ready, reason)
        local currentId = API.GetCurrentNodeId()
        local head = API.GetMainlineHeadId()
        local pending = API.GetPendingBranch()
        Log("after-load(store=" .. tostring(ready) .. "/" .. tostring(reason) .. "): current="
            .. tostring(currentId) .. " head=" .. tostring(head)
            .. " pending=" .. (pending ~= nil and tostring(pending.Parent) or "nil"))

        -- 新局 + 有待接分支 ⇒ **开局就固化成本局的来源**（写进 CustomData，随档保存），
        -- 然后把存储里那条消费掉：
        --   ① 之后存档不再依赖“存储此刻读不读得到”（这正是分支认不出自己的根因）；
        --   ② 万一玩家之后退回主菜单另开新局，也不会被这条陈旧的 pending 误挂成分支。
        if currentId == nil and pending ~= nil and pending.Parent ~= nil then
            WriteCustomDataValue("PendingParent", pending.Parent)
            WriteCustomDataValue("PendingKind", pending.Kind or MODMISC_KIND_BRANCH)
            ClearPendingBranch()
            Log("本局接手待接分支：parent=" .. tostring(pending.Parent)
                .. " kind=" .. tostring(pending.Kind or MODMISC_KIND_BRANCH)
                .. "（已固化到本局身份，存储里那条已消费）")
        end
    end)
    -- 顺手扫一次存档列表（异步），完成后把关系树打进日志，便于对照
    API.Refresh(function()
        Log("after-load 关系树：\n" .. API.DescribeTree())
    end)
end
