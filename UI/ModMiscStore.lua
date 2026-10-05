-- ===========================================================================
-- Mod Misc Tool: 跨存档数据存储（UI 层）
--
-- 【为什么用「存档文件名」当载体】原版通道已全部实测（见 API_Verification_Status.md 通道表）：
--   ✗ CustomData 不落盘、配置档也不带它        ✗ 对局内读配置档直接卡死
--   ✗ io 库不存在（安卓 Lua 无 io/io.open）    ✗ Options 拒绝未注册的键
--   ✗ 存档元数据字段全由引擎填
-- 剩下唯一由 mod 控制、又**不需要读档**就能拿到的字段，就是存档列表里的**文件名**：
--   写 Network.SaveGame{Name = …}（前端不需要运行中的对局即可写配置档）
--   读 UI.QuerySaveGameList 的 Name（前后端都可用）
-- 2026-10-04 实机验证：写一轮 → 杀进程 → 下一轮读回，payload 逐字一致。
--
-- 【文件命名】ModMiscStore~<hex(key)>~<hex(value)>.Civ6Cfg
--   一个 key 一个档。hex 是为了绕开文件名禁用字符（`% " < > | / \ * ? :` 与控制字符）。
--   写：先写新档，再删同一个 key 的旧档（写失败也不丢数据）。
--   读：扫一遍配置档列表，把所有 ModMiscStore~ 开头的档解码进内存表。
--
-- 【公开 API】本 mod 内直接调；外部 mod 走 ExposedMembers.ModMiscToolUI
--   ModMiscStore.Refresh()        重新扫存档列表（异步，结果进内存表）
--   ModMiscStore.IsReady()        首次扫描是否已完成
--   ModMiscStore.OnReady(fn)      扫描完成时回调（若已就绪则立刻调用）
--   ModMiscStore.Save(key, value) 写一个键（异步落盘；值建议 ≤ 80 字节）
--   ModMiscStore.Get(key)         读一个键（没存过 → nil）
--   ModMiscStore.GetAll()         整张表（副本）
--
-- 注意：每个 UI context 有独立脚本环境，各持一份内存表；跨 context 靠 ExposedMembers。
-- ===========================================================================

local MODMISC_STORE_PREFIX = "ModMiscStore~"
local MODMISC_STORE_BUILD_TAG = "2026-10-04-F"
-- 自检：每轮写一份 ms=… payload 并读回上一轮的（验证通道还活着）。
-- 通道已验证完毕（2026-10-04），关掉 —— 正式用起来它就是噪音键。
local MODMISC_STORE_SELFTEST = false
-- 值长度上限（hex 后翻倍，文件名总长别顶到系统上限）
-- 值长度上限：**按文件名长度反推**，不是拍脑袋的常数。
-- 文件名 = "ModMiscStore~" + hex(key) + "~" + hex(value) + ".Civ6Cfg"
--          (13)            (2*len(key))      (1)   (2*len(value))   (9)
-- 文件名（一个路径分量）在 Android 上是 255 **字节**上限，留点余量按 240 算：
--     2*len(key) + 2*len(value) <= 240 - 13 - 1 - 9 = 217
-- 旧版写死 120 字节，其实对稍长的键就已经超了（例子：key=15 → 需要 293 字节 ✗），
-- 超长会被底层拒写/截断，表现就是“存不进去”——授权者 2026-10-05 反馈的“不支持大型表格”。
local MODMISC_STORE_NAME_BUDGET = 240
local MODMISC_STORE_NAME_FIXED = 13 + 1 + 9   -- 前缀 + 分隔符 + 扩展名
-- 这个键最多能写多少字节的值（hex 后仍放得进文件名）
local function ComputeMaxValueBytes(key)
    local keyLength = #tostring(key or "")
    local room = MODMISC_STORE_NAME_BUDGET - MODMISC_STORE_NAME_FIXED - 2 * keyLength
    if room < 2 then return 0 end
    return math.floor(room / 2)
end

