-- ===========================================================================
-- Mod Misc Tool: 回合事件（gameplay 后端）
--
-- 【干什么】**只做定时触发**（授权者 2026-10-05 定）：
--   接收别的存档“发过来”的事件 → 存进本局游戏状态里的「回合事件列表」→
--   到点（逻辑回合）**触发** → 广播 LuaEvents 文本事件。
--   **执行方式不写死**：触发之后“到底干什么”由注册进来的处理器决定，
--   别的 mod 用 TurnEvents.RegisterHandler(类型, fn, 优先级) 就能接管/自定义。
--   本 mod 自带一套“默认处理方式”（金币→国库、单位→首都、资源→库存或地图），
--   见 ModTool_TurnEventHandlers.lua —— 它只是当前测试框架用的默认实现，可以关掉或覆盖。
--
-- 【为什么用 Game:SetProperty 存列表】它是游戏状态的一部分：随档保存、读档还原，
-- 所以“已接收但还没到点”的事件会跟着存档走（也能被任何一次存档带走）。
-- 封装在 ModTool_DataStore.lua 里（键前缀 kocmoca_modmisctool_）。
--
-- 【回合同步是“逻辑”的，不做硬同步】（授权者 2026-10-05 明确）
--   分支从主线某回合分叉出去时，引擎回合会从 1 重新数；逻辑上它接着主线的回合走：
--       主线第 18 回合开分支 → 分支的引擎第 1 回合 = 逻辑第 18 回合
--       ⇒ 分支引擎第 3 回合 = 逻辑第 20 回合（偏移 = 18 - 1 = 17）
--   偏移由 UI 侧算好（它知道树的父子与节点记录的逻辑回合），开局时推给这里：
--       TurnEvents.SetLogicalOffset(offset)
--   这里只用它换算，**绝不改引擎回合**（引擎回合也改不动，见第 47 条）。
--
-- 【事件记录】{ Type, Detail, Amount, AcceptTurn(逻辑), FromNode, FromPlayerID,
--              FromCiv, Stamp, Overdue, InheritedFrom }
--   InheritedFrom 换图切到**逻辑占位**时才有：事件原本发给那个占位（它已随切换移除），
--                 由新局接手送达；UI/别的 mod 可据此写“来自已切换掉的逻辑档 X”
--   Type      GOLD / UNIT / RESOURCE
--   Detail    UNIT 事件是单位类型名，RESOURCE 事件是资源类型名，GOLD 为空
--   AcceptTurn 接受回合（逻辑）：到点或已过点就执行
--   Overdue   收到时就已过期 ⇒ 下一回合触发（授权者定的口径），文案可标“补发”
--
-- 【处理方式（默认实现，可替换）】见 ModTool_TurnEventHandlers.lua：
--   GOLD      player:GetTreasury():ChangeGoldBalance(n)（游戏自带场景脚本在用）
--   UNIT      首都地块上 UnitManager.InitUnit(playerID, unitType, x, y)；没有首都 → defer（顺延）
--   RESOURCE  ① 先探库存通道 player:GetResources():ChangeResourceAmount(idx, n)（引擎没有文档化写接口）
--             ② 不行就落到地图上：WorldBuilderAPI.SetResourceType(plot, idx, n)（本 mod 已验证通道）
--
-- 【文本提示】执行/失败时广播：
--   LuaEvents.ModMiscToolTurnEventFired.Call(type, detail, amount, fromNode, overdue, toPlayerID, result)
--   UI 侧（Support_UI）收到后按类型组默认文案，并允许其它 mod 注册解析函数覆盖/补充：
--   ExposedMembers.ModMiscToolUI.RegisterTurnEventTextResolver(fn)
--
-- 公开 API（本 mod 内直接调；外部 mod 走 ExposedMembers.ModMiscToolScript.TurnEvents）：
--   SetLogicalOffset(offset) / GetLogicalOffset() / GetLogicalTurn()
--   AddIncoming(event)        收件：入列（过期则排到下一回合）
--   GetAll() / Clear()        列表副本 / 清空
--   ProcessDue(reason)        结算到点事件（每回合开始自动跑一次）
--   TriggerEvent(event)       触发单条（只问处理器，不自己执行）
--   RegisterHandler(type, fn, priority) / UnregisterHandler / ClearHandlers / GetHandlerTypes
-- ===========================================================================

