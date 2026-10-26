-- ===========================================================================
-- Mod Misc Tool: 大载荷跨存档存储（统一门面）
--
-- 【为什么要有这一层】跨存档有两条通道，能力差得很远：
--   * 存档名编码（ModMiscStore）：一个键 = 一个小配置档，单片 ~80 字节、单键 ~100 字节，
--     **不用载入就能读**（关系树的头指针/信箱索引这种几十字节的小数据最适合）；
--   * 模组配置组名字（ModMiscModGroupStore）：一个片 = 一条配置组，
--     **实机已验证 1 MB 跨进程读回逐字一致**（4000 字节/片 → 263 片，单条组名 8024 字符被引擎原样接受）。
--     代价：数据片会出现在模组界面的配置组下拉框里。
--
-- 这一层的职责就一句话：**大数据自动走大通道，小数据/读不到时回退小通道**。
-- 事件的大载荷（PayloadText）、以后的表格都走它，调用的地方不用关心底下是谁。
--
-- 【回退与兼容】Load 先问大通道，没有再问小通道的分片 blob ——
-- 这样“以前用 blob 写的事件”和“现在用配置组写的事件”都能读回来，不需要迁移旧数据。
--
-- 【2026-10-21 性能】两条缓存，目标是把“开一次面板读 5~6 个键”从多次全量枚举
-- 压到 0~1 次：
--   ① ModMiscModGroupStore 里的组索引缓存：读 key 变成 O(1) 查表（见那个文件）；
--   ② 本文件的文本缓存：同一个 key 反复读（开面板 / 回合开始 / 跨存档写后读回）
--      直接命中内存，不再走组索引/hex 解码。写入/删除会立刻失效；2 秒 TTL 兜底
--      外部写入。缓存上限 64 条 / 512KB，超出淘汰最旧的，不会把内存吃穿。
--
-- 【为什么不用 Game:SetProperty 缓存】UI 上下文没有 Game:SetProperty（授权者
--   2026-10-05 实机确认，见 UI/Support_UI.lua 顶部说明）；UI 侧只能内存缓存。
--   真正要落盘的数据仍走配置组（跨存档）/ CustomData（随档）这两条既有通道。
-- ===========================================================================

local BIGSTORE_BUILD_TAG = "2026-10-21-C"
local BIGSTORE_CHUNK_BYTES = 4000      -- 实机验证过 4000 字节/片（组名 ≈8024 字符）

local TEXT_CACHE_TTL_SECONDS = 2.0
local TEXT_CACHE_MAX_ENTRIES = 64
local TEXT_CACHE_MAX_BYTES = 512 * 1024
local m_TextCache = {}
local m_TextCacheCount = 0
local m_TextCacheBytes = 0
local m_Stats = {
    TextHits = 0,
    TextMisses = 0,
    Saves = 0,
    Removes = 0,
    BatchLoads = 0,
    BatchKeys = 0,
    CacheEvictions = 0,
}

local function Log(message)
    print("[ModMiscTool][BigStore] " .. tostring(message))
end

local function NowSeconds()
    local now = nil
    pcall(function() now = os.time() end)
    return now
end

