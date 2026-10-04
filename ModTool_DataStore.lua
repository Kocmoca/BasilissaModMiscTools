-- ===========================================================================
-- Mod Misc Tool: 跨存档数据存取（gameplay 侧公开 API）
--
-- 【为什么只能用 Game:SetProperty】
--   对局内要“存数据”且**自动落盘**，唯一途径是 `Game:SetProperty` —— 它是游戏状态
--   的一部分，存档即带走、读档自动还原（幽灵池就是这么存的，已验证）。
--   `Game:SetProperty` 是 **gameplay 专用**：UI 端用不了（授权者确认）。
--   UI 侧想存只能 `WriteCustomData`，而且**写完必须再存一次档**才落盘，
--   见 UI/Support_UI.lua 的 SetCustomData / GetCustomData。
--
-- 【命名空间】所有键统一加前缀，避免和别的 mod 撞键。
-- 【值的类型】数字 / 字符串 / 表都可以（幽灵池存的就是一张 id 表）。
--
-- 公开 API（本 mod 内直接调；外部 mod 走 ExposedMembers.ModMiscToolScript）：
--   SetData(key, value) / GetData(key) / HasData(key) / RemoveData(key)
--   BuildKey(key)  —— 需要自己拼键（例如存多份带后缀的数据）时用
--
-- 【开局探针】每次进游戏读一次探针键并打日志（只打日志，不做别的），
-- 用来验证「对局内写 → 存档 → 读档读回」这条链：
--   [ModMiscTool][DataStore] startup: 读到 [...]            ← 存档带回来的值
--   [ModMiscTool][DataStore] startup: 没读到 → 已写入 [...]  ← 本局第一次写
-- ===========================================================================

local MODMISC_DATA_KEY_PREFIX = "kocmoca_modmisctool_"
local MODMISC_DATA_PROBE_KEY = "datastore_probe"

local function Log(message)
    print("[ModMiscTool][DataStore] " .. message)
end

ModMiscToolData = ModMiscToolData or {}

-- 键拼装：外部要自己拼键时也走这里，保证前缀一致
function ModMiscToolData.BuildKey(key)
    return MODMISC_DATA_KEY_PREFIX .. tostring(key)
end

-- 写：返回 true / false（false 时日志里带原因）
function ModMiscToolData.Set(key, value)
    if key == nil then
        Log("Set 失败：key 为 nil")
        return false
    end
    local ok, err = pcall(function()
        Game:SetProperty(ModMiscToolData.BuildKey(key), value)
    end)
    if not ok then
        Log("Set 失败 key=" .. tostring(key) .. " -> " .. tostring(err))
        return false
    end
    return true
end

-- 读：没存过 → nil
function ModMiscToolData.Get(key)
    if key == nil then return nil end
    local ok, value = pcall(function()
        return Game:GetProperty(ModMiscToolData.BuildKey(key))
    end)
    if not ok then
        Log("Get 失败 key=" .. tostring(key) .. " -> " .. tostring(value))
        return nil
    end
    return value
end

function ModMiscToolData.Has(key)
    return ModMiscToolData.Get(key) ~= nil
end

-- 清掉一个键：把 nil 写回去。
-- [未验证] 引擎是否把 nil 视为“删除”还没实测 —— 先按删除用，实测后再改注释。
function ModMiscToolData.Remove(key)
    return ModMiscToolData.Set(key, nil)
end

-- ===========================================================================
-- 开局探针：只读一次、读不到才写一份，结论看日志
-- 协议：开局1（读到空 → 写 P1）→ 存档 → 读这个档 → 应当读到 P1
-- ===========================================================================

local function RunDataStoreProbe()
    local previous = ModMiscToolData.Get(MODMISC_DATA_PROBE_KEY)
    if previous ~= nil then
        Log("startup: 读到 [" .. tostring(previous)
            .. "] —— 这是随存档带回来的值（对局内存数据闭环的直接证据）")
        return
    end

    local turn = 0
    local ok, turnValue = pcall(function() return Game.GetCurrentGameTurn() end)
    if ok and turnValue ~= nil then turn = turnValue end

    local payload = "ds=1;t=" .. tostring(os.time())
        .. ";r=" .. tostring(math.random(100000, 999999))
        .. ";turn=" .. tostring(turn)
    if ModMiscToolData.Set(MODMISC_DATA_PROBE_KEY, payload) then
        Log("startup: 没读到 → 已写入 [" .. payload
            .. "]；存档后再读这个档，下一行应当原样读到它")
    end
end

Events.LoadGameViewStateDone.Add(RunDataStoreProbe)