local MODMISC_TURNEVENTS_BUILD_TAG = "2026-10-05-A"
local MODMISC_TURNEVENTS_KEY = "turnevents"
local MODMISC_TURNEVENTS_OFFSET_KEY = "turnevents_offset"

local function Log(message)
    print("[ModMiscTool][TurnEvent] " .. tostring(message))
end

TurnEvents = TurnEvents or {}
local API = TurnEvents
API.BuildTag = MODMISC_TURNEVENTS_BUILD_TAG

local function GetStore()
    return ModMiscToolData
end

local function ReadKey(key)
    local store = GetStore()
    if store == nil or store.Get == nil then return nil end
    local ok, value = pcall(store.Get, key)
    if not ok then return nil end
    return value
end

local function WriteKey(key, value)
    local store = GetStore()
    if store == nil or store.Set == nil then
        Log("写入 " .. tostring(key) .. " 失败：ModMiscToolData 不可用（漏 include？）")
        return false
    end
    local ok, err = pcall(store.Set, key, value)
    if not ok then
        Log("写入 " .. tostring(key) .. " 失败 -> " .. tostring(err))
        return false
    end
    return true
end

-- ===========================================================================
-- 逻辑回合
-- ===========================================================================

function API.SetLogicalOffset(offset)
    local value = tonumber(offset) or 0
    WriteKey(MODMISC_TURNEVENTS_OFFSET_KEY, value)
    Log("逻辑回合偏移已设为 " .. tostring(value)
        .. "（引擎第 1 回合 = 逻辑第 " .. tostring(value + 1) .. " 回合）")
    return true
end

function API.GetLogicalOffset()
    return tonumber(ReadKey(MODMISC_TURNEVENTS_OFFSET_KEY)) or 0
end

function API.GetLogicalTurn()
    local turn = 1
    local ok, value = pcall(function() return Game.GetCurrentGameTurn() end)
    if ok and value ~= nil then turn = tonumber(value) or 1 end
    return turn + API.GetLogicalOffset()
end

-- ===========================================================================
-- 列表读写
-- ===========================================================================

local function GetList()
    local value = ReadKey(MODMISC_TURNEVENTS_KEY)
    if type(value) ~= "table" then return {} end
    return value
end

local function SaveList(list)
    return WriteKey(MODMISC_TURNEVENTS_KEY, list or {})
end

function API.GetAll()
    local copy = {}
    for index, event in ipairs(GetList()) do
        copy[index] = event
    end
    return copy
end

function API.Clear()
    local count = #GetList()
    SaveList({})
    Log("已清空回合事件列表（原 " .. tostring(count) .. " 条）")
    return count
end

-- ===========================================================================
-- 收件
-- ===========================================================================