-- 文本缓存：key -> { Text, Source, At, Bytes }
local function TextCacheRemove(key)
    local entry = m_TextCache[key]
    if entry == nil then return false end
    m_TextCacheCount = math.max(0, m_TextCacheCount - 1)
    m_TextCacheBytes = math.max(0, m_TextCacheBytes - (entry.Bytes or #entry.Text or 0))
    m_TextCache[key] = nil
    return true
end

local function TextCacheClear()
    for key in pairs(m_TextCache) do m_TextCache[key] = nil end
    m_TextCacheCount = 0
    m_TextCacheBytes = 0
end

local function TextCacheGet(key)
    local entry = m_TextCache[key]
    if entry == nil then return nil end
    local now = NowSeconds()
    if now ~= nil and entry.At ~= nil and (now - entry.At) >= TEXT_CACHE_TTL_SECONDS then
        TextCacheRemove(key)
        return nil
    end
    m_Stats.TextHits = m_Stats.TextHits + 1
    return entry.Text, entry.Source
end

local function TextCachePut(key, text, source)
    if text == nil then return false end
    local bytes = #text
    -- 先摘掉同 key 的旧条目：新值太大不缓存时，也不能让旧值继续冒充新值。
    TextCacheRemove(key)
    if bytes > TEXT_CACHE_MAX_BYTES then return false end
    -- 超出条数/字节上限时淘汰最旧的一条（缓存条目很少，线性找最旧足够）
    while m_TextCacheCount >= TEXT_CACHE_MAX_ENTRIES
        or (m_TextCacheBytes + bytes) > TEXT_CACHE_MAX_BYTES do
        local oldestKey, oldestAt = nil, nil
        for cachedKey, entry in pairs(m_TextCache) do
            local at = entry.At or 0
            if oldestAt == nil or at < oldestAt then
                oldestKey, oldestAt = cachedKey, at
            end
        end
        if oldestKey == nil then break end
        TextCacheRemove(oldestKey)
        m_Stats.CacheEvictions = m_Stats.CacheEvictions + 1
    end
    m_TextCache[key] = { Text = text, Source = source, At = NowSeconds() or 0, Bytes = bytes }
    m_TextCacheCount = m_TextCacheCount + 1
    m_TextCacheBytes = m_TextCacheBytes + bytes
    return true
end

ModMiscBigStore = ModMiscBigStore or {}
ModMiscBigStore.BuildTag = BIGSTORE_BUILD_TAG
ModMiscBigStore.ChunkBytes = BIGSTORE_CHUNK_BYTES

function ModMiscBigStore.SetChunkBytes(bytes)
    bytes = tonumber(bytes)
    if bytes ~= nil and bytes >= 16 then
        BIGSTORE_CHUNK_BYTES = bytes
        ModMiscBigStore.ChunkBytes = bytes
        if ModMiscModGroupStore ~= nil and ModMiscModGroupStore.SetDefaultChunkBytes ~= nil then
            ModMiscModGroupStore.SetDefaultChunkBytes(bytes)
        end
        return true
    end
    return false
end

-- 文本缓存 TTL / 清理 / 统计：给调试面板和“换图/读档后强制重读”用
function ModMiscBigStore.SetCacheTtl(seconds)
    seconds = tonumber(seconds)
    if seconds == nil or seconds < 0 then return false end
    TEXT_CACHE_TTL_SECONDS = seconds
    return true
end

function ModMiscBigStore.GetCacheTtl()
    return TEXT_CACHE_TTL_SECONDS
end

function ModMiscBigStore.InvalidateCache(key)
    if key == nil then
        TextCacheClear()
        return true
    end
    return TextCacheRemove(tostring(key))
end

function ModMiscBigStore.GetStats()
    local stats = {}
    for name, value in pairs(m_Stats) do stats[name] = value end
    stats.Entries = m_TextCacheCount
    stats.Bytes = m_TextCacheBytes
    stats.Ttl = TEXT_CACHE_TTL_SECONDS
    return stats
end

function ModMiscBigStore.ResetStats()
    m_Stats.TextHits = 0
    m_Stats.TextMisses = 0
    m_Stats.Saves = 0
    m_Stats.Removes = 0
    m_Stats.BatchLoads = 0
    m_Stats.BatchKeys = 0
    m_Stats.CacheEvictions = 0
    return true
end

-- 大通道（配置组）在不在、能不能用
function ModMiscBigStore.HasBigChannel()
    return ModMiscModGroupStore ~= nil and ModMiscModGroupStore.IsAvailable ~= nil
        and ModMiscModGroupStore.IsAvailable() == true
end

function ModMiscBigStore.GetInfo()
    local info = { Tag = BIGSTORE_BUILD_TAG, ChunkBytes = BIGSTORE_CHUNK_BYTES,
                   Big = ModMiscBigStore.HasBigChannel() }
    if info.Big then
        local groups = ModMiscModGroupStore.ListOurs()
        info.Groups = groups ~= nil and #groups or 0
        if ModMiscModGroupStore.GetStats ~= nil then
            local groupStats = ModMiscModGroupStore.GetStats()
            info.GroupEnumerationCalls = groupStats.EnumerationCalls
            info.GroupCacheBuilds = groupStats.Builds
            info.GroupCacheHits = groupStats.CacheHits
        end
    end
    local stats = ModMiscBigStore.GetStats()
    info.TextCacheEntries = stats.Entries
    info.TextCacheBytes = stats.Bytes
    info.TextHits = stats.TextHits
    info.TextMisses = stats.TextMisses
    info.BatchLoads = stats.BatchLoads
    info.BatchKeys = stats.BatchKeys
    info.Saves = stats.Saves
    info.Removes = stats.Removes
    return info
end

-- 读一个 key：先查文本缓存，未命中再按“大通道 → blob”的顺序读。
-- 返回 (文本, 来源)；失败时返回 (nil, 原因)。
local function LoadUncached(key)
    if ModMiscBigStore.HasBigChannel() then
        local text, reason = ModMiscModGroupStore.Load(key)
        if text ~= nil then return text, "modgroup" end
        -- “没有这个 key”是正常的回退情形；其它原因（缺片/重复片）要说出来
        if reason ~= nil and tostring(reason):find("没有这个 key") == nil then
            Log("大通道读取异常（" .. tostring(reason) .. "）→ 仍尝试回退 blob")
        end
    end
    if ModMiscStore ~= nil and ModMiscStore.LoadBlob ~= nil then
        local text, err = ModMiscStore.LoadBlob(key)
        if text ~= nil then return text, "blob" end
        return nil, err
    end
    return nil, "没有可用的大载荷通道"
end

function ModMiscBigStore.Load(key)
    key = tostring(key)
    local text, source = TextCacheGet(key)
    if text ~= nil then return text, source end
    m_Stats.TextMisses = m_Stats.TextMisses + 1
    local loaded, loadedSource = LoadUncached(key)
    if loaded ~= nil then TextCachePut(key, loaded, loadedSource) end
    return loaded, loadedSource
end

-- 批量读：一次组索引枚举 + 一次文本缓存命中；返回：
--   texts[key]   = 文本
--   sources[key] = "modgroup" / "blob"
--   errors[key]  = 失败原因
-- 组存储不支持 LoadMany（旧版）时自动退回逐 key 读。
function ModMiscBigStore.LoadMany(keys)
    local list = keys
    if type(keys) ~= "table" then list = { keys } end
    if list[1] == nil then
        local ordered = {}
        for key in pairs(list) do ordered[#ordered + 1] = key end
        table.sort(ordered, function(a, b) return tostring(a) < tostring(b) end)
        list = ordered
    end

    local texts, sources, errors = {}, {}, {}
    local misses = {}
    for _, key in ipairs(list) do
        local keyText = tostring(key)
        local text, source = TextCacheGet(keyText)
        if text ~= nil then
            texts[keyText], sources[keyText] = text, source
        else
            m_Stats.TextMisses = m_Stats.TextMisses + 1
            misses[#misses + 1] = keyText
        end
    end

    local unresolved = {}
    if #misses > 0 then
        if ModMiscBigStore.HasBigChannel() and ModMiscModGroupStore.LoadMany ~= nil then
            local groupTexts, groupErrors, summary = ModMiscModGroupStore.LoadMany(misses)
            if groupTexts == nil then
                Log("批量读大通道失败（" .. tostring(groupErrors or summary) .. "）→ 逐个回退 blob")
                for _, keyText in ipairs(misses) do unresolved[#unresolved + 1] = keyText end
            else
                for _, keyText in ipairs(misses) do
                    local text = groupTexts[keyText]
                    if text ~= nil then
                        texts[keyText], sources[keyText] = text, "modgroup"
                        TextCachePut(keyText, text, "modgroup")
                    else
                        local reason = groupErrors ~= nil and groupErrors[keyText] or nil
                        if reason ~= nil and tostring(reason):find("没有这个 key") == nil then
                            Log("大通道读取异常（" .. tostring(reason) .. "）→ 仍尝试回退 blob")
                        end
                        unresolved[#unresolved + 1] = keyText
                    end
                end
            end
        elseif ModMiscBigStore.HasBigChannel() then
            -- 旧版组存储：没有批量接口，只能逐 key 读（仍然比没有缓存好）
            for _, keyText in ipairs(misses) do
                local text, reason = ModMiscModGroupStore.Load(keyText)
                if text ~= nil then
                    texts[keyText], sources[keyText] = text, "modgroup"
                    TextCachePut(keyText, text, "modgroup")
                else
                    if reason ~= nil and tostring(reason):find("没有这个 key") == nil then
                        Log("大通道读取异常（" .. tostring(reason) .. "）→ 仍尝试回退 blob")
                    end
                    unresolved[#unresolved + 1] = keyText
                end
            end
        else
            for _, keyText in ipairs(misses) do unresolved[#unresolved + 1] = keyText end
        end
    end

    -- 大通道没有的/读不出的，再回退分片 blob（与单 key Load 的行为一致）
    for _, keyText in ipairs(unresolved) do
        local text, err = nil, nil
        if ModMiscStore ~= nil and ModMiscStore.LoadBlob ~= nil then
            text, err = ModMiscStore.LoadBlob(keyText)
        else
            err = "没有可用的大载荷通道"
        end
        if text ~= nil then
            texts[keyText], sources[keyText] = text, "blob"
            TextCachePut(keyText, text, "blob")
        else
            errors[keyText] = err or "没有这份数据"
        end
    end

    m_Stats.BatchLoads = m_Stats.BatchLoads + 1
    m_Stats.BatchKeys = m_Stats.BatchKeys + #list
    return texts, sources, errors
end

-- 写大载荷：优先配置组通道；它不可用才退回分片 blob。
-- ⚠️ 写成功后**不**往文本缓存里放：调用方（CrossSaveWrite）会立刻读回校验，
--    那个读回必须读引擎里的真实数据；拿“刚写进去的字符串”回它等于把校验废掉。
--    第一次真实读回成功后会自然进缓存，后面的读仍然是内存命中。
function ModMiscBigStore.Save(key, text)
    key = tostring(key)
    text = tostring(text or "")
    TextCacheRemove(key)
    if ModMiscBigStore.HasBigChannel() then
        local ok, chunks, bytes = ModMiscModGroupStore.Save(key, text, BIGSTORE_CHUNK_BYTES)
        if ok then
            m_Stats.Saves = m_Stats.Saves + 1
            Log("大通道写入 key=" .. key .. " 字节=" .. tostring(bytes)
                .. " 片=" .. tostring(chunks))
            return true, "modgroup", chunks
        end
        -- 写失败时先把它写了一半的片清掉，再回退 —— 否则那些半成品会变成没人认领的孤儿，
        -- 一直挂在模组界面的配置组里（模拟器场景 5.1/5.2 抓到）。
        if ModMiscModGroupStore.Remove ~= nil then
            ModMiscModGroupStore.Remove(key)
        end
        TextCacheRemove(key)
        Log("大通道写入失败（" .. tostring(chunks) .. "）→ 已清半成品，回退分片 blob")
    end
    if ModMiscStore == nil or ModMiscStore.SaveBlob == nil then
        return false, "没有可用的大载荷通道"
    end
    local ok, err = ModMiscStore.SaveBlob(key, text)
    if not ok then return false, err end
    m_Stats.Saves = m_Stats.Saves + 1
    Log("回退通道写入 key=" .. key .. " 字节=" .. tostring(#text))
    return true, "blob"
end

-- 删大载荷：**两条都删**（同一个 key 可能在两条通道里都留过东西）
function ModMiscBigStore.Remove(key)
    key = tostring(key)
    TextCacheRemove(key)
    local removed = 0
    if ModMiscBigStore.HasBigChannel() then
        local count = ModMiscModGroupStore.Remove(key)
        if tonumber(count) ~= nil then removed = removed + count end
    end
    if ModMiscStore ~= nil and ModMiscStore.RemoveBlob ~= nil then
        ModMiscStore.RemoveBlob(key)
    end
    m_Stats.Removes = m_Stats.Removes + 1
    return removed
end

-- 对外别名：与 Support_UI 暴露的 LoadBigData 同一命名风格。
-- EH 侧可以直接 api.LoadBigDataMany({ "av_eh_registry", ... }) 一次读多个键；
-- 没走 ExposedMembers 的调用方仍可用 ModMiscBigStore.LoadMany。
if ExposedMembers ~= nil then
    ExposedMembers.ModMiscToolUI = ExposedMembers.ModMiscToolUI or {}
    ExposedMembers.ModMiscToolUI.LoadBigDataMany = ModMiscBigStore.LoadMany
    ExposedMembers.ModMiscToolUI.GetBigDataStats = ModMiscBigStore.GetStats
    ExposedMembers.ModMiscToolUI.InvalidateBigDataCache = ModMiscBigStore.InvalidateCache
end
