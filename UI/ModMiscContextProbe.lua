-- ===========================================================================
-- 前端 ↔ 对局内：**UI 环境连通性探针**（授权者 2026-10-06 要求的新测试项）
--
-- 要回答的问题：**主页面（前端）缓存的数据，进游戏后读得到吗？退出回主页面后呢？**
-- 也就是「跨游戏状态的两个 Lua 环境之间，到底有没有共享的读写通道」。
--
-- 三个通道各测一遍，每个都写清“写/读/结果”，日志前缀统一 [CtxProbe] 便于 grep：
--
--   A 模组配置组名字（ModMiscModGroupStore / Modding）
--       引擎数据库里的自由文本，理论上跨上下文、跨进程都在 ⇒ **最有希望的那条**
--   B 档名通道（ModMiscStore）
--       **只读不写**：前端写普通存档已实机证否（闪退，见第 73 条），不能拿它冒险
--   C 进程内共享表（ExposedMembers / 全局变量）
--       两个游戏状态各自一份 Lua 状态，多半不共享 —— 测出来才能确定（写进去再读回来）
--
-- 触发点（自动，不用手点）：
--   * 前端上下文加载 = 主页面出现（首次进主页面 / 退出对局回主页面都会走一次）
--   * 对局内 LoadGameViewStateDone = 进游戏（Support_UI.Initialize 里调）
--
-- 【为什么不用面板按钮】前端没有本 mod 的面板；这个测试要测的正是“换环境”那一刻，
-- 自动挂在两个上下文的入口最直接。要手动复测就在 Automation 面板点「环境连通性」按钮。
-- ===========================================================================

local MODMISC_CONTEXT_PROBE_BUILD_TAG = "2026-10-06-A"

ModMiscContextProbe = ModMiscContextProbe or {}
local API = ModMiscContextProbe
API.BuildTag = MODMISC_CONTEXT_PROBE_BUILD_TAG

-- 【开关】前端那一侧要不要**写** A 通道（模组配置组）？
--   授权者 2026-10-06：主界面闪退过一次（引擎 luaL_unref），虽然那次日志里还没有本探针，
--   但“前端写引擎数据库”是这套里最可疑的一步。要是主界面再闪退，先把这里改 false
--   （那就只读不写：仍然能看到“进游戏读得到主页面写的东西吗”，只是主页面不参与写）。
local MODMISC_CTXPROBE_FRONTEND_WRITE = true

local PROBE_KEY = "ctxprobe"        -- A 通道用的键
local SHARED_KEY = "ModMiscCtxProbe"  -- C 通道：ExposedMembers 里的字段名

local function Log(message)
    print("[ModMiscTool][CtxProbe] " .. tostring(message))
end

local function Now()
    local ok, value = pcall(function() return os.time() end)
    if ok and value ~= nil then return tostring(value) end
    return "?"
end

-- 这一次的标记：<环境>-<原因>-<时间>-<随机>。同一个字符串写进去、读回来就能一一对上。
local function MakeStamp(context, reason)
    return tostring(context) .. "-" .. tostring(reason) .. "-" .. Now()
        .. "-" .. tostring(math.random(100, 999))
end

