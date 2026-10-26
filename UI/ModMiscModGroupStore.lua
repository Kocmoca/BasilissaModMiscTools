-- ===========================================================================
-- Mod Misc Tool: 把「模组配置组（mod group）的名字」当跨存档存储
--
-- 【授权者 2026-10-05 提示的方向】“有人提及 modgroupname 可以用作数据存储”。
-- 于是把原版里所有跟「文件存取 / 名字设定」有关的地方重新翻了一遍，这条最像样：
--
-- 【静态核对：数据库层（原版 Assets/Database/Modding.sql）】
--     CREATE TABLE ModGroups(
--         'ModGroupRowId' INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
--         'Name'          TEXT NOT NULL,          -- 注释原文：the user-provided name of the group
--         'CanDelete'     BOOLEAN DEFAULT 1,
--         'Selected'      BOOLEAN DEFAULT 0,
--         'SortIndex'     INTEGER DEFAULT 100);
--     CREATE TABLE ModGroupItems(...);            -- 组里启用了哪些 mod
--     INSERT INTO ModGroups VALUES (1, 'LOC_MODS_GROUP_DEFAULT_NAME', 0, 1, 0);   -- 默认组不可删
--   * `Name` 是**自由文本**：长度只受 SQLite 的 TEXT 限制，
--     **不受**“存档名 = 一个文件名分量 ≤ 255 字节”那条限制（那条把 ModMiscStore 卡在 ~100 字节/键）。
--   * 这张表属于**模组框架数据库**（模组界面那份），不是某个存档的一部分 ⇒ 跨存档、跨进程都在。
--
-- 【静态核对：能用的接口（原版 FrontEnd/Mods.lua 就在用这些）】
--     Modding.GetModGroups()                    -- 列表，每项 { Handle, Name, CanDelete, SortIndex }
--     Modding.GetCurrentModGroup()              -- 当前选中的组句柄
--     Modding.CreateModGroup(name, sourceGroup) -- 建组，并把 sourceGroup 的启用项复制过去
--     Modding.DeleteModGroup(handle)            -- 删组（数据库层自带 CanDelete = 1 限制）
--     Modding.SetCurrentModGroup(handle)
--   * **没有改名接口**：Modding.sql 里也没有 `UPDATE ModGroups SET Name` 这类存储过程
--     ⇒ “改值”只能 = 先删同 key 的旧组、再按序新建。
--   * 这个 API **对局内也能用**：原版 Menus/InGameTopOptionsMenu.lua、
--     Choosers/ResearchChooser.lua 都在对局里调用 Modding.GetActiveMods()。
--     所以它是目前唯一“前后端都能读写、且与存档无关”的自由文本通道。
--
-- 【怎么存】组名格式（定长片段，按序号拼回）：
--     MMTSTORE~<hex(key)>~<3 位序号>~<hex(值分片)>
--   值按 chunk 切片；改值 = 删掉这个 key 的所有旧组再重写（见上：没有改名接口）。
--   hex 是为了名字里不出现奇怪字符（这个名字玩家在模组界面的下拉框里看得见）。
--
-- 【安全规矩】**只碰自己前缀 `MMTSTORE~` 的组**；所有引擎调用一律 pcall 包住。
--
-- 【实机教训 · 2026-10-05，两条都是我这边写错了，不是通道不通】
--   ① **`Modding.CreateModGroup` 会把新建的组设为“当前选中的组”**（原版界面里看不出来，
--      因为它建完就刷新下拉框、玩家自己会再选回去）。后果：玩家的配置组选择被我们的写入
--      悄悄改掉；而且下一次写同 key 时，旧片因为“正被选中”删不掉 ⇒ 同 key 同序号出现多份
--      ⇒ `Load` 数到 2 组但只有第 1 片 ⇒ 报“缺第 2 片”（实机日志里就是这个）。
--      修法：**写之前记住原来的选中组，写完全部恢复**；删“当前选中的组”之前，先照抄原版
--      `FrontEnd/Mods.lua` 的 `DeleteModGroup()` —— 把选中切到另一个组，再删。
--   ② 自检报的“尺寸”和实际字节数不一致（8B 的载荷其实只有 7 字节，`<8></e>`），
--      容易把“读回 7 字节”误读成失败。修法：载荷**长度精确等于标称尺寸**。
--   顺带：写入 29 字节的小数据实机是**成功**的（写 29B、读回 29B、逐字一致），
--   所以通道 E 本身可用 —— 之前看到的失败全是上面这两条引起的。
--
-- 【对玩家的可见影响】每个数据片 = 模组界面下拉框里的一条配置组。
--   建组时会把“当前组”的启用项复制过去 ⇒ 即使它被选中，启用集合也跟原来一样（不会把 mod 关掉）。
--   面板上给了「清理」按钮，测试完请点掉；正式使用前要先想好“玩家会看到什么”。
-- ===========================================================================

local MODGROUP_STORE_BUILD_TAG = "2026-10-21-B"

