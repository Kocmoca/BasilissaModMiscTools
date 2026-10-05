-- ===========================================================================
-- Mod Misc Tool: 通用数据存储协议（序列化 / 生命周期 / 通道 / 审计）
--
-- 【授权者 2026-10-05 的要求】建立通用序列化-反序列化协议，按
--   * 生命周期：永久 / 进程内 / 用后即焚
--   * 类型：字符串 / 数字 / 表格
-- 把数据存储“有规可循”；大型多层数据可以“头文件指向下属文件”；**用永久数据要慎重**。
--
-- ===========================================================================
-- 一、三条铁律（本模块存在的意义）
-- ===========================================================================
--   ① **没登记不许写**：任何落盘写入都必须先 Register 一份规格（Owner/生命周期/通道/版本）。
--      于是“谁写了永久数据、多大、什么时候写的”永远查得到（Audit）。
--   ② **永久数据必须显式**：Lifecycle=Permanent 的条目要写 Owner + Version，
--      并且必须能被 Purge 掉；写入一律打日志（谁、多大、哪条通道）。
--      能用 Ephemeral/Session 解决的，不要用 Permanent。
--   ③ **用后即焚的要真的焚**：Ephemeral 记录里带写入时间戳，GC 按 TTL 清；
--      需要“读到就删”的（事件载荷）标 AutoDeleteOnLoad。
--
-- ===========================================================================
-- 二、生命周期
-- ===========================================================================
--   permanent  跨存档 / 跨进程长期存在（关系树头指针、分片索引…）。**慎重**：
--              一旦写下去就会一直在玩家的机器上，直到被 Purge 或玩家自己删。
--   session    只在本次运行的内存里（每个 context 各一份，不落盘、重启即无）。
--              用于缓存、UI 状态、本局临时表。
--   ephemeral  落盘但“用后即焚”：带 TTL，GC 会清；可配 AutoDeleteOnLoad（读到就删）。
--              事件信箱、事件大载荷、换图 pending、测试数据都属于这类。
--
-- ===========================================================================
-- 三、通道（按“读的代价 / 容量”选，别乱用）
-- ===========================================================================
--   memory   进程内（session 专用）
--   small    存档名编码通道 ModMiscStore：单键 ~100 字节，**不用载入就能读**（列存档即可）
--            → 头指针、小索引、几十字节的标记
--   big      大通道 ModMiscBigStore：实测 1 MB 跨进程一致（内部优先配置组、回退分片 blob）
--            → 事件大载荷、表格
--   carrier  载体存档 ModMiscCarrier：随某份档走、模组界面干净，但**要载入那份档**才能读
--            → 超大表、需要“跟档一起搬走”的数据
--
-- ===========================================================================
-- 四、序列化格式（自描述信封，二进制安全，Lua 5.1 手写）
-- ===========================================================================
--   信封：  "MMT1|<生命周期>|<版本>|<写入时间>|<类型>|<负载长度>|<负载>"
--   值编码（长度前缀，字符串里出现什么都不怕）：
--     n             nil
--     b0 / b1       布尔
--     d<数字>;      数字（含负数/小数/1e9 这种科学计数）
--     s<长度>:<字节> 字符串（UTF-8 原样，二进制也行）
--     t<个数>:{ <键><值>… }   表格（键值成对递归；个数用于校验完整性）
--   解码是严格递归下降：长度不对/个数不对/剩尾巴 → 明确报错，**不返回半截数据**。
--
-- ===========================================================================
-- 五、大型多层数据：头记录指向下属分片
-- ===========================================================================
--   SaveTree(name, root)：把整棵树编码后切成若干“分片”（默认 32 KB 一片），
--     头记录（Kind="tree"，含每片的键与字节数）存 <name>$h，
--     分片存 <name>$p1、<name>$p2…（都走大通道；头很小且放得下时也允许走小通道）。
--   LoadTree(name)：先读头 → 按头取分片 → 逐个校验字节数 → 拼回 → 解码。
--   任何一片缺失都会明确报“缺第 N 片”，绝不返回拼不完整的树。
-- ===========================================================================

local DP_BUILD_TAG = "2026-10-05-A"

local DP_ENVELOPE_PREFIX = "MMT1"       -- 老信封（兼容读）
local DP_ENVELOPE_PREFIX_V2 = "MMT2"   -- 新信封：带数据集名 + 校验和
local DP_HEADER_SUFFIX = "$h"
local DP_PART_SUFFIX = "$p"
local DP_DEFAULT_PART_BYTES = 32768      -- 每个分片 32 KB（大通道内部再按 4000 字节切配置组）

local DP_LIFECYCLE = { Permanent = "permanent", Session = "session", Ephemeral = "ephemeral" }
local DP_CHANNEL = { Memory = "memory", Small = "small", Big = "big", Carrier = "carrier" }

local m_Registry = {}          -- name -> spec
local m_Order = {}             -- 登记顺序（面板按这个列）
local m_Session = {}           -- session 数据（进程内）
-- 元表类登记 + 最近一次解码报告：**必须在 DecodeValue 之前声明**
-- （第一版写在使用点之后 ⇒ 函数体里解析成全局 nil，解码带类名的表就会 index nil；
--   fwdcheck2 的前向引用检查当场抓到）
local m_Classes = {}
local m_LastDecodeReport = nil
local m_LastErrors = {}

local function Log(message)
    print("[ModMiscTool][DataProtocol] " .. tostring(message))
end

local function TryCall(getter)
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter)
    if not ok then return nil end
    return value
end

