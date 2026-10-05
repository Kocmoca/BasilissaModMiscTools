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
-- 【安全规矩】**只碰自己前缀 `MMTSTORE~` 的组**；**永不删除当前选中的组**
--   （哪怕它的名字碰巧带我们的前缀 —— 宁可漏删，也不能把玩家正在用的配置组删掉）；
--   所有引擎调用一律 pcall 包住，失败只记日志、不抛异常。
--
-- 【对玩家的可见影响】每个数据片 = 模组界面下拉框里的一条配置组。
--   建组时会把“当前组”的启用项复制过去 ⇒ 即使它被选中，启用集合也跟原来一样（不会把 mod 关掉）。
--   面板上给了「清理」按钮，测试完请点掉；正式使用前要先想好“玩家会看到什么”。
-- ===========================================================================

local MODGROUP_STORE_BUILD_TAG = "2026-10-05-A"

local MODGROUP_PREFIX = "MMTSTORE~"        -- 我们的组名前缀，也是唯一的“这是我们的数据”判据
local MODGROUP_PROBE_KEY = "probe"         -- 自检用的 key
local MODGROUP_DEFAULT_CHUNK_BYTES = 600   -- 每片原始字节数（hex 后 ×2 = 1200 字符）
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

-- ===========================================================================
-- 对外接口
-- ===========================================================================

ModMiscModGroupStore = ModMiscModGroupStore or {}
ModMiscModGroupStore.BuildTag = MODGROUP_STORE_BUILD_TAG
ModMiscModGroupStore.Prefix = MODGROUP_PREFIX
ModMiscModGroupStore.DefaultChunkBytes = MODGROUP_DEFAULT_CHUNK_BYTES
ModMiscModGroupStore.ProbeKey = MODGROUP_PROBE_KEY

function ModMiscModGroupStore.IsAvailable()
    if Modding == nil or Modding.GetModGroups == nil then return false end
    if Modding.CreateModGroup == nil or Modding.DeleteModGroup == nil then return false end
    if EncodeText("x") == nil or DecodeText("78") == nil then return false end
    return true
end

-- 列出全部组：{ Handle, Name, CanDelete, SortIndex, Ours, Key, Index, IsCurrent }
function ModMiscModGroupStore.List()
    local groups, reason = GetGroupsRaw()
    if groups == nil then return nil, reason end
    local current = GetCurrentGroup()
    local out = {}
    for _, group in ipairs(groups) do
        if type(group) == "table" then
            local parsed = ParseGroupName(group.Name)
            table.insert(out, {
                Handle = group.Handle,
                Name = tostring(group.Name),
                CanDelete = group.CanDelete,
                SortIndex = group.SortIndex,
                Ours = parsed ~= nil,
                Key = parsed ~= nil and parsed.Key or nil,
                Index = parsed ~= nil and parsed.Index or nil,
                IsCurrent = (group.Handle == current),
            })
        end
    end
    return out
end

function ModMiscModGroupStore.ListOurs()
    local groups, reason = ModMiscModGroupStore.List()
    if groups == nil then return nil, reason end
    local ours = {}
    for _, group in ipairs(groups) do
        if group.Ours then table.insert(ours, group) end
    end
    table.sort(ours, function(a, b)
        if a.Key == b.Key then return a.Index < b.Index end
        return tostring(a.Key) < tostring(b.Key)
    end)
    return ours
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
    for _, group in ipairs(groups) do
        if group.Ours then info.Ours = info.Ours + 1 end
        if #group.Name > info.MaxNameLength then info.MaxNameLength = #group.Name end
        if group.IsCurrent then
            info.CurrentHandle = group.Handle
            info.CurrentName = group.Name
        end
    end
    return info
end

-- 删除某个 key 的所有片（当前选中的组永不删）
local function RemoveByKey(key, onlyKey)
    local ours, reason = ModMiscModGroupStore.ListOurs()
    if ours == nil then return nil, reason end
    local removed, skipped = 0, 0
    for _, group in ipairs(ours) do
        if (not onlyKey) or tostring(group.Key) == tostring(key) then
            if group.IsCurrent then
                skipped = skipped + 1
                Log("跳过：这个组正被选中，不能删 -> " .. group.Name)
            else
                local ok = pcall(function() return Modding.DeleteModGroup(group.Handle) end)
                if ok then
                    removed = removed + 1
                else
                    Log("删除失败 -> " .. group.Name)
                end
            end
        end
    end
    return removed, nil, skipped
