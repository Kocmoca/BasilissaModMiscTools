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
-- 【换图流程】（两步式：先存原档 → 再点一次直接重开）
--   ① 换图（面板「重开为新分支」）**不存档**：先看有没有主线存档（没有就要求玩家手动存一档），
--      然后写一条**换图广播**（`sw_bcast`：跨存档存储、**5 分钟有效、读到即删**），立刻重开；
--   ② 新局进游戏 → 开局探针先清过期广播，再看有没有它：**有就一律认定自己是分支**
--      （父 / 逻辑回合锚点都取自广播），然后删掉广播（用后即焚）；
--   ③ 玩家手动改关系（设主线/分支、换父）走**关系覆盖表** `sg_over`：档名改不了（引擎没有改名
--      API），所以在树这一层覆盖；本局自己那条同时改写身份，下次存档自然写进档名。
--
-- 【公开 API】本 mod 内直接调 ModMiscSaveGraph.*
--   DescribeContext()                 只读：格式说明 + 当前节点 / 主线头 / 换图广播 + 扫描状态
--   BuildSaveName(node) / ParseSaveName(rawName)   档名 ↔ 节点（外部工具/测试也用）
--   Refresh(onDone)                   扫存档列表（只收 MMT~ 前缀的档）
--   GetNodes()                        已解析的节点副本
--   BuildTreeLines()                  深度优先的 { { Node, Depth }, … }（面板渲染用）
--   DescribeTree()                    关系树文本（日志/面板都能用）
--   GetCurrentNodeId() / GetMainlineHeadId() / GetIncomingBranch()
--   SaveCurrentGame(options)          options = { Reason = "manual", OnSaved = fn, OnChecked = fn }
--   HasMainlineSave()                 换图门槛：有没有主线存档（没有就得先手动存档）
--   BroadcastBranchSwitch()           写换图广播（sw_bcast：5 分钟、读到即删）
--   TakeBranchBroadcast() / PeekBranchBroadcast() / ClearBranchBroadcast()
--   SwitchToNewBranch()               换图 = 写广播 + 直接重开（**不存档**）
--   RestartNow(reason)                只重开（诊断用）
--   SetCurrentRelation(kind, parentId) / SetNodeRelation(id, kind, parentId) / ClearNodeRelation(id)
--                                     手动把某条档设为主线/分支、或改它的父（关系覆盖表 sg_over）
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

-- 前置声明（Lua 5.1：local 必须先用后声明就会解析成全局 nil —— 本项目踩过好几次）：
-- 这两个在后面才定义，但换图广播 / 关系覆盖那两块要用它们。
local GetMapToken = nil
local SetMainlineHead = nil

-- 跨存档存储（ModMiscStore，通道 C）里的键
local MODMISC_IDENTITY_KEY = "sgnode"       -- 本局身份（persave 表）
local MODMISC_STORE_KEY_MAINLINE_HEAD = "sg_head"
local MODMISC_BCAST_KEY = "sw_bcast"        -- 换图广播（ephemeral/big，5 分钟，读到即删）
local MODMISC_OVERRIDE_KEY = "sg_over"      -- 存档关系覆盖表（permanent/small）

-- 换图广播的有效期（秒）——授权者 2026-10-06 定的 **5 分钟**：
-- 点「重开为新分支」时写一条，新局开局读到就认定自己是分支，读完立刻删（用后即焚）。
-- 开局先清过期的，再看有没有它。有漏洞（5 分钟内开的任何新局都会被当成分支），但实现容易。
local MODMISC_BCAST_MAX_AGE = 300

-- 存档回执丢失时的自愈：超过这个秒数还没等到 SaveComplete 就丢弃待回执状态
local MODMISC_SAVE_PENDING_TIMEOUT = 20

-- 事件信箱：键前缀 + 值里的分隔符
local MODMISC_EVENT_KEY_PREFIX = "ev_"
local MODMISC_EVENT_BLOB_PREFIX = "evb_"

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

-- ===========================================================================
-- 时钟：`os.time()`（Lua 标准库，epoch 秒，整数）
--
--   * 项目里早已验证可用：对局内写存储档的 payload `ig=1;t=<os.time()>` 实机跑通过
--     （Support_UI 的 RunStoreProbeInGame），所以不是新引入的依赖；
--   * 只用来量“过了几秒”（换图各阶段的等待上限、pending 有效期、存档回执自愈），
--     1 秒粒度足够，不需要毫秒；
--   * **不假设它一定在**：取不到时 ReadClock() 返回 nil，调用方一律按“已超时”处理并继续，
--     宁可不等也不要把流程挂住（面板按帧回调仍在跑，只是少了时间判断）。
--   * 它是墙上时钟（会被系统对时/用户改时间影响），只用于秒级等待；时钟往回跳时
--     下面的 NowOrExpired 会把当前时刻当作“远远超过”，同样不会卡死。
-- ===========================================================================
local function ReadClock()
    local ok, value = pcall(function() return os.time() end)
    if not ok or value == nil then return nil end
    return tonumber(value)
end

-- 取“现在”；取不到就返回基准 + 一个足够大的偏移（= 立刻超时）
local function NowOrExpired(base)
    local now = ReadClock()
    if now ~= nil then return now, true end
    return (tonumber(base) or 0) + 100000, false
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

-- 按分隔符切字段。**别用 `^a|b|c|d$` 这种固定段数的模式**：
-- 段数一变（例如给 pending 加了时间戳）整条就匹配不上，静默读成 nil
-- —— 2026-10-05 实测踩过：旧版写的 3 段 pending 在新版读不出来，新局于是当了自己是树根。
local function SplitFields(text, separator)
    local fields = {}
    local source = tostring(text or "")
    local start = 1
    while true do
        local position = source:find(separator, start, true)
        if position == nil then
            table.insert(fields, source:sub(start))
            break
        end
        table.insert(fields, source:sub(start, position - 1))
        start = position + 1
    end
    return fields
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
    local stamp = ToBase36(ReadClock() or 0)
    return stamp .. ToBase36(math.random(0, 1295))
end

-- 【实机约束 2026-10-06，授权者指出】文明 6 里**同名存档不能直接存**：玩家操作时存档键会变灰，
-- UI 层的 Network.SaveGame 很可能同样被忽略。所以档名必须**构造上唯一** ——
-- 时间戳精确到秒，再缀 2 位随机 base36；同一秒内连存两次也不会撞名。
-- 字段数不变（时间戳还是第 7 段、不含 "~"），老档名照样能解析。
local function BuildStamp()
    local ok, text = pcall(function() return os.date("%Y%m%d-%H%M%S") end)
    if ok and text ~= nil and tostring(text) ~= "" then
        return SanitizeToken(text) .. "-" .. ToBase36(math.random(0, 1295))
    end
    return ToBase36(ReadClock() or 0)
end

-- node = { Id, Parent, Kind, Turn, Map, Stamp, Logical }
-- 档名：MMT~<id>~<parent>~<kind>~T<引擎回合>~<map>~<stamp>[~L<逻辑回合>]
--   末尾的 L 字段是 2026-10-05 加的“回合同步（纯逻辑）”，老档名没有 → 解析时可选。
function API.BuildSaveName(node)
    if node == nil or node.Id == nil then return nil end
    local parent = node.Parent
    if parent == nil or tostring(parent) == "" then parent = MODMISC_SAVE_ROOT_PARENT end
    local kind = tostring(node.Kind or MODMISC_KIND_BRANCH)
    local turn = tonumber(node.Turn) or 0
    local fields = {
        MODMISC_SAVE_PREFIX,
        SanitizeToken(node.Id),
        SanitizeToken(parent),
        SanitizeToken(kind),
        "T" .. string.format("%03d", turn),
        SanitizeToken(node.Map),
        SanitizeToken(node.Stamp),
    }
    if tonumber(node.Logical) ~= nil then
        table.insert(fields, "L" .. string.format("%03d", tonumber(node.Logical)))
    end
    return table.concat(fields, MODMISC_SAVE_SEP)
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
    -- 按字段切（不要用固定段数的模式：老档名少一个 L 字段就整条匹配不上）
    local fields = SplitFields(name, MODMISC_SAVE_SEP)
    if fields[1] ~= MODMISC_SAVE_PREFIX or #fields < 7 then return nil, "格式不符" end

    local id, parent, kind = fields[2], fields[3], fields[4]
    local turnText = fields[5]
    local map, stamp = fields[6], fields[7]
    local logicalText = fields[8]
    if id == nil or id == "" or turnText == nil or turnText:sub(1, 1) ~= "T" then
        return nil, "格式不符"
    end

    local node = {
        Id = id,
        Parent = (parent ~= MODMISC_SAVE_ROOT_PARENT) and parent or nil,
        Kind = kind,
        Turn = tonumber(turnText:sub(2)),
        Map = map,
        Stamp = stamp,
        Logical = (logicalText ~= nil and logicalText:sub(1, 1) == "L")
            and tonumber(logicalText:sub(2)) or nil,
        RawName = name,
        Depth = 0,
        Children = {},
    }
    return node
