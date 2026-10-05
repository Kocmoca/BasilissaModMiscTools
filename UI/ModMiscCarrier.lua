-- ===========================================================================
-- Mod Misc Tool: 载体存档（大块数据跨存档通道，UI 层）
--
-- 【为什么需要它】配置档名编码通道（UI/ModMiscStore.lua）一个键只能塞 ~100 字节
-- （文件名 255 字节上限，hex 后翻倍），大表格得分片成成百上千个小档 —— 不现实。
-- 载体存档把**整块数据写进 CustomData**（它随普通存档序列化、读档原样还原，第 21 条），
-- 再存一份普通档当载体 ⇒ 一份档带走一整张表。
--
-- 【代价】（必须让使用方知道）
--   * 载体是一份**完整的普通存档**（几 MB），不是小文件；
--   * 读取要**载入**那份载体档（会顶掉当前局；对局内读档已验证可用，见第 38 条）；
--   * CustomData 本身能吃下 KB 级文本（本 mod 的永久放置就是越长越长的字符串），
--     但没有公开的硬上限 —— 超大表建议自己再做一次分批。
--
-- 【协议】
--   发送方： ModMiscCarrier.Write("battle_table", text)
--            → CustomData 键 ModMiscCarrier_battle_table = text
--            → 存一份档名 MMTBlob~battle_table~<stamp> 的普通档
--   接收方： 载入那份载体档之后 ModMiscCarrier.Read("battle_table") 拿到完整文本
--   载体档不会被当成关系树节点（树只认 MMT~ 前缀 + 至少 7 段，见 ModMiscSaveGraph）
--
-- 公开 API（本 mod 内直接调；外部走 ExposedMembers.ModMiscToolUI.Carrier）：
--   Write(name, text)      写载荷 + 存载体档（返回 ok, 档名）
--   Read(name)             读载荷（返回文本或 nil）
--   Peek()                 本局里有哪些载荷（{ {Name, Bytes}, … }）
--   Clear(name)            清一个载荷（CustomData）
--   BuildCarrierName(name) / ParseCarrierName(rawName)   档名构造 / 识别
-- ===========================================================================

local MODMISC_CARRIER_BUILD_TAG = "2026-10-05-A"
local MODMISC_CARRIER_FILE_PREFIX = "MMTBlob"
local MODMISC_CARRIER_CD_PREFIX = "ModMiscCarrier_"
local MODMISC_CARRIER_SEP = "~"

local function Log(message)
    print("[ModMiscTool][Carrier] " .. tostring(message))
end

ModMiscCarrier = ModMiscCarrier or {}
local API = ModMiscCarrier
API.BuildTag = MODMISC_CARRIER_BUILD_TAG
API.FilePrefix = MODMISC_CARRIER_FILE_PREFIX

local function TryCall(getter)
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter)
    if not ok then return nil end
    return value
end

local function SanitizeToken(text)
    if text == nil then return "_" end
    local cleaned = tostring(text):gsub("[%%\"<>|/\\*%?:~\r\n\t]", "_"):gsub("%s+", "_")
    if cleaned == "" then return "_" end
    return cleaned
end

local function BuildStamp()
    local ok, text = pcall(function() return os.date("%Y%m%d-%H%M") end)
    if ok and text ~= nil and tostring(text) ~= "" then return SanitizeToken(text) end
    return tostring(TryCall(function() return os.time() end) or 0)
end

-- 记下本进程写过的载荷名（Peek 用；CustomData 没有“列出所有键”的接口）
-- ⚠️ 必须声明在 API.Write 之前：Lua 5.1 里 local function 不前置声明的话，
--    函数体内的引用会被解析成全局 nil（本项目反复踩过）。
local m_KnownNames = {}
API.KnownNames = m_KnownNames

local function RememberName(name)
    local text = tostring(name or "")
    if text == "" then return end
    for _, existing in ipairs(m_KnownNames) do
        if existing == text then return end
    end
    table.insert(m_KnownNames, text)
