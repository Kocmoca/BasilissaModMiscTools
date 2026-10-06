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
--              persave 要指定在哪一侧：save = UI 的 CustomData，property = gameplay 的
--              Game:SetProperty（两者互不可见，别混用同一个键）
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

-- 换图**广播**（授权者 2026-10-06 新方案）：点「重开为新分支」时写一条，新局开局读。
--
--   语义是**广播**而不是定向交接单：写的人不关心谁读，读到的人**一律认定自己是分支**
--   （有漏洞 —— 5 分钟内开的任何新局都会被当成分支 —— 但实现容易，授权者认可）。
--   生命周期：用后即焚 + **5 分钟**有效期；开局先清过期，再检测有没有它。
--   通道同下：大通道是模组数据库的同步调用（实机 1 MB 验证过），不受“排队异步写”的时间窗影响。
Register({
    Name = "sw_bcast", Lifecycle = "ephemeral", Channel = "big",
    Owner = "存档关系树", Version = 1, Type = "table", TTL = 300,
    Describe = "换图广播（表：Parent/Kind/Logical/Turn/Map/FromNode/WrittenAt；5 分钟内有效，读到即删）",
})

-- 存档关系**覆盖**（授权者 2026-10-06 要求的手动接口）：把某条档改成主线/分支、或改它的父。
-- 档名里的 parent/kind 是引擎写下的、改不了（没有改名 API），所以“改关系”只能在树这一层覆盖：
--   读列表时套用覆盖 → 树上立刻生效；本局自己那条同时改写身份，下次存档就写进档名。
-- 生命周期：permanent（很小的表，一条覆盖几十字节；关系是长期事实，不该 5 分钟就没）。
Register({
    Name = "sg_over", Lifecycle = "permanent", Channel = "small",
    Owner = "存档关系树", Version = 1, Type = "table", MaxBytes = 4096,
    Describe = "存档关系覆盖（表：{ [节点id] = {K=主线/分支, P=父节点id 或 根, Stamp=改动时间} }）",
})

Register({
    Name = "sgnode", Lifecycle = "persave", Owner = "存档关系树", Version = 1, Type = "table",
    Describe = "本局节点身份（表：Id/Parent/Kind/Stamp/Logical/Offset）——随档走，新局不继承",
})

-- ===========================================================================
-- 二、跨存档事件
-- ===========================================================================

Register({
    -- 同样是表（{Type, Detail, Amount, AcceptTurn, FromNode, FromPlayerID, FromCiv, Stamp, PayloadKey}）
    -- 通道同 sg_pending：信箱条目 ~200 字节，在 small 上要分 3 片 ⇒ 爆发写有落盘风险
    -- （收件人可能正好在读档/重开的窗口里），所以也走大通道。
    Name = "ev_*", Lifecycle = "ephemeral", Channel = "big",
    Owner = "跨存档事件", Version = 1, Type = "table", TTL = 7 * 24 * 3600,
    Describe = "事件信箱条目（表；发给某个节点，收件后由调用方投递并清理）",
})

Register({
    -- 换图时要带过去的**数据**（大块）：一次换图一份，新局开局读走就删（用后即焚）
    Name = "xmap_*", Lifecycle = "ephemeral", Channel = "big",
    Owner = "换图交接", Version = 1, Type = "table", TTL = 900,
    Describe = "换图交接载荷（表）——新局开局消费后删掉，900 秒没被消费就过期",
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
    Name = "probe_*", Lifecycle = "ephemeral", Channel = "small",
    Owner = "诊断探针", Version = 1, Type = "string", TTL = 3600, MaxBytes = 96,
    Describe = "开局/读档探针写的小标记（selftest/ingame 这类；1 小时过期）",
})

-- gameplay 侧的随档存储（Game:SetProperty）：DataStore 的公开 API 用的就是这条。
-- **通配**：外部 mod 可以拿任意 key 存东西（API 是通用的，不能要求每个 key 都来登记）。
Register({
    Name = "ds_*", Lifecycle = "persave", Channel = "property",
    Owner = "DataStore（gameplay 侧公开 API）", Version = 1, Type = "any",
    Describe = "对局内 SetData/GetData 的随档数据（数字/字符串/表都行；本档内持久、新局不继承）",
})


-- ===========================================================================
-- 二、跨存档事件
-- ===========================================================================

Register({
    -- 同样是表（{Type, Detail, Amount, AcceptTurn, FromNode, FromPlayerID, FromCiv, Stamp, PayloadKey}）
    -- 通道同 sg_pending：信箱条目 ~200 字节，在 small 上要分 3 片 ⇒ 爆发写有落盘风险
    -- （收件人可能正好在读档/重开的窗口里），所以也走大通道。
    Name = "ev_*", Lifecycle = "ephemeral", Channel = "big",
    Owner = "跨存档事件", Version = 1, Type = "table", TTL = 7 * 24 * 3600,
    Describe = "事件信箱条目（表；发给某个节点，收件后由调用方投递并清理）",
})

Register({
    -- 换图时要带过去的**数据**（大块）：一次换图一份，新局开局读走就删（用后即焚）
    Name = "xmap_*", Lifecycle = "ephemeral", Channel = "big",
    Owner = "换图交接", Version = 1, Type = "table", TTL = 900,
    Describe = "换图交接载荷（表）——新局开局消费后删掉，900 秒没被消费就过期",
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
    Name = "probe_*", Lifecycle = "ephemeral", Channel = "small",
    Owner = "诊断探针", Version = 1, Type = "string", TTL = 3600, MaxBytes = 96,
    Describe = "开局/读档探针写的小标记（selftest/ingame 这类；1 小时过期）",
})

-- gameplay 侧的随档存储（Game:SetProperty）：DataStore 的公开 API 用的就是这条。
-- **通配**：外部 mod 可以拿任意 key 存东西（API 是通用的，不能要求每个 key 都来登记）。
Register({
    Name = "ds_*", Lifecycle = "persave", Channel = "property",
    Owner = "DataStore（gameplay 侧公开 API）", Version = 1, Type = "any",
    Describe = "对局内 SetData/GetData 的随档数据（数字/字符串/表都行；本档内持久、新局不继承）",
})


Register({
    Name = "cg_marker", Lifecycle = "persave", Owner = "创建新局验证", Version = 1, Type = "table",
    Describe = "切换/建局前打的时间戳标记（表：Act/Nonce/At/Fingerprint）——用来判断“这局是不是全新的”",
})

Register({
    Name = "ghost_citystates", Lifecycle = "persave", Owner = "幽灵玩家（建局侧）", Version = 1,
    Type = "string", Describe = "建局时把城邦数量记下来，对局内读它决定幽灵槽位",
})

Register({
    Name = "ghost_majorplayers", Lifecycle = "persave", Owner = "幽灵玩家（建局侧）", Version = 1,
    Type = "string", Describe = "建局时的主要文明数量（只记录、不抬高）",
})

Register({
    Name = "svprobe", Lifecycle = "persave", Owner = "诊断探针", Version = 1, Type = "string",
    Describe = "跨存档探针（验证随档通道能写能读）",
})

Register({
    Name = "ModMiscAssetPlacements", Lifecycle = "persave", Owner = "永久资产放置", Version = 1,
    Type = "table",
    Describe = "摆在地图上的资产记录（表：V/Records[{fn,args}]）——随档走，新局不继承",
})

Register({
    Name = "ui_*", Lifecycle = "persave", Owner = "UI 侧数据", Version = 1, Type = "string",
    Describe = "UI 存给 gameplay 读的随档数据（CustomData）",
})

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