end

-- ===========================================================================
-- 当前节点 / 主线头 / 换图广播
-- ===========================================================================

-- ===========================================================================
-- 单向通道：Game:SetProperty（gameplay 侧）
--
-- 授权者 2026-10-05 提议：把分支树的识别特征存进 **Game:SetProperty** ——
--   * 它是**游戏状态**的一部分：存档即带走、读档原样还原；
--   * 它**不会被带到新局**（新局状态是全新的）⇒ 不会像全局存储那样“串味”；
--   * 它只在 gameplay 层可读，前端拿不到 —— 天然是**单向**的。
-- 本 mod 已经把它封装好了（ModTool_DataStore.lua，键前缀 kocmoca_modmisctool_），
-- 这里直接经 ExposedMembers.ModMiscToolScript.SetData / GetData 用，不再自己搓一遍。
-- ===========================================================================
local MODMISC_PROPERTY_KEY = "savegraph_node"

local function GetGameplayMembers()
    return ExposedMembers ~= nil and ExposedMembers.ModMiscToolScript or nil
end

-- 身份载荷：id|parent|kind|stamp|logical|offset
--   offset 是“回合同步”的关键：逻辑回合 = 引擎回合 + offset（纯逻辑，不动引擎回合）
local function BuildNodePayload(node)
    return table.concat({
        tostring(node.Id or ""),
        tostring(node.Parent or MODMISC_SAVE_ROOT_PARENT),
        tostring(node.Kind or MODMISC_KIND_BRANCH),
        tostring(node.Stamp or ""),
        tostring(node.Logical or ""),
        tostring(node.Offset or ""),
    }, "|")
end

local function WriteNodeProperty(node)
    local members = GetGameplayMembers()
    if members == nil or members.SetData == nil then return false, "gameplay SetData 不可用" end
    local ok, err = pcall(members.SetData, MODMISC_PROPERTY_KEY, BuildNodePayload(node))
    if not ok then return false, tostring(err) end
    return true
end

local function ReadNodeProperty()
    local members = GetGameplayMembers()
    if members == nil or members.GetData == nil then return nil end
    local ok, payload = pcall(members.GetData, MODMISC_PROPERTY_KEY)
    if not ok or payload == nil or tostring(payload) == "" then return nil end
    local fields = SplitFields(payload, "|")
    local id = fields[1]
    local parent = fields[2]
    local kind = fields[3]
    local stamp = fields[4]
    if id == nil or id == "" then return nil end
    return {
        Id = id,
        Parent = (parent ~= nil and parent ~= "" and parent ~= MODMISC_SAVE_ROOT_PARENT) and parent or nil,
        Kind = (kind ~= nil and kind ~= "") and kind or MODMISC_KIND_BRANCH,
        Stamp = stamp,
        Logical = tonumber(fields[5]),
        Offset = tonumber(fields[6]),
    }
end

-- 本局身份（随档）：
--   现在整份身份就是**一个表**（sgnode：Id/Parent/Kind/Stamp/Logical/Offset），
--   走协议的 persave 通道（CustomData）—— 不再往 CustomData 里塞 5 个散键、也不再拼串。
--   Game:SetProperty（gameplay 侧写的）仍作为**交叉校验**读一份：两个上下文的存储互不可见，
--   两边都写着同一份身份，读得到哪份用哪份。
local function LoadNodeIdentity()
    if DataProtocol == nil then return nil end
    local identity = DataProtocol.Load(MODMISC_IDENTITY_KEY)
    if type(identity) ~= "table" then return nil end
    return identity
end

local function SaveNodeIdentity(identity)
    if DataProtocol == nil then return false end
    return DataProtocol.Save(MODMISC_IDENTITY_KEY, identity) == true
end

function API.GetCurrentNodeId()
    local identity = LoadNodeIdentity()
    if identity ~= nil and identity.Id ~= nil then return tostring(identity.Id), "persave" end
    local fromProperty = ReadNodeProperty()
    if fromProperty ~= nil then return fromProperty.Id, "property" end
    return nil, "none"
end

-- “本局来源”：换图重开后，开局探针把待接分支固化进**本局身份**（随档保存），
-- 于是本局第一次存档就知道自己挂在谁下面、算分支 —— 也不依赖“存储此刻还读不读得到”。
function API.GetIncomingBranch()
    local identity = LoadNodeIdentity()
    if identity == nil then return nil end
    local parent = identity.Parent
    if parent == nil or tostring(parent) == "" then return nil end
    return {
        Parent = (tostring(parent) ~= MODMISC_SAVE_ROOT_PARENT) and tostring(parent) or nil,
        Kind = identity.Kind or MODMISC_KIND_BRANCH,
        Logical = tonumber(identity.Logical),
    }
end

-- ===========================================================================
-- 回合同步（**纯逻辑**，不做硬同步、不改引擎回合）
--
--   主线在第 18 逻辑回合开分支 → 分支引擎第 1 回合 = 逻辑第 18 回合
--   ⇒ 偏移 offset = 18 - 1 = 17；分支引擎第 3 回合 = 逻辑第 20 回合
--
-- 偏移在本局内是常数（引擎回合与逻辑回合 1:1 走），所以只要在**开局**算一次并固化：
--   * 本局已经存过档/读过本 mod 的档 → CustomData / Game:SetProperty 里有 Offset；
--   * 刚接手换图分支（incoming）→ offset = 起点逻辑回合 - 1；
--   * 其余（根档 / 老档 / 非本 mod 档）→ offset = 0，逻辑回合就是引擎回合。
-- ===========================================================================

function API.GetLogicalTurnInfo()
    local engineTurn = tonumber(TryCall(function() return Game.GetCurrentGameTurn() end)) or 1

    -- ① 本局偏移（身份里带的，或开局固化下来的）
    local identity = LoadNodeIdentity()
    local offset = identity ~= nil and tonumber(identity.Offset) or nil
    local source = "persave"
    if offset == nil then
        local fromProperty = ReadNodeProperty()
        if fromProperty ~= nil and fromProperty.Offset ~= nil then
            offset = fromProperty.Offset
            source = "property"
        end
    end

    -- ② 刚接手换图分支：用起点逻辑回合算偏移，并固化
    if offset == nil then
        local incoming = API.GetIncomingBranch()
        if incoming ~= nil and incoming.Logical ~= nil then
            offset = incoming.Logical - 1
            source = "incoming"
            -- 固化进本局身份（随档）
            local current = LoadNodeIdentity() or {}
            current.Offset = offset
            SaveNodeIdentity(current)
        end
    end

    if offset == nil then
        offset = 0
        source = "none"
    end
    return engineTurn + offset, engineTurn, offset, source
end

function API.GetLogicalTurn()
    local logical = API.GetLogicalTurnInfo()
    return logical
end

