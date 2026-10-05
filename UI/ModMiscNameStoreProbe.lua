-- ===========================================================================
-- Mod Misc Tool: 探「引擎设置类」的键值存储能不能当跨存档通道
--
-- 【授权者 2026-10-05 的要求】重新检查原版里涉及**文件存取**与**名字设定**的地方。
-- 翻完原版后，除「存档文件名」（ModMiscStore 已用）和「模组配置组名字」
-- （ModMiscGroupStore，本轮新增）之外，还有两处**引擎自己会持久化的键值存储**：
--
--   ① Options.SetUserOption(category, name, value) + Options.SaveOptions()
--      原版用法（FrontEnd/Multiplayer/Lobby.lua 等）就是“记一个自己的标记”：
--          Options.SetUserOption("Interface", "SeenPlayByCloudLobby", 1)
--      读：Options.GetUserOption(category, name)
--      → 值写进**用户选项文件**（AppOptions 那一份），跨存档、跨进程都在。
--      好处：**玩家界面上看不见**（不像模组配置组会列在模组界面里）。
--
--   ② UserConfiguration.SetValue(name, value) + UserConfiguration.SaveCheckpoint()
--      读：UserConfiguration.GetValue(name)
--      原版用法：Options_*.lua 把界面选项灌进去、ToolTips 里读；
--      还有字符串值的先例：UserConfiguration.SetValue("LANPlayerName", option)。
--
-- 【这两个到底能存什么】未知，所以本轮只做**探针**：写标记 → 立刻读回 →
-- 报“能不能往返 / 值有没有被截断 / 类型有没有被改”，然后**清掉**。
-- 想验证“跨进程还在不在”：写完 → 杀进程重开 → 点面板「设置存储读取」看还在不在
-- （值里带了 os.time()，所以是不是上一轮写的一眼能看出）。
--
-- 【为什么值得试】它俩都不占文件名、不占存档、玩家看不见；
-- 若任意 key/任意长度都能存，就是比「模组配置组」干净得多的跨存档通道。
-- ===========================================================================

local NAMESTORE_PROBE_BUILD_TAG = "2026-10-05-A"

local NAMESTORE_PROBE_CATEGORY = "ModMiscTool"     -- useroption 用的分类（原版分类之外的自己的名字）
local NAMESTORE_PROBE_KEY = "MMTProbe"             -- service 键名
local NAMESTORE_PROBE_PREFIX = "mmt=1"             -- 值的前缀：一眼看出这条是我们的探针

local function Log(message)
    print("[ModMiscTool][NameStoreProbe] " .. tostring(message))
end

-- 数据驱动：加通道只改这张表
local CHANNELS = {
    {
        Id = "useroption",
        Describe = "Options.SetUserOption/SaveOptions",
        Available = function()
            return Options ~= nil and Options.SetUserOption ~= nil
                and Options.GetUserOption ~= nil and Options.SaveOptions ~= nil
        end,
        Write = function(key, value) Options.SetUserOption(NAMESTORE_PROBE_CATEGORY, key, value) end,
        Read = function(key) return Options.GetUserOption(NAMESTORE_PROBE_CATEGORY, key) end,
        Flush = function() Options.SaveOptions() end,
    },
    {
        Id = "userconfig",
        Describe = "UserConfiguration.SetValue/SaveCheckpoint",
        Available = function()
            return UserConfiguration ~= nil and UserConfiguration.SetValue ~= nil
                and UserConfiguration.GetValue ~= nil and UserConfiguration.SaveCheckpoint ~= nil
        end,
        Write = function(key, value) UserConfiguration.SetValue(key, value) end,
        Read = function(key) return UserConfiguration.GetValue(key) end,
        Flush = function() UserConfiguration.SaveCheckpoint() end,
    },
}

local function FindChannel(channelId)
    for _, channel in ipairs(CHANNELS) do
        if channel.Id == channelId then return channel end
    end
    return nil
end

ModMiscNameStoreProbe = ModMiscNameStoreProbe or {}
ModMiscNameStoreProbe.BuildTag = NAMESTORE_PROBE_BUILD_TAG
ModMiscNameStoreProbe.Category = NAMESTORE_PROBE_CATEGORY
ModMiscNameStoreProbe.Key = NAMESTORE_PROBE_KEY

function ModMiscNameStoreProbe.GetChannels()
    local out = {}
    for _, channel in ipairs(CHANNELS) do
        table.insert(out, { Id = channel.Id, Describe = channel.Describe,
                            Available = channel.Available() and true or false })
    end
    return out
