-- ===========================================================================
-- 桩测试：城邦面板加固补丁（UI/Replacements/CityStates_ModMiscGhost.lua）
--   复现基座的真实崩溃点：
--     * GetBonusText 在“领袖不是小文明原型”时只返回 "UNKNOWN"（Details=nil）
--     * AddCityStateRow 无条件拼接 Bonuses[n].Details ⇒ 拼接 nil 抛错 ⇒ 面板打不开
--   然后验证补丁后：① Details 一定是字符串；② 单行出错只跳过该行。
--   跑法（工作目录 = 本项目根）：lua5.1 .harness/citystates_patch_test.lua
-- ===========================================================================
local PATCH = "UI/Replacements/CityStates_ModMiscGhost.lua"

local function stripAnnotations(source)
	source = source:gsub(":%s*[A-Za-z_]+%s*([,)=;])", "%1")
	source = source:gsub(":%s*[A-Za-z_]+%s*%)", ")")
	return source
end
local function readFile(path)
	local handle = assert(io.open(path, "rb"))
	local content = handle:read("*a"); handle:close(); return content
end

local env = setmetatable({}, { __index = _G })
local logs = {}
env.print = function(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
	logs[#logs + 1] = table.concat(parts, " ")
end

-- ==== 模拟“当前生效的那一层”（基座 + XP1 的行为） ====
-- 基座 GetBonusText：坏领袖只返回一个值（Details = nil）
local bonusTextCalls = 0
env.GetBonusText = function(playerID, envoyTokenNum)
	bonusTextCalls = bonusTextCalls + 1
	if playerID == "BAD" then
		return "UNKNOWN"            -- ← 只有 1 个返回值，第二个是 nil
	end
	return "TITLE", "DETAILS"
end
-- 基座 DIPLO_PIP_INFO（真实基座里是 local 表）+ 行构造：两处都会因缺字段抛错
local DIPLO_PIP_INFO = { DIPLO_STATE_AWARE = { IconName = "ICON_RELATIONSHIP_NEUTRAL" } }
local baseRowBuilder = function(kCityState)
	local pipIcon = DIPLO_PIP_INFO[kCityState.DiplomaticState].IconName          -- 状态 nil ⇒ 这里炸
	local text = kCityState.Bonuses[1].Title .. "[NEWLINE]" .. kCityState.Bonuses[1].Details
	for _ in pairs(kCityState.Quests) do end                                    -- Quests nil ⇒ 这里炸
	return pipIcon .. text
end
env.AddCityStateRow = function(kCityState)
	local rendered = baseRowBuilder(kCityState)
	env.__lastRowRendered = (rendered ~= nil)
	return { NameButton = rendered }        -- 模拟基座返回的 InstanceManager 实例（表）
end
env.pcall = pcall

-- 面板的显示状态机（基座）：只有 Show() 才会 unhide 上下文
local contextHidden = true
env.ContextPtr = {
	IsHidden = function() return contextHidden end,
	SetHide = function(self, value) contextHidden = value end,
	GetID = function() return "CityStates" end,
}
-- 基座 Refresh：正常时没事；测试里我们会让它抛错，验证兜底
local refreshShouldThrow = false
env.Refresh = function()
	if refreshShouldThrow then error("boom in Refresh (模拟面板数据出错)") end
	return "refreshed"
end
env.OpenOverview = function() env.Refresh(); contextHidden = false end     -- 模拟 Show() 的 unhide
env.OnOpenSendEnvoys = function() env.Refresh(); contextHidden = false end
env.OnOpenCityStates = function() env.OpenOverview() end
-- LuaEvents 桩：记录登记/移除/触发
local listeners = {}
env.LuaEvents = setmetatable({}, { __index = function(_, name)
	return {
		Add = function(fn) listeners[name] = listeners[name] or {}; table.insert(listeners[name], fn) end,
		Remove = function(fn)
			local list = listeners[name] or {}
			for index = #list, 1, -1 do if list[index] == fn then table.remove(list, index) end end
		end,
		Call = function(...)
			for _, fn in ipairs(listeners[name] or {}) do fn(...) end
		end,
	}
end })
-- 原版在这两个事件上登记的是**函数引用**（用来验证我们把它换成了包装版）
listeners["PartialScreenHooks_OpenCityStates"] = { env.OnOpenCityStates }
listeners["NotificationPanel_OpenCityStatesSendEnvoys"] = { env.OnOpenSendEnvoys }

-- 补丁需要的两个外部件：层链助手（真实实现在 ModMiscGhostShared.lua，这里给桩）
env.include = function() end
env.ModMiscToolIncludeUILayer = function(contextName) return contextName end

-- ==== 打补丁前：复现崩溃（外交状态 nil + 加成缺失，真实日志里的那种行） ====
local badRow = { iPlayer = 6, DiplomaticState = nil, Bonuses = {}, Quests = nil, Relationships = nil }
local title, details = env.GetBonusText("BAD", 1)
badRow.Bonuses[1] = { Title = title, Details = details }
local okBefore = pcall(env.AddCityStateRow, badRow)
print("打补丁前：坏数据行构造成功 = " .. tostring(okBefore)
	.. "（应为 false —— 这就是面板打不开的原因）")

-- ==== 加载补丁 ====
local chunk = assert(loadstring(stripAnnotations(readFile(PATCH)), "@" .. PATCH))
setfenv(chunk, env)
chunk()

local failures = 0
local function check(label, actual, expected)
	local ok = (actual == expected)
	if not ok then failures = failures + 1 end
	print(string.format("%s %-46s 期望=%s 实际=%s",
		ok and "  ✓" or "  ✗", label, tostring(expected), tostring(actual)))
end

-- ==== 打补丁后 ====
title, details = env.GetBonusText("BAD", 1)
check("坏领袖的 Details", details, "")
check("坏领袖的 Title", title, "UNKNOWN")
title, details = env.GetBonusText("GOOD", 1)
check("正常领袖 Details 未被吞", details, "DETAILS")

badRow = { iPlayer = 6, DiplomaticState = nil, Bonuses = { [1] = { Title = title, Details = details } } }
local okAfter = pcall(env.AddCityStateRow, badRow)
check("坏数据行不再抛错", okAfter, true)
check("缺字段的行被补齐后**渲染出来**（不再从列表里消失）", okAfter and env.__lastRowRendered or false, true)
check("外交状态缺省值已补", badRow.DiplomaticState, "DIPLO_STATE_AWARE")
check("加成项已补齐", badRow.Bonuses["Suzerain"] ~= nil and badRow.Bonuses[6] ~= nil, true)
check("Quests/Relationships 已补空表", type(badRow.Quests) == "table" and type(badRow.Relationships) == "table", true)

-- 单行坏数据：让“当前层”的行构造对某一行抛错，验证只跳过这一行
env.MODMISC_BASE_AddCityStateRow = function(kCityState)
	if kCityState.iPlayer == 9 then error("bad row") end
	return { NameButton = "ok" }              -- 真实基座返回的是 InstanceManager 实例（表）
end
-- 关键契约：基座 ViewList 是 `local kInst :table = AddCityStateRow(...)`，
-- 游戏 Lua 会运行时检查 :table —— 返回布尔/nil 会把整个列表循环打断（实机就是这么少显示一个城邦的）
local badReturn = env.AddCityStateRow({ iPlayer = 9 })
check("坏行也返回表（否则类型检查会掐断后续行）", type(badReturn), "table")
check("坏行表是空的（没有假造行控件）", next(badReturn), nil)
local goodReturn = env.AddCityStateRow({ iPlayer = 8 })
check("好行原样透传基座返回（表）", type(goodReturn), "table")
local sawSkipLog = false
for _, line in ipairs(logs) do
	if string.find(line, "跳过一行坏数据") then sawSkipLog = true end
end
check("坏行有日志", sawSkipLog, true)

-- ==== 豁免型过滤：只摘"主流转出来的城邦"，城邦幽灵池出身的照常显示 ====
print("== 豁免型过滤 ==")
env.GameInfo = { Civilizations = {
	CIVILIZATION_ROME = { StartingCivilizationLevelType = "CIVILIZATION_LEVEL_FULL_CIV" },
	CIVILIZATION_AMSTERDAM = { StartingCivilizationLevelType = "CIVILIZATION_LEVEL_CITY_STATE" },
} }
local originalIdentities = {}
env.ExposedMembers = { ModMiscToolScript = {
	GetGhostOriginalIdentity = function(iPlayer) return originalIdentities[iPlayer] end,
} }

local function MakeRow(iPlayer)
	return { iPlayer = iPlayer, DiplomaticState = "DIPLO_STATE_AWARE",
		Bonuses = { [1] = { Title = "T", Details = "D" } }, Quests = {}, Relationships = {} }
end

-- 正常原生城邦（无台账）⇒ 正常显示（顺带成为"样板行"）
local hiddenCalls = 0
env.MODMISC_BASE_AddCityStateRow = function(kCityState)
	return { Root = { SetHide = function(_, value) if value then hiddenCalls = hiddenCalls + 1 end end } }
end
local nativeRow = env.AddCityStateRow(MakeRow(3))
check("原生城邦（无台账）照常渲染", type(nativeRow), "table")

-- 主流转出来的城邦 ⇒ 隐形占位（不可见）
originalIdentities[6] = { civ = "CIVILIZATION_ROME" }
local hiddenRow = env.AddCityStateRow(MakeRow(6))
check("主流转出的城邦被摘成隐形占位", type(hiddenRow), "table")
check("隐形占位的控件被隐藏（用户看不到这一行）", hiddenCalls > 0, true)

-- 城邦幽灵池出身 ⇒ 豁免，照常渲染
originalIdentities[7] = { civ = "CIVILIZATION_AMSTERDAM" }
local exemptRow = env.AddCityStateRow(MakeRow(7))
check("城邦幽灵池出身 ⇒ 豁免并正常渲染", next(exemptRow) ~= nil, true)

-- ==== 补丁后：Refresh 抛错也必须让面板弹出来（这就是“点不开”的命门） ====
print("== Refresh 抛错时面板仍要弹出 ==")
refreshShouldThrow = true
-- 原版登记在事件上的还是旧引用 ⇒ 补丁应已把它换成包装版
local probeErrors = 0
for _, fn in ipairs(listeners["PartialScreenHooks_OpenCityStates"] or {}) do
	local ok = pcall(fn)
	if not ok then probeErrors = probeErrors + 1 end
end
check("事件触发不再抛错", probeErrors, 0)
check("上下文已被 unhide（面板能弹出来）", contextHidden, false)
local sawRefreshGuard, sawOpenLog, sawSummary = false, false, false
for _, line in ipairs(logs) do
	if string.find(line, "Refresh 出错已兜住") then sawRefreshGuard = true end
	if string.find(line, "打开面板入口=") then sawOpenLog = true end
	if string.find(line, "本轮列表：渲染") then sawSummary = true end
end
check("Refresh 兜底有日志", sawRefreshGuard, true)
check("入口日志有输出", sawOpenLog, true)
check("每轮渲染/跳过计数有日志", sawSummary, true)

-- 派使者（回合拦截）那条路同样要弹出
contextHidden = true
refreshShouldThrow = true
local envoyErrors = 0
for _, fn in ipairs(listeners["NotificationPanel_OpenCityStatesSendEnvoys"] or {}) do
	local ok = pcall(fn)
	if not ok then envoyErrors = envoyErrors + 1 end
end
check("派使者入口不抛错", envoyErrors, 0)
check("派使者入口也能弹出面板", contextHidden, false)

print(failures == 0 and "\n全部通过 ✓" or ("\n失败 " .. failures .. " 项 ✗"))
os.exit(failures == 0 and 0 or 1)