-- 存储调用一律走通用数据协议（DataProtocol）：
--   * 登记表在 UI/ModMiscDataRegistry.lua；没登记的键写不进去；
--   * 协议负责编解码（表/数字/字符串都行）、校验和（防损坏）、数据集名（防误领）、TTL；
--   * 本文件**不再直接碰** ModMiscStore / ModMiscBigStore / CustomData。
-- 扫描就绪是**通道**的事（小通道要先扫一遍存档列表），仍然问 ModMiscStore；
-- 数据读写一律走 DataProtocol。
local function GetScanStore()
    return ModMiscStore
end

function API.GetMainlineHeadId()
    if DataProtocol == nil then return nil end
    local value = DataProtocol.Load(MODMISC_STORE_KEY_MAINLINE_HEAD)
    if value == nil or tostring(value) == "" then return nil end
    return tostring(value)
end

-- ===========================================================================
-- 换图**广播**（授权者 2026-10-06 新方案）
--
--   点「重开为新分支」时写一条：**进程内、用后即焚、5 分钟有效**。
--   新局开局：先清过期的 → 再看有没有它 → **有就一律认定自己是分支**（父/锚点取自广播），
--   然后立刻删掉它（读到即删）。
--
--   为什么不再用“定向交接单”：换图不再存原档、不再依赖逻辑存档，写的人不需要知道谁读；
--   广播的漏洞（5 分钟内开的任何新局都会被当成分支）授权者明确接受。
-- ===========================================================================

-- 写广播。parentId 省略时用**本局当前节点**，再退到主线头。
function API.BroadcastBranchSwitch(options)
    if DataProtocol == nil then return false, "数据协议没加载" end
    local opts = options or {}
    -- 父 = **主线存档**（门槛已经保证它存在）；调用方也可以显式指定
    local parentId = opts.Parent or API.GetMainlineAnchor()
    if parentId == nil then
        return false, "没有主线存档：请先按「存档」手动存一档，再换图"
    end
    local logicalTurn = API.GetLogicalTurn()
    local payload = {
        Parent = tostring(parentId),
        Kind = MODMISC_KIND_BRANCH,
        Logical = tonumber(logicalTurn),
        Turn = tonumber(TryCall(function() return Game.GetCurrentGameTurn() end)),
        Map = GetMapToken(),
        FromNode = tostring(API.GetCurrentNodeId() or ""),
        Stamp = BuildStamp(),
        WrittenAt = ReadClock() or 0,
    }
    local ok, err = DataProtocol.Save(MODMISC_BCAST_KEY, payload)
    if not ok then
        Log("换图广播写入失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    Log("换图广播已写入（**5 分钟内有效、读到即删**）：父=" .. tostring(payload.Parent)
        .. " 逻辑回合=" .. tostring(payload.Logical) .. " 地图=" .. tostring(payload.Map)
        .. " 来自节点=" .. tostring(payload.FromNode))
    return true, payload
end

-- 只读广播（不删）。过期的一律当没有，并顺手删掉（“开局先清超出有效期的信息”）。
function API.PeekBranchBroadcast()
    if DataProtocol == nil then return nil end
    local value = DataProtocol.Load(MODMISC_BCAST_KEY, { keep = true })
    if type(value) ~= "table" then return nil end
    local written = tonumber(value.WrittenAt)
    local now = ReadClock()
    if written ~= nil and now ~= nil then
        local age = now - written
        if age > MODMISC_BCAST_MAX_AGE then
            Log("换图广播已过期（写于 " .. tostring(age) .. " 秒前 > "
                .. tostring(MODMISC_BCAST_MAX_AGE) .. " 秒）→ 清掉，不认这条")
            DataProtocol.Remove(MODMISC_BCAST_KEY)
            return nil
        end
        value.Age = age
    end
    value.Parent = (value.Parent ~= nil and tostring(value.Parent) ~= MODMISC_SAVE_ROOT_PARENT)
        and tostring(value.Parent) or nil
    value.Kind = (value.Kind ~= nil and tostring(value.Kind) ~= "")
        and tostring(value.Kind) or MODMISC_KIND_BRANCH
    return value
end

-- 取广播（读到即删 = 用后即焚）
function API.TakeBranchBroadcast(reason)
    local value = API.PeekBranchBroadcast()
    if value == nil then return nil end
    DataProtocol.Remove(MODMISC_BCAST_KEY)
    Log("换图广播已消费（" .. tostring(reason or "?") .. "）：父=" .. tostring(value.Parent)
        .. " 逻辑回合=" .. tostring(value.Logical)
        .. (value.Age ~= nil and ("，写于 " .. tostring(value.Age) .. " 秒前") or ""))
    return value
end

function API.ClearBranchBroadcast(reason)
    if DataProtocol == nil then return false end
    Log("清除换图广播（" .. tostring(reason or "?") .. "）")
    return DataProtocol.Remove(MODMISC_BCAST_KEY) and true or false
end

-- ===========================================================================
-- 存档关系**覆盖**（授权者 2026-10-06 要求的手动接口）
--
--   为什么需要覆盖：parent/kind 写在**档名**里，而引擎没有改名 API ⇒ “把某条档改成主线/分支、
--   或改它的父”只能在树这一层做：读列表时套用覆盖，树上立刻生效。
--   本局自己那条同时改写身份（sgnode），于是**下次存档**就把它写进档名里（自然收敛）。
--
--   kind：MODMISC_KIND_MAINLINE / MODMISC_KIND_BRANCH；parent：父节点 id，主线传 nil（根）。
-- ===========================================================================

local function LoadOverrideTable()
    if DataProtocol == nil then return {} end
    local value = DataProtocol.Load(MODMISC_OVERRIDE_KEY, { keep = true })
    if type(value) ~= "table" then return {} end
    return value
end

function API.ListRelationOverrides()
    return LoadOverrideTable()
end

function API.GetRelationOverride(nodeId)
    if nodeId == nil then return nil end
    return LoadOverrideTable()[tostring(nodeId)]
end

-- 设一条档的关系。isCurrent=true（或 nodeId == 本局节点）时同时改写本局身份。
function API.SetNodeRelation(nodeId, kind, parentId, extra)
    if DataProtocol == nil then return false, "数据协议没加载" end
    if nodeId == nil or tostring(nodeId) == "" then return false, "没指定存档" end
    local id = tostring(nodeId)
    if kind ~= MODMISC_KIND_MAINLINE and kind ~= MODMISC_KIND_BRANCH then
        return false, "类型只能是 M（主线）或 B（分支）"
    end
    local parent = nil
    if kind == MODMISC_KIND_BRANCH then
        if parentId == nil or tostring(parentId) == "" then
            return false, "设为分支要指定父存档"
        end
        parent = tostring(parentId)
        if parent == id then return false, "父不能是自己" end
    end

    local table_ = LoadOverrideTable()
    table_[id] = {
        K = kind,
        P = parent or MODMISC_SAVE_ROOT_PARENT,
        Stamp = BuildStamp(),
        Why = extra ~= nil and extra.Why or nil,
    }
    local ok, err = DataProtocol.Save(MODMISC_OVERRIDE_KEY, table_)
    if not ok then return false, tostring(err) end

    Log("关系覆盖已写入：" .. id .. " ⇒ " .. kind
        .. (parent ~= nil and ("（父=" .. parent .. "）") or "（根）"))

    -- 本局自己那条：同时改写身份，下次存档就写进档名
    if API.GetCurrentNodeId() ~= nil and tostring(API.GetCurrentNodeId()) == id then
        local identity = LoadNodeIdentity() or {}
        identity.Id = id
        identity.Kind = kind
        identity.Parent = parent or MODMISC_SAVE_ROOT_PARENT
        if kind == MODMISC_KIND_MAINLINE then
            SetMainlineHead(id)
            identity.Offset = tonumber(identity.Offset) or 0
        end
        SaveNodeIdentity(identity)
        Log("本局身份同步改写：kind=" .. kind .. " parent=" .. tostring(identity.Parent))
    end
    return true, id
end

-- 本档设为主线/分支（本局必须已经存过档 —— 没有 id 就没有“本档”这回事）
function API.SetCurrentRelation(kind, parentId, extra)
    local currentId = API.GetCurrentNodeId()
    if currentId == nil then
        return false, "本局还没有本 mod 的存档：先按「存档」建一档，再改关系"
    end
    return API.SetNodeRelation(currentId, kind, parentId, extra)
