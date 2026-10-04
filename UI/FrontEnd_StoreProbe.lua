-- ===========================================================================
-- Mod Misc Tool: 跨存档存储探针 —— 把 payload 编进「配置档的名字」
--
-- 【为什么只剩这条路】原版能提供的通道已全部实测：
--   ✗ CustomData：不落盘、配置档也不带它（第 39 条）
--   ✗ 对局内读配置档：直接卡死（第 36 条）
--   ✗ io 库：不存在（`[IOProbe] io=n io.open=n`）→ 没法自己写文件
--   ✗ Options.SetUserOption：拒绝未注册的键（`... is not a registered option`），
--     而选项注册表在引擎内部、数据文件里没有任何选项声明 → mod 注册不了
--
-- 剩下唯一**由 mod 控制、又不需要读档就能拿到**的字段，就是存档列表里的**文件名**：
--   写：Network.SaveGame{Name = 前缀..hex(payload)}（前端存配置档，不需要运行中的对局）
--   读：UI.QuerySaveGameList 的 Name（前后端都能用，实测多次）
-- 两端都已在实机验证过（清单第 32、34 条），这里只是把两端接起来 —— 这就是
-- “利用普通存档”那条路的最小实现。
--
-- 【编码】十六进制（0-9a-f）。文件名禁止 `%` `"` `<` `>` `|` `/` `\` `*` `?` `:` 与控制字符，
-- hex 天然合法；代价是长度翻倍，短 payload 无所谓（几十字节）。
--
-- 【协议】只在前端主界面跑，一轮写、下一轮读：
--   列表里找到 ModMiscStore~ 前缀的档 → 解码打出来（**跨存档成立**）→ 写新一轮 → 删旧档
--   没找到 → 写一份，下一轮再看
-- ===========================================================================

local MODMISC_STORE_PREFIX = "ModMiscStore~"
local MODMISC_STORE_BUILD_TAG = "2026-10-04-A"

local m_QueryIssued = false
local m_QueryRequestId = nil
local m_ContextInstance = nil

local function Log(message)
    print("[ModMiscTool][StoreProbe] " .. message)
end

-- ===========================================================================
-- 编解码：hex，避开文件名禁用字符
-- ===========================================================================

local function EncodePayload(text)
    return (tostring(text):gsub(".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end

local function DecodePayload(hex)
    if hex == nil or #hex == 0 or #hex % 2 ~= 0 then return nil end
    local bytes = {}
    for i = 1, #hex, 2 do
        local byte = tonumber(hex:sub(i, i + 1), 16)
        if byte == nil then return nil end
        table.insert(bytes, string.char(byte))
    end
    return table.concat(bytes)
end

-- 存档列表里的 Name 带扩展名（配置档是 xxx.Civ6Cfg），比对前先剥掉
local function NormalizeSaveName(name)
    if name == nil then return nil end
    local text = tostring(name)
    local stripped = text:match("^(.*)%.[^%.]+$")
    if stripped ~= nil and stripped ~= "" then return stripped end
    return text
end

local function BuildStoreFileName(payload)
    return MODMISC_STORE_PREFIX .. EncodePayload(payload)
end

-- ===========================================================================
-- 写 / 查
-- ===========================================================================

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

local function WriteStore(payload)
    if Network == nil or Network.SaveGame == nil then
        Log("写入失败：Network.SaveGame 不可用")
        return false
    end
    local configFile = BuildConfigFile(BuildStoreFileName(payload))
    if configFile == nil then
        Log("写入失败：存档表构建不了")
        return false
    end
    local ok, err = pcall(Network.SaveGame, configFile)
    if not ok then
        Log("写入失败 -> " .. tostring(err))
        return false
    end
    Log("已请求写入 [" .. payload .. "] → 文件名 " .. configFile.Name)
    return true
end

local function BuildPayload()
    return "ms=1;t=" .. tostring(os.time())
        .. ";r=" .. tostring(math.random(100000, 999999))
end

-- 查询回调：引擎通过 LuaEvents 回传 (fileList, 请求号)
local function OnStoreQueryResults(fileList, requestId)
    if requestId ~= nil and m_QueryRequestId ~= nil and requestId ~= m_QueryRequestId then
        return
    end

    local previousPayload = nil
    local previousEntry = nil
    local names = {}
    if fileList ~= nil then
        for _, entry in ipairs(fileList) do
            if entry ~= nil and entry.Name ~= nil then
                local shortName = NormalizeSaveName(entry.Name)
                table.insert(names, tostring(entry.Name))
                if shortName ~= nil and shortName:sub(1, #MODMISC_STORE_PREFIX) == MODMISC_STORE_PREFIX then
                    local decoded = DecodePayload(shortName:sub(#MODMISC_STORE_PREFIX + 1))
                    if decoded ~= nil then
                        previousPayload = decoded
                        previousEntry = entry
                    end
                end
            end
        end
    end

    local listing = "(空)"
    if #names > 0 then listing = table.concat(names, ",") end

    if previousPayload ~= nil then
        Log("读到上一轮存的 payload [" .. previousPayload .. "]"
            .. " ⇒ **跨存档/跨启动通道成立**（列表=[" .. listing .. "]）")
    else
        Log("没有找到存储档（列表=[" .. listing .. "]）")
    end

    -- 先写新一轮，再删旧档：万一写失败，旧数据还在
    local newPayload = BuildPayload()
    if not WriteStore(newPayload) then return end

    if previousEntry ~= nil and UI ~= nil and UI.DeleteSavedGame ~= nil then
        local ok, err = pcall(UI.DeleteSavedGame, previousEntry)
        Log(ok and "已删除旧存储档" or ("删除旧档失败 -> " .. tostring(err)))
    end

    if UI ~= nil and UI.CloseFileListQuery ~= nil and m_QueryRequestId ~= nil then
        pcall(function() UI.CloseFileListQuery(m_QueryRequestId) end)
        m_QueryRequestId = nil
    end
end

local function IssueStoreQuery()
    if UI == nil or UI.QuerySaveGameList == nil or LuaEvents == nil
        or LuaEvents.FileListQueryResults == nil or SaveLocationOptions == nil then
        Log("查询不可用（QuerySaveGameList / SaveLocationOptions 缺失）")
        return
    end
    local configFile = BuildConfigFile(MODMISC_STORE_PREFIX .. "probe")
    if configFile == nil then
        Log("查询不可用：存档表构建不了")
        return
    end
    local options = SaveLocationOptions.NORMAL + SaveLocationOptions.QUICKSAVE
        + SaveLocationOptions.LOAD_METADATA
    LuaEvents.FileListQueryResults.Add(OnStoreQueryResults)
    m_QueryRequestId = UI.QuerySaveGameList(configFile.Location, configFile.Type,
        options, configFile.FileType, nil)
    Log("已发出存档列表查询（找 " .. MODMISC_STORE_PREFIX .. " 前缀的档）build="
        .. MODMISC_STORE_BUILD_TAG)
end

-- ===========================================================================
-- 对外入口：由 Civ6Common replacement 的刷新回调每帧调用；只认前端主界面
-- ===========================================================================

function ModMiscStoreProbeRefresh()
    if ContextPtr == nil or ContextPtr.GetID == nil then return end
    local ok, contextID = pcall(function() return ContextPtr:GetID() end)
    if not ok or tostring(contextID) ~= "MainMenu" then return end

    -- 上下文被重建（进对局再回来）也要重跑一轮
    local instance = tostring(ContextPtr)
    if m_ContextInstance ~= instance then
        m_ContextInstance = instance
        m_QueryIssued = false
    end
    if m_QueryIssued then return end
    m_QueryIssued = true
    IssueStoreQuery()
end
