-- ===========================================================================
-- 桩测试：幽灵申报**由 Vassal System 决定、Mod Misc Tool 只接受**
--   加载 Misc Tool 的真实前端 hook（UI/Replacements/Civ6Common.lua），DB 桩按
--   Vassal System 的声明 SQL（../Vassal System/Vassal_GhostDemand.sql）喂行：
--     * 声明行按地图尺寸：DUEL 4 / TINY 8 / SMALL 12 / STANDARD 16 / LARGE 20 / HUGE 24
--       （另有 '*' 兜底行 12）
--     * 表不存在 / 没有行 ⇒ 该类幽灵为 0（本工具自己不申报）
--     * 槽位闸 / 幽灵总预算 / 同局换尺寸重算 / 真机哈希路径 / 声明表读取的缓存
--   跑法（工作目录 = 本项目根）：lua5.1 .harness/frontend_major_gradient_test.lua
-- ===========================================================================

local MISC_TOOL_FILE = "UI/Replacements/Civ6Common.lua"
local DEMAND_SQL_FILE = "../Vassal System/Vassal_GhostDemand.sql"

-- 引擎类型标注（a: number 之类）是给官方脚本检查器看的，标准 Lua 解析不了，先剥掉
local function stripAnnotations(source)
	source = source:gsub(":%s*[A-Za-z_]+%s*([,)=;])", "%1")
	source = source:gsub(":%s*[A-Za-z_]+%s*%)", ")")
	return source
end

local function readFile(path)
	local handle = io.open(path, "rb")
	if handle == nil then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

-- 声明方是**数据**（SQL），这里把它解析成“DB.ConfigurationQuery 会返回的行”
local DEMAND_ROWS = {}
do
	local sql = readFile(DEMAND_SQL_FILE)
	if sql == nil then
		print("找不到声明方 SQL：" .. DEMAND_SQL_FILE .. "（从项目根目录跑）")
		os.exit(1)
	end
	for source, mapSize, major, cityState in
		sql:gmatch("%('([^']+)',%s*'([^']+)',%s*(%d+),%s*(%d+)%)") do
		DEMAND_ROWS[#DEMAND_ROWS + 1] = {
			Source = source, MapSizeType = mapSize,
			MajorGhosts = tonumber(major), CityStateGhosts = tonumber(cityState),
		}
	end
	if #DEMAND_ROWS == 0 then
		print("声明方 SQL 里没解析到 INSERT 行：" .. DEMAND_SQL_FILE)
		os.exit(1)
	end
end

local SIZE_ORDER = {
	"MAPSIZE_DUEL", "MAPSIZE_TINY", "MAPSIZE_SMALL",
	"MAPSIZE_STANDARD", "MAPSIZE_LARGE", "MAPSIZE_HUGE",
}

