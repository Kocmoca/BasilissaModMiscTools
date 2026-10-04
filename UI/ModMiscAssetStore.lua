-- ===========================================================================
-- Mod Misc Tool: 永久资产放置（落入存档，读档自动重放）
--
-- 【为什么需要它】AssetPreview 摆出来的模型**只是视觉预览**，不属于游戏状态 ——
-- 存档再读回来就没了。要做“永久放置”，就得自己把放置参数记下来，读档时重放。
--
-- 【记在哪】CustomData（WriteCustomData/ReadCustomData）。它随**普通存档**一起
-- 序列化、读档还原 —— 这一条是本项目实测过的（见 API_Verification_Status.md 第 21 条）。
-- 注意它记的是**存档那一刻**的快照：所以顺序是「先放置 → 再存档」。
-- （配置档那条不走：它不带 CustomData，且对局内读会卡死。）
--
-- 【记什么】不记“选中了哪个资产”，而是记**已经解析好的调用**：
--     { fn = "SpoofCityAt", args = { x, y, civIndex, eraIndex, 22 } }
-- 重放时直接 AssetPreview[fn](unpack(args))。这样读档时不必再去查一遍资产库，
-- 也就不会因为索引变化而放错东西。
--
-- 【存法】CustomData 里一行字符串：
--     fn|x|y|arg1|arg2|…;fn|x|y|…        （; 分记录，| 分字段，数字自动还原成 number）
--
-- 【公开 API】本 mod 内直接调 ModMiscAssetStore.*；外部走 ExposedMembers.ModMiscToolUI
--   PlaceAndRecord(fnName, args)  放置 + 记录 + 落 CustomData（args 是数组）
--   RemoveAt(x, y)                只删记录（该地块的），不动画面
--   ClearAllRecords()             清空记录
--   RestoreAll()                  按记录重放（读档/开局自动调一次）
--   GetCount() / GetAll()         记录条数 / 副本
--   Save() / Load()               手动落盘 / 读回
-- 面板上的「放置资产」「清除地块资产」「清除全部资产」已接这套；另有「重放放置」按钮。
-- ===========================================================================

local MODMISC_ASSET_BUILD_TAG = "2026-10-04-A"
local MODMISC_ASSET_CUSTOM_DATA_KEY = "ModMiscAssetPlacements"

local m_Placements = {}

local function Log(message)
    print("[ModMiscTool][AssetStore] " .. message)
end

ModMiscAssetStore = ModMiscAssetStore or {}
ModMiscAssetStore.BuildTag = MODMISC_ASSET_BUILD_TAG

-- ===========================================================================
-- 序列化
-- ===========================================================================

local function Serialize()
    local records = {}
    for _, spec in ipairs(m_Placements) do
        local fields = { tostring(spec.fn) }
        for _, arg in ipairs(spec.args) do
            table.insert(fields, tostring(arg))
        end
        table.insert(records, table.concat(fields, "|"))
    end
    return table.concat(records, ";")
end

local function Deserialize(text)
    local list = {}
    if text == nil or tostring(text) == "" then return list end
    for record in tostring(text):gmatch("[^;]+") do
        local fields = {}
        for field in record:gmatch("[^|]+") do
            local number = tonumber(field)
            table.insert(fields, number ~= nil and number or field)
        end
        if #fields >= 3 then
            local fn = table.remove(fields, 1)
            table.insert(list, { fn = fn, args = fields })
        end
    end
    return list
end

-- ===========================================================================
-- 落盘 / 读回（CustomData）
-- ===========================================================================

function ModMiscAssetStore.Save()
    if WriteCustomData == nil then
        Log("Save 失败：WriteCustomData 不可用（Civ6Common 没 include？）")
        return false
    end
    local ok, err = pcall(WriteCustomData, MODMISC_ASSET_CUSTOM_DATA_KEY, Serialize())
    if not ok then
        Log("Save 失败 -> " .. tostring(err))
        return false
    end
    return true
end