end

function ModMiscModGroupStore.Remove(key)
    return RemoveByKey(key, true)
end

-- 清掉本 mod 的所有数据组（测试后收摊用）
function ModMiscModGroupStore.ClearAll()
    return RemoveByKey(nil, false)
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

    local removed, reason = RemoveByKey(key, true)
    if removed == nil then return false, reason end

    local current = GetCurrentGroup()
    local created = 0
    for i, chunk in ipairs(chunks) do
        local name = BuildGroupName(key, i, chunk)
        local ok, err = pcall(function() return Modding.CreateModGroup(name, current) end)
        if not ok then
            return false, "第 " .. tostring(i) .. " 片建组失败: " .. tostring(err)
        end
        created = created + 1
    end

    -- 复查：名字都回来了才算写成
    local ours = ModMiscModGroupStore.ListOurs() or {}
    local seen = 0
    for _, group in ipairs(ours) do
        if tostring(group.Key) == key then seen = seen + 1 end
    end
    Log("Save key=" .. key .. " 字节=" .. tostring(#text) .. " 片=" .. tostring(created)
        .. " 复查到=" .. tostring(seen))
    if seen < created then
        return false, "复查只看到 " .. tostring(seen) .. "/" .. tostring(created) .. " 片"
    end
    return true, created, #text
end

-- 读一个 key：片按序号拼回；缺片直接拒绝（不返回半截数据）
function ModMiscModGroupStore.Load(key)
    if not ModMiscModGroupStore.IsAvailable() then
        return nil, "Modding 组接口不可用（或 hex 工具没加载）"
    end
    key = tostring(key)
    local ours, reason = ModMiscModGroupStore.ListOurs()
    if ours == nil then return nil, reason end

    local byIndex = {}
    local count = 0
    for _, group in ipairs(ours) do
        if tostring(group.Key) == key then
            byIndex[group.Index] = group
            count = count + 1
        end
    end
    if count == 0 then return nil, "没有这个 key" end

    local parts = {}
    for i = 1, count do
        local group = byIndex[i]
        if group == nil then return nil, "缺第 " .. tostring(i) .. " 片" end
        local parsed = ParseGroupName(group.Name)
        local text = DecodeText(parsed.PayloadHex)
        if text == nil then return nil, "第 " .. tostring(i) .. " 片解码失败" end
        table.insert(parts, text)
    end
    local text = table.concat(parts)
    Log("Load key=" .. key .. " 片=" .. tostring(count) .. " 字节=" .. tostring(#text))
    return text, count
end

-- 自检：按尺寸阶梯写→读→逐字节比对，找出“能完整往返”的上限，然后清理
function ModMiscModGroupStore.SelfTest(sizes)
    sizes = sizes or { 8, 64, 256, 1024, 4096, 16384 }
    local report = { Tag = MODGROUP_STORE_BUILD_TAG, Steps = {}, Available = ModMiscModGroupStore.IsAvailable() }
    if not report.Available then
        report.Error = "Modding 组接口不可用"
        return report
    end

    local currentBefore = GetCurrentGroup()
    for _, size in ipairs(sizes) do
        -- 可读的测试内容（重复字符 + 首尾标记，肉眼也能看出截断/串位）
        local payload = "<" .. tostring(size) .. ">" .. string.rep("A", math.max(0, size - 8)) .. "</e>"
        local step = { Size = size }
        local ok, chunks, written = ModMiscModGroupStore.Save(MODGROUP_PROBE_KEY, payload,
            MODGROUP_DEFAULT_CHUNK_BYTES)
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
    local removed, reason, skipped = ModMiscModGroupStore.ClearAll()
    report.CleanupRemoved = removed
    report.CleanupSkipped = skipped
    report.CleanupError = reason
    local currentAfter = GetCurrentGroup()
    report.CurrentGroupUnchanged = (currentBefore == currentAfter)
    report.CurrentBefore = currentBefore
    report.CurrentAfter = currentAfter
    return report
end