-- 每个场景一份全新运行环境（模拟“重新开一局”），把引擎侧能观察到的东西都记下来
local function newHarness(mapSizeKey, options)
	options = options or {}
	local saved = {}          -- DataProtocol.Save 收到的键值
	local logs = {}
	local hashCalls = 0       -- DB.MakeHash 调用次数 = 尺寸解析成本
	local hashTexts = {}
	local demandQueries = 0   -- 声明表查询次数 = 读表成本
	local sizeCalls = 0       -- MapConfiguration.GetMapSize 调用次数 = 每帧固定成本
	local state = {
		participating = options.majorChoice or 4,
		hidden = 0,
		cityStates = options.cityChoice or 6,
		maxMajor = options.maxMajor or 62,
		maxMinor = options.maxMinor or 62,
		rawMapSize = options.rawMapSize,
	}

	local env = setmetatable({}, { __index = _G })
	env.print = function(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(index, ...)))
		end
		logs[#logs + 1] = table.concat(parts, " ")
	end
	env.MapSize_ValueChanged = function() end       -- 让 ModMiscToolIsGameSetupContext() 为真
	env.DataProtocol = {
		Save = function(key, value) saved[key] = value; return true end,
	}
	env.ExposedMembers = {}
	env.Controls = {}                              -- 建局界面控件表（探针靠 StartButton 判断界面）
	env.DB = {
		MakeHash = function(text)
			hashCalls = hashCalls + 1
			if options.debugHashes then hashTexts[#hashTexts + 1] = text end
			return "H:" .. text
		end,
		-- 声明表桩：像 SQLite 那样按 WHERE（精确行 OR '*' 兜底行）过滤
		ConfigurationQuery = function(sql)
			if not string.find(sql, "ModMiscGhostDemand") then return {} end
			if options.demandTableMissing then error("no such table: ModMiscGhostDemand") end
			demandQueries = demandQueries + 1
			local rows = {}
			local exact = string.match(sql, "MapSizeType = '([^']*)'")
			for _, row in ipairs(DEMAND_ROWS) do
				if row.MapSizeType == exact or row.MapSizeType == "*" then
					rows[#rows + 1] = row
				end
			end
			return rows
		end,
	}
	env.include = function() end       -- 框架不再 include 任何外部文件
	env.MapConfiguration = {
		GetValue = function(key)
			if key == "MapSize" and options.rawMapSize == nil then return mapSizeKey end
			return nil
		end,
		GetMapSize = function()
			sizeCalls = sizeCalls + 1
			return state.rawMapSize
		end,
		GetMaxMinorPlayers = function() return state.maxMinor end,
		GetMaxMajorPlayers = function() return state.maxMajor end,
		GetScript = function() return "Continents.lua" end,
	}
	env.GameConfiguration = {
		GetValue = function(key)
			if key == "CITY_STATE_COUNT" then return state.cityStates end
			return nil
		end,
		GetParticipatingPlayerCount = function() return state.participating end,
		GetHiddenPlayerCount = function() return state.hidden end,
		SetParticipatingPlayerCount = function(count) state.participating = count end,
		SetValue = function(key, value) saved["config:" .. key] = value end,
	}
	local refreshHandler = nil
	env.ContextPtr = {
		-- 官方接口是冒号调用（ContextPtr:SetRefreshHandler(fn)），第一个参数是 self
		SetRefreshHandler = function(self, handler) refreshHandler = handler or self end,
		RequestRefresh = function() end,
		IsHidden = function() return false end,
		GetID = function() return "SetupTest" end,
	}

	local chunk = assert(loadstring(stripAnnotations(readFile(MISC_TOOL_FILE)), "@" .. MISC_TOOL_FILE))
	setfenv(chunk, env)
	chunk()

	return {
		env = env,
		state = state,
		saved = saved,
		logs = logs,
		hashCalls = function() return hashCalls end,
		hashTexts = function() return hashTexts end,
		demandQueries = function() return demandQueries end,
		sizeCalls = function() return sizeCalls end,
		refresh = function() assert(refreshHandler, "钩子没装上") refreshHandler(0) end,
	}
end

local failures = 0
local function check(label, actual, expected)
	local ok = (actual == expected)
	if not ok then failures = failures + 1 end
	print(string.format("%s %-50s 期望=%s 实际=%s",
		ok and "  ✓" or "  ✗", label, tostring(expected), tostring(actual)))
end

-- ---------------------------------------------------------------------------
print("== ① 声明方（Vassal System）按地图尺寸申报：自选 4 主流 + 6 城邦 ==")
local EXPECTED = {
	MAPSIZE_DUEL = 4, MAPSIZE_TINY = 8, MAPSIZE_SMALL = 12,
	MAPSIZE_STANDARD = 16, MAPSIZE_LARGE = 20, MAPSIZE_HUGE = 24,
}
for _, size in ipairs(SIZE_ORDER) do
	local harness = newHarness(size)
	harness.refresh()
	check(size .. " 主流幽灵", tonumber(harness.saved["ghost_majorpool"]), EXPECTED[size])
	check(size .. " 参与玩家 = 4 + 幽灵", harness.state.participating, 4 + EXPECTED[size])
	check(size .. " 城邦幽灵（声明 0）", tonumber(harness.saved["ghost_citystatepool"]), 0)
end

-- ---------------------------------------------------------------------------
print("== ② 声明表不存在 / 没有行 ⇒ 本工具不产生幽灵（硬规则） ==")
local silent = newHarness("MAPSIZE_HUGE", { demandTableMissing = true })
silent.refresh()
check("没建表 ⇒ 主流幽灵", tonumber(silent.saved["ghost_majorpool"]) or 0, 0)
check("没建表 ⇒ 参与玩家不变", silent.state.participating, 4)

local emptyRows = newHarness("MAPSIZE_HUGE")
emptyRows.env.DB.ConfigurationQuery = function(sql)
	if string.find(sql, "ModMiscGhostDemand") then return {} end   -- 表在，但一行都没有
	return {}
end
emptyRows.refresh()
check("表里没有行 ⇒ 主流幽灵", tonumber(emptyRows.saved["ghost_majorpool"]) or 0, 0)

print("== ②b 动态通道（ExposedMembers）：同 source 覆盖、异 source 相加 ==")
local dynamic = newHarness("MAPSIZE_HUGE")
dynamic.env.ExposedMembers.ModMiscToolUI.RegisterGhostDemandProvider("VassalSystem", function()
	return 6, 0
end)
dynamic.refresh()
check("同 source（VassalSystem）覆盖表值 24 ⇒ 6", tonumber(dynamic.saved["ghost_majorpool"]), 6)

local added = newHarness("MAPSIZE_HUGE")
added.env.ExposedMembers.ModMiscToolUI.RegisterGhostDemandProvider("AnotherMod", function()
	return 2, 0
end)
added.refresh()
check("异 source 相加 ⇒ 24 + 2", tonumber(added.saved["ghost_majorpool"]), 26)

-- ---------------------------------------------------------------------------
print("== ③ 槽位闸：上限 10、自选 6 主流 + 6 城邦 ==")
local tight = newHarness("MAPSIZE_STANDARD", { majorChoice = 6, cityChoice = 6, maxMajor = 10 })
tight.refresh()
check("槽位不足 ⇒ 主流幽灵", tonumber(tight.saved["ghost_majorpool"]), 0)
check("槽位不足 ⇒ 参与玩家不变", tight.state.participating, 6)

-- ---------------------------------------------------------------------------
print("== ④ 幽灵总预算优先：DUEL 城邦已 15 ⇒ 只剩 1 个槽位 ==")
local budget = newHarness("MAPSIZE_DUEL", { cityChoice = 15 })
budget.refresh()
check("DUEL 总预算 1 ⇒ 主流幽灵", tonumber(budget.saved["ghost_majorpool"]), 1)

-- ---------------------------------------------------------------------------
print("== ⑤ 同局里换地图尺寸 ⇒ 申报自动重算 ==")
local swap = newHarness("MAPSIZE_SMALL")
swap.refresh()
check("SMALL 首轮", tonumber(swap.saved["ghost_majorpool"]), 12)
check("SMALL 参与玩家", swap.state.participating, 16)
swap.env.MapConfiguration.GetValue = function(key)
	if key == "MapSize" then return "MAPSIZE_HUGE" end
	return nil
end
swap.refresh()
check("HUGE 重算后主流幽灵", tonumber(swap.saved["ghost_majorpool"]), 24)
check("HUGE 参与玩家 = 4 + 24", swap.state.participating, 28)

-- ---------------------------------------------------------------------------
print("== ⑥ 真机取尺寸路径：GetValue 拿不到 ⇒ GetMapSize() 哈希（只解析一次） ==")
local hashed = newHarness("ignored", { rawMapSize = "H:MAPSIZE_LARGE", debugHashes = true })
hashed.refresh()
check("哈希路径 ⇒ LARGE 主流幽灵", tonumber(hashed.saved["ghost_majorpool"]), 20)
local hashCallsAfterFirst = hashed.hashCalls()
local sizeCallsAfterFirst = hashed.sizeCalls()
local demandQueriesAfterFirst = hashed.demandQueries()
print("    首轮：声明表查询 " .. tostring(demandQueriesAfterFirst)
	.. " 次、哈希解析 " .. tostring(#hashed.hashTexts())
	.. " 次（都是“尺寸变化/计划需要重算”时才发生）")
hashed.refresh()
check("第二轮不再重算哈希（缓存）", hashed.hashCalls(), hashCallsAfterFirst)
check("第二轮不再重查声明表（缓存）", hashed.demandQueries(), demandQueriesAfterFirst)
hashed.refresh()
check("第三轮仍然不重算", hashed.hashCalls(), hashCallsAfterFirst)
check("第三轮仍然不重查", hashed.demandQueries(), demandQueriesAfterFirst)
print(string.format("    每帧固定成本：首轮 GetMapSize %d 次（含拆账），之后每轮 %d 次，无哈希比对",
	sizeCallsAfterFirst, hashed.sizeCalls() - sizeCallsAfterFirst))
hashed.state.rawMapSize = "H:MAPSIZE_DUEL"
hashed.refresh()
check("换尺寸后重算 ⇒ DUEL 主流幽灵", tonumber(hashed.saved["ghost_majorpool"]), 4)

-- ---------------------------------------------------------------------------
print("== ⑦ 尺寸完全认不出 ⇒ 声明方兜底 12 ==")
local unknown = newHarness("Continents.lua")
unknown.refresh()
check("认不出尺寸 ⇒ 主流幽灵", tonumber(unknown.saved["ghost_majorpool"]), 12)

-- ---------------------------------------------------------------------------
print("== 日志抽样（HUGE：声明表一行 + 拆账一行） ==")
do
	local harness = newHarness("MAPSIZE_HUGE")
	harness.refresh()
	for _, line in ipairs(harness.logs) do
		if string.find(line, "%[DemandTable%]") or string.find(line, "%[MajorPlan%]") then
			print("    " .. line)
		end
	end
end

print(failures == 0 and "\n全部通过 ✓" or ("\n失败 " .. failures .. " 项 ✗"))
os.exit(failures == 0 and 0 or 1)