function ModMiscAssetStore.Load()
    if ReadCustomData == nil then
        Log("Load 失败：ReadCustomData 不可用")
        return false
    end
    local ok, value = pcall(ReadCustomData, MODMISC_ASSET_CUSTOM_DATA_KEY)
    if not ok then
        Log("Load 失败 -> " .. tostring(value))
        return false
    end
    m_Placements = Deserialize(value)
    Log("Load 完成 build=" .. MODMISC_ASSET_BUILD_TAG
        .. "：读到 " .. tostring(#m_Placements) .. " 条放置记录")
    return true
end

-- ===========================================================================
-- 放置 / 记录
-- ===========================================================================

-- 真正调用 AssetPreview（args 是数组）
function ModMiscAssetStore.Place(spec)
    if AssetPreview == nil or AssetPreview[spec.fn] == nil then
        return false, "AssetPreview." .. tostring(spec.fn) .. " is nil"
    end
    local args = spec.args
    local ok, err = pcall(function()
        return AssetPreview[spec.fn](args[1], args[2], args[3], args[4], args[5],
            args[6], args[7], args[8], args[9], args[10])
    end)
    if not ok then return false, err end
    return true
end

-- 放置 + 记录 + 落 CustomData。args 是数组：{ x, y, ... }
function ModMiscAssetStore.PlaceAndRecord(fnName, args)
    if fnName == nil or args == nil or args[1] == nil then
        Log("PlaceAndRecord 失败：参数不全")
        return false
    end
    local spec = { fn = fnName, args = {} }
    for _, arg in ipairs(args) do
        table.insert(spec.args, arg)
    end

    local ok, err = ModMiscAssetStore.Place(spec)
    if not ok then
        Log("放置失败 " .. tostring(fnName) .. " -> " .. tostring(err))
        return false, err
    end

    table.insert(m_Placements, spec)
    ModMiscAssetStore.Save()
    Log("已放置并记录 " .. tostring(fnName) .. " @" .. tostring(args[1]) .. "," .. tostring(args[2])
        .. "（现有 " .. tostring(#m_Placements) .. " 条）")
    return true
end

-- 删掉某个地块上的记录（只动记录，不动画面）
function ModMiscAssetStore.RemoveAt(x, y)
    local removed = 0
    for i = #m_Placements, 1, -1 do
        local args = m_Placements[i].args
        if args[1] == x and args[2] == y then
            table.remove(m_Placements, i)
            removed = removed + 1
        end
    end
    if removed > 0 then
        ModMiscAssetStore.Save()
        Log("已删除地块 (" .. tostring(x) .. "," .. tostring(y) .. ") 的 "
            .. tostring(removed) .. " 条记录")
    end
    return removed
end

function ModMiscAssetStore.ClearAllRecords()
    local count = #m_Placements
    m_Placements = {}
    ModMiscAssetStore.Save()
    Log("已清空放置记录（原 " .. tostring(count) .. " 条）")
    return count
end

function ModMiscAssetStore.GetCount()
    return #m_Placements
end

function ModMiscAssetStore.GetAll()
    local copy = {}
    for i, spec in ipairs(m_Placements) do
        local argsCopy = {}
        for j, arg in ipairs(spec.args) do argsCopy[j] = arg end
        copy[i] = { fn = spec.fn, args = argsCopy }
    end
    return copy
end

-- ===========================================================================
-- 重放：读档 / 开局时按记录重新摆出来
-- ===========================================================================

function ModMiscAssetStore.RestoreAll()
    if #m_Placements == 0 then
        Log("RestoreAll：没有记录，跳过")
        return 0
    end
    local placed, failed = 0, 0
    for _, spec in ipairs(m_Placements) do
        local ok = ModMiscAssetStore.Place(spec)
        if ok then placed = placed + 1 else failed = failed + 1 end
    end
    Log("RestoreAll：重放 " .. tostring(placed) .. " 条"
        .. (failed > 0 and ("，失败 " .. tostring(failed) .. " 条") or ""))
    return placed
end

-- 开局/读档：先读记录，再重放。
-- **故意不在这里挂 Events.LoadGameViewStateDone** —— 这个模块会被多个 context include
-- （Support_UI 与测试面板），各自挂一次就会重放多遍。由 Support_UI 的 Initialize 调一次。
function ModMiscAssetStore.LoadAndRestore()
    ModMiscAssetStore.Load()
    return ModMiscAssetStore.RestoreAll()
end