end

-- 档名：MMTBlob~<载荷名>~<时间>
function API.BuildCarrierName(name)
    return MODMISC_CARRIER_FILE_PREFIX .. MODMISC_CARRIER_SEP .. SanitizeToken(name)
        .. MODMISC_CARRIER_SEP .. BuildStamp()
end

-- 认出“这是不是一份载体档”，是的话返回载荷名
function API.ParseCarrierName(rawName)
    if rawName == nil then return nil end
    local text = tostring(rawName):gsub("%.Civ6Save$", ""):gsub("%.Civ6Cfg$", "")
    if text:sub(1, #MODMISC_CARRIER_FILE_PREFIX) ~= MODMISC_CARRIER_FILE_PREFIX then return nil end
    local body = text:sub(#MODMISC_CARRIER_FILE_PREFIX + 2)   -- 跳过前缀与分隔符
    local name = body:match("^([^" .. MODMISC_CARRIER_SEP .. "]+)")
    if name == nil or name == "" then return nil end
    return name
end

function API.Write(name, text)
    if name == nil or tostring(name) == "" then return false, "载荷名不能为空" end
    if WriteCustomData == nil then return false, "WriteCustomData 不可用" end
    if Network == nil or Network.SaveGame == nil then return false, "Network.SaveGame 不可用" end

    local payload = tostring(text or "")
    local cdKey = MODMISC_CARRIER_CD_PREFIX .. tostring(name)
    local writeOk, writeErr = pcall(WriteCustomData, cdKey, payload)
    if not writeOk then
        Log("写载荷失败 -> " .. tostring(writeErr))
        return false, tostring(writeErr)
    end

    local fileName = API.BuildCarrierName(name)
    local saveFile = {
        Name = fileName,
        Location = SaveLocations ~= nil and SaveLocations.LOCAL_STORAGE or nil,
        Type = SaveTypes ~= nil and SaveTypes.SINGLE_PLAYER or nil,
        FileType = SaveFileTypes ~= nil and SaveFileTypes.GAME_STATE or nil,
        IsAutosave = false,
        IsQuicksave = false,
    }
    if SaveDirectories ~= nil then saveFile.Directory = SaveDirectories.DEFAULT end

    Log("即将写载体存档：" .. fileName .. "（载荷 " .. tostring(#payload) .. " 字节）")
    local ok, err = pcall(Network.SaveGame, saveFile)
    if not ok then
        Log("载体存档写入调用失败 -> " .. tostring(err))
        return false, tostring(err)
    end
    RememberName(name)
    Log("载体存档调用已返回（没卡死）：接收方载入这份档之后 Read(\""
        .. tostring(name) .. "\") 即可拿到全文")
    return true, fileName
end

function API.Read(name)
    if name == nil then return nil, "载荷名为空" end
    if ReadCustomData == nil then return nil, "ReadCustomData 不可用" end
    local ok, value = pcall(ReadCustomData, MODMISC_CARRIER_CD_PREFIX .. tostring(name))
    if not ok then return nil, tostring(value) end
    if value == nil then return nil, "本局里没有这个载荷（要先载入对应的载体档）" end
    return tostring(value)
end

function API.Peek()
    -- CustomData 没有“列出所有键”的接口，只能按已知命名逐个问；
    -- 这里给的是**已知载荷名清单**（模块内记着本进程写过的），够诊断用。
    local rows = {}
    for _, name in ipairs(API.KnownNames or {}) do
        local text = API.Read(name)
        if text ~= nil then
            table.insert(rows, { Name = name, Bytes = #text })
        end
    end
    return rows
end

function API.Clear(name)
    if name == nil or WriteCustomData == nil then return false end
    local ok = pcall(WriteCustomData, MODMISC_CARRIER_CD_PREFIX .. tostring(name), "")
    Log("已清载荷 " .. tostring(name) .. " 结果=" .. tostring(ok))
    return ok
end