end

function API.ClearNodeRelation(nodeId)
    if DataProtocol == nil or nodeId == nil then return false end
    local table_ = LoadOverrideTable()
    if table_[tostring(nodeId)] == nil then return false, "这条没有覆盖" end
    table_[tostring(nodeId)] = nil
    Log("关系覆盖已清除：" .. tostring(nodeId))
    local empty = true
    for _ in pairs(table_) do empty = false break end
    if empty then return DataProtocol.Remove(MODMISC_OVERRIDE_KEY) and true or false end
    return DataProtocol.Save(MODMISC_OVERRIDE_KEY, table_) == true
end

-- 把覆盖套到扫出来的节点上（读列表之后、建树之前调用）
-- nodes 由调用方传进来：m_Nodes 的 local 声明在本函数之后（Lua 5.1 不能前向引用）
local function ApplyRelationOverrides(nodes)
    local table_ = LoadOverrideTable()
    local applied = 0
    for _, node in ipairs(nodes or {}) do
        local override = table_[tostring(node.Id)]
        if type(override) == "table" then
            node.Kind = override.K or node.Kind
            node.Parent = (override.P ~= nil and tostring(override.P) ~= MODMISC_SAVE_ROOT_PARENT)
                and tostring(override.P) or nil
            node.Overridden = true
            applied = applied + 1
        end
    end
    if applied > 0 then
        Log("套用关系覆盖 " .. tostring(applied) .. " 条（手动改过主线/分支的档）")
    end
    return applied
end

SetMainlineHead = function(nodeId)
    if DataProtocol == nil or nodeId == nil then return false end
    return DataProtocol.Save(MODMISC_STORE_KEY_MAINLINE_HEAD, tostring(nodeId)) == true
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
    local store = GetScanStore()
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

-- 把就绪门暴露出去：其它模块（Support_UI / 面板）要做“依赖存储”的事情时也走它
function API.WhenStoreReady(callback)
    EnsureStoreReady(callback)
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
                -- 原始条目留着：读档就是把它原样交给 Network.LoadGame
                -- （原版载入菜单也是这么干的：m_thisLoadFile = g_FileList[i]）
                node.FileEntry = entry
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
    ApplyRelationOverrides(m_Nodes)   -- 手动改过主线/分支的档（覆盖表）在建树前套上

    -- 把解析出来的节点逐条打出来：一眼看出“刚建的分支档到底进没进列表”
    for _, node in ipairs(m_Nodes) do
        Log("  关系档 " .. tostring(node.Id) .. " kind=" .. tostring(node.Kind)
            .. " parent=" .. tostring(node.Parent or "-")
            .. " T" .. tostring(node.Turn) .. " " .. tostring(node.Map)
            .. " L" .. tostring(node.Logical or "-"))
    end

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

-- 存档行标签：手动改过关系的加个标记，跟档名里写死的区分开
local function NodeLabel(node)
    local label = tostring(node.Id) .. " " .. tostring(node.Kind)
    if node.Overridden then label = label .. "（手动改过关系）" end
    return label
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
-- 从关系树里读档
--
-- 原版载入菜单的做法就是 `Network.LoadGame(g_FileList[i], serverType)` —— 直接把
-- **存档列表里的原始条目**交给引擎，所以这里也照做（条目由 UI.QuerySaveGameList 拿到，
-- 带扩展名、Location/Type/FileType/Directory 都在里面）。
-- 对局内读普通档已验证可用（第 38 条），会把当前局整局顶掉 ⇒ 面板必须先弹确认。
-- ===========================================================================

function API.FindNode(nodeId)
    if nodeId == nil then return nil end
    return m_NodeById[tostring(nodeId)]
end