local function DescribeValue(value)
    if value == nil then return "nil（没有这份数据）" end
    if type(value) == "table" then return "table（" .. tostring(#value) .. " 项）" end
    return tostring(value)
end

-- ===========================================================================
-- 通道 A：模组配置组名字
-- ===========================================================================
local function ChannelModGroup(write, stamp, context)
    if ModMiscModGroupStore == nil then
        Log("  A 模组配置组：模块没加载")
        return nil
    end
    if not ModMiscModGroupStore.IsAvailable() then
        Log("  A 模组配置组：**不可用**（Modding 组接口缺失 / 前端没这个 API？）")
        return nil
    end
    if write and context == "frontend" and not MODMISC_CTXPROBE_FRONTEND_WRITE then
        Log("  A 模组配置组：前端写入被开关关掉（MODMISC_CTXPROBE_FRONTEND_WRITE=false）⇒ 只读")
        write = false
    end
    if write then
        local ok, err = ModMiscModGroupStore.Save(PROBE_KEY, stamp)
        Log("  A 模组配置组：写入 " .. tostring(ok) .. (ok and "" or (" -> " .. tostring(err))))
        if not ok then return nil end
    end
    local value, err = ModMiscModGroupStore.Load(PROBE_KEY)
    Log("  A 模组配置组：读到 " .. DescribeValue(value)
        .. (value == nil and err ~= nil and ("（" .. tostring(err) .. "）") or ""))
    return value
end

-- ===========================================================================
-- 通道 B：档名通道 —— **只读**
-- ===========================================================================
local function ChannelNameStore(write, stamp)
    if ModMiscStore == nil then
        Log("  B 档名通道：模块没加载")
        return nil
    end
    if write then
        -- 故意不写：前端写普通存档实机闪退过（第 73 条）。这里只报告“能不能读”。
        Log("  B 档名通道：**只读不写**（前端写档已证否：会闪退）")
    end
    local ready = ModMiscStore.IsReady ~= nil and ModMiscStore.IsReady()
    local value = ModMiscStore.Get ~= nil and ModMiscStore.Get(PROBE_KEY) or nil
    Log("  B 档名通道：IsReady=" .. tostring(ready) .. " 读到 " .. DescribeValue(value))
    return value
end

-- ===========================================================================
-- 通道 C：进程内共享表（ExposedMembers / 全局）
-- ===========================================================================
local function ChannelShared(write, stamp, context)
    local holder = nil
    local where = "exposed"
    if ExposedMembers ~= nil then
        if ExposedMembers.ModMiscToolUI == nil then ExposedMembers.ModMiscToolUI = {} end
        holder = ExposedMembers.ModMiscToolUI
    else
        holder = _G
        where = "global"
    end
    if write then
        holder[SHARED_KEY] = stamp
        holder[SHARED_KEY .. "_" .. tostring(context)] = stamp
        Log("  C 进程内共享表（" .. where .. "）：写入自己的标记")
    end
    local mine = holder[SHARED_KEY]
    local fromFrontEnd = holder[SHARED_KEY .. "_frontend"]
    local fromInGame = holder[SHARED_KEY .. "_ingame"]
    Log("  C 进程内共享表（" .. where .. "）：通用=" .. DescribeValue(mine)
        .. " ｜frontend 写的=" .. DescribeValue(fromFrontEnd)
        .. " ｜ingame 写的=" .. DescribeValue(fromInGame))
    return mine, fromFrontEnd, fromInGame
end

-- ===========================================================================
-- 对外：跑一轮（写自己的标记 + 读所有通道）
-- ===========================================================================
function API.Run(context, reason)
    API._runs = API._runs or {}
    local runs = API._runs[context] or 0
    if runs >= 2 then
        -- 同一个上下文里最多跑两次（include 那一刻 + 刷新回调那一刻）：
        -- 前端上下文那一刻存储可能还没就绪，第二次正好补上。
        return false
    end
    API._runs[context] = runs + 1
    local stamp = MakeStamp(context, reason)
    Log("==== 环境连通性检查：context=" .. tostring(context)
        .. " 原因=" .. tostring(reason) .. " 本次标记=" .. stamp .. " ====")
    ChannelModGroup(true, stamp, context)
    ChannelNameStore(false, stamp)
    ChannelShared(true, stamp, context)
    Log("==== 检查结束（把这几行连同上一轮对照看：通道 A 能不能跨环境读到写的那串标记）====")
    return true
end

-- 手动入口（Automation 面板 / 别的 mod 随时可调，不受上面的次数限制）
function API.Check(context, reason)
    API._runs = API._runs or {}
    API._runs[context or "manual"] = 0
    return API.Run(context or "manual", reason or "手动")
end

Log("探针已加载 build=" .. tostring(API.BuildTag))
