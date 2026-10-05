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
-- ===========================================================================

local BIGSTORE_BUILD_TAG = "2026-10-05-A"
local BIGSTORE_CHUNK_BYTES = 4000      -- 实机验证过 4000 字节/片（组名 ≈8024 字符）

local function Log(message)
    print("[ModMiscTool][BigStore] " .. tostring(message))
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
    end
    return info
end

-- 写大载荷：优先配置组通道；它不可用才退回分片 blob
function ModMiscBigStore.Save(key, text)
    key = tostring(key)
    text = tostring(text or "")
    if ModMiscBigStore.HasBigChannel() then
        local ok, chunks, bytes = ModMiscModGroupStore.Save(key, text, BIGSTORE_CHUNK_BYTES)
        if ok then
            Log("大通道写入 key=" .. key .. " 字节=" .. tostring(bytes)
                .. " 片=" .. tostring(chunks))
            return true, "modgroup", chunks
        end
        -- 写失败时先把它写了一半的片清掉，再回退 —— 否则那些半成品会变成没人认领的孤儿，
        -- 一直挂在模组界面的配置组里（模拟器场景 5.1/5.2 抓到）。
        if ModMiscModGroupStore.Remove ~= nil then
            ModMiscModGroupStore.Remove(key)
        end
        Log("大通道写入失败（" .. tostring(chunks) .. "）→ 已清半成品，回退分片 blob")
    end
    if ModMiscStore == nil or ModMiscStore.SaveBlob == nil then
        return false, "没有可用的大载荷通道"
    end
    local ok, err = ModMiscStore.SaveBlob(key, text)
    if not ok then return false, err end
    Log("回退通道写入 key=" .. key .. " 字节=" .. tostring(#text))
    return true, "blob"
end

-- 读大载荷：先大通道（有就信它），读不到再回退分片 blob
function ModMiscBigStore.Load(key)
    key = tostring(key)
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

-- 删大载荷：**两条都删**（同一个 key 可能在两条通道里都留过东西）
function ModMiscBigStore.Remove(key)
    key = tostring(key)
    local removed = 0
    if ModMiscBigStore.HasBigChannel() then
        local count = ModMiscModGroupStore.Remove(key)
        if tonumber(count) ~= nil then removed = removed + count end
    end
    if ModMiscStore ~= nil and ModMiscStore.RemoveBlob ~= nil then
        ModMiscStore.RemoveBlob(key)
    end
    return removed
end