-- 分片：blob 的元数据键 / 数据键（键名保持短，别把预算吃光）
local MODMISC_STORE_BLOB_META_SUFFIX = "$m"
local MODMISC_STORE_BLOB_CHUNK_SUFFIX = "$"
-- 每片的目标字节数（按最坏情况的键长留余量；实际写入前还会按 ComputeMaxValueBytes 再夹一次）
local MODMISC_STORE_BLOB_CHUNK_BYTES = 80
-- 早期探测阶段留下的档：扫到就顺手删掉，免得一直在列表里当“非存储档”碍眼
--   ModMiscFrontEndProbe —— 前端存读档探针写过的那种配置档（探针已默认关闭）
--   形如 ModMiscStore~<单段hex> —— 本模块改版前的老格式（没有 key/value 两段）
local MODMISC_STORE_LEGACY_NAME = "ModMiscFrontEndProbe"
-- 退役的测试键：通道验证阶段由「自检」与「对局内写测试」写过，现在这两个测试都关了，
-- 扫到就把它们的档一并清掉，免得正式用起来还躺着几条脚手架数据。
local MODMISC_STORE_RETIRED_KEYS = { selftest = true, ingame = true }

-- 本进程已解码到的数据
local m_Data = {}
-- key -> 存档列表条目（覆盖时用来删旧档）
local m_Entries = {}
-- 写完新档后要删的旧条目
local m_PendingDelete = {}

local m_RefreshRequestId = nil
local m_Refreshing = false
-- 本次扫描完成后要回调的函数（Refresh(onDone) 用）——一次性
local m_RefreshCallbacks = {}
local m_Ready = false
local m_ReadyCallbacks = {}

local function Log(message)
    print("[ModMiscTool][Store] " .. message)
end

ModMiscStore = ModMiscStore or {}
ModMiscStore.BuildTag = MODMISC_STORE_BUILD_TAG

-- ===========================================================================
-- 编解码 / 文件名
-- ===========================================================================