-- 模块表：**方法体里一律用 M.**，不要用全局 DataProtocol
-- （全局在“同一进程里被 dofile 两次”时会指向最新实例，方法却挂在旧实例上 ⇒ 登记表对不上号；
--   dp_harness 第 6 组就是这么抓出来的）
local M = DataProtocol or {}
DataProtocol = M
M.BuildTag = DP_BUILD_TAG
M.Lifecycle = DP_LIFECYCLE
M.Channel = DP_CHANNEL
M.HeaderSuffix = DP_HEADER_SUFFIX
M.PartSuffix = DP_PART_SUFFIX

-- ===========================================================================
-- 序列化 / 反序列化
-- ===========================================================================

-- 数字：**必须用 %.17g**。
-- tostring() 在 Lua 5.1 是 "%.14g" ⇒ 0.1+0.2 会写成 "0.3"、大整数会掉精度，
-- 那样“还原成原来的数据”就是假的（这条是模拟器/桩测试里最容易漏掉的失真）。
local function EncodeNumber(value)
    if value ~= value then return "dnan;" end                       -- NaN
    if value == math.huge then return "dinf;" end
    if value == -math.huge then return "d-inf;" end
    return "d" .. string.format("%.17g", value) .. ";"
end

local function DecodeNumber(text)
    if text == "nan" then return 0 / 0 end
    if text == "inf" then return math.huge end
    if text == "-inf" then return -math.huge end
    return tonumber(text)
end