end

function ModMiscNameStoreProbe.Write(channelId, key, text)
    local channel = FindChannel(channelId)
    if channel == nil then return false, "没有这个通道: " .. tostring(channelId) end
    if not channel.Available() then return false, channel.Describe .. " 不可用" end
    key = tostring(key or NAMESTORE_PROBE_KEY)
    local value = tostring(text)
    local ok, err = pcall(channel.Write, key, value)
    if not ok then return false, "写失败: " .. tostring(err) end
    local flushed, flushErr = pcall(channel.Flush)
    if not flushed then return false, "落盘失败: " .. tostring(flushErr) end
    return true
end

function ModMiscNameStoreProbe.Read(channelId, key)
    local channel = FindChannel(channelId)
    if channel == nil then return nil, "没有这个通道: " .. tostring(channelId) end
    if not channel.Available() then return nil, channel.Describe .. " 不可用" end
    key = tostring(key or NAMESTORE_PROBE_KEY)
    local ok, value = pcall(channel.Read, key)
    if not ok then return nil, "读失败: " .. tostring(value) end
    if value == nil then return nil, "没有这个键" end
    return tostring(value)
end

-- 清掉探针键（写空串，不留垃圾键）
function ModMiscNameStoreProbe.Clear(channelId)
    return ModMiscNameStoreProbe.Write(channelId, NAMESTORE_PROBE_KEY, "")
end

function ModMiscNameStoreProbe.GetInfo()
    local info = { Tag = NAMESTORE_PROBE_BUILD_TAG, Channels = {} }
    for _, channel in ipairs(CHANNELS) do
        local entry = { Id = channel.Id, Describe = channel.Describe,
                        Available = channel.Available() and true or false }
        if entry.Available then
            local value, reason = ModMiscNameStoreProbe.Read(channel.Id)
            entry.Value = value
            entry.Reason = reason
        end
        table.insert(info.Channels, entry)
    end
    return info
end

-- 自检：按尺寸阶梯写→立刻读回→比对；跑完把探针键清空
function ModMiscNameStoreProbe.SelfTest(channelId, sizes)
    sizes = sizes or { 8, 64, 256, 1024, 4096 }
    local channel = FindChannel(channelId)
    local report = { Id = channelId, Tag = NAMESTORE_PROBE_BUILD_TAG, Steps = {} }
    if channel == nil then
        report.Error = "没有这个通道: " .. tostring(channelId)
        return report
    end
    report.Describe = channel.Describe
    report.Available = channel.Available() and true or false
    if not report.Available then
        report.Error = channel.Describe .. " 不可用"
        return report
    end

    for _, size in ipairs(sizes) do
        local payload = NAMESTORE_PROBE_PREFIX .. ";t=" .. tostring(os.time()) .. ";n=" .. tostring(size)
            .. ";" .. string.rep("B", math.max(0, size - 24))
        local step = { Size = size, Written = #payload }
        local ok, err = ModMiscNameStoreProbe.Write(channelId, NAMESTORE_PROBE_KEY, payload)
        step.Ok = ok and true or false
        if not ok then
            step.Error = tostring(err)
            table.insert(report.Steps, step)
            report.FirstFailure = step
            break
        end
        local value, reason = ModMiscNameStoreProbe.Read(channelId, NAMESTORE_PROBE_KEY)
        step.Read = value ~= nil and #value or nil
        step.Type = type(value)
        -- 引擎可能把值当数字/布尔解释：值类型变了也算“不一致”
        step.Match = (value == payload)
        if not step.Match then
            step.Error = "读回不一致（读到 " .. tostring(step.Read) .. " 字节，类型 "
                .. tostring(step.Type) .. (reason ~= nil and (", " .. tostring(reason)) or "") .. "）"
        end
        table.insert(report.Steps, step)
        Log("自检 " .. tostring(channelId) .. " size=" .. tostring(size) .. " ok=" .. tostring(step.Ok)
            .. " 读回=" .. tostring(step.Read) .. " 类型=" .. tostring(step.Type)
            .. " 一致=" .. tostring(step.Match))
        if not step.Match then
            report.FirstFailure = step
            break
        end
        report.LastSuccess = step
    end

    local cleared = ModMiscNameStoreProbe.Clear(channelId)
    report.Cleared = cleared and true or false
    return report
end
