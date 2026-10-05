-- ===========================================================================
-- Mod Misc Tool: 跨“本档内”数据存取（gameplay 侧公开 API）
--
-- 【只看这一页就够的规则】本文件现在**不自己拼键、不自己拼串**，一律走通用数据协议
-- （UI/ModMiscDataProtocol.lua + UI/ModMiscDataRegistry.lua，2026-10-05 迁移）：
--   * 键：`ds_<你的 key>`（登记项 `ds_*`，**通配** ⇒ 任意 key 都能用，不要求逐个登记）；
--   * 生命周期：**persave**（随档：存档带走、读档还原、**新局不继承**）；
--   * 通道：**property** = `Game:SetProperty/GetProperty`（gameplay 专用，UI 端没有这个 API）；
--   * 值：数字 / 字符串 / 表都行 —— 协议负责编解码（数字按 %.17g 精确还原、表支持嵌套/共享引用），
--         还会带数据集名与校验和（读到别人家的数据/内容被改都会明确报出来）。
--
-- 【能力边界 —— 授权者既有 mod 制作经验，2026-10-04 确认；2026-10-05 迁移后不变】
--   ✅ **随存档落盘**：写完之后存档，读这个档能原样读回。
--   ❌ **不可跨存档**：数据属于那一份存档；别的档、以及新开的一局都读不到。
--   ❌ **与 UI 侧互不可见**：UI 用 WriteCustomData 写的东西，这里读不到；反之亦然
--      （两个独立存储。UI 侧请用 Support_UI 的 SetModMiscCustomData/GetModMiscCustomData，
--        它们走协议的 `save` 通道；本文件走 `property`）
--   要跨存档请用跨存档那几条通道（small/big/carrier，见 API_Verification_Status §18/§19）。
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

-- include 用“不带路径、不带扩展名”的写法（本项目一贯做法：VFS 按文件名解析）
include("ModMiscDataProtocol")          -- 通用数据协议（序列化 / 生命周期 / 通道 / 审计）
include("ModMiscDataRegistry")          -- 数据登记表（没登记的键写不进去）

local MODMISC_DATASTORE_BUILD_TAG = "2026-10-05-B"
local MODMISC_DATA_KEY_PREFIX = "ds_"
local MODMISC_DATA_PROBE_KEY = "ds_probe"

local function Log(message)
    print("[ModMiscTool][DataStore] " .. message)
end

-- 取时钟要包起来：gameplay 侧不保证一定有 os（取不到就写 0，别把探针搞崩）
local function NowSeconds()
    local ok, value = pcall(function() return os.time() end)
    if ok and tonumber(value) ~= nil then return tonumber(value) end
    return 0
end

ModMiscToolData = ModMiscToolData or {}
ModMiscToolData.BuildTag = MODMISC_DATASTORE_BUILD_TAG

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
    if DataProtocol == nil then
        Log("Set 失败：数据协议没加载")
        return false
    end
    local ok, err = DataProtocol.Save(ModMiscToolData.BuildKey(key), value)
    if not ok then
        Log("Set 失败 key=" .. tostring(key) .. " -> " .. tostring(err))
        return false
    end
    return true
end

-- 读：没存过 → nil
function ModMiscToolData.Get(key)
    if key == nil or DataProtocol == nil then return nil end
    local value, err = DataProtocol.Load(ModMiscToolData.BuildKey(key))
    if value == nil and err ~= nil and tostring(err):find("没有这份数据") == nil
        and tostring(err):find("没有这个键") == nil then
        Log("Get 说明 key=" .. tostring(key) .. " -> " .. tostring(err))
    end
    return value
end

function ModMiscToolData.Has(key)
    return ModMiscToolData.Get(key) ~= nil
end

-- 清掉一个键（协议内部对 property 通道就是写 nil）
function ModMiscToolData.Remove(key)
    if key == nil or DataProtocol == nil then return false end
    return DataProtocol.Remove(ModMiscToolData.BuildKey(key)) and true or false
end

-- ===========================================================================
-- 开局探针：只读一次、读不到才写一份，结论看日志
-- 协议：开局1（读到空 → 写 P1）→ 存档 → 读这个档 → 应当读到 P1
-- ===========================================================================

local function RunDataStoreProbe()
    -- 顺带测一条边界：UI 侧（走协议 save 通道 = CustomData）写的东西，
    -- gameplay 侧用 property 通道读同一个键读不读得到？预期读不到（两个独立存储）。
    -- 那个键由 UI/Support_UI.lua 的开局探针每次进游戏写入，所以这里必定有值可比。
    local uiSideValue = nil
    if Game ~= nil and Game.GetProperty ~= nil then
        local ok = pcall(function() uiSideValue = Game:GetProperty("svprobe") end)
        if ok then
            Log("startup: gameplay 读 UI 那条键（svprobe）-> " .. tostring(uiSideValue)
                .. "（预期 nil = 两个存储互不可见）")
        end
    end

    local previous = ModMiscToolData.Get(MODMISC_DATA_PROBE_KEY)
    if previous ~= nil then
        Log("startup: 读到 " .. (type(previous) == "table"
            and ("[t=" .. tostring(previous.At) .. ";turn=" .. tostring(previous.Turn)
                 .. ";r=" .. tostring(previous.Nonce) .. "]") or ("[" .. tostring(previous) .. "]"))
            .. " —— 随存档带回来的值（只证明“本档内持久”，不代表跨存档）")
        return
    end

    local turn = 0
    local ok, turnValue = pcall(function() return Game.GetCurrentGameTurn() end)
    if ok and turnValue ~= nil then turn = turnValue end

    local probe = { At = NowSeconds(), Nonce = math.random(100000, 999999), Turn = turn }
    if ModMiscToolData.Set(MODMISC_DATA_PROBE_KEY, probe) then
        Log("startup: 没读到 → 已写入 [t=" .. tostring(probe.At) .. ";r=" .. tostring(probe.Nonce)
            .. ";turn=" .. tostring(probe.Turn)
            .. "]（新档/新局本来就没有这份数据，属预期）")
    end
end

Events.LoadGameViewStateDone.Add(RunDataStoreProbe)

-- 模块加载横幅：gameplay 上下文一加载就打，用来确认这个文件到底有没有上机
-- （比等开局探针更早，部署核对时看这一行最省事）
print("[ModMiscTool][DataStore] module loaded build=" .. MODMISC_DATASTORE_BUILD_TAG)
