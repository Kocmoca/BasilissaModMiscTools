-- ===========================================================================
-- 桩测试：主流 → 城邦的**入口授权**（2026-10-26 授权者恢复 A 方案）
--
-- 要证明的事（这次改动的回归防线）：
--   ① 手动 / 其它 mod 调用（不给来源）仍然被拦截，不会造出半城邦；
--   ② 只有 'auto_first_city'（本地玩家建第一座城）这一个入口放行；
--   ③ 首城自动转换成功后落"已完成"标记，第二次不再执行；
--   ④ 本地玩家已经见过面的幽灵照旧跳过（2026-10-15 的硬规则没被改坏）；
--   ⑤ 全部转换失败时不落"已完成"标记（留给下一座城再试），不把功能一次失败就弄死。
--
-- 跑法（工作目录 = 本项目根）：lua5.1 .harness/ghost_citystate_entry_test.lua
-- ===========================================================================
local MODULE = "ModTool_GhostPlayers.lua"
local GHOST_KEY = 'kocmoca_modmisctool_ghost_players'
local DONE_KEY = 'kocmoca_modmisctool_ghost_autoconvert_done'

local pass, fail = 0, 0
local function Check(name, cond, detail)
	if cond then
		pass = pass + 1
		print("  [OK]   " .. name)
	else
		fail = fail + 1
		print("  [FAIL] " .. name .. (detail ~= nil and ("   -> " .. tostring(detail)) or ""))
	end
end
local function Section(title) print("\n== " .. title) end