local MODGROUP_PREFIX = "MMTSTORE~"        -- 我们的组名前缀，也是唯一的“这是我们的数据”判据
local MODGROUP_PROBE_KEY = "probe"         -- 自检用的 key
-- 每片原始字节数（hex 后 ×2 = 1200 字符）。实机已验证 1224 字符的名字能被引擎原样存下，
-- 所以这个值可以由面板的「分片」选择器调大；具体能到多少由「名字上限」探针量出来。
local MODGROUP_DEFAULT_CHUNK_BYTES = 600
local MODGROUP_MAX_CHUNKS = 400            -- 防御：一个 key 最多多少片（别把模组界面刷爆）

-- ===========================================================================
-- 基础工具
-- ===========================================================================

local function Log(message)
    print("[ModMiscTool][ModGroupStore] " .. tostring(message))
end

-- hex 编解码复用 ModMiscStore 的那套（同一个 mod 里不重复造）
local function EncodeText(text)
    if ModMiscStore ~= nil and ModMiscStore.EncodeText ~= nil then
        return ModMiscStore.EncodeText(text)
    end
    return nil
end

local function DecodeText(hex)
    if ModMiscStore ~= nil and ModMiscStore.DecodeText ~= nil then
        return ModMiscStore.DecodeText(hex)
    end
    return nil
end

local function PadIndex(index)
    local text = tostring(index)
    while #text < 3 do text = "0" .. text end
    return text
end

local function BuildGroupName(key, index, chunkText)
    return MODGROUP_PREFIX .. EncodeText(tostring(key)) .. "~" .. PadIndex(index)
        .. "~" .. EncodeText(chunkText)
end