-- 过期判定：接受回合 < 当前逻辑回合 ⇒ 排到下一回合（授权者口径）
function API.AddIncoming(event)
    if type(event) ~= "table" or event.Type == nil then
        return false, "事件格式不对"
    end
    local currentTurn = API.GetLogicalTurn()
    local accept = tonumber(event.AcceptTurn) or currentTurn
    if accept < currentTurn then
        event.Overdue = true
        event.AcceptTurn = currentTurn + 1
        Log("事件已过期（接受回合 " .. tostring(accept) .. " < 当前逻辑回合 "
            .. tostring(currentTurn) .. "）→ 排到下一回合触发")
    end
    local list = GetList()
    table.insert(list, event)
    SaveList(list)
    Log("已入列：" .. tostring(event.Type) .. " " .. tostring(event.Detail or "")
        .. " x" .. tostring(event.Amount or "?")
        .. " 接受回合=" .. tostring(event.AcceptTurn)
        .. " 来自=" .. tostring(event.FromNode)
        .. (event.InheritedFrom ~= nil and ("（继承自逻辑档 " .. tostring(event.InheritedFrom) .. "）") or "")
        .. "（现有 " .. tostring(#list) .. " 条）")
    return true
end

-- ===========================================================================
-- 处理器（**执行方式不写死** —— 授权者 2026-10-05 定）
--
-- 核心只负责：跨存档投递 + 按（逻辑）回合**定时触发** + 广播文本事件。
-- “触发之后到底干什么”由**注册进来的处理器**决定，别的 mod 想怎么处理就怎么处理：
--
--     TurnEvents.RegisterHandler("GOLD", function(event) ... end, 优先级)
--     TurnEvents.RegisterHandler("*",    function(event) ... end)   -- 通配，接所有类型
--
-- 处理器契约：handler(event) 返回 (status, detail)
--     "handled"  已处理 → 出队，并按 detail 组提示文案
--     "defer"    这次处理不了（例如首都还没建）→ 留在队里，下一回合再问
--     "failed"   处理失败 → 出队，提示文案里带失败原因
--     其它/nil   这个处理器不管这条 → 继续问下一个处理器
-- 同类处理器按优先级从大到小依次询问；本 mod 自带的“默认处理方式”在
-- ModTool_TurnEventHandlers.lua 里注册（金币/单位/资源），别的 mod 可以：
--     * 注册更高优先级的处理器来接管某个类型；
--     * 或 TurnEvents.ClearHandlers("GOLD") / TurnEventHandlers.Disable() 先清掉默认的。
-- ===========================================================================

local m_Handlers = {}   -- [类型] = { { Fn, Priority }, ... }（按优先级降序）

function API.RegisterHandler(eventType, handler, priority)
    if type(handler) ~= "function" then return false, "handler 不是函数" end
    local key = tostring(eventType or "*")
    m_Handlers[key] = m_Handlers[key] or {}
    table.insert(m_Handlers[key], { Fn = handler, Priority = tonumber(priority) or 0, Type = key })
    table.sort(m_Handlers[key], function(a, b) return a.Priority > b.Priority end)
    Log("已注册处理器：类型=" .. key .. " 优先级=" .. tostring(priority or 0)
        .. "（该类型现有 " .. tostring(#m_Handlers[key]) .. " 个）")
    return true
end

function API.UnregisterHandler(eventType, handler)
    local key = tostring(eventType or "*")
    local list = m_Handlers[key]
    if list == nil then return false end
    for index = #list, 1, -1 do
        if list[index].Fn == handler then
            table.remove(list, index)
            Log("已注销处理器：类型=" .. key)
            return true
        end
    end
    return false
end

function API.ClearHandlers(eventType)
    local removed = 0
    if eventType == nil then
        for key, list in pairs(m_Handlers) do
            removed = removed + #list
            m_Handlers[key] = nil
        end
    else
        local key = tostring(eventType)
        if m_Handlers[key] ~= nil then
            removed = #m_Handlers[key]
            m_Handlers[key] = nil
        end
    end
    Log("已清空处理器 " .. tostring(removed) .. " 个（类型=" .. tostring(eventType or "全部") .. "）")
    return removed
end

function API.GetHandlerTypes()
    local rows = {}
    for key, list in pairs(m_Handlers) do
        table.insert(rows, { Type = key, Count = #list })
    end
    table.sort(rows, function(a, b) return tostring(a.Type) < tostring(b.Type) end)
    return rows
end

local function DispatchToHandlers(event)
    local lists = { m_Handlers[tostring(event.Type)], m_Handlers["*"] }
    for _, list in ipairs(lists) do
        if list ~= nil then
            for _, entry in ipairs(list) do
                local ok, status, detail = pcall(entry.Fn, event)
                if not ok then
                    -- 处理器自己报错：当成 failed 出队，别把队列挂死
                    return "failed", "handler-error:" .. tostring(status)
                end
                if status == "handled" or status == "defer" or status == "failed" then
                    return status, detail
                end
            end
        end
    end
    return "no-handler", nil
end

-- 触发一条事件：只问处理器，不问“该怎么执行”
-- 返回 status("handled"/"defer"/"failed"/"no-handler"), detail
function API.TriggerEvent(event)
    if type(event) ~= "table" then return "failed", "事件格式不对" end
    local status, detail = DispatchToHandlers(event)
    if status == "no-handler" then
        Log("没有处理器认领这条事件（类型 " .. tostring(event.Type)
            .. "）→ 留在队列里，等注册了处理器的 mod 接手")
    elseif status == "handled" then
        Log("已触发并由处理器完成：" .. tostring(event.Type) .. " " .. tostring(event.Detail or "")
            .. " x" .. tostring(event.Amount or "?") .. "（" .. tostring(detail or "") .. "）")
    elseif status == "defer" then
        Log("处理器要求顺延：" .. tostring(event.Type) .. " → " .. tostring(detail or ""))
    else
        Log("处理器报告失败：" .. tostring(event.Type) .. " → " .. tostring(detail or ""))
    end
    return status, detail
end

-- 文本事件：核心只把「触发了什么 + 处理器给的结果」广播出去，文案由 UI 侧/其它 mod 决定
local function FireEventText(event, result)
    if LuaEvents == nil or LuaEvents.ModMiscToolTurnEventFired == nil then return end
    pcall(function()
        -- 第 8 个参数是**继承来源**（换图切到逻辑占位时才有）：那条事件本来是发给已被移除的
        -- 逻辑档的，由新局接手。UI 侧要用就用，签名兼容旧的 7 参调用。
        LuaEvents.ModMiscToolTurnEventFired.Call(
            tostring(event.Type), tostring(event.Detail or ""), tonumber(event.Amount) or 0,
            tostring(event.FromNode or ""), event.Overdue == true,
            tonumber(event.FromPlayerID) or -1, tostring(result or ""),
            event.InheritedFrom ~= nil and tostring(event.InheritedFrom) or nil)
    end)
end

-- 结算到点事件：每回合开始跑一次；面板也能手动触发
function API.ProcessDue(reason)
    local list = GetList()
    if #list == 0 then return 0 end

    local currentTurn = API.GetLogicalTurn()
    local remaining = {}
    local executed = 0
    for _, event in ipairs(list) do
        local accept = tonumber(event.AcceptTurn) or currentTurn
        if accept > currentTurn then
            table.insert(remaining, event)
        else
            local status, detail = API.TriggerEvent(event)
            if status == "handled" then
                executed = executed + 1
                FireEventText(event, detail)
            elseif status == "failed" then
                executed = executed + 1
                FireEventText(event, "failed:" .. tostring(detail))
            else
                -- "defer"（处理器说这次不行）或 "no-handler"（还没人接手）：留在队里，下回合再试
                table.insert(remaining, event)
            end
        end
    end
    SaveList(remaining)
    Log("结算完成（" .. tostring(reason) .. "）：执行 " .. tostring(executed)
        .. " 条，剩余 " .. tostring(#remaining) .. " 条（逻辑回合 " .. tostring(currentTurn) .. "）")

    -- 批次收尾事件：UI 侧用它把本回合的多条提示合成一条弹窗
    if executed > 0 and LuaEvents ~= nil and LuaEvents.ModMiscToolTurnEventBatch ~= nil then
        pcall(function() LuaEvents.ModMiscToolTurnEventBatch.Call(executed, currentTurn) end)
    end
    return executed
end

-- 每回合开始结算一次（gameplay 侧只加载一次，不存在重复注册问题）
if Events ~= nil and Events.LocalPlayerTurnBegin ~= nil then
    Events.LocalPlayerTurnBegin.Add(function()
        local ok, err = pcall(API.ProcessDue, "turn-begin")
        if not ok then
            Log("回合结算失败 -> " .. tostring(err))
        end
    end)
end
