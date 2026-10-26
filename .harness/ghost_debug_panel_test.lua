-- ===========================================================================
-- 桩测试：幽灵玩家 debug 面板的四个操作（2026-10-26 授权者要求）
--
-- 要证明的事：
--   ① GetGhostPlayerDebugList 给得出面板要的字段（池 / 身份 / 可用 / 原身份）；
--   ② 面板入口 'debug_panel' 能城邦化；其它手动调用仍然被拦；
--   ③ 主流化用**进池时记的原身份**复原（不是当前城邦身份）；
--   ④ 建城自动选址（本地玩家首都附近），建完即从池子摘掉；
--   ⑤ 移除幽灵：杀掉名下所有单位（先伤害 100 再 Kill），清池 + 清原身份台账。
--   ⑥ 面板列表扩展：GetPlayerDebugList 给出「幽灵 + 全部存活玩家」，isGhost 标记正确；
--   ⑦ 杀死有城市的玩家：全部城市转自由城市（对齐 GrayFox），**不杀单位**；
--   ⑧ 杀死没有城市的幽灵：只清池，同样不杀单位；非法目标被拒。
--
-- 跑法（工作目录 = 本项目根）：lua5.1 .harness/ghost_debug_panel_test.lua
-- ===========================================================================
local MODULE = "ModTool_GhostPlayers.lua"
local GHOST_KEY = 'kocmoca_modmisctool_ghost_players'
local CITY_GHOST_KEY = 'kocmoca_modmisctool_city_state_ghost_players'
local IDENTITY_KEY = 'kocmoca_modmisctool_ghost_identities'

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

