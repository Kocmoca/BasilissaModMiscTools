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

local MODGROUP_STORE_BUILD_TAG = "2026-10-05-A"

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

-- 要删“当前选中的组”时，得先把选中挪到别的组（原版 DeleteModGroup() 就是这么做的）。
-- 挑法：**不挑我们自己的组**（免得把选中留在一堆数据组里），优先挑不可删的那个默认组。
local function PickFallbackGroup(excludeHandle)
    local groups = GetGroupsRaw()
    if groups == nil then return nil end
    local firstOther = nil
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.Handle ~= excludeHandle then
            if group.CanDelete == false or group.CanDelete == 0 then
                return group.Handle                     -- 默认组：最稳的落脚点
            end
            if firstOther == nil and ParseGroupName(group.Name) == nil then
                firstOther = group.Handle               -- 退而求其次：别的非数据组
            end
        end
    end
    if firstOther ~= nil then return firstOther end
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.Handle ~= excludeHandle then
            return group.Handle                         -- 实在没有就随便挑一个别的
        end
    end
    return nil
end

local function GroupExists(handle)
    if handle == nil then return false end
    local groups = GetGroupsRaw()
    if groups == nil then return false end
    for _, group in ipairs(groups) do
        if type(group) == "table" and group.Handle == handle then return true end
    end
    return false
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
    return info
end

-- 删除某个 key 的所有片（当前选中的组永不删）
-- 删除本 mod 的组；选中组先切走再删（原版做法）；originHandle 是“玩家的选中组”，删完恢复
local function RemoveByKey(key, onlyKey, originHandle)
    local ours, reason = ModMiscModGroupStore.ListOurs()
    if ours == nil then return nil, reason end
    local removed, failed = 0, 0
    for _, group in ipairs(ours) do
        local targeted = (not onlyKey) or tostring(group.Key) == tostring(key)
        if targeted then
            -- 引擎不让我们删“当前选中的组”⇒ 先把选中挪到别的组（原版做法）
            local canDelete = true
            if group.IsCurrent then
                local fallback = PickFallbackGroup(group.Handle)
                Log("要删的组正被选中，先把选中切到 handle=" .. tostring(fallback))
                canDelete = SetCurrentGroup(fallback)
                if not canDelete then
                    failed = failed + 1
                    Log("切走失败，跳过 -> " .. group.Name)
                end
            end
            if canDelete then
                local ok = pcall(function() return Modding.DeleteModGroup(group.Handle) end)
                if ok then
                    removed = removed + 1
                else
                    failed = failed + 1
                    Log("删除失败 -> " .. group.Name)
                end
            end
        end
    end
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
    local groups = ModMiscModGroupStore.List()
    if groups == nil then return false end
    for _, group in ipairs(groups) do
        if group.Handle == handle then return group.Ours end
    end
    return false
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

    -- 记住玩家原本选中的组：CreateModGroup **会把新组设为选中**（实机教训 ①），写完全恢复
    local origin = GetCurrentGroup()
    local removed, reason = RemoveByKey(key, true, origin)
    if removed == nil then return false, reason end

    local source = GetCurrentGroup()
    local expected = {}
    local created = 0
    for i, chunk in ipairs(chunks) do
        local name = BuildGroupName(key, i, chunk)
        expected[name] = true
        -- 以“当前组”为模板复制启用项：来源组要是我们的数据组也没关系（启用集合一样）
        local ok, err = pcall(function() return Modding.CreateModGroup(name, source) end)
        if not ok then
            SettleSelection(origin, "Save(失败后)")
            return false, "第 " .. tostring(i) .. " 片建组失败: " .. tostring(err)
        end
        created = created + 1
    end
    -- 引擎把选中挪到了最后建的那个组 ⇒ 立刻收尾（恢复玩家的组，或落到一个正常组）
    local restored = SettleSelection(origin, "Save")

    -- 精确复查：**按名字逐个核对**，并数一数有没有同 key 同序号的重复片
    local ours = ModMiscModGroupStore.ListOurs() or {}
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
    key = tostring(key)
    local ours, reason = ModMiscModGroupStore.ListOurs()
    if ours == nil then return nil, reason end

    local byIndex = {}
    local count, duplicated = 0, 0
    for _, group in ipairs(ours) do
        if tostring(group.Key) == key then
            if byIndex[group.Index] ~= nil then duplicated = duplicated + 1 end
            byIndex[group.Index] = group
            count = count + 1
        end
    end
    if count == 0 then return nil, "没有这个 key" end
    if duplicated > 0 then
        -- 实机踩过：CreateModGroup 抢走选中 ⇒ 旧片删不掉 ⇒ 同序号两份 ⇒ 拼出来是错的
        return nil, "有 " .. tostring(duplicated) .. " 个重复片（同 key 同序号）——先点清理再写"
    end

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
        local ok, err = pcall(function() return Modding.CreateModGroup(name, source) end)
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