-- 名字是不是我们的、属于哪个 key、第几片
local function ParseGroupName(name)
    if type(name) ~= "string" then return nil end
    if name:sub(1, #MODGROUP_PREFIX) ~= MODGROUP_PREFIX then return nil end
    local rest = name:sub(#MODGROUP_PREFIX + 1)
    local keyHex, indexText, payloadHex = rest:match("^([^~]*)~([^~]*)~([^~]*)$")
    if keyHex == nil then return nil end
    local key = DecodeText(keyHex)
    local index = tonumber(indexText)
    if key == nil or index == nil then return nil end
    return { Key = key, Index = index, PayloadHex = payloadHex }
end

local function GetGroupsRaw()
    if Modding == nil or Modding.GetModGroups == nil then
        return nil, "Modding.GetModGroups 不可用"
    end
    local ok, groups = pcall(function() return Modding.GetModGroups() end)
    if not ok then return nil, "GetModGroups 抛错: " .. tostring(groups) end
    if type(groups) ~= "table" then return nil, "GetModGroups 没返回表" end
    return groups
end

local function GetCurrentGroup()
    if Modding == nil or Modding.GetCurrentModGroup == nil then return nil end
    local ok, handle = pcall(function() return Modding.GetCurrentModGroup() end)
    if ok then return handle end
    return nil
end

local function SetCurrentGroup(handle)
    if handle == nil then return false end
    if Modding == nil or Modding.SetCurrentModGroup == nil then return false end
    local ok = pcall(function() return Modding.SetCurrentModGroup(handle) end)
    return ok and true or false
end

-- ===========================================================================
-- 组列表缓存（2026-10-21 性能优化）
--
-- 【问题】跨存档每读一个 key 都要 Modding.GetModGroups() 全量枚举一次：
--   Load → ListOurs → List → GetGroupsRaw；开一次面板读 5~6 个 key
--   ⇒ 5~6 次全量枚举。写入更贵：Save 内部 RemoveByKey / SettleSelection /
--   复查各枚举一次，CrossSaveWrite 读回再枚举一次。
--
-- 【做法】把“全量组列表 + 每组的解析结果”缓存成一张索引表：
--   * ByKey[key][index] = 该片；Load 直接查表，不再扫全部组；
--   * ByHandle[handle] = 组；GroupExists / IsOurs / PickFallback 直接查表；
--   * 删除时增量更新（删片从索引里摘掉），新建片后从引擎重建一次；
--   * 1 秒 TTL 兜底外部写入（别的 mod 直接建组时最多 1 秒后可见）。
--
-- 【为什么不用 Game:SetProperty】UI 上下文没有 Game:SetProperty（授权者 2026-10-05
--   实机确认，见 UI/Support_UI.lua 顶部说明）；UI 侧只能内存缓存。真正要落盘的数据
--   仍走配置组（跨存档）/ CustomData（随档）这两条既有通道。
-- ===========================================================================

local CACHE_TTL_SECONDS = 1.0
local m_Cache = nil
local m_CacheBuiltAt = nil
local m_CacheDirty = true
local m_BatchDepth = 0
local m_Stats = {
    Builds = 0,
    EnumerationCalls = 0,
    CacheHits = 0,
    BatchSkips = 0,
    LastBuildMs = 0,
    LastReason = nil,
}

local function CacheExpired()
    if m_Cache == nil then return true end
    if m_CacheBuiltAt == nil then return false end
    local now = nil
    pcall(function() now = os.time() end)
    if now == nil then return false end
    return (now - m_CacheBuiltAt) >= CACHE_TTL_SECONDS
end

-- 从 cache.Ours 重建 key/handle 索引（删片后调用；只在内存里做，不再问引擎）
local function RebuildKeyIndex(cache)
    local byKey, byKeyCount, byKeyDup, byHandle = {}, {}, {}, {}
    for _, entry in ipairs(cache.All) do
        if entry.Handle ~= nil then byHandle[entry.Handle] = entry end
    end
    for _, entry in ipairs(cache.Ours) do
        local bucket = byKey[entry.Key]
        if bucket == nil then
            bucket = {}
            byKey[entry.Key] = bucket
        end
        if bucket[entry.Index] ~= nil then
            byKeyDup[entry.Key] = (byKeyDup[entry.Key] or 0) + 1
        end
        bucket[entry.Index] = entry
        byKeyCount[entry.Key] = (byKeyCount[entry.Key] or 0) + 1
    end
    cache.ByKey, cache.ByKeyCount, cache.ByKeyDup, cache.ByHandle = byKey, byKeyCount, byKeyDup, byHandle
end

local function RebuildGroupCache(reason)
    local started = nil
    pcall(function() started = os.clock() end)
    local raw, err = GetGroupsRaw()
    if raw == nil then
        -- 枚举失败时**不**返回旧缓存：读方（尤其是 Save 的复查）必须知道“这次没读到真实组”，
        -- 否则会把旧索引当成新结果，长组名截断/缺片都会被掩盖。
        m_CacheDirty = true
        Log("组缓存重建失败（" .. tostring(err) .. "，原因=" .. tostring(reason) .. "）")
        return nil, err
    end
    m_Stats.EnumerationCalls = m_Stats.EnumerationCalls + 1

    local all, ours = {}, {}
    for _, group in ipairs(raw) do
        if type(group) == "table" then
            local parsed = ParseGroupName(group.Name)
            local entry = {
                Handle = group.Handle,
                Name = tostring(group.Name),
                CanDelete = group.CanDelete,
                SortIndex = group.SortIndex,
                Ours = parsed ~= nil,
                Key = parsed ~= nil and tostring(parsed.Key) or nil,
                Index = parsed ~= nil and tonumber(parsed.Index) or nil,
                PayloadHex = parsed ~= nil and parsed.PayloadHex or nil,
            }
            all[#all + 1] = entry
            if entry.Ours then ours[#ours + 1] = entry end
        end
    end
    table.sort(ours, function(a, b)
        if a.Key == b.Key then return a.Index < b.Index end
        return tostring(a.Key) < tostring(b.Key)
    end)
    m_Cache = { All = all, Ours = ours, Total = #all }
    RebuildKeyIndex(m_Cache)
    m_CacheDirty = false
    local now = nil
    pcall(function() now = os.time() end)
    m_CacheBuiltAt = now
    m_Stats.Builds = m_Stats.Builds + 1
    m_Stats.LastReason = tostring(reason)
    if started ~= nil then
        local ended = nil
        pcall(function() ended = os.clock() end)
        if ended ~= nil then m_Stats.LastBuildMs = (ended - started) * 1000 end
    end
    Log("组缓存重建：全部=" .. tostring(#all) .. " 本mod=" .. tostring(#ours)
        .. " 耗时=" .. string.format("%.1f", m_Stats.LastBuildMs) .. "ms"
        .. " 原因=" .. tostring(reason)
        .. " 累计枚举=" .. tostring(m_Stats.EnumerationCalls))
    return m_Cache
end

local function EnsureGroupCache(reason)
    if m_Cache ~= nil and not m_CacheDirty and not CacheExpired() then
        m_Stats.CacheHits = m_Stats.CacheHits + 1
        return m_Cache
    end
    -- 写批量期间不要为了“看新片”重建：新片由写完后的一次重建统一收进来。
    if m_Cache ~= nil and m_BatchDepth > 0 then
        m_Stats.BatchSkips = m_Stats.BatchSkips + 1
        return m_Cache
    end
    return RebuildGroupCache(reason)
end

local function BeginCacheBatch()
    m_BatchDepth = m_BatchDepth + 1
end

local function EndCacheBatch()
    m_BatchDepth = math.max(0, m_BatchDepth - 1)
end

-- 新建组：引擎调用 + 标记缓存失效。
-- ⚠️ **不能**把“我们打算写的名字”直接塞进缓存：引擎可能截断超长组名，
--    Save / ProbeNameCeiling 的复查必须读引擎里的真实名字，所以这里只标 dirty，
--    由下一次 ListOurs 从 GetModGroups 重建一次。
local function CreateGroup(name, source)
    local ok, err = pcall(function() return Modding.CreateModGroup(name, source) end)
    m_CacheDirty = true
    return ok, err
end

-- 删片后整理缓存：从 All/Ours 里剔除已删句柄，再重建 key/handle 索引。
-- 只在内存里做；不为一次 Delete 重新问引擎。
local function CompactCacheAfterRemoval(removedHandles)
    local cache = m_Cache
    if cache == nil or removedHandles == nil then return end
    local keptAll, keptOurs = {}, {}
    for _, entry in ipairs(cache.All) do
        if not removedHandles[entry.Handle] then keptAll[#keptAll + 1] = entry end
    end
    for _, entry in ipairs(cache.Ours) do
        if not removedHandles[entry.Handle] then keptOurs[#keptOurs + 1] = entry end
    end
    cache.All, cache.Ours, cache.Total = keptAll, keptOurs, #keptAll
    RebuildKeyIndex(cache)
end

-- 从缓存读一个 key：O(片数)，不再扫全部组。
local function LoadKeyFromCache(keyText)
    local cache = m_Cache
    if cache == nil then return nil, "组缓存不可用" end
    local bucket = cache.ByKey[keyText]
    if bucket == nil then return nil, "没有这个 key" end
    local count = cache.ByKeyCount[keyText] or 0
    local duplicated = cache.ByKeyDup[keyText] or 0
    if count == 0 then return nil, "没有这个 key" end
    if duplicated > 0 then
        -- 实机踩过：CreateModGroup 抢走选中 ⇒ 旧片删不掉 ⇒ 同序号两份 ⇒ 拼出来是错的
        return nil, "有 " .. tostring(duplicated) .. " 个重复片（同 key 同序号）——先点清理再写"
    end
    local parts = {}
    for index = 1, count do
        local entry = bucket[index]
        if entry == nil then return nil, "缺第 " .. tostring(index) .. " 片" end
        local text = DecodeText(entry.PayloadHex)
        if text == nil then return nil, "第 " .. tostring(index) .. " 片解码失败" end
        parts[#parts + 1] = text
    end
    return table.concat(parts), count
end

-- 要删“当前选中的组”时，得先把选中挪到别的组（原版 DeleteModGroup() 就是这么做的）。
-- 挑法：**不挑我们自己的组**（免得把选中留在一堆数据组里），优先挑不可删的那个默认组。
local function PickFallbackGroup(excludeHandle)
    local cache = EnsureGroupCache("pick-fallback")
    if cache == nil then return nil end
    local firstOther = nil
    for _, entry in ipairs(cache.All) do
        if entry.Handle ~= excludeHandle then
            if entry.CanDelete == false or entry.CanDelete == 0 then
                return entry.Handle                     -- 默认组：最稳的落脚点
            end
            if firstOther == nil and not entry.Ours then
                firstOther = entry.Handle               -- 退而求其次：别的非数据组
            end
        end
    end
    if firstOther ~= nil then return firstOther end
    for _, entry in ipairs(cache.All) do
        if entry.Handle ~= excludeHandle then
            return entry.Handle                         -- 实在没有就随便挑一个别的
        end
    end
    return nil
end

local function GroupExists(handle)
    if handle == nil then return false end
    local cache = EnsureGroupCache("group-exists")
    if cache == nil then return false end
    return cache.ByHandle[handle] ~= nil
end

-- 选中组收尾：
--   * 玩家的组还在 ⇒ 恢复成它；
--   * 原选中组已经不存在、或它本来就是**我们的数据组**（上一轮写崩留下的）⇒ 落到一个正常组，
--     别把玩家的配置组选择留在一堆数据组里。
local function SettleSelection(preferredHandle, logTag)
    if GroupExists(preferredHandle) and not ModMiscModGroupStore.IsOurs(preferredHandle) then
        local ok = SetCurrentGroup(preferredHandle)
        Log(tostring(logTag) .. " 恢复选中组 handle=" .. tostring(preferredHandle)
            .. " 结果=" .. tostring(ok))
        return ok
    end
    local fallback = PickFallbackGroup(nil)
    if fallback == nil then
        Log(tostring(logTag) .. " 没有可落脚的其他配置组（只有数据组）")
        return false
    end
    local ok = SetCurrentGroup(fallback)
    Log(tostring(logTag) .. " 原选中组不可用/是数据组 -> 落到 handle=" .. tostring(fallback)
        .. " 结果=" .. tostring(ok))
    return ok
end

-- ===========================================================================
-- 对外接口
-- ===========================================================================

ModMiscModGroupStore = ModMiscModGroupStore or {}
ModMiscModGroupStore.BuildTag = MODGROUP_STORE_BUILD_TAG
ModMiscModGroupStore.Prefix = MODGROUP_PREFIX
ModMiscModGroupStore.DefaultChunkBytes = MODGROUP_DEFAULT_CHUNK_BYTES
ModMiscModGroupStore.ProbeKey = MODGROUP_PROBE_KEY
-- 每个 key 的 Load 日志（默认关：一次开面板读 5~6 个 key，逐条打印会很吵）
ModMiscModGroupStore.VerboseLoad = false

-- 缓存 TTL（秒）：外部 mod 直接建组/删组时，最多这么久后可见。
-- 本 mod 自己的写走 CreateGroup/RemoveByKey，会立刻更新索引，不等 TTL。
function ModMiscModGroupStore.SetCacheTtl(seconds)
    seconds = tonumber(seconds)
    if seconds == nil or seconds < 0 then return false end
    CACHE_TTL_SECONDS = seconds
    return true
end

function ModMiscModGroupStore.GetCacheTtl()
    return CACHE_TTL_SECONDS
end

-- 外部（别的 mod / 调试面板）直接动过配置组时调用；正常情况下不需要。
function ModMiscModGroupStore.InvalidateCache(reason)
    m_CacheDirty = true
    m_Stats.LastReason = "invalidate:" .. tostring(reason or "?")
    return true
end

-- 性能统计：给调试面板 / 日志验收用（枚举次数是这次优化最关键的指标）
function ModMiscModGroupStore.GetStats()
    local stats = {}
    for key, value in pairs(m_Stats) do stats[key] = value end
    stats.Ttl = CACHE_TTL_SECONDS
    stats.Cached = m_Cache ~= nil
    stats.Dirty = m_CacheDirty
    stats.BatchDepth = m_BatchDepth
    stats.Total = m_Cache ~= nil and m_Cache.Total or 0
    stats.Ours = m_Cache ~= nil and #m_Cache.Ours or 0
    return stats
end

function ModMiscModGroupStore.ResetStats()
    m_Stats.Builds = 0
    m_Stats.EnumerationCalls = 0
    m_Stats.CacheHits = 0
    m_Stats.BatchSkips = 0
    m_Stats.LastBuildMs = 0
    m_Stats.LastReason = nil
    return true
end

-- 面板上的「分片」选择器用它改默认分片大小（名字越长片越少）
function ModMiscModGroupStore.SetDefaultChunkBytes(bytes)
    bytes = tonumber(bytes)
    if bytes ~= nil and bytes >= 16 then
        MODGROUP_DEFAULT_CHUNK_BYTES = bytes
        ModMiscModGroupStore.DefaultChunkBytes = bytes
        return true
    end
    return false
end

function ModMiscModGroupStore.IsAvailable()
    if Modding == nil or Modding.GetModGroups == nil then return false end
    if Modding.CreateModGroup == nil or Modding.DeleteModGroup == nil then return false end
    if EncodeText("x") == nil or DecodeText("78") == nil then return false end
    return true
end

-- 列出全部组：{ Handle, Name, CanDelete, SortIndex, Ours, Key, Index, IsCurrent }
-- 只从缓存拷贝（不碰 Modding.GetModGroups）；IsCurrent 每次按引擎当前选中组现算。
function ModMiscModGroupStore.List()
    local cache, reason = EnsureGroupCache("list")
    if cache == nil then return nil, reason end
    local current = GetCurrentGroup()
    local out = {}
    for _, entry in ipairs(cache.All) do
        out[#out + 1] = {
            Handle = entry.Handle,
            Name = entry.Name,
            CanDelete = entry.CanDelete,
            SortIndex = entry.SortIndex,
            Ours = entry.Ours,
            Key = entry.Key,
            Index = entry.Index,
            IsCurrent = (entry.Handle == current),
        }
    end
    return out
end

-- 本 mod 的数据组（已按 key/index 排序）。缓存里就是有序的，只做拷贝，不再排序。
function ModMiscModGroupStore.ListOurs()
    local cache, reason = EnsureGroupCache("list-ours")
    if cache == nil then return nil, reason end
    local current = GetCurrentGroup()
    local out = {}
    for _, entry in ipairs(cache.Ours) do
        out[#out + 1] = {
            Handle = entry.Handle,
            Name = entry.Name,
            CanDelete = entry.CanDelete,
            SortIndex = entry.SortIndex,
            Ours = true,
            Key = entry.Key,
            Index = entry.Index,
            IsCurrent = (entry.Handle == current),
        }
    end
    return out
end

-- 诊断信息（面板上直接显示）
function ModMiscModGroupStore.GetInfo()
    local info = { Available = ModMiscModGroupStore.IsAvailable(), Tag = MODGROUP_STORE_BUILD_TAG }
    local groups, reason = ModMiscModGroupStore.List()
    if groups == nil then
        info.Error = reason
        return info
    end
    info.Total = #groups
    info.Ours = 0
    info.MaxNameLength = 0
    info.Duplicates = 0
    local seen = {}
    for _, group in ipairs(groups) do
        if group.Ours then
            info.Ours = info.Ours + 1
            local slot = tostring(group.Key) .. "#" .. tostring(group.Index)
            if seen[slot] ~= nil then info.Duplicates = info.Duplicates + 1 end
            seen[slot] = true
        end
        if #group.Name > info.MaxNameLength then info.MaxNameLength = #group.Name end
        if group.IsCurrent then
            info.CurrentHandle = group.Handle
            info.CurrentName = group.Name
            info.CurrentIsOurs = group.Ours and true or false
        end
    end
    local stats = ModMiscModGroupStore.GetStats()
    info.CacheBuilds = stats.Builds
    info.CacheHits = stats.CacheHits
    info.EnumerationCalls = stats.EnumerationCalls
    info.LastBuildMs = stats.LastBuildMs
    info.CacheTtl = stats.Ttl
    return info
end

-- 删除某个 key 的所有片（当前选中的组永不删）
-- 删除本 mod 的组；选中组先切走再删（原版做法）；originHandle 是“玩家的选中组”，删完恢复
local function RemoveByKey(key, onlyKey, originHandle)
    local cache, reason = EnsureGroupCache("remove-by-key")
    if cache == nil then return nil, reason end

    -- 目标直接从缓存取：删一个 key 不再遍历全部组。
    local targets = {}
    if onlyKey then
        local keyText = tostring(key)
        local bucket = cache.ByKey[keyText]
        if (cache.ByKeyDup[keyText] or 0) == 0 and bucket ~= nil then
            for _, entry in pairs(bucket) do targets[#targets + 1] = entry end
        else
            -- 有重复片 / 或索引里没有这个 key：退回扫一遍 Ours，确保重复片也能被清掉。
            for _, entry in ipairs(cache.Ours) do
                if tostring(entry.Key) == keyText then targets[#targets + 1] = entry end
            end
        end
    else
        for _, entry in ipairs(cache.Ours) do targets[#targets + 1] = entry end
    end

    local removed, failed = 0, 0
    local removedHandles = {}
    local currentHandle = GetCurrentGroup()
    for _, entry in ipairs(targets) do
        -- 引擎不让我们删“当前选中的组”⇒ 先把选中挪到别的组（原版做法）。
        -- 这里用**实时**当前组，不用缓存里的 IsCurrent（删过一片之后它就旧了）。
        local canDelete = true
        if currentHandle == entry.Handle then
            local fallback = PickFallbackGroup(entry.Handle)
            Log("要删的组正被选中，先把选中切到 handle=" .. tostring(fallback))
            canDelete = SetCurrentGroup(fallback)
            if canDelete then currentHandle = fallback end
            if not canDelete then
                failed = failed + 1
                Log("切走失败，跳过 -> " .. entry.Name)
            end
        end
        if canDelete then
            local ok = pcall(function() return Modding.DeleteModGroup(entry.Handle) end)
            if ok then
                removed = removed + 1
                removedHandles[entry.Handle] = true
            else
                failed = failed + 1
                Log("删除失败 -> " .. entry.Name)
            end
        end
    end
    if removed > 0 then CompactCacheAfterRemoval(removedHandles) end

    local restored = SettleSelection(originHandle, "RemoveByKey")
    return removed, nil, failed, restored
end

function ModMiscModGroupStore.Remove(key, originHandle)
    local current = originHandle ~= nil and originHandle or GetCurrentGroup()
    return RemoveByKey(key, true, current)
end

-- 清掉本 mod 的所有数据组（测试后收摊用）；顺带把选中组恢复成“玩家的那个”
function ModMiscModGroupStore.ClearAll(originHandle)
    local current = originHandle ~= nil and originHandle or GetCurrentGroup()
    if ModMiscModGroupStore.IsOurs(current) then
        -- 玩家当前选中的竟然是我们的数据组（上一轮写崩了）⇒ 先挪到正常组
        local fallback = PickFallbackGroup(current)
        Log("当前选中的是我们的数据组，先切到 handle=" .. tostring(fallback))
        SetCurrentGroup(fallback)
        current = fallback
    end
    local removed, reason, failed, restored = RemoveByKey(nil, false, current)
    if removed == nil then return nil, reason end
    local info = { Failed = failed, CurrentRestored = restored, CurrentHandle = GetCurrentGroup() }
    return removed, nil, failed, info
end

-- 某个句柄是不是我们的数据组
function ModMiscModGroupStore.IsOurs(handle)
    if handle == nil then return false end
    local cache = EnsureGroupCache("is-ours")
    if cache == nil then return false end
    local entry = cache.ByHandle[handle]
    return entry ~= nil and entry.Ours == true
end

-- 写一个 key：先删旧片，再按序建新片；最后复查一遍名字是否都在
function ModMiscModGroupStore.Save(key, text, chunkBytes)
    if not ModMiscModGroupStore.IsAvailable() then
        return false, "Modding 组接口不可用（或 hex 工具没加载）"
    end
    key = tostring(key)
    text = tostring(text)
    local size = tonumber(chunkBytes) or MODGROUP_DEFAULT_CHUNK_BYTES
    if size < 16 then size = 16 end

    local chunks = {}
    local index = 1
    while index <= #text do
        table.insert(chunks, text:sub(index, index + size - 1))
        index = index + size
    end
    if #chunks == 0 then chunks = { "" } end
    if #chunks > MODGROUP_MAX_CHUNKS then
        return false, "分片太多（" .. tostring(#chunks) .. " > " .. tostring(MODGROUP_MAX_CHUNKS) .. "）"
    end

    -- 写之前先保证缓存是新的（上一次写留下的 dirty 在这里结算一次）。
    local cache, cacheErr = EnsureGroupCache("save-begin")
    if cache == nil then return false, cacheErr end

    -- 记住玩家原本选中的组：CreateModGroup **会把新组设为选中**（实机教训 ①），写完全恢复
    local origin = GetCurrentGroup()
    BeginCacheBatch()
    local removed, reason = RemoveByKey(key, true, origin)
    if removed == nil then
        EndCacheBatch()
        m_CacheDirty = true
        return false, reason
    end

    local source = GetCurrentGroup()
    local expected = {}
    local created = 0
    for i, chunk in ipairs(chunks) do
        local name = BuildGroupName(key, i, chunk)
        expected[name] = true
        -- 以“当前组”为模板复制启用项：来源组要是我们的数据组也没关系（启用集合一样）
        local ok, err = CreateGroup(name, source)
        if not ok then
            SettleSelection(origin, "Save(失败后)")
            EndCacheBatch()
            m_CacheDirty = true
            return false, "第 " .. tostring(i) .. " 片建组失败: " .. tostring(err)
        end
        created = created + 1
    end
    -- 引擎把选中挪到了最后建的那个组 ⇒ 立刻收尾（恢复玩家的组，或落到一个正常组）
    local restored = SettleSelection(origin, "Save")

    -- 批量结束：新建的片必须从引擎重读（长组名可能被截断，复查不能被“打算写的名字”骗过）。
    EndCacheBatch()
    m_CacheDirty = true
    local ours = ModMiscModGroupStore.ListOurs() or {}

    -- 精确复查：**按名字逐个核对**，并数一数有没有同 key 同序号的重复片
    local seen, duplicated, missing = 0, 0, 0
    local seenIndex = {}
    for _, group in ipairs(ours) do
        if tostring(group.Key) == key then
            seen = seen + 1
            if seenIndex[group.Index] ~= nil then duplicated = duplicated + 1 end
            seenIndex[group.Index] = true
            if not expected[group.Name] then duplicated = duplicated + 1 end
        end
    end
    for i = 1, created do
        if seenIndex[i] == nil then missing = missing + 1 end
    end
    Log("Save key=" .. key .. " 字节=" .. tostring(#text) .. " 片=" .. tostring(created)
        .. " 复查到=" .. tostring(seen) .. " 重复=" .. tostring(duplicated)
        .. " 缺=" .. tostring(missing) .. " 选中已恢复=" .. tostring(restored))
    if missing > 0 then
        return false, "复查缺 " .. tostring(missing) .. " 片（见 " .. tostring(seen) .. " 组）"
    end
    if duplicated > 0 then
        return false, "有 " .. tostring(duplicated) .. " 个重复/多余的片（点清理再写一次）"
    end
    return true, created, #text
end

-- 读一个 key：片按序号拼回；缺片直接拒绝（不返回半截数据）
function ModMiscModGroupStore.Load(key)
    if not ModMiscModGroupStore.IsAvailable() then
        return nil, "Modding 组接口不可用（或 hex 工具没加载）"
    end
    local cache, reason = EnsureGroupCache("load")
    if cache == nil then return nil, reason end
    local text, count = LoadKeyFromCache(tostring(key))
    if text ~= nil and ModMiscModGroupStore.VerboseLoad then
        Log("Load key=" .. tostring(key) .. " 片=" .. tostring(count) .. " 字节=" .. tostring(#text))
    end
    return text, count
end

-- 批量读：只建一次索引/枚举一次，然后逐个 key 查表；返回：
--   texts[key]  = 文本
--   errors[key] = 失败原因
--   summary     = { Requested, Loaded }
-- 缓存重建失败时第三个返回值是字符串（调用方按“整批失败”处理）。
function ModMiscModGroupStore.LoadMany(keys)
    if not ModMiscModGroupStore.IsAvailable() then
        return nil, nil, "Modding 组接口不可用（或 hex 工具没加载）"
    end
    local list = keys
    if type(keys) ~= "table" then list = { keys } end
    if list[1] == nil then
        local ordered = {}
        for key in pairs(list) do ordered[#ordered + 1] = key end
        table.sort(ordered, function(a, b) return tostring(a) < tostring(b) end)
        list = ordered
    end
    local cache, reason = EnsureGroupCache("load-many")
    if cache == nil then return nil, nil, reason end
    local texts, errors = {}, {}
    local loaded = 0
    for _, key in ipairs(list) do
        local keyText = tostring(key)
        local text, detail = LoadKeyFromCache(keyText)
        if text ~= nil then
            texts[keyText] = text
            loaded = loaded + 1
        else
            errors[keyText] = detail
        end
    end
    return texts, errors, { Requested = #list, Loaded = loaded }
end

-- 自检/面板共用的载荷：长度恰好 size 字节，带首尾标记（肉眼能看出截断/串位）
local function BuildProbePayload(size)
    size = tonumber(size) or 0
    local head = "<" .. tostring(size) .. ">"
    local tail = "</e>"
    if size <= #head + #tail then return (head .. tail):sub(1, math.max(0, size)) end
    return head .. string.rep("A", size - #head - #tail) .. tail
end

ModMiscModGroupStore.BuildPayload = BuildProbePayload

-- ===========================================================================
-- 名字长度上限探针（授权者关心“modgroupname 能不能到 1G”，先用它把真实上限量出来）
--
-- 做法：拿**一个**组来试——组名 = MMTSTORE~<probe 的 key>~001~<hex(载荷)>，
-- 载荷取 1KB → 2KB → … 逐级往上（hex 后名字长度 = 2×载荷 + 前缀开销），
-- 每级写完**读回这个名字**，比对“引擎实际存下的名字长度”和“载荷能不能逐字还原”：
--   * 读回名字变短 ⇒ 引擎截断了名字，这一级就是上限（上一级就是可用的最大名字）；
--   * 读回一致但载荷还原不了 ⇒ 引擎在更下层做了手脚，同样记为失败。
-- 跑完把探测键的组删掉、并把玩家选中的组恢复回去。
--
-- 【为什么重要】分片数 × 每片名字长度 = 单键容量。名字越长，片数越少：
-- 每个片都是一条配置组（还会把启用项复制一份），片太多会拖慢模组界面与数据库。
-- ===========================================================================
function ModMiscModGroupStore.ProbeNameCeiling(sizes)
    sizes = sizes or { 1024, 2048, 4096, 8192, 16384, 32768, 65536 }
    local probeKey = "nameprobe"
    local report = { Tag = MODGROUP_STORE_BUILD_TAG, Steps = {},
                     Available = ModMiscModGroupStore.IsAvailable() }
    if not report.Available then
        report.Error = "Modding 组接口不可用"
        return report
    end

    local origin = GetCurrentGroup()
    RemoveByKey(probeKey, true, origin)          -- 先清掉上次探测留下的

    for _, size in ipairs(sizes) do
        local payload = BuildProbePayload(size)
        local name = BuildGroupName(probeKey, 1, payload)
        local step = { Payload = size, NameLength = #name }
        local source = GetCurrentGroup()
        local ok, err = CreateGroup(name, source)
        if not ok then
            step.Error = "建组失败: " .. tostring(err)
            table.insert(report.Steps, step)
            report.FirstFailure = step
            break
        end
        -- 读回：找到这条探测组，量名字长度、还原载荷
        local ours = ModMiscModGroupStore.ListOurs() or {}
        local found = nil
        for _, group in ipairs(ours) do
            if tostring(group.Key) == probeKey then found = group break end
        end
        if found == nil then
            step.Error = "写完却读不到这条组"
            table.insert(report.Steps, step)
            report.FirstFailure = step
            break
        end
        step.ReadNameLength = #found.Name
        local parsed = ParseGroupName(found.Name)
        local back = parsed ~= nil and DecodeText(parsed.PayloadHex) or nil
        step.ReadPayload = back ~= nil and #back or nil
        step.Truncated = (#found.Name < #name)
        step.Match = (back == payload)
        if not step.Match then
            step.Error = step.Truncated
                and ("名字被截断：写 " .. tostring(#name) .. " 字符，存下 "
                     .. tostring(#found.Name) .. " 字符")
                or "载荷还原不一致"
        end
        table.insert(report.Steps, step)
        Log("名字探针 载荷=" .. tostring(size) .. "B 名字=" .. tostring(#name)
            .. " 字符 读回=" .. tostring(step.ReadNameLength) .. " 字符 一致="
            .. tostring(step.Match))
        if not step.Match then
            report.FirstFailure = step
            break
        end
        report.LastSuccess = step
        -- 下一级要重新建（改值=删旧建新）
        RemoveByKey(probeKey, true, origin)
    end

    local removed, reason, failed, info = ModMiscModGroupStore.ClearAll(origin)
    report.CleanupRemoved = removed
    report.CleanupFailed = failed
    report.CleanupError = reason
    report.CurrentGroupUnchanged = (GetCurrentGroup() == origin)
    return report
end

-- 自检：按尺寸阶梯写→读→逐字节比对，找出“能完整往返”的上限，然后清理
function ModMiscModGroupStore.SelfTest(sizes, chunkBytes)
    sizes = sizes or { 8, 64, 256, 1024, 4096, 16384 }
    local report = { Tag = MODGROUP_STORE_BUILD_TAG, Steps = {}, Available = ModMiscModGroupStore.IsAvailable() }
    if not report.Available then
        report.Error = "Modding 组接口不可用"
        return report
    end

    local currentBefore = GetCurrentGroup()
    for _, size in ipairs(sizes) do
        -- 载荷**长度精确等于标称尺寸**（实机教训 ②：以前 8B 的载荷其实只有 7 字节，日志会误读）
        local payload = BuildProbePayload(size)
        local step = { Size = size, PayloadBytes = #payload }
        local ok, chunks, written = ModMiscModGroupStore.Save(MODGROUP_PROBE_KEY, payload,
            chunkBytes or MODGROUP_DEFAULT_CHUNK_BYTES)
        step.Ok = ok and true or false
        step.Chunks = chunks
        step.Written = written
        if not ok then
            step.Error = tostring(chunks)
        else
            local readBack, count = ModMiscModGroupStore.Load(MODGROUP_PROBE_KEY)
            step.ReadChunks = count
            step.Match = (readBack == payload)
            step.ReadBytes = readBack ~= nil and #readBack or nil
            if not step.Match then
                step.Error = "读回不一致（读到 " .. tostring(step.ReadBytes) .. " 字节）"
            end
        end
        table.insert(report.Steps, step)
        Log("自检 size=" .. tostring(size) .. " ok=" .. tostring(step.Ok)
            .. " 片=" .. tostring(step.Chunks) .. " 读回=" .. tostring(step.ReadBytes)
            .. " 一致=" .. tostring(step.Match))
        if not step.Match then
            report.FirstFailure = step
            break
        end
        report.LastSuccess = step
    end

    -- 收摊：把自检留下的组删掉，并回报“当前选中的组有没有被我们动过”
    local removed, reason, failed, info = ModMiscModGroupStore.ClearAll(currentBefore)
    report.CleanupRemoved = removed
    report.CleanupFailed = failed
    report.CleanupError = reason
    report.CleanupInfo = info
    local currentAfter = GetCurrentGroup()
    report.CurrentGroupUnchanged = (currentBefore == currentAfter)
    report.CurrentBefore = currentBefore
    report.CurrentAfter = currentAfter
    return report
end