-- 值编码：
--   n / b0|b1 / d<数字>; / s<长度>:<字节>
--   t<个数>:[<类名>]{ 键 值 … }   表格（可带元表类名）
--   r<编号>;                      引用（同一个表第二次出现、以及环）
-- 引用机制同时解决两件事：**共享子表还原成同一张表**、**自引用/环不会把编码器转死**。
local function EncodeValue(value, out, ctx)
    local kind = type(value)
    if value == nil then
        out[#out + 1] = "n"
    elseif kind == "boolean" then
        out[#out + 1] = value and "b1" or "b0"
    elseif kind == "number" then
        out[#out + 1] = EncodeNumber(value)
    elseif kind == "string" then
        out[#out + 1] = "s" .. tostring(#value) .. ":" .. value
    elseif kind == "table" then
        local seenId = ctx.seen[value]
        if seenId ~= nil then
            out[#out + 1] = "r" .. tostring(seenId) .. ";"     -- 共享/环：写成引用
            return true
        end
        ctx.nextId = ctx.nextId + 1
        local id = ctx.nextId
        ctx.seen[value] = id
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        local className = nil
        local meta = getmetatable(value)
        if type(meta) == "table" and type(meta.__mmtclass) == "string" then
            className = meta.__mmtclass                            -- 只认显式的类名标记
        end
        out[#out + 1] = "t" .. tostring(count) .. ":"
            .. (className ~= nil and ("[" .. className .. "]") or "") .. "{"
        if className ~= nil then ctx.classes[className] = true end   -- 别拿 nil 当下标
        for key, item in pairs(value) do
            local okKey, errKey = EncodeValue(key, out, ctx)
            if not okKey then return false, errKey end
            local okVal, errVal = EncodeValue(item, out, ctx)
            if not okVal then return false, errVal end
        end
        out[#out + 1] = "}"
    else
        -- 函数 / userdata / thread：明确报错，别静默丢字段（“还原不出的东西要说出来”）
        return false, "不支持的类型: " .. tostring(kind)
    end
    return true
end

local function DecodeValue(text, pos, ctx)
    local tag = text:sub(pos, pos)
    if tag == "" then return nil, nil, "数据提前结束" end
    if tag == "n" then return nil, pos + 1 end
    if tag == "b" then
        local bit = text:sub(pos + 1, pos + 1)
        if bit == "1" then return true, pos + 2 end
        if bit == "0" then return false, pos + 2 end
        return nil, nil, "布尔值坏了"
    end
    if tag == "r" then
        local stop = text:find(";", pos + 1, true)
        if stop == nil then return nil, nil, "引用没有结束符" end
        local id = tonumber(text:sub(pos + 1, stop - 1))
        if id == nil then return nil, nil, "引用编号非法" end
        if ctx.refs[id] == nil then
            return nil, nil, "引用指向一个还没出现的表（编号 " .. tostring(id) .. "）"
        end
        return ctx.refs[id], stop + 1
    end
    if tag == "d" then
        local stop = text:find(";", pos + 1, true)
        if stop == nil then return nil, nil, "数字没有结束符" end
        local number = DecodeNumber(text:sub(pos + 1, stop - 1))
        if number == nil then return nil, nil, "数字解析失败" end
        return number, stop + 1
    end
    if tag == "s" then
        local colon = text:find(":", pos + 1, true)
        if colon == nil then return nil, nil, "字符串没有长度分隔符" end
        local length = tonumber(text:sub(pos + 1, colon - 1))
        if length == nil then return nil, nil, "字符串长度非法" end
        local start = colon + 1
        local finish = start + length - 1
        if finish > #text then return nil, nil, "字符串长度超出数据尾部" end
        return text:sub(start, finish), finish + 1
    end
    if tag == "t" then
        -- 格式：t<个数>:[<类名>]{键 值 …}；类名可省
        local colon = text:find(":", pos + 1, true)
        if colon == nil then return nil, nil, "表格没有个数分隔符" end
        local count = tonumber(text:sub(pos + 1, colon - 1))
        if count == nil then return nil, nil, "表格元素个数非法" end
        local cursor = colon + 1
        local className = nil
        if text:sub(cursor, cursor) == "[" then
            local close = text:find("]", cursor + 1, true)
            if close == nil then return nil, nil, "类名没有结束方括号" end
            className = text:sub(cursor + 1, close - 1)
            cursor = close + 1
        end
        if text:sub(cursor, cursor) ~= "{" then return nil, nil, "表格没有起始花括号" end
        local result = {}
        ctx.nextId = ctx.nextId + 1
        ctx.refs[ctx.nextId] = result          -- **先登记再填**：自引用/环才解得开
        cursor = cursor + 1
        for _ = 1, count do
            local key, value, err
            key, cursor, err = DecodeValue(text, cursor, ctx)
            if err ~= nil then return nil, nil, "表格键: " .. err end
            value, cursor, err = DecodeValue(text, cursor, ctx)
            if err ~= nil then return nil, nil, "表格值: " .. err end
            result[key] = value
        end
        if text:sub(cursor, cursor) ~= "}" then return nil, nil, "表格没有结束花括号" end
        if className ~= nil then
            local class = m_Classes[className]
            if class ~= nil and class.OnDecode ~= nil then
                local ok, applied = pcall(class.OnDecode, result)
                if not ok then
                    table.insert(ctx.classErrors, className .. ": " .. tostring(applied))
                end
            else
                -- 元表类没登记：**如实报告**，别假装还原成功
                table.insert(ctx.droppedClasses, className)
            end
            result.__mmtclass = nil                -- 别把标记本身留在数据里
        end
        return result, cursor + 1
    end
    return nil, nil, "不认识的标记 '" .. tostring(tag) .. "'"
end

-- 元表类登记：`__mmtclass = "名字"` 的表，解码时交给这里登记的 OnDecode 还原。
-- 【为什么只做这么点】元表里的函数没法序列化（也不该序列化），
-- 所以协议只保存“类名”，由使用方在解码侧把行为装回去；没登记的类会**如实报出来**，
-- 绝不让“以为还原了、其实没有”这种情况静默通过。
function M.RegisterClass(name, handler)
    if type(name) ~= "string" or name == "" then return false, "类名非法" end
    m_Classes[name] = handler or {}
    return true
end

function M.GetLastDecodeReport()
    return m_LastDecodeReport
end

-- 对外：编码成负载串 / 从负载串解回
function M.EncodeValue(value)
    local ctx = { seen = {}, nextId = 0, classes = {} }
    local out = {}
    local ok, err = EncodeValue(value, out, ctx)
    if not ok then return nil, err end
    return table.concat(out)
end

function M.DecodeValue(text)
    text = tostring(text or "")
    local ctx = { refs = {}, nextId = 0, droppedClasses = {}, classErrors = {} }
    local value, pos, err = DecodeValue(text, 1, ctx)
    if err ~= nil then
        m_LastDecodeReport = { Error = err }
        return nil, err
    end
    if pos <= #text then
        m_LastDecodeReport = { Error = "尾部多余内容" }
        return nil, "数据尾部有多余内容（第 " .. tostring(pos) .. " 字节起）"
    end
    m_LastDecodeReport = { Refs = ctx.nextId, DroppedClasses = ctx.droppedClasses,
                           ClassErrors = ctx.classErrors }
    return value
end

-- 校验和（FNV-1a 32 位）：用来发现**静默损坏**——长度对得上、内容被改了的那种。
-- 丢片/截断靠长度校验，改字节靠它。
local function Checksum(text)
    local hash = 2166136261
    for i = 1, #text do
        hash = hash % 4294967296
        hash = (hash * 16777619 + text:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

M.Checksum = Checksum

-- 信封 v2：MMT2|生命周期|版本|写入时间|类型|<名字长度>:<数据集名>|<校验和>|<负载长度>|<负载>
--   * 带**数据集名** ⇒ 读到别人家的数据能当作“误领”报出来（Load 会比对登记名/通配匹配）
--   * 带**校验和** ⇒ 内容被改一个字节也认得出来
--   * 仍然能读 v1 老信封（没有名字与校验和 ⇒ 只做长度校验，并在解码报告里标注）
local function BuildEnvelope(spec, value, datasetName)
    local payload, err = M.EncodeValue(value)
    if payload == nil then return nil, err end
    local stamp = tostring(TryCall(function() return os.time() end) or 0)
    local name = tostring(datasetName or spec.Name or "")
    local head = table.concat({ DP_ENVELOPE_PREFIX_V2, tostring(spec.Lifecycle),
        tostring(spec.Version), stamp, type(value),
        tostring(#name) .. ":" .. name, Checksum(payload) }, "|")
    return head .. "|" .. tostring(#payload) .. "|" .. payload
end

local function ParseEnvelope(text)
    if type(text) ~= "string" then return nil, "不是字符串" end
    local prefix = text:match("^([^|]*)|")
    if prefix == DP_ENVELOPE_PREFIX_V2 then
        local a, b, c, d, e, f = text:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|")
        if a == nil then return nil, "信封头不完整" end
        local nameLen, name = f:match("^(%d+):(.*)$")
        if nameLen == nil then return nil, "数据集名段非法" end
        name = name:sub(1, tonumber(nameLen))
        local headLen = #a + #b + #c + #d + #e + #f + 7
        local cursor = headLen
        local checkEnd = text:find("|", cursor, true)
        if checkEnd == nil then return nil, "信封缺校验和段" end
        local checksum = text:sub(cursor, checkEnd - 1)
        local lenEnd = text:find("|", checkEnd + 1, true)
        if lenEnd == nil then return nil, "信封缺负载长度段" end
        local declared = tonumber(text:sub(checkEnd + 1, lenEnd - 1))
        if declared == nil then return nil, "负载长度非法" end
        local payload = text:sub(lenEnd + 1)
        if #payload ~= declared then
            return nil, "负载长度不符（头写 " .. tostring(declared) .. "，实到 "
                .. tostring(#payload) .. "）"
        end
        return { Format = "v2", Lifecycle = b, Version = tonumber(c), Stamp = tonumber(d),
                 ValueType = e, Name = name, Checksum = checksum, Payload = payload }
    end
    -- v1（老格式）：6 段头 + 负载
    local a, b, c, d, e, f = text:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|")
    if a == nil then return nil, "信封头不完整" end
    if a ~= DP_ENVELOPE_PREFIX then return nil, "不是本协议的封包（" .. tostring(a) .. "）" end
    local length = tonumber(f)
    if length == nil then return nil, "负载长度非法" end
    local payload = text:sub(#a + #b + #c + #d + #e + #f + 7)
    if #payload ~= length then
        return nil, "负载长度不符（头写 " .. tostring(length) .. "，实到 " .. tostring(#payload) .. "）"
    end
    return { Format = "v1", Lifecycle = b, Version = tonumber(c), Stamp = tonumber(d),
             ValueType = e, Payload = payload }
end

M.BuildEnvelope = BuildEnvelope
M.ParseEnvelope = ParseEnvelope

-- ===========================================================================
-- 通道适配
-- ===========================================================================

local function ChannelAvailable(channel)
    if channel == DP_CHANNEL.Memory then return true end
    if channel == DP_CHANNEL.Small then
        return ModMiscStore ~= nil and ModMiscStore.Save ~= nil
    end
    if channel == DP_CHANNEL.Big then
        return ModMiscBigStore ~= nil and ModMiscBigStore.Save ~= nil
    end
    if channel == DP_CHANNEL.Carrier then
        return ModMiscCarrier ~= nil and ModMiscCarrier.Write ~= nil
    end
    return false
end

local function ChannelWrite(channel, key, text)
    if channel == DP_CHANNEL.Small then
        return ModMiscStore.Save(key, text)
    end
    if channel == DP_CHANNEL.Big then
        local ok, err = ModMiscBigStore.Save(key, text)
        return ok, err
    end
    if channel == DP_CHANNEL.Carrier then
        -- 载体档：写入要给出一个“载体名”，键名就是名（读的时候要载入那份档）
        return ModMiscCarrier.Write(key, text)
    end
    return false, "不支持的通道: " .. tostring(channel)
end

local function ChannelRead(channel, key)
    if channel == DP_CHANNEL.Small then
        if ModMiscStore.Refresh ~= nil and ModMiscStore.IsReady ~= nil
            and ModMiscStore.IsReady() ~= true then
            return nil, "小通道还没就绪（先 Refresh）"
        end
        return ModMiscStore.Get(key)
    end
    if channel == DP_CHANNEL.Big then
        return ModMiscBigStore.Load(key)
    end
    if channel == DP_CHANNEL.Carrier then
        return ModMiscCarrier.Read(key)
    end
    return nil, "不支持的通道: " .. tostring(channel)
end

local function ChannelRemove(channel, key)
    if channel == DP_CHANNEL.Small then
        return ModMiscStore.Remove(key)
    end
    if channel == DP_CHANNEL.Big then
        return ModMiscBigStore.Remove(key)
    end
    if channel == DP_CHANNEL.Carrier then
        if ModMiscCarrier.Clear ~= nil then return ModMiscCarrier.Clear(key) end
        return false
    end
    return false
end

-- ===========================================================================
-- 登记表
-- ===========================================================================

local function ValidateSpec(spec)
    if type(spec) ~= "table" or type(spec.Name) ~= "string" or spec.Name == "" then
        return false, "规格缺 Name"
    end
    local lifecycle = spec.Lifecycle
    if lifecycle ~= DP_LIFECYCLE.Permanent and lifecycle ~= DP_LIFECYCLE.Session
        and lifecycle ~= DP_LIFECYCLE.Ephemeral then
        return false, "生命周期非法（permanent/session/ephemeral）"
    end
    if lifecycle == DP_LIFECYCLE.Session then
        spec.Channel = DP_CHANNEL.Memory
    elseif spec.Channel == nil then
        return false, "落盘的条目必须指定通道（small/big/carrier）"
    elseif spec.Channel ~= DP_CHANNEL.Small and spec.Channel ~= DP_CHANNEL.Big
        and spec.Channel ~= DP_CHANNEL.Carrier then
        return false, "通道非法（small/big/carrier）"
    end
    if lifecycle == DP_LIFECYCLE.Permanent then
        -- 铁律②：永久数据必须写清“谁的、第几版”，便于审计与迁移
        if spec.Owner == nil or spec.Owner == "" then return false, "永久数据必须写 Owner" end
        if tonumber(spec.Version) == nil then return false, "永久数据必须写 Version（数字）" end
    end
    spec.Version = tonumber(spec.Version) or 1
    if lifecycle == DP_LIFECYCLE.Ephemeral and tonumber(spec.TTL) == nil then
        spec.TTL = 7 * 24 * 3600        -- 默认一周：事件这类数据足够长，又不会永远留着
    end
    return true
end

function M.Register(spec)
    local ok, err = ValidateSpec(spec)
    if not ok then
        Log("登记失败 [" .. tostring(spec ~= nil and spec.Name or "?") .. "]：" .. tostring(err))
        return false, err
    end
    if m_Registry[spec.Name] == nil then table.insert(m_Order, spec.Name) end
    m_Registry[spec.Name] = spec
    return true
end

-- 支持通配：完全匹配优先，其次按前缀通配（例："evb_*"）
function M.FindSpec(name)
    name = tostring(name or "")
    local spec = m_Registry[name]
    if spec ~= nil then return spec end
    for _, pattern in ipairs(m_Order) do
        local candidate = m_Registry[pattern]
        if candidate ~= nil and pattern:sub(-1) == "*"
            and name:sub(1, #pattern - 1) == pattern:sub(1, #pattern - 1) then
            return candidate
        end
    end
    return nil
end

function M.GetRegistered()
    local out = {}
    for _, name in ipairs(m_Order) do
        table.insert(out, m_Registry[name])
    end
    return out
end

-- ===========================================================================
-- 存 / 取 / 删
-- ===========================================================================

function M.Save(name, value, options)
    options = options or {}
    name = tostring(name or "")
    local spec = M.FindSpec(name)
    if spec == nil then
        -- 铁律①：没登记不许写
        Log("拒绝写入未登记的数据集：" .. name)
        return false, "未登记的数据集（先在 ModMiscDataRegistry 里登记）"
    end
    if spec.Lifecycle == DP_LIFECYCLE.Session then
        m_Session[name] = value
        return true, "session"
    end
    if not ChannelAvailable(spec.Channel) then
        return false, "通道不可用: " .. tostring(spec.Channel)
    end
    -- 信封里写**真实键名**（不是登记表里的通配名）：读的时候靠它认“这是不是给我的数据”
    local envelope, err = BuildEnvelope(spec, value, name)
    if envelope == nil then return false, err end
    if spec.MaxBytes ~= nil and #envelope > spec.MaxBytes then
        Log("写入超限：" .. name .. " " .. tostring(#envelope) .. " > " .. tostring(spec.MaxBytes)
            .. "（大表格请用 SaveTree 或 carrier 通道）")
        return false, "超过该数据集上限（" .. tostring(spec.MaxBytes) .. " 字节）"
    end
    local ok, writeErr = ChannelWrite(spec.Channel, name, envelope)
    if not ok then
        Log("写入失败：" .. name .. " -> " .. tostring(writeErr))
        return false, writeErr
    end
    Log("写入 " .. name .. " [" .. spec.Lifecycle .. "/" .. tostring(spec.Channel) .. "] "
        .. tostring(#envelope) .. " 字节 owner=" .. tostring(spec.Owner or "-"))
    return true, #envelope
end

function M.Load(name, options)
    options = options or {}
    name = tostring(name or "")
    local spec = M.FindSpec(name)
    if spec == nil then return nil, "未登记的数据集" end
    if spec.Lifecycle == DP_LIFECYCLE.Session then
        return m_Session[name], "session"
    end
    local text, readErr = ChannelRead(spec.Channel, name)
    if text == nil then return nil, readErr or "没有这份数据" end
    local envelope, parseErr = ParseEnvelope(text)
    if envelope == nil then return nil, parseErr end

    -- ① 校验和：内容被改过/传丢了一段（长度还对得上）也要认出来
    if envelope.Checksum ~= nil then
        local actual = Checksum(envelope.Payload)
        if actual ~= envelope.Checksum then
            Log("校验和不符：" .. name .. "（头写 " .. tostring(envelope.Checksum)
                .. "，实算 " .. tostring(actual) .. "）—— 数据被改过或传坏了")
            return nil, "校验和不符（数据损坏或丢包）"
        end
    end

    -- ② 误领：信封里写着这份数据是给谁的；不是这个键（也不匹配通配）就拒收
    if envelope.Name ~= nil and envelope.Name ~= "" and envelope.Name ~= name then
        local expected = false
        if spec.Name:sub(-1) == "*" then
            local prefix = spec.Name:sub(1, #spec.Name - 1)
            expected = (envelope.Name:sub(1, #prefix) == prefix)
        end
        if not expected then
            Log("误领拦截：" .. name .. " 里读到的是给 " .. tostring(envelope.Name) .. " 的数据")
            return nil, "误领：这份数据属于 " .. tostring(envelope.Name) .. "，不是 " .. name
        end
    end

    local value, decodeErr = M.DecodeValue(envelope.Payload)
    if decodeErr ~= nil then return nil, decodeErr end

    -- ③ 元表类没登记/装不回去：如实报出来（别让“以为还原了”静默通过）
    local decodeReport = M.GetLastDecodeReport()
    if decodeReport ~= nil then
        for _, className in ipairs(decodeReport.DroppedClasses or {}) do
            Log("警告：" .. name .. " 里的表带元表类 '" .. tostring(className)
                .. "'，但解码侧没登记 ⇒ 只还原了字段，行为没装回去")
        end
        for _, classErr in ipairs(decodeReport.ClassErrors or {}) do
            Log("警告：类还原失败 " .. tostring(classErr))
        end
    end
    if spec.Type ~= nil and spec.Type ~= "any" and type(value) ~= spec.Type then
        return nil, "类型不符（登记为 " .. tostring(spec.Type) .. "，实际 " .. tostring(type(value)) .. "）"
    end
    if envelope.Version ~= nil and spec.Version ~= nil and envelope.Version ~= spec.Version then
        if spec.Migrate ~= nil then
            local migrated, migrateErr = spec.Migrate(value, envelope.Version)
            if migrated == nil then
                return nil, "版本迁移失败（" .. tostring(migrateErr) .. "）"
            end
            value = migrated
            Log("已迁移 " .. name .. "：v" .. tostring(envelope.Version) .. " → v" .. tostring(spec.Version))
        else
            Log("警告：" .. name .. " 的版本是 v" .. tostring(envelope.Version) .. "，登记为 v"
                .. tostring(spec.Version) .. "（没有 Migrate，按原样返回）")
        end
    end
    -- 用后即焚：读到就删（事件载荷这类）—— 调用方可以 keep=true 改为只看不焚
    if spec.AutoDeleteOnLoad and options.keep ~= true then
        ChannelRemove(spec.Channel, name)
        Log("已按“用后即焚”删除：" .. name)
    end
    return value, spec.Channel
end

function M.Remove(name)
    name = tostring(name or "")
    local spec = M.FindSpec(name)
    if spec == nil then return false, "未登记的数据集" end
    if spec.Lifecycle == DP_LIFECYCLE.Session then
        m_Session[name] = nil
        return true
    end
    return ChannelRemove(spec.Channel, name)
end

-- ===========================================================================
-- 大型多层数据：头记录 + 分片
-- ===========================================================================

local function PartKey(name, index) return name .. DP_PART_SUFFIX .. tostring(index) end
local function HeaderKey(name) return name .. DP_HEADER_SUFFIX end

function M.SaveTree(name, root, options)
    options = options or {}
    name = tostring(name or "")
    local spec = M.FindSpec(name)
    if spec == nil then return false, "未登记的数据集" end
    local payload, err = M.EncodeValue(root)
    if payload == nil then return false, err end

    local partBytes = tonumber(options.PartBytes) or tonumber(spec.PartBytes) or DP_DEFAULT_PART_BYTES
    local parts, index = {}, 1
    local cursor = 1
    while cursor <= #payload do
        local chunk = payload:sub(cursor, cursor + partBytes - 1)
        local key = PartKey(name, index)
        local ok, writeErr = ChannelWrite(spec.Channel, key, chunk)
        if not ok then
            Log("分片写入失败（第 " .. tostring(index) .. " 片）：" .. tostring(writeErr))
            return false, "第 " .. tostring(index) .. " 片写入失败：" .. tostring(writeErr)
        end
        table.insert(parts, { Key = key, Bytes = #chunk })
        cursor = cursor + partBytes
        index = index + 1
    end
    if #parts == 0 then
        table.insert(parts, { Key = PartKey(name, 1), Bytes = 0 })
        ChannelWrite(spec.Channel, parts[1].Key, "")
    end

    local header = {
        Kind = "tree", V = spec.Version or 1, Name = name,
        Bytes = #payload, Parts = parts,
        Stamp = tostring(TryCall(function() return os.time() end) or 0),
        Owner = spec.Owner or "",
    }
    -- 头记录：小通道放得下就放小通道（不用载入就能读），否则也走大通道
    local headerText, headerErr = M.EncodeValue(header)
    if headerText == nil then return false, headerErr end
    local headerChannel = spec.Channel
    if spec.Channel ~= DP_CHANNEL.Small and ModMiscStore ~= nil
        and ModMiscStore.ComputeMaxValueBytes ~= nil then
        local limit = ModMiscStore.ComputeMaxValueBytes(HeaderKey(name))
        if limit ~= nil and #headerText <= limit then headerChannel = DP_CHANNEL.Small end
    end
    local okHeader, headerWriteErr = ChannelWrite(headerChannel, HeaderKey(name), headerText)
    if not okHeader then
        Log("头记录写入失败：" .. tostring(headerWriteErr))
        return false, "头记录写入失败：" .. tostring(headerWriteErr)
    end
    Log("SaveTree " .. name .. "：负载 " .. tostring(#payload) .. " 字节 → " .. tostring(#parts)
        .. " 片（每片 ≤" .. tostring(partBytes) .. "），头记录通道 " .. tostring(headerChannel))
    return true, #parts, #payload
end

function M.LoadTree(name, options)
    options = options or {}
    name = tostring(name or "")
    local spec = M.FindSpec(name)
    if spec == nil then return nil, "未登记的数据集" end
    local headerText, headerErr = ChannelRead(spec.Channel, HeaderKey(name))
    if headerText == nil and spec.Channel ~= DP_CHANNEL.Small then
        headerText, headerErr = ChannelRead(DP_CHANNEL.Small, HeaderKey(name))
    end
    if headerText == nil then return nil, headerErr or "没有头记录" end
    local header, parseErr = M.DecodeValue(headerText)
    if header == nil or type(header) ~= "table" or header.Kind ~= "tree" then
        return nil, "头记录坏了（" .. tostring(parseErr or "Kind 不是 tree") .. "）"
    end
    local pieces = {}
    for index, part in ipairs(header.Parts or {}) do
        local chunk, partErr = ChannelRead(spec.Channel, part.Key)
        if chunk == nil then
            return nil, "缺第 " .. tostring(index) .. " 片（" .. tostring(part.Key) .. "）："
                .. tostring(partErr)
        end
        if #chunk ~= tonumber(part.Bytes) then
            return nil, "第 " .. tostring(index) .. " 片字节数不符（头写 " .. tostring(part.Bytes)
                .. "，实到 " .. tostring(#chunk) .. "）"
        end
        pieces[#pieces + 1] = chunk
    end
    local payload = table.concat(pieces)
    if #payload ~= tonumber(header.Bytes) then
        return nil, "拼回的负载长度不符（头写 " .. tostring(header.Bytes) .. "，实到 "
            .. tostring(#payload) .. "）"
    end
    local value, decodeErr = M.DecodeValue(payload)
    if value == nil and decodeErr ~= nil then return nil, decodeErr end
    Log("LoadTree " .. name .. "：头 " .. tostring(#(header.Parts or {})) .. " 片，负载 "
        .. tostring(#payload) .. " 字节")
    return value, header
end

function M.RemoveTree(name)
    name = tostring(name or "")
    local spec = M.FindSpec(name)
    if spec == nil then return 0, "未登记的数据集" end
    local headerText = ChannelRead(spec.Channel, HeaderKey(name))
    local removed = 0
    if headerText ~= nil then
        local header = M.DecodeValue(headerText)
        if type(header) == "table" and type(header.Parts) == "table" then
            for _, part in ipairs(header.Parts) do
                ChannelRemove(spec.Channel, part.Key)
                removed = removed + 1
            end
        end
    end
    ChannelRemove(spec.Channel, HeaderKey(name))
    return removed
end

-- ===========================================================================
-- 审计 / GC / 清理（“用永久数据要慎重”的落地）
-- ===========================================================================

-- 枚举某个数据集“现在真正在盘上的键”：
--   * 字面名：就它自己；
--   * 通配（"ev_*" / "evb_*"）：去两条通道里按前缀找——
--     这一步是必需的：GC 与审计都得按**真实键**走，盯着字面名 "evb_*" 什么都清不掉
--     （模拟器场景 4 抓到：TTL 过期了 GC 却报“清了 0 项”）。
local function EnumerateKeys(spec)
    local keys = {}
    local name = tostring(spec.Name or "")
    if name:sub(-1) ~= "*" then
        keys[name] = true
        return keys
    end
    local prefix = name:sub(1, #name - 1)
    if spec.Channel == DP_CHANNEL.Small and ModMiscStore ~= nil and ModMiscStore.GetAll ~= nil then
        for key in pairs(ModMiscStore.GetAll() or {}) do
            key = tostring(key)
            if key:sub(1, #prefix) == prefix then keys[key] = true end
        end
    end
    if spec.Channel == DP_CHANNEL.Big and ModMiscModGroupStore ~= nil
        and ModMiscModGroupStore.ListOurs ~= nil then
        for _, group in ipairs(ModMiscModGroupStore.ListOurs() or {}) do
            local key = tostring(group.Key)
            -- 分片与头记录归到逻辑键上：<name>$p1 / <name>$h
            local base = key:gsub("%$p%d+$", ""):gsub("%$h$", "")
            if base:sub(1, #prefix) == prefix then keys[base] = true end
        end
    end
    return keys
end

M.EnumerateKeys = EnumerateKeys

-- 审计：登记了什么、盘上真有没有、多大、什么时候写的、是不是孤儿
function M.Audit()
    local report = { Entries = {}, Orphans = {}, Tag = DP_BUILD_TAG }
    for _, spec in ipairs(M.GetRegistered()) do
        local entry = { Name = spec.Name, Lifecycle = spec.Lifecycle, Channel = spec.Channel,
                        Owner = spec.Owner, Version = spec.Version, TTL = spec.TTL,
                        Present = false }
        if spec.Lifecycle == DP_LIFECYCLE.Session then
            entry.Present = (m_Session[spec.Name] ~= nil)
            entry.Note = "内存"
        elseif spec.Name:sub(-1) == "*" then
            -- 通配数据集：按真实键逐条列（别只报 "evb_* 不存在" 这种没用的结论）
            local keys = EnumerateKeys(spec)
            local listed = 0
            for key in pairs(keys) do
                local text = ChannelRead(spec.Channel, key)
                if text ~= nil and type(text) == "string" then
                    local sub = { Name = key, Lifecycle = spec.Lifecycle, Channel = spec.Channel,
                                  Owner = spec.Owner, Version = spec.Version, TTL = spec.TTL,
                                  Present = true, Bytes = #text, Pattern = spec.Name }
                    local envelope = ParseEnvelope(text)
                    if envelope ~= nil then
                        sub.Stamp = envelope.Stamp
                        sub.ValueType = envelope.ValueType
                        sub.StoredVersion = envelope.Version
                        if envelope.Stamp ~= nil and envelope.Stamp > 0 then
                            local current = tonumber(TryCall(function() return os.time() end) or 0)
                            sub.Age = current - envelope.Stamp
                        end
                    end
                    table.insert(report.Entries, sub)
                    listed = listed + 1
                end
            end
            entry.Note = listed > 0 and ("通配：" .. tostring(listed) .. " 个真实键") or "通配：当前没有数据"
            entry.Present = listed > 0
        else
            local text = ChannelRead(spec.Channel, spec.Name)
            if text ~= nil and type(text) == "string" then
                local envelope = ParseEnvelope(text)
                entry.Present = true
                entry.Bytes = #text
                if envelope ~= nil then
                    entry.Stamp = envelope.Stamp
                    entry.ValueType = envelope.ValueType
                    entry.StoredVersion = envelope.Version
                    if envelope.Stamp ~= nil and envelope.Stamp > 0 then
                        local now = tonumber(TryCall(function() return os.time() end) or 0)
                        entry.Age = now - envelope.Stamp
                    end
                else
                    entry.Note = "不是本协议封包（可能是老格式）"
                end
            end
        end
        if spec.Lifecycle == DP_LIFECYCLE.Permanent and not entry.Present then
            entry.Note = "永久数据集当前没有落盘内容"
        end
        table.insert(report.Entries, entry)
    end

    -- 孤儿：大通道里我们的数据片，但没有任何登记项认领
    if ModMiscModGroupStore ~= nil and ModMiscModGroupStore.ListOurs ~= nil then
        local ours = ModMiscModGroupStore.ListOurs() or {}
        local seen = {}
        for _, group in ipairs(ours) do
            local key = tostring(group.Key)
            local base = key
            local partIndex = key:match("^(.*)" .. DP_PART_SUFFIX .. "%d+$")
            if partIndex ~= nil then base = partIndex end
            if base:sub(-#DP_HEADER_SUFFIX) == DP_HEADER_SUFFIX then
                base = base:sub(1, #base - #DP_HEADER_SUFFIX)
            end
            if M.FindSpec(base) == nil and seen[key] == nil then
                seen[key] = true
                table.insert(report.Orphans, { Key = key, Groups = 1, Reason = "没有登记项认领" })
            end
        end
        report.BigGroups = #ours
    end
    return report
end

-- GC：清过期 ephemeral；可选清孤儿（默认只报不删）
function M.GC(options)
    options = options or {}
    local result = { Expired = {}, Removed = 0, OrphansRemoved = 0, Skipped = {} }
    local now = tonumber(TryCall(function() return os.time() end) or 0)
    for _, spec in ipairs(M.GetRegistered()) do
        if spec.Lifecycle == DP_LIFECYCLE.Ephemeral and tonumber(spec.TTL) ~= nil then
            for key in pairs(EnumerateKeys(spec)) do
                local text = ChannelRead(spec.Channel, key)
                if text ~= nil and type(text) == "string" then
                    local envelope = ParseEnvelope(text)
                    local stamp = envelope ~= nil and envelope.Stamp or nil
                    -- 没有时间戳的一律当过期处理：宁可不留，也不留一堆来历不明的永久垃圾
                    if stamp == nil or stamp == 0 or (now - stamp) > tonumber(spec.TTL) then
                        M.RemoveTree(key)
                        ChannelRemove(spec.Channel, key)
                        table.insert(result.Expired, key)
                        result.Removed = result.Removed + 1
                    end
                end
            end
        end
    end
    if options.PurgeOrphans == true then
        local report = M.Audit()
        for _, orphan in ipairs(report.Orphans or {}) do
            ChannelRemove(DP_CHANNEL.Big, orphan.Key)
            result.OrphansRemoved = result.OrphansRemoved + 1
        end
    end
    Log("GC：清过期 " .. tostring(result.Removed) .. " 项，清孤儿 "
        .. tostring(result.OrphansRemoved) .. " 项")
    return result
end

-- 通配条目（"evb_*" 这种）不能只按字面删：得把“当前真在盘上的、匹配前缀的键”都清掉。
-- （dp_harness 第 14 组抓到：PurgeAllPermanent 只删了登记表里那个字面名 "blob*"，真数据没动）
local function PurgeMatchingPrefix(prefix)
    prefix = tostring(prefix or "")
    local removed, failed = 0, 0
    if ModMiscStore ~= nil and ModMiscStore.GetAll ~= nil then
        local snapshot = {}
        for key in pairs(ModMiscStore.GetAll() or {}) do
            if tostring(key):sub(1, #prefix) == prefix then table.insert(snapshot, tostring(key)) end
        end
        for _, key in ipairs(snapshot) do
            if ModMiscStore.Remove(key) then removed = removed + 1 else failed = failed + 1 end
        end
    end
    if ModMiscModGroupStore ~= nil and ModMiscModGroupStore.ListOurs ~= nil then
        local keys = {}
        for _, group in ipairs(ModMiscModGroupStore.ListOurs() or {}) do
            local key = tostring(group.Key)
            if key:sub(1, #prefix) == prefix then keys[key] = true end
        end
        for key in pairs(keys) do
            local count = ModMiscModGroupStore.Remove(key)
            if tonumber(count) ~= nil and tonumber(count) > 0 then
                removed = removed + tonumber(count)
            else
                failed = failed + 1
            end
        end
    end
    return removed, failed
end

-- 慎重的入口：清掉某个数据集（含其分片与头记录；通配条目清掉所有匹配键）
function M.Purge(name)
    name = tostring(name or "")
    local spec = M.FindSpec(name)
    if spec == nil then return false, "未登记的数据集" end
    if spec.Name:sub(-1) == "*" then
        local removed, failed = PurgeMatchingPrefix(spec.Name:sub(1, #spec.Name - 1))
        Log("Purge（通配）" .. spec.Name .. "：清 " .. tostring(removed) .. " 项，失败 "
            .. tostring(failed) .. " 项")
        return true, removed
    end
    M.RemoveTree(name)
    if spec.Lifecycle == DP_LIFECYCLE.Session then
        m_Session[name] = nil
        return true, 0
    end
    local removed = ChannelRemove(spec.Channel, name) and 1 or 0
    Log("Purge " .. name .. "（" .. spec.Lifecycle .. "）")
    return true, removed
end

-- 清掉**全部永久数据**：只有显式调用才执行（UI 上要点两次确认）
function M.PurgeAllPermanent()
    local count = 0
    for _, spec in ipairs(M.GetRegistered()) do
        if spec.Lifecycle == DP_LIFECYCLE.Permanent then
            M.Purge(spec.Name)
            count = count + 1
        end
    end
    Log("PurgeAllPermanent：清了 " .. tostring(count) .. " 个永久数据集")
    return count
end

-- 进程内数据（session）：给缓存/UI 状态用，绝不落盘
function M.SetSession(name, value)
    m_Session[tostring(name)] = value
    return true
end

function M.GetSession(name)
    return m_Session[tostring(name)]
end