function API.LoadNode(nodeId, onIssued)
    local node = API.FindNode(nodeId)
    if node == nil then return false, "找不到节点 " .. tostring(nodeId) end
    if node.FileEntry == nil then
        return false, "这条档没有可用的存档条目（先点一次「刷新列表」再试）"
    end
    if Network == nil or Network.LoadGame == nil then
        return false, "Network.LoadGame 不可用"
    end
    if ServerType == nil or ServerType.SERVER_TYPE_NONE == nil then
        return false, "ServerType.SERVER_TYPE_NONE 不可用"
    end

    Log("即将调用 Network.LoadGame（节点 " .. tostring(nodeId)
        .. "，档名 " .. tostring(node.RawName)
        .. "，引擎回合 " .. tostring(node.Turn)
        .. "，逻辑回合 " .. tostring(node.Logical or "?") .. "）")
    local ok, err = pcall(Network.LoadGame, node.FileEntry, ServerType.SERVER_TYPE_NONE)
    if not ok then
        Log("Network.LoadGame 调用失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    Log("Network.LoadGame 调用已返回（没卡死）")
    if onIssued ~= nil then pcall(onIssued, node) end
    return true, node
end

-- 删除一条关系档（游戏内 UI 层就能删：UI.DeleteSavedGame —— ModMiscStore 已在用同一条通道）
function API.DeleteNode(nodeId)
    local node = API.FindNode(nodeId)
    if node == nil then return false, "找不到节点 " .. tostring(nodeId) end
    if node.FileEntry == nil then return false, "这条档没有可用的存档条目（先刷新列表）" end
    if UI == nil or UI.DeleteSavedGame == nil then return false, "UI.DeleteSavedGame 不可用" end

    Log("即将调用 UI.DeleteSavedGame（节点 " .. tostring(nodeId)
        .. "，档名 " .. tostring(node.RawName) .. "）")
    local ok, err = pcall(UI.DeleteSavedGame, node.FileEntry)
    if not ok then
        Log("删除失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    Log("已删除 " .. tostring(node.RawName))
    return true, node.RawName
end

-- ===========================================================================
-- 事件信箱（发给某个存档节点的事件；一个事件一个键，走跨存档存储）
--
--   键：`ev_<目标节点id>_<序号>`；值：type|detail|amount|acceptTurn|fromNode|playerID|civ|stamp
--   接收方开局时把发给**自己节点**的键全部取走，交给 gameplay 侧的回合事件列表，
--   然后把这些键删掉（投递一次）。
-- ===========================================================================

-- 只报前缀：信箱条目现在是协议的表，不再有“字段分隔符”这回事
function API.GetEventTypeKeys()
    return MODMISC_EVENT_KEY_PREFIX
end

-- 本机玩家身份（事件要带上“发给谁”：玩家 id + 文明类型，方便跨分支对上号）
function API.GetMyPlayerInfo()
    local playerID = TryCall(function() return Game.GetLocalPlayer() end)
    local civType = nil
    if playerID ~= nil and PlayerConfigurations ~= nil and PlayerConfigurations[playerID] ~= nil then
        civType = TryCall(function() return PlayerConfigurations[playerID]:GetCivilizationTypeName() end)
    end
    return playerID, civType
end

-- 发件：event = { Type, Detail, Amount, AcceptTurn, TargetPlayerID }
function API.SendEvent(targetNodeId, event)
    if DataProtocol == nil then return false, "数据协议没加载" end
    if targetNodeId == nil or tostring(targetNodeId) == "" then return false, "没选目标存档" end
    if type(event) ~= "table" or event.Type == nil then return false, "事件格式不对" end

    local fromNode = API.GetCurrentNodeId() or "0"
    local playerID, civType = API.GetMyPlayerInfo()
    local targetPlayer = event.TargetPlayerID
    if targetPlayer == nil then targetPlayer = playerID end
    local acceptTurn = tonumber(event.AcceptTurn) or API.GetLogicalTurn()
    -- 大载荷：事件里的 PayloadText 交给 ModMiscBigStore —— 它优先走**配置组大通道**
    -- （实机 1 MB 跨进程已验证），不可用时自动回退到分片 blob；事件记录里只留一个引用。
    -- 大载荷：登记表里 evb_* 是 ephemeral/big（优先配置组大通道，实测 1 MB 跨进程一致）
    local payloadKey = nil
    if event.PayloadText ~= nil and tostring(event.PayloadText) ~= "" then
        payloadKey = MODMISC_EVENT_BLOB_PREFIX .. tostring(targetNodeId)
            .. "_" .. tostring(TryCall(function() return os.time() end) or 0)
            .. tostring(math.random(100, 999))
        local bigOk, detail = DataProtocol.Save(payloadKey, tostring(event.PayloadText))
        if not bigOk then
            Log("发件失败：大载荷写入失败 -> " .. tostring(detail))
            return false, "大载荷写入失败"
        end
        Log("大载荷已存：" .. #tostring(event.PayloadText) .. " 字节 key=" .. payloadKey)
    end

    local key = MODMISC_EVENT_KEY_PREFIX .. tostring(targetNodeId)
        .. "_" .. tostring(TryCall(function() return os.time() end) or 0)
        .. tostring(math.random(100, 999))
    -- 信箱条目直接存**表**（协议负责编解码），不再拼 "字段|字段|…" 那种串
    local ok = DataProtocol.Save(key, {
        Type = tostring(event.Type),
        Detail = tostring(event.Detail or ""),
        Amount = tonumber(event.Amount) or 0,
        AcceptTurn = acceptTurn,
        FromNode = tostring(fromNode),
        FromPlayerID = targetPlayer or -1,
        FromCiv = civType,
        Stamp = BuildStamp(),
        PayloadKey = payloadKey,
    })
    Log("发件：" .. tostring(event.Type) .. " " .. tostring(event.Detail or "")
        .. " x" .. tostring(event.Amount or "?") .. " → 节点 " .. tostring(targetNodeId)
        .. "（接受逻辑回合 " .. tostring(acceptTurn) .. "）key=" .. tostring(key)
        .. " 结果=" .. tostring(ok))
    return ok, key
end

-- 收件：把发给 nodeId 的事件全部取出来（不删除；删不删由调用方决定）
function API.FetchEventsForNode(nodeId)
    local events, keys = {}, {}
    if DataProtocol == nil or nodeId == nil then return events, keys end
    -- 按“节点前缀”列出真实键（协议负责枚举两条通道），再逐个按协议读回**表**
    local wantedPrefix = MODMISC_EVENT_KEY_PREFIX .. tostring(nodeId) .. "_"
    local matchedKeys = DataProtocol.ListMatching(wantedPrefix)
    Log("收件扫描：节点 " .. tostring(nodeId) .. " 找前缀 " .. wantedPrefix
        .. "，命中 " .. tostring(#matchedKeys) .. " 个键"
        .. (#matchedKeys > 0 and ("（" .. table.concat(matchedKeys, ", ") .. "）") or "（大通道里没有它的信箱）"))
    for _, keyText in ipairs(matchedKeys) do
        local record, reason = DataProtocol.Load(keyText, { keep = true })
        if type(record) ~= "table" then
            Log("跳过一条读不出来的信箱条目 " .. tostring(keyText) .. "：" .. tostring(reason))
        else
            local payloadKey = record.PayloadKey
            local eventRecord = {
                Type = record.Type,
                Detail = record.Detail or "",
                Amount = tonumber(record.Amount) or 0,
                AcceptTurn = tonumber(record.AcceptTurn),
                FromNode = record.FromNode or "",
                FromPlayerID = tonumber(record.FromPlayerID),
                FromCiv = record.FromCiv,
                Stamp = record.Stamp or "",
                MailKey = keyText,
                PayloadKey = payloadKey,
            }
            -- 大载荷：读回来挂在事件上（缺片/重复片/校验和不对都会明确报出来）
            if payloadKey ~= nil then
                local text, channel = DataProtocol.Load(payloadKey, { keep = true })
                if text == nil then
                    Log("警告：事件 " .. tostring(eventRecord.Type) .. " 的大载荷读不出来（"
                        .. tostring(channel) .. "），只带元数据入列")
                else
                    eventRecord.PayloadText = text
                    eventRecord.PayloadChannel = channel
                end
            end
            table.insert(events, eventRecord)
            table.insert(keys, keyText)
        end
    end
    table.sort(events, function(a, b)
        return (tonumber(a.AcceptTurn) or 0) < (tonumber(b.AcceptTurn) or 0)
    end)
    Log("收件：节点 " .. tostring(nodeId) .. " 有 " .. tostring(#events) .. " 条待取事件")
    return events, keys
end

function API.DropEventKeys(keys)
    if DataProtocol == nil or type(keys) ~= "table" then return 0 end
    local removed = 0
    for _, key in ipairs(keys) do
        -- ⚠️ 顺序：**先读值拿到大载荷键，再删信箱键**。
        -- 反过来的话大载荷就永远留在存储里（这里踩过一次）。
        local payloadKey = nil
        if type(key) == "string" then
            local record = DataProtocol.Load(key, { keep = true })
            if type(record) == "table" then payloadKey = record.PayloadKey end
        end
        if DataProtocol.Remove(key) then removed = removed + 1 end
        if payloadKey ~= nil then DataProtocol.Remove(payloadKey) end
    end
    Log("已投递并清理 " .. tostring(removed) .. " 个信箱键")
    return removed
end

-- ===========================================================================
-- 收件：把发给本节点的事件交给 gameplay 的回合事件列表
--
-- 时机：开局（Support_UI 的探针）与面板刷新都可以调；内部先等跨存档存储就绪。
-- 逻辑回合偏移也在这里推给 gameplay —— 事件要到点触发，靠的就是它换算。
-- ===========================================================================

function API.IntakeEvents(onDone)
    -- 【2026-10-06】收件**只走大通道**（信箱条目 ev_* 与载荷 evb_* 都在 big 上），
    -- 所以不再等“小通道扫描就绪”—— 那是个多余的门，扫描慢/不回包时会把收件一起卡住
    -- （授权者反馈“事件接受没有成功”）。身份来自随档数据、事件来自大通道，都不需要那次扫描。
    local function Run()
        local script = GetGameplayMembers()
        local turnEvents = script ~= nil and script.TurnEvents or nil
        if turnEvents == nil or turnEvents.AddIncoming == nil then
            Log("收件跳过：gameplay 侧 TurnEvents 不可用")
            if onDone ~= nil then pcall(onDone, 0, "no-gameplay-api") end
            return
        end

        local logicalTurn, engineTurn, offset = API.GetLogicalTurnInfo()
        if turnEvents.SetLogicalOffset ~= nil then
            turnEvents.SetLogicalOffset(offset)
        end

        local nodeId = API.GetCurrentNodeId()
        if nodeId == nil then
            Log("收件跳过：本局还没有节点身份（第一次存档之后才会收到发给它的信箱）")
            if onDone ~= nil then pcall(onDone, 0, "no-node") end
            return
        end

        local events, keys = API.FetchEventsForNode(nodeId)
        if #events == 0 then
            if onDone ~= nil then pcall(onDone, 0, "empty") end
            return
        end

        local added = 0
        for _, event in ipairs(events) do
            local ok = turnEvents.AddIncoming(event)
            if ok then added = added + 1 end
        end
        API.DropEventKeys(keys)
        Log("收件完成：本局节点 " .. tostring(nodeId) .. " 入列 " .. tostring(added) .. " 条"
            .. "（本局逻辑回合 " .. tostring(logicalTurn) .. "，引擎 " .. tostring(engineTurn)
            .. "，偏移 +" .. tostring(offset) .. "）")
        if onDone ~= nil then pcall(onDone, added, "ok") end
    end
    Run()
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
        .. "(" .. tostring(select(2, API.GetCurrentNodeId())) .. ")"
        .. " property=" .. tostring(ReadNodeProperty() ~= nil and ReadNodeProperty().Id or "nil")
        .. " head=" .. tostring(API.GetMainlineHeadId()))

    local broadcast = API.PeekBranchBroadcast()
    table.insert(lines, "broadcast=" .. (broadcast ~= nil
        and (tostring(broadcast.Parent) .. "|" .. tostring(broadcast.Kind)
             .. "|" .. tostring(broadcast.Age) .. "s") or "nil"))

    local store = GetScanStore()
    table.insert(lines, "policy=" .. tostring(DataProtocol ~= nil)
        .. " channel=" .. tostring(store ~= nil)
        .. " scanReady=" .. tostring(store ~= nil and store.IsReady ~= nil and store.IsReady())
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
GetMapToken = function()
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
    -- 注意条件只判 incoming 本身：树根位置的换图（目标占位自己没有父）Parent 是 nil，
    -- 但它**仍然是接手来的一条分支**（kind=B、有逻辑回合锚点）——
    -- 早前这里要求 Parent ~= nil，于是这种新局会掉到下面的 root 分支、被当成主线 M。
    local incoming = API.GetIncomingBranch()
    if incoming ~= nil then
        return incoming.Parent, incoming.Kind or MODMISC_KIND_BRANCH, "incoming"
    end
    -- 兜底：存储里的**换图广播**（理论上开局探针已经消费掉，这里防“探针没跑到”）
    local broadcast = API.PeekBranchBroadcast()
    if broadcast ~= nil and broadcast.Parent ~= nil then
        return broadcast.Parent, broadcast.Kind or MODMISC_KIND_BRANCH, "broadcast"
    end
    -- 什么都没有（第一次用 / 读的是老档或非本 mod 档）→ 无父，当树根
    return nil, MODMISC_KIND_MAINLINE, "root"
end

-- 本次要写的节点：Parent / Kind / Id / Turn / Map / Stamp 全定下来
local function BuildNextNode()
    local currentId = API.GetCurrentNodeId()
    local headId = API.GetMainlineHeadId()
    local broadcast = API.PeekBranchBroadcast()

    local incoming = API.GetIncomingBranch()
    local logicalTurn, engineTurn, offset, logicalSource = API.GetLogicalTurnInfo()

    -- 【原地覆盖】本局已经有节点 ⇒ 沿用它的 id / parent / kind，只更新内容与时间，
    -- 旧文件在存档成功后删掉 —— “一条线只有一个格式化档”（授权者 2026-10-05 要求）。
    -- 换图后的新局第一次存档仍然**建新节点**（那时还没有本局节点，走下面的分支逻辑）。
    if currentId ~= nil then
        local existing = m_NodeById[currentId]
        local identity = LoadNodeIdentity() or {}
        local parentFromIdentity = identity.Parent
        local kindFromIdentity = identity.Kind or MODMISC_KIND_MAINLINE
        local existingParent = (existing ~= nil and existing.Parent)
            or ((parentFromIdentity ~= nil and tostring(parentFromIdentity) ~= MODMISC_SAVE_ROOT_PARENT)
                and tostring(parentFromIdentity) or nil)
        local existingKind = (existing ~= nil and existing.Kind) or kindFromIdentity
        Log("判定：current=" .. tostring(currentId) .. " ⇒ 原地覆盖（沿用 id / 父="
            .. tostring(existingParent) .. " / " .. tostring(existingKind) .. "）"
            .. " ｜逻辑回合=" .. tostring(logicalTurn) .. "（引擎 " .. tostring(engineTurn)
            .. "，偏移 +" .. tostring(offset) .. "）")
        return {
            Id = currentId,
            Parent = existingParent,
            Kind = existingKind,
            Turn = engineTurn,
            Logical = logicalTurn,
            Offset = offset,
            Map = GetMapToken(),
            Stamp = BuildStamp(),
            Overwrite = true,
            OldEntry = existing ~= nil and existing.FileEntry or nil,
            OldName = existing ~= nil and existing.RawName or nil,
        }
    end

    local parentId, forcedKind, parentSource = ResolveNewSaveParent()
    local kind = forcedKind
    if kind == nil then
        kind = IsMainlineHead(parentId) and MODMISC_KIND_MAINLINE or MODMISC_KIND_BRANCH
    end
    Log("判定：current=" .. tostring(currentId)
        .. " incoming=" .. (incoming ~= nil and tostring(incoming.Parent) or "nil")
        .. " head=" .. tostring(headId)
        .. " broadcast=" .. (broadcast ~= nil and tostring(broadcast.Parent) or "nil")
        .. " 来源=" .. tostring(parentSource)
        .. " => parent=" .. tostring(parentId) .. " kind=" .. tostring(kind)
        .. " ｜逻辑回合=" .. tostring(logicalTurn) .. "（引擎 " .. tostring(engineTurn)
        .. "，偏移 +" .. tostring(offset) .. "，来源 " .. tostring(logicalSource) .. "）")
    return {
        Id = BuildNodeId(),
        Parent = parentId,
        Kind = kind,
        Turn = engineTurn,
        Logical = logicalTurn,
        Offset = offset,
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

    -- 删除本节点**除本次之外**的档：唯一名 ⇒ 每存一次都会留下上一份，所以按节点 id 清一遍。
    -- （OldEntry 只是“扫描时看到的那一份”，可能不是全部。）
    if UI ~= nil and UI.DeleteSavedGame ~= nil then
        local staleCount = 0
        for _, node in ipairs(m_Nodes) do
            if node.Id == pending.Node.Id and node.RawName ~= nil
                and StripExtension(node.RawName) ~= pending.NewName then
                local delOk = pcall(UI.DeleteSavedGame, node.FileEntry or node)
                if delOk then staleCount = staleCount + 1 end
            end
        end
        if staleCount > 0 then
            Log("清理同一节点的陈旧档 " .. tostring(staleCount) .. " 份（一条线只留一份）")
        end
    end

    -- 原地覆盖：旧档删掉（同名跳过 —— 同一分钟同一回合会取到同一个文件名）
    if pending.OldEntry ~= nil then
        local oldName = StripExtension(pending.OldEntry.Name)
        if oldName ~= nil and oldName == pending.NewName then
            Log("覆盖：新旧同名（" .. tostring(pending.NewName) .. "），跳过删除")
        elseif UI ~= nil and UI.DeleteSavedGame ~= nil then
            local delOk, delErr = pcall(UI.DeleteSavedGame, pending.OldEntry)
            Log("覆盖：删除旧档 " .. tostring(oldName)
                .. (delOk and " 已删除" or (" 删除失败 -> " .. tostring(delErr))))
        else
            Log("覆盖：UI.DeleteSavedGame 不可用，旧档留着")
        end
    end

    -- 主线头推进：主线档存成功就把它记成主线头
    if pending.Node.Kind == MODMISC_KIND_MAINLINE then
        SetMainlineHead(pending.Node.Id)
    end

    -- 【2026-10-06 实机教训】**SaveComplete 不等于“我们这份档写好了”**：
    --   它是所有存档（含 ModMiscStore 那些小配置档）共用的事件，回调参数只有一个数字、认不出是谁；
    --   换图前刚好写了交接单（小配置档）⇒ 很容易把**它的回执**当成原档写完 ⇒ 提前重开 ⇒
    --   原档根本没落盘（授权者实测：面板说存好了，存档列表里却没有）。
    --   所以这里**只记日志**，能不能切换一律以“存档列表里查得到”为准（见 API.VerifySaveNow）。
    Log("SaveComplete 回执：" .. tostring(saveResult) .. "（节点 " .. tostring(pending.Node.Id)
        .. "）—— 注意：这个事件认不出是哪一份存档，是否落盘以列表复查为准")

    -- 【别删这段】回执到了要**照常刷新列表并回调 OnChecked**：
    -- 上一版把它当成“只记日志”、顺手把刷新删了 ⇒ 面板点保存后列表不刷新（授权者 2026-10-06 反馈）。
    -- 注意语义：found=true 只代表“列表里有这个 id”，不代表 SaveComplete 就是这份档的。
    if pending.OnSaved ~= nil then
        pcall(pending.OnSaved, nil, pending.Node)
    end
    API.Refresh(function(nodes)
        local found = false
        for _, node in ipairs(nodes) do
            if node.Id == pending.Node.Id then found = true break end
        end
        Log("回执后列表复查：节点 " .. tostring(pending.Node.Id)
            .. (found and " 已在列表里" or " 不在列表里（保存还没落盘 / 或这一笔根本不是我们的）"))
        if pending.OnChecked ~= nil then pcall(pending.OnChecked, found, pending.Node) end
    end)
end

-- 按既定节点写一档：写 CustomData 身份 → Network.SaveGame → 等 SaveComplete → 复查落盘
-- opts = { Reason = "manual"|"switch",
--          OnSaved = function(found, node) end,    -- SaveComplete 回执（立刻）
--          OnChecked = function(found, node) end }  -- 落盘复查结果（异步，可能不来）
local function SaveNode(node, opts)
    local options = opts or {}
    if Network == nil or Network.SaveGame == nil then
        Log("存档失败：Network.SaveGame 不可用")
        return false, "Network.SaveGame 不可用"
    end
    if m_SavePending ~= nil then
        -- 自愈：SaveComplete 有可能永远不来（引擎不给回执 / 上下文被顶掉）。
        -- 卡在这里会让之后每一次存档与换图都被拒，所以超时后丢弃旧状态、继续走。
        local now, clockOk = NowOrExpired(m_SavePending.StartedAt)
        local age = now - (m_SavePending.StartedAt or 0)
        -- 【实机反馈 2026-10-06】上一笔的回执可能永远不来（引擎不给 / 上下文被顶掉），
        -- 卡在这里会让之后每一次存档都被拒。所以只在“刚发出去的一小段时间内”才拦（8 秒），
        -- 超时一律自愈放行。
        local blockWindow = math.min(MODMISC_SAVE_PENDING_TIMEOUT or 8, 8)
        if (not clockOk) or age > blockWindow then
            Log("警告：上一笔存档等回执已超时 " .. tostring(age) .. " 秒，丢弃该状态继续")
            m_SavePending = nil
            if Events ~= nil and Events.SaveComplete ~= nil then
                Events.SaveComplete.Remove(OnSaveGraphSaveComplete)
            end
        else
            Log("存档失败：上一笔存档还在等 SaveComplete（" .. tostring(age) .. " 秒）")
            return false, "上一笔存档还没回执"
        end
    end

    local name = API.BuildSaveName(node)
    if name == nil then
        Log("存档失败：档名构造失败")
        return false, "档名构造失败"
    end

    -- ① 节点身份：**一个表**走协议的 persave 通道（CustomData），另有 gameplay 侧的
    --    Game:SetProperty 作为交叉校验（两个上下文互不可见，各写一份同一身份）。
    -- 【实机教训 2026-10-06】创建分支时**不能**改本局身份：
    -- 分支档是“另一条线”的记录，不是“我是谁”。上一版把分支的身份写进了本局 ⇒ 之后所有存档
    -- 都跟着算成分支（授权者反馈“存档保存后被识别为分支了”）。所以加 WriteIdentity=false 开关。
    if options.WriteIdentity == false then
        Log("按调用方要求：本次只写档，**不改本局身份**（创建分支档）")
    else
        local identityOk = SaveNodeIdentity({
            Id = node.Id,
            Parent = node.Parent or MODMISC_SAVE_ROOT_PARENT,
            Kind = node.Kind,
            Stamp = node.Stamp,
            Offset = node.Offset,
            Logical = node.Logical,
        })
        local propertyOk, propertyErr = WriteNodeProperty(node)
        Log("节点身份已写入：persave=" .. tostring(identityOk) .. " property=" .. tostring(propertyOk)
            .. (propertyOk and "" or ("（" .. tostring(propertyErr) .. "）")))
    end

    local saveFile = BuildGameSaveFile()
    if saveFile == nil then
        Log("存档失败：存档表构建不了（SaveLocations / SaveTypes / SaveFileTypes 缺失）")
        return false, "存档表构建不了"
    end
    saveFile.Name = name
    saveFile.IsAutosave = false
    saveFile.IsQuicksave = false

    m_SavePending = {
        Node = node,
        OnSaved = options.OnSaved,      -- SaveComplete 一回执就回调（只代表“引擎受理了”）
        OnChecked = options.OnChecked,  -- 列表复查之后的结论（found 才代表真的在盘上）
        Reason = options.Reason,
        StartedAt = ReadClock() or 0,
        -- 原地覆盖：旧档等这一笔写成功之后再删（写失败也不丢旧档）
        OldEntry = node.Overwrite and node.OldEntry or nil,
        NewName = name,
    }
    if Events ~= nil and Events.SaveComplete ~= nil then
        Events.SaveComplete.Add(OnSaveGraphSaveComplete)
    else
        Log("警告：Events.SaveComplete 不可用，落盘复查会缺失")
    end
    Log("即将调用 Network.SaveGame（" .. tostring(options.Reason or "manual") .. "）"
        .. " name=" .. name
        .. "（parent=" .. tostring(node.Parent or MODMISC_SAVE_ROOT_PARENT)
        .. " kind=" .. tostring(node.Kind) .. " turn=" .. tostring(node.Turn) .. "）")
    -- 【诊断，实机 2026-10-06】把实际交给引擎的字段全打出来 + 引擎“最近一次存档名”回显：
    -- 万一引擎改了名/换了目录，这两行能一眼看出来（否则只能猜）。
    Log("  saveFile: Name=" .. tostring(saveFile.Name)
        .. " Location=" .. tostring(saveFile.Location)
        .. " Type=" .. tostring(saveFile.Type)
        .. " FileType=" .. tostring(saveFile.FileType)
        .. " Directory=" .. tostring(saveFile.Directory))
    -- 【实机 2026-10-06】授权者怀疑“旧档的存在阻止了新存档的建立”。
    -- 保险做法：**挡在路上的同名旧档先删掉**（保证唯一性），再发存档请求；
    -- 不同名的旧档仍然走老规矩（写成功后再删），这样万一写失败也不会丢档。
    if UI ~= nil and UI.DeleteSavedGame ~= nil then
        local removedSame = 0
        for _, existing in ipairs(m_Nodes) do
            local existingName = existing.RawName ~= nil and StripExtension(existing.RawName) or nil
            if existingName ~= nil and existingName == name then
                local entry = existing.FileEntry or existing
                local delOk, delErr = pcall(UI.DeleteSavedGame, entry)
                Log("同名旧档先删除：" .. tostring(existingName)
                    .. (delOk and " 已删除" or (" 删除失败 -> " .. tostring(delErr))))
                if delOk then removedSame = removedSame + 1 end
            end
        end
        if removedSame > 0 then
            Log("为保证唯一性，先删掉 " .. tostring(removedSame) .. " 份同名旧档，再写新档")
        end
    end

    local ok, err = pcall(Network.SaveGame, saveFile)
    if not ok then
        m_SavePending = nil
        Log("Network.SaveGame 调用失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    -- 【诊断，实机 2026-10-06】引擎自己的回显：它认为最近一次存档叫什么。
    -- 与请求的档名不一致 ⇒ 引擎改了名（那就解释了“列表里查不到我们请求的那个名字”）。
    local echoed = TryCall(function() return UI.GetLastSaveName() end)
    Log("  Network.SaveGame 已受理；引擎回显 GetLastSaveName=" .. tostring(echoed)
        .. (echoed ~= nil and StripExtension(tostring(echoed)) ~= name
            and " ← 与请求的档名不同（引擎改名？）" or ""))
    if node.Overwrite then
        Log("原地覆盖：旧档 " .. tostring(node.OldName or "(列表里没扫到，可能没有旧档)")
            .. " 将在这笔写成功后删除")
    end
    Log("Network.SaveGame 调用已返回（没卡死），等 SaveComplete")
    return true, name
end

-- options = { Reason = "manual"|"switch", OnSaved = ..., OnChecked = ... }
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

-- 换图 = **纯重开**（授权者 2026-10-06 新方案：存储与切换彻底分开）
--
--   ① 门槛：必须先存在**主线存档**（本局这条线已经存过，或列表里有主线档）。
--      没有 ⇒ 直接告诉玩家「请先手动按「存档」创建一档」，**不做任何自动存档**。
--   ② 写一条**换图广播**（sw_bcast：进程内、用后即焚、5 分钟）。
--   ③ 立刻 `Network.RestartGame()` —— 这两步都在**按钮回调里**跑（唯一被实机证明可用的形态）。
--
--   新局开局读到广播 ⇒ 认定自己是那条线的分支（父=广播里的 Parent，锚点=广播里的逻辑回合），
--   读完删掉广播。详见 ReportAfterLoad。
-- ===========================================================================

-- 门槛（授权者 2026-10-06）：**必须存在主线存档**才允许换图 —— 它就是新分支的父。
-- 本局自己是分支、或本局还没存过档，都**不算**（那时要让玩家先手动按「存档」建主线）。
function API.GetMainlineAnchor()
    local head = API.GetMainlineHeadId()
    if head ~= nil and tostring(head) ~= "" then return tostring(head), "主线头" end
    for _, node in ipairs(m_Nodes) do
        if node.Kind == MODMISC_KIND_MAINLINE then
            return tostring(node.Id), "列表里的主线档"
        end
    end
    -- 兜底（不用扫列表也能判）：**本局自己就是一条主线档**（身份里 Kind=M）——
    -- 刚存完档就点换图时列表可能还没扫完，这时拒掉就纯属误伤。
    local identity = LoadNodeIdentity()
    local currentId = API.GetCurrentNodeId()
    if currentId ~= nil and identity ~= nil
        and (identity.Kind == MODMISC_KIND_MAINLINE or identity.Kind == nil) then
        return tostring(currentId), "本局就是主线档"
    end
    return nil, "既没有主线头、存档列表里也没有主线档"
end

function API.HasMainlineSave()
    local anchor, why = API.GetMainlineAnchor()
    return anchor ~= nil, why
end

-- 切换 = 写广播 + 重开（**不存档**）。返回 (ok, err)；成功时游戏通常已经重开。
function API.SwitchToNewBranch(options)
    local opts = options or {}
    if Network == nil or Network.RestartGame == nil then
        return false, "Network.RestartGame 不可用（换图只能靠它）"
    end
    local hasMainline, why = API.HasMainlineSave()
    if not hasMainline then
        Log("拒绝换图：" .. tostring(why))
        return false, "没有主线存档：请先按「存档」手动存一档，再换图"
    end
    if m_Nodes == nil or #m_Nodes == 0 then
        -- 列表没扫过也能切（广播只依赖本局节点/主线头），但要把这件事记下来
        Log("注意：切换前列表是空的（还没扫过存档列表）—— 主线判定用的是主线头/本局身份")
    end

    local ok, payloadOrErr = API.BroadcastBranchSwitch({
        Parent = opts.Parent, Reason = opts.Reason,
    })
    if not ok then
        Log("换图失败：广播没写成功 -> " .. tostring(payloadOrErr))
        return false, "换图广播没写成功：" .. tostring(payloadOrErr)
    end

    Log("换图[3/3]：即将调用 Network.RestartGame()（原因=" .. tostring(opts.Reason or "面板按钮")
        .. "） 环境：anyMultiplayer=" .. tostring(TryCall(function() return GameConfiguration.IsAnyMultiplayer() end))
        .. " savedGame=" .. tostring(TryCall(function() return GameConfiguration.IsSavedGame() end))
        .. " worldBuilder=" .. tostring(TryCall(function() return GameConfiguration.IsWorldBuilderEditor() end))
        .. " isGameHost=" .. tostring(TryCall(function() return Network.IsGameHost() end))
        .. " turn=" .. tostring(TryCall(function() return Game.GetCurrentGameTurn() end)))
    local called, result = pcall(function() return Network.RestartGame() end)
    if not called then
        Log("换图[3/3]：调用失败 -> " .. tostring(result))
        return false, tostring(result)
    end
    Log("换图[3/3]：调用已返回 result=" .. tostring(result)
        .. "（**若之后还打得出日志，说明引擎没真的重开**）")
    return true, result
end

-- 复用给别的入口（Automation 面板等）的诊断：只重开，什么都不做
function API.RestartNow(reason)
    if Network == nil or Network.RestartGame == nil then
        return false, "Network.RestartGame 不可用"
    end
    Log("只重开（" .. tostring(reason or "?") .. "）：Network.RestartGame()")
    local ok, result = pcall(function() return Network.RestartGame() end)
    if not ok then return false, tostring(result) end
    return true, result
end

-- ===========================================================================
-- 开局探针：每次进游戏报一次现状（由 Support_UI.Initialize 调一次）
-- ===========================================================================

function API.ReportAfterLoad()
    -- ⚠️ 新 context 的存储内存表是空的：不等它读起来，广播/主线头一定读成 nil
    -- （“分支不知道自己是分支”就是这么来的）。所以探针先触发存储扫描，扫完再打权威那行。
    EnsureStoreReady(function(ready, reason)
        -- 【授权者 2026-10-06 新方案】开局先清**超出有效期**的信息，再检测有没有换图广播：
        -- 有就**一律认定本局是分支**（父 / 逻辑回合锚点取自广播），读到即删（用后即焚）。
        local broadcast = API.PeekBranchBroadcast()   -- 过期的会在里面被删掉并记日志

        local currentId = API.GetCurrentNodeId()
        local head = API.GetMainlineHeadId()
        Log("after-load(store=" .. tostring(ready) .. "/" .. tostring(reason) .. "): current="
            .. tostring(currentId) .. " head=" .. tostring(head)
            .. " broadcast=" .. (broadcast ~= nil
                and (tostring(broadcast.Parent) .. "（写于 " .. tostring(broadcast.Age) .. " 秒前）")
                or "nil"))

        if broadcast ~= nil and currentId == nil and broadcast.Parent ~= nil then
            -- 新局（没有本局身份）+ 有广播 ⇒ 固化成本局来源
            local identity = LoadNodeIdentity() or {}
            identity.Parent = tostring(broadcast.Parent)
            identity.Kind = broadcast.Kind or MODMISC_KIND_BRANCH
            identity.Logical = tonumber(broadcast.Logical)
            if broadcast.Logical ~= nil then
                -- 回合同步锚点：逻辑回合 = 引擎回合 + (起点逻辑回合 - 1)
                identity.Offset = tonumber(broadcast.Logical) - 1
            end
            if broadcast.Map ~= nil and tostring(broadcast.Map) ~= "" then
                identity.FromMap = tostring(broadcast.Map)
            end
            SaveNodeIdentity(identity)
            API.TakeBranchBroadcast("开局已认定本局为分支")   -- 用后即焚
            Log("本局认定为**分支**（换图广播）：父=" .. tostring(identity.Parent)
                .. " kind=" .. tostring(identity.Kind)
                .. " 锚点逻辑回合=" .. tostring(identity.Logical)
                .. "（偏移 +" .. tostring(identity.Offset) .. "）"
                .. "；广播已消费（无永久数据留下）")
        elseif broadcast ~= nil then
            -- 有广播但本局已经有自己的身份（玩家在这 5 分钟里读了一份老档）：
            -- 不覆盖它的关系，但广播要消费掉 —— 否则它会一直骗下一个人。
            Log("注意：检测到换图广播，但本局已经有自己的身份（current=" .. tostring(currentId)
                .. "）⇒ **不改**本局关系，只把广播消费掉（这就是广播的漏洞）")
            API.TakeBranchBroadcast("本局已有身份，丢弃")
        end
    end)
    -- 加载自检：把过了 TTL 的用后即焚数据清掉（永久/随档的不碰）——授权者 2026-10-06 要求
    if DataProtocol ~= nil and DataProtocol.AutoGC ~= nil then
        DataProtocol.AutoGC("after-load")
    end

    -- 顺手扫一次存档列表（异步），完成后把关系树打进日志，便于对照
    API.Refresh(function()
        Log("after-load 关系树：\n" .. API.DescribeTree())
    end)
end