local function EncodeText(text)
    return (tostring(text):gsub(".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end

local function DecodeText(hex)
    if hex == nil or #hex == 0 or #hex % 2 ~= 0 then return nil end
    local bytes = {}
    for i = 1, #hex, 2 do
        local byte = tonumber(hex:sub(i, i + 1), 16)
        if byte == nil then return nil end
        table.insert(bytes, string.char(byte))
    end
    return table.concat(bytes)
end

-- 供别的模块复用（例：UI/ModMiscModGroupStore.lua 把值写进「模组配置组名字」里，
-- 那边不想再抄一份 hex —— 同一个 mod 里只留一套编解码）
ModMiscStore.EncodeText = EncodeText
ModMiscStore.DecodeText = DecodeText

-- 存档列表里的 Name 带扩展名（配置档是 xxx.Civ6Cfg），比对前先剥掉
local function StripExtension(name)
    if name == nil then return nil end
    local text = tostring(name)
    local stripped = text:match("^(.*)%.[^%.]+$")
    if stripped ~= nil and stripped ~= "" then return stripped end
    return text
end

local function BuildFileName(key, value)
    return MODMISC_STORE_PREFIX .. EncodeText(key) .. "~" .. EncodeText(value)
end

-- 从档名里解出 (key, value)；不是本存储的档 → nil
local function ParseFileName(name)
    local shortName = StripExtension(name)
    if shortName == nil or shortName:sub(1, #MODMISC_STORE_PREFIX) ~= MODMISC_STORE_PREFIX then
        return nil
    end
    local body = shortName:sub(#MODMISC_STORE_PREFIX + 1)
    local keyHex, valueHex = body:match("^([^~]*)~(.+)$")
    if keyHex == nil or valueHex == nil then return nil end
    local key = DecodeText(keyHex)
    local value = DecodeText(valueHex)
    if key == nil or value == nil then return nil end
    return key, value
end

local function BuildConfigFile(name)
    if SaveLocations == nil or SaveFileTypes == nil then return nil end
    local saveType = nil
    if Network ~= nil and Network.GetGameConfigurationSaveType ~= nil then
        local ok, value = pcall(function() return Network.GetGameConfigurationSaveType() end)
        if ok then saveType = value end
    end
    if saveType == nil and SaveTypes ~= nil then saveType = SaveTypes.SINGLE_PLAYER end
    if saveType == nil then return nil end

    local configFile = {
        Name = name,
        Location = SaveLocations.LOCAL_STORAGE,
        Type = saveType,
        FileType = SaveFileTypes.GAME_CONFIGURATION,
    }
    if SaveDirectories ~= nil then
        configFile.Directory = SaveDirectories.DEFAULT
    end
    return configFile
end

-- ===========================================================================
-- 扫描（读）：一次列表查询，把所有存储档解码进内存表
-- ===========================================================================

local function NotifyReady()
    m_Ready = true
    for _, callback in ipairs(m_ReadyCallbacks) do
        pcall(callback)
    end
    m_ReadyCallbacks = {}
end

-- 档的修改时间（同一个 key 有多份时用来挑最新的一份）
local function GetEntryTimestamp(entry)
    if UI == nil or UI.GetSaveGameModificationTimeRaw == nil then return nil end
    local ok, value = pcall(UI.GetSaveGameModificationTimeRaw, entry)
    if ok then return value end
    return nil
end

local function OnStoreQueryResults(fileList, requestId)
    -- 【必须严格对号】LuaEvents.FileListQueryResults 是**全局广播**：游戏自己的存档菜单
    -- 每次查存档列表（快速存档 / 自动存档 / 载入游戏）也会发这个事件。
    -- 实测过一次事故：主菜单查“继续游戏”时把 quicksave/autosave 列表送到这里，
    -- 被当成我们的扫描结果 → 内存表被清空（键值：(空)）。
    -- 所以只接受“就是我们这次发的那个请求号”，而且处理完立刻退订。
    if m_RefreshRequestId == nil or requestId ~= m_RefreshRequestId then return end
    LuaEvents.FileListQueryResults.Remove(OnStoreQueryResults)
    m_Refreshing = false

    m_Data = {}
    m_Entries = {}
    local m_EntryTime = {}
    local decodedFileCount = 0
    local duplicateEntries = {}
    local otherNames = {}
    local legacyEntries = {}
    if fileList ~= nil then
        for _, entry in ipairs(fileList) do
            if entry ~= nil and entry.Name ~= nil then
                local key, value = ParseFileName(entry.Name)
                if key ~= nil then
                    decodedFileCount = decodedFileCount + 1
                    if MODMISC_STORE_RETIRED_KEYS[key] then
                        -- 退役的测试键：不进内存表，直接排进删除队列
                        table.insert(legacyEntries, { name = StripExtension(entry.Name), entry = entry })
                        key = nil
                    end
                end
                if key ~= nil then
                    -- 同一个 key 可能有多份档（多次扫描各写一份、删旧档偶尔没跟上）：
                    -- 比修改时间，留最新的一份，其余排进删除队列
                    local timestamp = GetEntryTimestamp(entry)
                    if m_Entries[key] == nil then
                        m_Data[key] = value
                        m_Entries[key] = entry
                        m_EntryTime[key] = timestamp
                    else
                        local keepNew = false
                        if timestamp ~= nil and m_EntryTime[key] ~= nil then
                            keepNew = timestamp > m_EntryTime[key]
                        elseif timestamp ~= nil then
                            keepNew = true
                        end
                        if keepNew then
                            table.insert(duplicateEntries, { name = StripExtension(entry.Name), entry = m_Entries[key] })
                            m_Data[key] = value
                            m_Entries[key] = entry
                            m_EntryTime[key] = timestamp
                        else
                            table.insert(duplicateEntries, { name = StripExtension(entry.Name), entry = entry })
                        end
                    end
                else
                    table.insert(otherNames, tostring(entry.Name))
                    -- 本模块前缀但解不出来 = 老格式或坏档；外加已知的旧探针档，一并清理
                    local shortName = StripExtension(entry.Name)
                    if shortName ~= nil
                        and (shortName:sub(1, #MODMISC_STORE_PREFIX) == MODMISC_STORE_PREFIX
                             or shortName == MODMISC_STORE_LEGACY_NAME) then
                        table.insert(legacyEntries, { name = shortName, entry = entry })
                    end
                end
            end
        end
    end

    local listing = "(只有存储档)"
    if #otherNames > 0 then listing = table.concat(otherNames, ",") end
    local keyCount = 0
    for _ in pairs(m_Data) do keyCount = keyCount + 1 end
    Log("扫描完成 build=" .. MODMISC_STORE_BUILD_TAG
        .. "：存储档 " .. tostring(decodedFileCount) .. " 份"
        .. " → 去重后 " .. tostring(keyCount) .. " 个键"
        .. "；非存储档=[" .. listing .. "]")

    -- 把解出来的键值全打出来：一轮日志就能看清存储里到底有什么
    local pairs_text = {}
    for key, value in pairs(m_Data) do
        table.insert(pairs_text, tostring(key) .. "=" .. tostring(value))
    end
    table.sort(pairs_text)
    Log("  键值：" .. (#pairs_text > 0 and table.concat(pairs_text, " | ") or "(空)"))

    -- 清理遗留档与重复档
    if UI ~= nil and UI.DeleteSavedGame ~= nil then
        for _, item in ipairs(legacyEntries) do
            local ok = pcall(UI.DeleteSavedGame, item.entry)
            Log(ok and ("已清理遗留档 [" .. item.name .. "]")
                or ("清理遗留档 [" .. item.name .. "] 失败"))
        end
        if #duplicateEntries > 0 then
            local removed = 0
            for _, item in ipairs(duplicateEntries) do
                if pcall(UI.DeleteSavedGame, item.entry) then removed = removed + 1 end
            end
            Log("已清理重复档 " .. tostring(removed) .. "/" .. tostring(#duplicateEntries) .. " 份")
        end
    end

    if UI ~= nil and UI.CloseFileListQuery ~= nil and m_RefreshRequestId ~= nil then
        pcall(function() UI.CloseFileListQuery(m_RefreshRequestId) end)
    end
    m_RefreshRequestId = nil

    NotifyReady()

    -- 本次扫描的完成回调（Refresh(onDone)）
    local callbacks = m_RefreshCallbacks
    m_RefreshCallbacks = {}
    for _, callback in ipairs(callbacks) do
        pcall(callback)
    end
    if MODMISC_STORE_SELFTEST then ModMiscStore.RunSelfTest() end
end

-- onDone：本次扫描完成后回调一次（比 OnReady 精确 —— OnReady 已就绪时会立刻触发，
-- 拿到的可能是上一次扫描的旧数据）
function ModMiscStore.Refresh(onDone)
    if onDone ~= nil then
        table.insert(m_RefreshCallbacks, onDone)
    end
    if m_Refreshing then return false end
    if UI == nil or UI.QuerySaveGameList == nil or LuaEvents == nil
        or LuaEvents.FileListQueryResults == nil or SaveLocationOptions == nil then
        Log("扫描不可用（QuerySaveGameList / SaveLocationOptions 缺失）")
        return false
    end
    local configFile = BuildConfigFile(MODMISC_STORE_PREFIX .. "probe")
    if configFile == nil then
        Log("扫描不可用：存档表构建不了")
        return false
    end
    local options = SaveLocationOptions.NORMAL + SaveLocationOptions.QUICKSAVE
        + SaveLocationOptions.LOAD_METADATA
    LuaEvents.FileListQueryResults.Add(OnStoreQueryResults)
    m_Refreshing = true
    m_RefreshRequestId = UI.QuerySaveGameList(configFile.Location, configFile.Type,
        options, configFile.FileType, nil)
    Log("已发出存档列表扫描（找 " .. MODMISC_STORE_PREFIX .. " 前缀的档）")
    return true
end

function ModMiscStore.IsReady()
    return m_Ready
end

-- 是否有扫描正在进行。调用方（如 UI/ModMiscSaveGraph 的换图流程）用它区分
-- Refresh 返回 false 的两种含义：① 已有扫描在跑（回调会被调用）/ ② 依赖缺失（回调永远不来）。
function ModMiscStore.IsRefreshing()
    return m_Refreshing
end

function ModMiscStore.OnReady(callback)
    if callback == nil then return end
    if m_Ready then
        pcall(callback)
        return
    end
    table.insert(m_ReadyCallbacks, callback)
end

function ModMiscStore.Get(key)
    if key == nil then return nil end
    return m_Data[tostring(key)]
end

function ModMiscStore.GetAll()
    local copy = {}
    for key, value in pairs(m_Data) do
        copy[key] = value
    end
    return copy
end

-- ===========================================================================
-- 写：新档写出去 → 收到 SaveComplete 再删同 key 的旧档
-- ===========================================================================

local function OnStoreSaveComplete()
    Events.SaveComplete.Remove(OnStoreSaveComplete)
    if UI == nil or UI.DeleteSavedGame == nil then return end
    for key, entry in pairs(m_PendingDelete) do
        local ok, err = pcall(UI.DeleteSavedGame, entry)
        if ok then
            Log("已删除 [" .. tostring(key) .. "] 的旧档")
        else
            Log("删除 [" .. tostring(key) .. "] 旧档失败 -> " .. tostring(err))
        end
    end
    m_PendingDelete = {}
end

function ModMiscStore.Save(key, value)
    if key == nil then
        Log("Save 失败：key 为 nil")
        return false
    end
    if Network == nil or Network.SaveGame == nil then
        Log("Save 失败：Network.SaveGame 不可用")
        return false
    end
    local text = tostring(value)
    local maxBytes = ComputeMaxValueBytes(key)
    if #text > maxBytes then
        Log("Save 失败：值太长（" .. tostring(#text) .. " > " .. tostring(maxBytes)
            .. " 字节；键 " .. tostring(key) .. " 按文件名长度算出来的上限）"
            .. "—— 大块数据请用 ModMiscStore.SaveBlob（自动分片）")
        return false
    end

    local name = BuildFileName(key, text)
    local configFile = BuildConfigFile(name)
    if configFile == nil then
        Log("Save 失败：存档表构建不了")
        return false
    end

    local ok, err = pcall(Network.SaveGame, configFile)
    if not ok then
        Log("Save 失败 -> " .. tostring(err))
        return false
    end

    -- 内存表立刻更新；旧档等 SaveComplete 再删（写失败也不丢）
    m_Data[tostring(key)] = text
    local oldEntry = m_Entries[tostring(key)]
    -- 顺手把“刚写的这份档”也记进 m_Entries：这样在同一次会话里马上 Remove 这个键也能删掉，
    -- 不用等下一次扫描（没有这条记录时 Remove 会以“没找到这个键的档”为由拒绝）
    m_Entries[tostring(key)] = {
        Name = configFile.Name .. ".Civ6Cfg",
        Location = configFile.Location,
        Type = configFile.Type,
        FileType = configFile.FileType,
        Directory = configFile.Directory,
    }
    if oldEntry ~= nil then
        m_PendingDelete[tostring(key)] = oldEntry
        if Events ~= nil and Events.SaveComplete ~= nil then
            Events.SaveComplete.Remove(OnStoreSaveComplete)
            Events.SaveComplete.Add(OnStoreSaveComplete)
        end
    end

    Log("已请求写入 [" .. tostring(key) .. "] = [" .. text .. "]")
    return true
end

-- 删除一个键（连同它的档）
function ModMiscStore.Remove(key)
    if key == nil then return false end
    local name = tostring(key)
    local entry = m_Entries[name]
    m_Data[name] = nil
    m_Entries[name] = nil
    if entry == nil then
        Log("Remove [" .. name .. "]：没找到这个键的档（可能还没扫描过）")
        return false
    end
    if UI == nil or UI.DeleteSavedGame == nil then return false end
    local ok, err = pcall(UI.DeleteSavedGame, entry)
    Log(ok and ("已删除 [" .. name .. "]") or ("删除 [" .. name .. "] 失败 -> " .. tostring(err)))
    return ok
end

-- 清空整张存储（删掉所有键的档）
-- ===========================================================================
-- 分片大对象（blob）：把任意长度的文本切成若干小片存进来
--
--   SaveBlob(key, text)   →  <key>$0, <key>$1, … 每片 ≤ 每键上限；最后写 <key>$m 元数据
--   LoadBlob(key)         →  按元数据拼回完整文本；缺片会明确报出来（不返回半截数据）
--   RemoveBlob(key)       →  连元数据一起删
--   GetBlobInfo(key)      →  { Chunks, Bytes, Missing = {…} }
--
-- 为什么先写片、最后写元数据：**元数据在 = 这个 blob 完整**；写到一半失败时，
-- 旧 blob 的元数据还在（读取方不会拿到半截新数据）。改写时多余的旧片会被删掉。
-- 片数 = ceil(字节数 / 每片上限)；每片上限还会按 ComputeMaxValueBytes 再夹一次。
-- 代价：一个 blob 会占 N 个小档（玩家的「载入配置」列表里会多出几个），
-- 所以它是“中等大小数据”的通道；**特别大的表格请用载体存档那条路**（见 API 文档 3.13.7）。
-- ===========================================================================

local function BlobMetaKey(key) return tostring(key) .. MODMISC_STORE_BLOB_META_SUFFIX end
local function BlobChunkKey(key, index)
    return tostring(key) .. MODMISC_STORE_BLOB_CHUNK_SUFFIX .. tostring(index)
end

local function ParseBlobMeta(key)
    local value = ModMiscStore.Get(BlobMetaKey(key))
    if value == nil then return nil end
    local chunks, bytes = tostring(value):match("^(%d+)|(%d+)$")
    if chunks == nil then return nil end
    return tonumber(chunks), tonumber(bytes)
end

function ModMiscStore.SaveBlob(key, text)
    if key == nil then
        Log("SaveBlob 失败：key 为 nil")
        return false
    end
    local payload = tostring(text or "")
    local chunkSize = MODMISC_STORE_BLOB_CHUNK_BYTES
    -- 每个分片键的实际上限（键名比基础键长一点）
    local perChunk = ComputeMaxValueBytes(BlobChunkKey(key, 99999))
    if perChunk < chunkSize then chunkSize = perChunk end
    if chunkSize < 8 then
        Log("SaveBlob 失败：键太长，" .. tostring(key) .. " 连一小片都放不下")
        return false
    end

    local oldChunks = ParseBlobMeta(key) or 0
    local total = #payload
    local count = math.ceil(total / chunkSize)
    if total == 0 then count = 0 end

    -- ① 先写数据片
    for index = 0, count - 1 do
        local chunk = payload:sub(index * chunkSize + 1, (index + 1) * chunkSize)
        if not ModMiscStore.Save(BlobChunkKey(key, index), chunk) then
            Log("SaveBlob 失败：第 " .. tostring(index) .. " 片写不进去")
            return false
        end
    end
    -- ② 多余的旧片删掉
    for index = count, oldChunks - 1 do
        ModMiscStore.Remove(BlobChunkKey(key, index))
    end
    -- ③ 最后写元数据（写完才算这个 blob 完整）
    local ok = ModMiscStore.Save(BlobMetaKey(key), tostring(count) .. "|" .. tostring(total))
    Log("SaveBlob [" .. tostring(key) .. "]：" .. tostring(total) .. " 字节 → "
        .. tostring(count) .. " 片（每片 ≤ " .. tostring(chunkSize) .. " 字节）结果=" .. tostring(ok))
    return ok
end

function ModMiscStore.GetBlobInfo(key)
    local chunks, bytes = ParseBlobMeta(key)
    if chunks == nil then return nil end
    local missing = {}
    for index = 0, chunks - 1 do
        local value = ModMiscStore.Get(BlobChunkKey(key, index))
        if value == nil then table.insert(missing, index) end
    end
    return { Chunks = chunks, Bytes = bytes, Missing = missing }
end

function ModMiscStore.LoadBlob(key)
    local info = ModMiscStore.GetBlobInfo(key)
    if info == nil then
        Log("LoadBlob [" .. tostring(key) .. "]：没有元数据（这个 blob 不存在 / 没写完整）")
        return nil, "no-meta"
    end
    if #info.Missing > 0 then
        Log("LoadBlob [" .. tostring(key) .. "]：缺 " .. tostring(#info.Missing) .. " 片 → 不返回半截数据")
        return nil, "missing-chunks:" .. table.concat(info.Missing, ",")
    end
    local parts = {}
    for index = 0, info.Chunks - 1 do
        table.insert(parts, tostring(ModMiscStore.Get(BlobChunkKey(key, index)) or ""))
    end
    local text = table.concat(parts)
    Log("LoadBlob [" .. tostring(key) .. "]：读回 " .. tostring(#text) .. " 字节（"
        .. tostring(info.Chunks) .. " 片）")
    return text
end

function ModMiscStore.RemoveBlob(key)
    if key == nil then return 0 end
    local chunks = ParseBlobMeta(key) or 0
    local removed = 0
    for index = 0, chunks - 1 do
        if ModMiscStore.Remove(BlobChunkKey(key, index)) then removed = removed + 1 end
    end
    if ModMiscStore.Remove(BlobMetaKey(key)) then removed = removed + 1 end
    Log("RemoveBlob [" .. tostring(key) .. "]：清掉 " .. tostring(removed) .. " 个档")
    return removed
end

function ModMiscStore.ComputeMaxValueBytes(key)
    return ComputeMaxValueBytes(key)
end

function ModMiscStore.RemoveAll()
    local keys = {}
    for key in pairs(m_Data) do
        table.insert(keys, key)
    end
    if #keys == 0 then
        Log("RemoveAll：内存表是空的（可能还没扫描过）")
        return 0
    end
    local removed = 0
    for _, key in ipairs(keys) do
        if ModMiscStore.Remove(key) then removed = removed + 1 end
    end
    Log("RemoveAll：已清空 " .. tostring(removed) .. "/" .. tostring(#keys) .. " 个键")
    return removed
end

-- ===========================================================================
-- 自检（测试期）：每轮写一份带 t/r 的 payload，并报告上一轮读到什么
-- ===========================================================================

function ModMiscStore.RunSelfTest()
    if not MODMISC_STORE_SELFTEST then return end
    local previous = m_Data["selftest"]
    if previous ~= nil then
        Log("自检：读到上一轮存的 [" .. tostring(previous) .. "] ⇒ 跨存档通道成立")
    else
        Log("自检：没有上一轮的值")
    end
    ModMiscStore.Save("selftest", "ms=1;t=" .. tostring(os.time())
        .. ";r=" .. tostring(math.random(100000, 999999)))
end