-- ---------------------------------------------------------------------------
-- 引擎桩
-- ---------------------------------------------------------------------------
local props = {}
local metSet = {}
local playerStubs = {}
local configs = {}
local unitLists = {}
local killCalls = {}
local transferCalls = {}
local createdCities = {}

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
		{ CivilizationType = 'CIVILIZATION_ROME', Name = 'LOC_CIVILIZATION_ROME',
			StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_FULL_CIV' },
		{ CivilizationType = 'CIVILIZATION_GREECE', Name = 'LOC_CIVILIZATION_GREECE',
			StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_FULL_CIV' },
		{ CivilizationType = 'CIVILIZATION_BRUSSELS', Name = 'LOC_CIVILIZATION_BRUSSELS',
			StartingCivilizationLevelType = 'CIVILIZATION_LEVEL_CITY_STATE' },
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
	Units = NewInfoTable({
		{ UnitType = 'UNIT_SETTLER', FoundCity = true },
		{ UnitType = 'UNIT_WARRIOR', FoundCity = false },
	}, 'UnitType'),
}

-- 地图：只有 (6,5) 是无人占用的陆地；其它地块都归本地玩家（模拟“首都周边没空地”）
local MAP_SIZE = 12
local function NewPlot(x, y)
	local plot = { x = x, y = y, water = false, impassable = false, city = false, owner = 0, unit = nil,
		district = -1 }
	plot.GetX = function() return x end
	plot.GetY = function() return y end
	plot.GetIndex = function() return y * 100 + x end
	plot.IsWater = function() return plot.water end
	plot.IsImpassable = function() return plot.impassable end
	plot.IsCity = function() return plot.city end
	plot.GetOwner = function() return plot.owner end
	plot.GetUnit = function() return plot.unit end
	plot.GetDistrictType = function() return plot.district end
	return plot
end
local plots = {}
for x = 0, MAP_SIZE - 1 do
	plots[x] = {}
	for y = 0, MAP_SIZE - 1 do plots[x][y] = NewPlot(x, y) end
end
plots[5][5].city = true                                  -- 本地玩家首都
plots[6][5].owner = -1                                   -- 唯一可用空地

Map = {
	GetPlot = function(x, y)
		if x == nil or y == nil then return nil end
		if x < 0 or y < 0 or x >= MAP_SIZE or y >= MAP_SIZE then return nil end
		return plots[x][y]
	end,
	GetPlotByIndex = function(index)
		local y = math.floor(index / 100)
		local x = index - y * 100
		return Map.GetPlot(x, y)
	end,
	GetGridSize = function() return MAP_SIZE, MAP_SIZE end,
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

local function NewUnitStub(unitID, x, y)
	local unit = { damage = 0 }
	unit.GetID = function() return unitID end
	unit.GetType = function() return 'UNIT_SETTLER' end
	unit.GetDamage = function() return unit.damage end
	unit.SetDamage = function(_, value) unit.damage = value end
	unit.GetX = function() return x end
	unit.GetY = function() return y end
	unit.IsAlive = function() return true end
	return unit
end

local capitalRef = nil
local function NewPlayer(id, isMajor)
	local player = { id = id, isMajor = isMajor }
	player.IsMajor = function() return player.isMajor end
	player.IsAlive = function() return player.alive ~= false end
	player.IsBarbarian = function() return player.barbarian == true end
	player.IsFreeCities = function() return player.freeCity == true end
	player.GetCities = function()
		if id ~= 0 then
			return { GetCapitalCity = function() return nil end,
				GetCount = function() return 0 end,
				Members = function() return function() return nil end end }
		end
		return { GetCapitalCity = function() return capitalRef end,
			GetCount = function() return 1 end,
			Members = function()
				local done = false
				return function()
					if done then return nil end
					done = true
					return 1, capitalRef
				end
			end }
	end
	player.GetUnits = function()
		local index = 0
		local list = unitLists[id] or {}
		return { Members = function()
			return function()
				index = index + 1
				local unit = list[index]
				if unit == nil then return nil end
				return index, unit
			end
		end }
	end
	player.GetDiplomacy = function()
		return { HasMet = function(_, otherID) return metSet[otherID] == true end }
	end
	return player
end

local function BuildWorld()
	props = {}
	metSet = {}
	playerStubs = {}
	configs = {}
	unitLists = {}
	killCalls = {}
	transferCalls = {}
	createdCities = {}
	capitalRef = { GetX = function() return 5 end, GetY = function() return 5 end,
		GetID = function() return 1 end }

	playerStubs[0] = NewPlayer(0, true)
	configs[0] = NewConfig('CIVILIZATION_ROME', 'LEADER_TRAJAN', 1)
	for _, playerID in ipairs({ 20, 21, 22 }) do
		playerStubs[playerID] = NewPlayer(playerID, true)
		configs[playerID] = NewConfig('CIVILIZATION_GREECE', 'LEADER_PERIKLES', 1)
	end
	Players = playerStubs
	PlayerConfigurations = configs

	props[GHOST_KEY] = { 20, 21, 22 }
	props[CITY_GHOST_KEY] = {}
	props[IDENTITY_KEY] = {
		[20] = { civ = 'CIVILIZATION_GREECE', leader = 'LEADER_PERIKLES' },
		[21] = { civ = 'CIVILIZATION_GREECE', leader = 'LEADER_PERIKLES' },
		[22] = { civ = 'CIVILIZATION_GREECE', leader = 'LEADER_PERIKLES' },
	}
	unitLists[22] = { NewUnitStub(901, -1, -1), NewUnitStub(902, -1, -1) }
end

Game = {
	GetLocalPlayer = function() return 0 end,
	GetCurrentGameTurn = function() return 1 end,
	GetProperty = function(_, key) return props[key] end,
	SetProperty = function(_, key, value) props[key] = value end,
}
UnitManager = {
	Kill = function(unit, delayed) killCalls[#killCalls + 1] = { unit = unit, delayed = delayed } end,
	PlaceUnit = function() end,
}
CityManager = {
	GetCity = function() return nil end,
	TransferCityToFreeCities = function(city)
		transferCalls[#transferCalls + 1] = city
		return true
	end,
}
WorldBuilder = {
	PlayerManager = function()
		return {
			SetPlayerLeader = function(_, playerID, leaderType, civType, civLevel)
				local config = PlayerConfigurations[playerID]
				config.civ = civType
				config.leader = leaderType
				config.levelID = (civLevel == 'CIVILIZATION_LEVEL_CITY_STATE') and 2 or 1
				Players[playerID].isMajor = (civLevel ~= 'CIVILIZATION_LEVEL_CITY_STATE')
			end,
		}
	end,
	CityManager = function()
		return {
			Create = function(_, playerID, plot)
				local city = { playerID = playerID, plot = plot, id = 1000 + #createdCities }
				createdCities[#createdCities + 1] = city
				return city
			end,
		}
	end,
}
MaxPlayerSlots = function() return 64 end
GameDefines = { MAX_PLAYERS = 64 }
CivilizationLevelTypes = { CIVILIZATION_LEVEL_FULL_CIV = 1, CIVILIZATION_LEVEL_CITY_STATE = 2 }
MODMISC_BUILD_TAG = 'ghost-debug-test'
ExposedMembers = { ModMiscToolScript = {} }
Events = nil

local function LoadModule()
	local chunk = assert(loadfile(MODULE))
	chunk()
end

-- ---------------------------------------------------------------------------
BuildWorld()
LoadModule()

Section('① 面板数据快照')
local list = GetGhostPlayerDebugList()
Check('列出 3 个幽灵', #list == 3, #list)
Check('条目带池标记', list[1].pool == 'major', list[1].pool)
Check('条目带玩家 ID', list[1].playerID == 20, list[1].playerID)
Check('可用性正确', list[1].available == true, list[1].available)
Check('主流身份正确', list[1].isMajor == true, list[1].isMajor)
Check('原身份台账被带出', list[1].originalCivType == 'CIVILIZATION_GREECE',
	list[1].originalCivType)
Check('见面标记默认 false', list[1].met == false, list[1].met)

Section('② 面板入口城邦化放行，其它手动入口仍拦')
local converted, convertReason = ConvertGhostPlayerToCityState(20, nil, 'debug_panel')
Check('debug_panel 城邦化成功', converted == true, convertReason)
Check('20 已不是主流', playerStubs[20].isMajor == false)
local blocked, blockedReason = ConvertGhostPlayerToCityState(21)
Check('无来源（手动）仍被拦', blocked == false, blocked)
Check('拦截原因正确', blockedReason == 'major to city-state conversion blocked', blockedReason)
Check('21 仍是主流', playerStubs[21].isMajor == true)

Section('③ 主流化用原身份复原')
local restored, restoreReason = RestoreGhostPlayerAsMajor(20)
Check('主流化成功', restored == true, restoreReason)
Check('20 已回到主流', playerStubs[20].isMajor == true)
Check('文明恢复成台账原文明', configs[20].civ == 'CIVILIZATION_GREECE', configs[20].civ)
Check('领袖恢复成台账原领袖', configs[20].leader == 'LEADER_PERIKLES', configs[20].leader)

Section('④ 幽灵建城：自动选址 + 建完出池')
local founded, foundReason, foundX, foundY = FoundCityForGhostPlayer(21)
Check('建城成功', founded == true, foundReason)
Check('选中的是唯一空地 (6,5)', foundX == 6 and foundY == 5,
	tostring(foundX) .. ',' .. tostring(foundY))
Check('建城调用落在 21 名下', #createdCities == 1 and createdCities[1].playerID == 21,
	#createdCities)
Check('21 已出池', GetGhostPlayerCount() == 2, GetGhostPlayerCount())

Section('⑤ 移除幽灵：杀单位 + 清池 + 清台账')
local removed, removeReason, killed = RemoveGhostPlayerByKillingUnits(22)
Check('移除成功', removed == true, removeReason)
Check('杀掉 2 个单位', killed == 2, killed)
Check('Kill 被调用 2 次', #killCalls == 2, #killCalls)
Check('先打伤害到 100', killCalls[1] ~= nil and killCalls[1].unit.damage == 100,
	killCalls[1] ~= nil and killCalls[1].unit.damage or nil)
Check('22 已出池', GetGhostPlayerCount() == 1, GetGhostPlayerCount())
Check('22 的原身份台账已清', GetGhostOriginalIdentity(22) == nil)

Section('⑥ 救档：一键未见面主流 -> 城邦')
BuildWorld()
playerStubs[22].isMajor = false          -- 22 已经是城邦身份
metSet[21] = true                        -- 21 已经和本地玩家见过面
LoadModule()
local rescueConverted, rescueFailed, rescueSkipped = ConvertUnmetMajorGhostsToCityState()
Check('转换 1 个未见面主流', rescueConverted == 1, rescueConverted)
Check('失败 0', rescueFailed == 0, rescueFailed)
Check('跳过 2 个（1 见面 + 1 已是城邦）', rescueSkipped == 2, rescueSkipped)
Check('20 已城邦化', playerStubs[20].isMajor == false)
Check('21 仍是主流（见过面不动）', playerStubs[21].isMajor == true)

Section('⑦ 面板列表扩展：幽灵 + 全部存活玩家')
BuildWorld()
LoadModule()
local playerList = GetPlayerDebugList()
Check('幽灵 3 + 存活玩家 1 = 4 条', #playerList == 4, #playerList)
Check('幽灵条目 isGhost=true', playerList[1].isGhost == true, playerList[1].isGhost)
Check('玩家条目 isGhost=false', playerList[4].isGhost == false, playerList[4].isGhost)
Check('玩家条目池标记为 player', playerList[4].pool == 'player', playerList[4].pool)
Check('玩家条目是本地玩家 0', playerList[4].playerID == 0, playerList[4].playerID)
Check('玩家条目带文明/领袖', playerList[4].civType == 'CIVILIZATION_ROME',
	playerList[4].civType)

Section('⑧ 杀死有城市的玩家：转自由城市、不杀单位')
BuildWorld()
LoadModule()
local killed, killReason, transferred, failedCities, unitsLeft = KillSelectedPlayer(0)
Check('杀死成功', killed == true, killReason)
Check('城市转自由城市 1 座', transferred == 1 and failedCities == 0,
	tostring(transferred) .. '/' .. tostring(failedCities))
Check('调用了 TransferCityToFreeCities', #transferCalls == 1, #transferCalls)
Check('没有杀单位', #killCalls == 0, #killCalls)
Check('回报剩余单位 0', unitsLeft == 0, unitsLeft)

Section('⑨ 杀死没有城市的幽灵：只清池、不杀单位')
BuildWorld()
LoadModule()
local killedGhost, ghostReason, ghostTransferred, _, ghostUnits = KillSelectedPlayer(22)
Check('杀死成功（无城市）', killedGhost == true, ghostReason)
Check('原因 no_city', ghostReason == 'no_city', ghostReason)
Check('没有城市可转', ghostTransferred == 0, ghostTransferred)
Check('没有杀单位', #killCalls == 0, #killCalls)
Check('回报剩余单位 2', ghostUnits == 2, ghostUnits)
Check('22 已出池', GetGhostPlayerCount() == 2, GetGhostPlayerCount())

Section('⑩ 非法目标被拒')
local killedBad, badReason = KillSelectedPlayer(999)
Check('不存在的玩家被拒', killedBad == false and badReason == 'no_player', badReason)

print('')
print('--------------------------------------------------')
print('桩测试结果：' .. pass .. ' 项通过，' .. fail .. ' 项失败')
print('--------------------------------------------------')
if fail > 0 then os.exit(1) end
