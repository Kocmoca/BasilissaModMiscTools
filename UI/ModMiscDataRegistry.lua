-- ===========================================================================
-- Mod Misc Tool: 数据登记表（谁是永久、谁是用后即焚、走哪条通道）
--
-- 【授权者 2026-10-05】数据存储要有规可循。这里就是“规”的那张表：
-- 每一份跨存档数据都必须在这里登记，`DataProtocol.Save` 才会放行（铁律①：没登记不许写）。
-- 加新数据 = 在这里加一行；**不要**在别处偷偷摸摸写永久数据。
--
-- 字段：
--   Name       键名（支持 `前缀*` 通配，用于事件那种动态键）
--   Lifecycle  permanent（永久）/ session（进程内）/ ephemeral（用后即焚）
--   Channel    small（存档名编码，~100B/键、不用载入可读）/ big（配置组大通道，1MB 已验证）
--              / carrier（载体存档，随档走但要载入才能读）；session 固定 memory
--   Owner      谁负责（出问题找谁、面板上显示）
--   Version    结构版本；改了结构就 +1，并给 Migrate
--   TTL        仅 ephemeral：多久没动就算过期（GC 清）
--   AutoDeleteOnLoad  仅 ephemeral：读到就删（事件载荷这种“一次性”的）
--   Type       期望的 Lua 类型（string/number/table/any），Load 时校验
--   MaxBytes   单份上限（超了让调用方改用 SaveTree / carrier）
--   Describe   人话说明（面板审计里显示）
--
-- 【用永久数据要慎重】permanent 的每一条都会长期留在玩家机器上，直到被 Purge。
-- 能做成 ephemeral（带 TTL）就别做成 permanent；能放 session（内存）就更别落盘。
-- ===========================================================================

local function Register(spec) DataProtocol.Register(spec) end

-- ===========================================================================
-- 一、成品功能的数据
-- ===========================================================================

-- 存档关系树：主线头指针（很小、要“不用载入就能读” → small 通道）
Register({
    Name = "sg_head", Lifecycle = "permanent", Channel = "small",
    Owner = "存档关系树", Version = 1, Type = "string", MaxBytes = 96,
    Describe = "主线头节点 id（关系树的入口；换图后新局靠它认亲）",
})

-- 换图待接分支：换图前写、新局开局消费；过期作废 → ephemeral
Register({
    Name = "sg_pending", Lifecycle = "ephemeral", Channel = "small",
    Owner = "存档关系树", Version = 1, Type = "string", TTL = 900, MaxBytes = 96,
    Describe = "换图时的待接分支（<原档id>|B|<stamp>|<epoch>；900 秒内有效）",
})

-- ===========================================================================
-- 二、跨存档事件
-- ===========================================================================

Register({
    Name = "ev_*", Lifecycle = "ephemeral", Channel = "small",
    Owner = "跨存档事件", Version = 1, Type = "string", TTL = 7 * 24 * 3600, MaxBytes = 200,
    Describe = "事件信箱条目（发给某个节点；收件后由调用方投递并清理）",
})

Register({
    -- 注意：**不能**设 AutoDeleteOnLoad —— 取件（FetchEventsForNode）和投递是两步，
    -- 读到就删的话“取了没投”就把载荷弄丢了。这里靠 TTL + 投递时显式 Remove 双保险。
    Name = "evb_*", Lifecycle = "ephemeral", Channel = "big",
    Owner = "跨存档事件", Version = 1, Type = "string", TTL = 7 * 24 * 3600,
    Describe = "事件大载荷（PayloadText；投递后由 DropEventKeys 删除，过期由 GC 清）",
})

-- ===========================================================================
-- 三、通用大对象（分片 blob / 载体档）
-- ===========================================================================

Register({
    Name = "blob*", Lifecycle = "permanent", Channel = "small",
    Owner = "通用分片大对象", Version = 1, Type = "string",
    Describe = "ModMiscStore 的分片大对象（元数据 + 分片，键名带 $m / $<n> 后缀）",
})

Register({
    Name = "carrier*", Lifecycle = "permanent", Channel = "carrier",
    Owner = "载体存档", Version = 1, Type = "string",
    Describe = "载体档里的大块数据（要载入那份档才能读）",
})

-- ===========================================================================
-- 四、探针与测试数据（都是临时货，别当永久用）
-- ===========================================================================

Register({
    Name = "panel", Lifecycle = "ephemeral", Channel = "big",
    Owner = "自动化测试面板", Version = 1, Type = "string", TTL = 3600,
    Describe = "面板写入/读取按钮的测试数据（1 小时过期）",
})

Register({
    Name = "probe", Lifecycle = "ephemeral", Channel = "big",
    Owner = "自动化测试面板", Version = 1, Type = "string", TTL = 3600,
    Describe = "自检用的探针数据（1 小时过期）",
})

Register({
    Name = "nameprobe", Lifecycle = "ephemeral", Channel = "big",
    Owner = "自动化测试面板", Version = 1, Type = "string", TTL = 3600,
    Describe = "名字上限探针的临时数据（1 小时过期）",
})

print("[ModMiscTool][DataRegistry] 已登记 " .. tostring(#DataProtocol.GetRegistered())
    .. " 条数据集（永久 "
    .. tostring((function()
        local count = 0
        for _, spec in ipairs(DataProtocol.GetRegistered()) do
            if spec.Lifecycle == "permanent" then count = count + 1 end
        end
        return count
    end)()) .. " 条）")