-- 捕获日志：既验证行为，也验证日志里能直接看出开关状态
local logLines = {}
local realPrint = print
print = function(...)
	local parts = {}
	for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
	local line = table.concat(parts, ' ')
	logLines[#logLines + 1] = line
	realPrint(line)
end
local function HasLog(fragment)
	for _, line in ipairs(logLines) do
		if string.find(line, fragment, 1, true) ~= nil then return true end
	end
	return false
end

-- ---------------------------------------------------------------------------
-- 引擎桩
-- ---------------------------------------------------------------------------
local props = {}
local metSet = {}
local playerStubs = {}
local configs = {}
local worldBuilderNoop = false

local function NewInfoTable(list, keyField)
	local byKey, ordered = {}, {}
	for _, row in ipairs(list) do
		ordered[#ordered + 1] = row
		if keyField ~= nil and row[keyField] ~= nil then byKey[row[keyField]] = row end
	end
	setmetatable(byKey, { __call = function()
		local index = 0
		return function() index = index + 1; return ordered[index] end
	end })
	return byKey
end

GameInfo = {
	Civilizations = NewInfoTable({
		{ CivilizationType = 'CIVILIZATION_ROME', StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_FULL_CIV' },
		{ CivilizationType = 'CIVILIZATION_GREECE', StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_FULL_CIV' },
		{ CivilizationType = 'CIVILIZATION_BRUSSELS', StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE' },
	}, 'CivilizationType'),
	Leaders = NewInfoTable({
		{ LeaderType = 'LEADER_TRAJAN', Name = 'LOC_LEADER_TRAJAN_NAME' },
		{ LeaderType = 'LEADER_PERIKLES', Name = 'LOC_LEADER_PERIKLES_NAME' },
		{ LeaderType = 'LEADER_MINOR_CIV_BRUSSELS', Name = 'LOC_LEADER_MINOR_CIV_BRUSSELS_NAME',
			InheritFrom = 'LEADER_MINOR_CIV_SCIENTIFIC' },
	}, 'LeaderType'),
	CivilizationLeaders = NewInfoTable({
		{ CivilizationType = 'CIVILIZATION_ROME', LeaderType = 'LEADER_TRAJAN' },
		{ CivilizationType = 'CIVILIZATION_GREECE', LeaderType = 'LEADER_PERIKLES' },
		{ CivilizationType = 'CIVILIZATION_BRUSSELS', LeaderType = 'LEADER_MINOR_CIV_BRUSSELS' },
	}),
}

local function NewConfig(civType, leaderType, levelID)
	local config = { civ = civType, leader = leaderType, levelID = levelID }
	config.GetCivilizationTypeName = function() return config.civ end
	config.SetCivilizationTypeName = function(_, value) config.civ = value end
	config.GetLeaderTypeName = function() return config.leader end
	config.SetLeaderTypeName = function(_, value) config.leader = value end
	config.SetLeaderName = function() end
	config.GetCivilizationLevelTypeID = function() return config.levelID end
	config.SetCivilizationLevelTypeID = function(_, value) config.levelID = value end
	config.SetMajorCiv = function() end
	config.SetIsMinorCiv = function(_, value) config.minor = value end
	return config
end

local function NewPlayerStub(playerID)
	local player = { isMajor = true }
	player.IsMajor = function() return player.isMajor end
	player.GetCities = function()
		return { GetCapitalCity = function() return nil end,
			GetCount = function() return 0 end,
			Members = function() return function() return nil end end }
	end
	player.GetUnits = function()
		return { Members = function() return function() return nil end end }
	end
	player.GetDiplomacy = function()
		return { HasMet = function(_, otherID) return metSet[otherID] == true end }
	end
	return player
end

-- 每次重建世界：玩家 0（本地）+ 20..24（幽灵候选），全部还没建城、还没见面
local function BuildWorld()
	props = {}
	metSet = {}
	playerStubs = {}
	configs = {}
	worldBuilderNoop = false
	playerStubs[0] = NewPlayerStub(0)
	configs[0] = NewConfig('CIVILIZATION_ROME', 'LEADER_TRAJAN', 1)
	for playerID = 20, 24 do
		playerStubs[playerID] = NewPlayerStub(playerID)
		configs[playerID] = NewConfig('CIVILIZATION_GREECE', 'LEADER_PERIKLES', 1)
	end
	Players = playerStubs
	PlayerConfigurations = configs
end

Game = {
	GetLocalPlayer = function() return 0 end,
	GetCurrentGameTurn = function() return 1 end,
	GetProperty = function(_, key) return props[key] end,
	SetProperty = function(_, key, value) props[key] = value end,
}
Map = {
	GetPlot = function(x, y) return nil end,
	GetPlotByIndex = function() return nil end,
}
CityManager = { GetCity = function() return nil end }
UnitManager = { PlaceUnit = function() end, Kill = function() end, InitUnit = function() end }
MaxPlayerSlots = function() return 64 end
MODMISC_BUILD_TAG = 'citystate-entry-test'
ExposedMembers = { ModMiscToolScript = {} }
Events = nil   -- 不注册事件，只测函数

-- 世界编辑器桩：模拟“SetPlayerLeader 生效”与“完全没生效”两种平台行为
WorldBuilder = {
	PlayerManager = function()
		return {
			SetPlayerLeader = function(_, playerID, leaderType, civType, civLevel)
				if worldBuilderNoop then return end
				local config = PlayerConfigurations[playerID]
				config.civ = civType
				config.leader = leaderType
				config.levelID = (civLevel == 'CIVILIZATION_LEVEL_CITY_STATE') and 2 or 1
				Players[playerID].isMajor = (civLevel ~= 'CIVILIZATION_LEVEL_CITY_STATE')
			end,
		}
	end,
}

local function LoadModule()
	logLines = {}
	local chunk = assert(loadfile(MODULE))
	chunk()
end

-- ---------------------------------------------------------------------------
Section('① 开关状态与日志可核对')
BuildWorld()
props[GHOST_KEY] = { 20, 21, 22, 23, 24 }
LoadModule()
Check('开局阶段转换保持关闭', HasLog('autoCityStateConvert=false'))
Check('首城自动转换已打开', HasLog('autoConvertOnFirstCity=true'))
Check('手动入口仍关闭', HasLog('manualConvert=false'))

Section('② 手动入口仍被拦截（不给来源 = manual）')
local manualOK, manualErr = ConvertGhostPlayerToCityState(20)
Check('手动转换返回 false', manualOK == false, manualErr)
Check('原因是入口拦截', manualErr == 'major to city-state conversion blocked', manualErr)
Check('玩家仍然是主流', playerStubs[20].isMajor == true)

metSet[21] = true
local manualCount, manualFailed, manualSkipped = ConvertAllGhostMajorPlayersToCityState()
Check('不带来源的批量转换 converted=0', manualCount == 0, manualCount)
Check('4 个候选被入口拦截（21 已见面单独跳过）', manualFailed == 4, manualFailed)
Check('见过面的 1 个被跳过', manualSkipped == 1, manualSkipped)

Section('③ auto_first_city 入口放行')
-- 把 20 挪出池子，只留 21（已见面）与 22/23/24（其中 24 已见面）
RemoveGhostPlayerFromPool(20, '桩测试')
metSet[24] = true
local autoCount, autoFailed, autoSkipped = ConvertAllGhostMajorPlayersToCityState('auto_first_city')
Check('转换成功 2 个', autoCount == 2, autoCount)
Check('没有失败', autoFailed == 0, autoFailed)
Check('跳过 2 个（见过面的）', autoSkipped == 2, autoSkipped)
Check('22 已不是主流', playerStubs[22].isMajor == false)
Check('23 已不是主流', playerStubs[23].isMajor == false)
Check('身份合规（城邦文明 + 小文明原型领袖）', IsLegalCityStateIdentity(22) == true)
Check('见过面的 21 没被转', playerStubs[21].isMajor == true)
Check('见过面的 24 没被转', playerStubs[24].isMajor == true)

Section('④ 建首城自动触发 + 只做一次')
BuildWorld()
props[GHOST_KEY] = { 22, 23 }
LoadModule()
local triggered = TryAutoConvertGhostsOnFirstCity(0)
Check('首城触发返回 true', triggered == true, triggered)
Check('22 被转成城邦', playerStubs[22].isMajor == false)
Check('23 被转成城邦', playerStubs[23].isMajor == false)
Check('落了"已完成"标记', props[DONE_KEY] == true)
Check('标记可读', IsGhostAutoConvertDone() == true)
Check('第二次调用不再执行', TryAutoConvertGhostsOnFirstCity(0) == false)

Section('⑤ 全失败不落标记（下一座城再试）')
BuildWorld()
worldBuilderNoop = true
props[GHOST_KEY] = { 22, 23 }
LoadModule()
local allFailed = TryAutoConvertGhostsOnFirstCity(0)
Check('全失败时返回 false', allFailed == false, allFailed)
Check('没有落"已完成"标记', props[DONE_KEY] ~= true, props[DONE_KEY])
Check('池子还在（下次可重试）', GetGhostPlayerCount() == 2, GetGhostPlayerCount())

Section('⑥ 手动身份下发（Vassal System 走的那条）仍拒绝主流 → 城邦')
BuildWorld()
props[GHOST_KEY] = { 22 }
LoadModule()
local configured, configErr = ConfigureGhostPlayerIdentity(
	22, 'CIVILIZATION_BRUSSELS', 'LEADER_MINOR_CIV_BRUSSELS', 'CIVILIZATION_LEVEL_CITY_STATE')
Check('ConfigureGhostPlayerIdentity 返回 false', configured == false, configured)
Check('原因是转换被拦截', configErr == 'major to city-state conversion blocked', configErr)
Check('玩家仍是主流', playerStubs[22].isMajor == true)

print('')
print('--------------------------------------------------')
print('桩测试结果：' .. pass .. ' 项通过，' .. fail .. ' 项失败')
print('--------------------------------------------------')
if fail > 0 then os.exit(1) end
