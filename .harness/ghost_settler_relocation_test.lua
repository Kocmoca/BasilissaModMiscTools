-- ===========================================================================
-- 桩测试：幽灵开拓者归位（ModTool_GhostPlayers.lua 里的
--   IsUnitOffMap / RelocateOffMapSettlersIntoCity / HandleGhostCityAddedToMap /
--   EnsureGhostSettlerInCity / HandleGhostCityTransfered）
--
-- 要证明的事（授权者 2026-10-17 两轮实机事故的回归防线）：
--   ① 只有"坐标读成功 + 为负 + 引擎地图上取不到该 plot + 单位还活着"才算地图外；
--   ② 读不到坐标 / 地图上存在该地块 ⇒ 一律不搬（本地玩家建城时的脏句柄属于这一类）；
--   ③ **非幽灵玩家（本地玩家、普通 AI、正常城邦）任何情况下都不搬**；
--   ④ 真的地图外开拓者仍然要能搬进城市。
--
-- 跑法（工作目录 = 本项目根）：lua5.1 .harness/ghost_settler_relocation_test.lua
-- ===========================================================================
local MODULE = "ModTool_GhostPlayers.lua"
local GHOST_ID = 20

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
local settlerRow = { UnitType = 'UNIT_SETTLER', FoundCity = true, Index = 1, Hash = 1001 }
local warriorRow = { UnitType = 'UNIT_WARRIOR', FoundCity = false, Index = 2, Hash = 1002 }
local rows = { settlerRow, warriorRow }

local function NewInfoTable(list)
	local byKey, ordered, idx = {}, {}, 0
	for _, row in ipairs(list) do
		ordered[#ordered + 1] = row
		if row.UnitType ~= nil then byKey[row.UnitType] = row end
		if row.Hash ~= nil then byKey[row.Hash] = row end
	end
	setmetatable(byKey, { __call = function()
		idx = 0
		return function() idx = idx + 1; return ordered[idx] end
	end })
	return byKey
end

GameInfo = {
	Units = NewInfoTable(rows),
	Leaders = {}, Civilizations = {},
}
UnitManager = { PlaceUnit = function(unit, x, y) end }
local props = {}
Game = {
	GetLocalPlayer = function() return 0 end,
	GetCurrentGameTurn = function() return 30 end,
	GetProperty = function(_, key) return props[key] end,
	SetProperty = function(_, key, value) props[key] = value end,
}

-- 地图：只有非负坐标才存在 plot
Map = { GetPlot = function(x, y)
	if x == nil or y == nil then return nil end
	if x < 0 or y < 0 then return nil end
	return { GetX = function() return x end, GetY = function() return y end,
		GetIndex = function() return y * 100 + x end }
end }
Map.GetPlotByIndex = function() return nil end
Map.GetNeighborPlots = function() return {} end

CityManager = { GetCity = function(_, cityID)
	return { GetID = function() return cityID end,
		GetX = function() return 21 end, GetY = function() return 22 end,
		GetName = function() return 'LOC_CITY_STUB' end }
end }

-- 单位桩：mode 控制它"看起来"是什么
local function NewUnitStub(id, mode, x, y, damage)
	local unit = { id = id }
	function unit.GetID() return id end
	function unit.GetType() return 1001 end
	function unit.GetDamage() return damage or 0 end
	function unit.SetDamage() end
	function unit.IsDelayedDeath() return mode == 'delayed' end
	if mode == 'throw' then
		unit.GetX = function() error('stale handle') end
		unit.GetY = function() error('stale handle') end
	else
		unit.GetX = function() return x end
		unit.GetY = function() return y end
	end
	unit.IsAlive = function() return mode ~= 'dead' end
	return unit
end

local unitLists = {}          -- playerID -> {unit, ...}
local placeCalls = {}         -- 记录 PlaceUnit
local function NewPlayer(id)
	local player = { id = id }
	player.GetUnits = function()
		local list = unitLists[id] or {}
		local index = 0
		return { Members = function()
			return function()
				index = index + 1
				local unit = list[index]
				if unit == nil then return nil end
				return index, unit
			end
		end }
	end
	player.GetCities = function() return { GetCapitalCity = function() return nil end,
		GetCount = function() return 0 end,
		Members = function() return function() return nil end end } end
	player.IsMajor = function() return true end
	player.GetDiplomacy = function() return { HasMet = function() return false end } end
	return player
end
Players = setmetatable({}, { __index = function(t, key)
	local p = NewPlayer(key); rawset(t, key, p); return p
end })

PlayerConfigurations = setmetatable({}, { __index = function(t, key)
	local cfg = {}
	cfg.GetCivilizationTypeName = function() return 'CIVILIZATION_ROME' end
	cfg.GetLeaderTypeName = function() return 'LEADER_TRAJAN' end
	cfg.GetCivilizationLevelTypeID = function() return 1 end
	rawset(t, key, cfg); return cfg
end })
CivilizationLevelTypes = { CIVILIZATION_LEVEL_FULL_CIV = 1, CIVILIZATION_LEVEL_CITY_STATE = 2 }
ExposedMembers = { ModMiscToolScript = {} }
Events = nil   -- 不注册事件，只测函数

-- ---------------------------------------------------------------------------
-- 载入被测模块
-- ---------------------------------------------------------------------------
local chunk = assert(loadfile(MODULE))
chunk()

Section('载入与接口')
Check('RelocateOffMapSettlersIntoCity 已定义', type(RelocateOffMapSettlersIntoCity) == 'function')
Check('IsGhostOrFormerGhost 已定义', type(IsGhostOrFormerGhost) == 'function')

-- 【授权者 2026-10-17 定案】判据只有一条：玩家名下有没有"正常存活的、坐标为负的开拓者"。
-- 不再按"是不是幽灵 / 是不是本地玩家"过滤，所以这里也不需要钉身份。

local function Reset()
	unitLists = {}
	placeCalls = {}
	UnitManager.PlaceUnit = function(unit, x, y)
		table.insert(placeCalls, { id = unit.GetID and unit.GetID() or '?', x = x, y = y })
		-- 模拟引擎真的把单位放上地图（这样二次调用不会重复搬运）
		local xx, yy = x, y
		unit.GetX = function() return xx end
		unit.GetY = function() return yy end
	end
end

-- ---------------------------------------------------------------------------
Section('① 真的地图外开拓者 ⇒ 搬进城市')
Reset()
unitLists[GHOST_ID] = { NewUnitStub(501, 'normal', -1, -1) }
local moved = RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试')
Check('地图外开拓者被拉进城市', moved == 1 and #placeCalls == 1
	and placeCalls[1].x == 12 and placeCalls[1].y == 34,
	tostring(moved) .. '/' .. tostring(#placeCalls))
Check('同一玩家再跑一次不会重复搬（已在地图内）',
	RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试·二次') == 0)

-- ---------------------------------------------------------------------------
Section('② 在地图内的开拓者 ⇒ 不动')
Reset()
unitLists[GHOST_ID] = { NewUnitStub(502, 'normal', 5, 6) }
Check('地图内的开拓者不搬', RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 0
	and #placeCalls == 0)

-- ---------------------------------------------------------------------------
Section('③ 脏句柄（读坐标报错）⇒ 不动  ← 本地玩家建城事故的正因')
Reset()
unitLists[GHOST_ID] = { NewUnitStub(503, 'throw') }
Check('读不到坐标的单位一律不搬', RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 0
	and #placeCalls == 0, #placeCalls)

-- ---------------------------------------------------------------------------
Section('④ 已经死掉的单位 ⇒ 不动')
Reset()
unitLists[GHOST_ID] = { NewUnitStub(504, 'dead', -1, -1) }
Check('IsAlive=false 的单位不搬', RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 0
	and #placeCalls == 0)

-- ---------------------------------------------------------------------------
Section('④b 血量/将死过滤（建城被消耗的开拓者不能再被搬回来）')
Reset()
unitLists[GHOST_ID] = { NewUnitStub(506, 'normal', -1, -1, 100) }
Check('GetDamage()>=100 的单位不搬（本项目杀单位是先 SetDamage(100) 再 Kill）',
	RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 0 and #placeCalls == 0)

Reset()
unitLists[GHOST_ID] = { NewUnitStub(507, 'delayed', -1, -1) }
Check('IsDelayedDeath=true 的单位不搬',
	RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 0 and #placeCalls == 0)

Reset()
unitLists[GHOST_ID] = { NewUnitStub(508, 'normal', -1, -1, 60) }
Check('掉血但还活着（<100）的地图外开拓者照旧搬',
	RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 1 and #placeCalls == 1)

-- ---------------------------------------------------------------------------
Section('⑤ 判据只到坐标为负：**不再**拿 Map.GetPlot 交叉验证')
-- 授权者 2026-10-17：地图上不显示的玩家/单位照样能取到地块 ⇒ 用"取不到地块"当判据会误杀幽灵。
Reset()
local savedGetPlot = Map.GetPlot
Map.GetPlot = function(x, y) return { GetX = function() return x end, GetY = function() return y end } end
unitLists[GHOST_ID] = { NewUnitStub(505, 'normal', -1, -1) }
Check('坐标为负 ⇒ 即使 Map.GetPlot 能取到地块也照样搬',
	RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 1 and #placeCalls == 1,
	tostring(#placeCalls))
Map.GetPlot = savedGetPlot

-- ---------------------------------------------------------------------------
Section('⑥ 判据只有"存活 + 负坐标"：没有这种单位就什么都不做')
Reset()
unitLists[0] = { NewUnitStub(601, 'normal', 5, 6) }          -- 本地玩家的普通单位
unitLists[7] = { NewUnitStub(602, 'throw') }                 -- 普通 AI 的脏句柄
Check('没有地图外开拓者 ⇒ 不搬（本地玩家）',
	RelocateOffMapSettlersIntoCity(0, 12, 34, '桩测试') == 0 and #placeCalls == 0)
Check('没有地图外开拓者 ⇒ 不搬（普通 AI 脏句柄）',
	RelocateOffMapSettlersIntoCity(7, 12, 34, '桩测试') == 0 and #placeCalls == 0)
Check('EnsureGhostSettlerInCity 同样只在有地图外开拓者时才动',
	EnsureGhostSettlerInCity(7, 12, 34, '桩测试') == 0 and #placeCalls == 0)

Section('⑦ 城市落地/转城事件：只看"有没有正常存活的负坐标开拓者"')
Reset()
unitLists[0] = { NewUnitStub(701, 'normal', 10, 29) }        -- 本地玩家：全在地图内
unitLists[7] = { NewUnitStub(702, 'normal', 10, 29) }
unitLists[GHOST_ID] = { NewUnitStub(703, 'normal', 10, 29) }
HandleGhostCityAddedToMap(0, 65536, 10, 29)
HandleGhostCityAddedToMap(7, 65537, 10, 29)
HandleGhostCityAddedToMap(GHOST_ID, 65538, 10, 29)
Check('都没有地图外开拓者 ⇒ 一律不动', #placeCalls == 0, #placeCalls)

-- 幽灵建城时"已被归到本地玩家名下"的情形：ownerID 就是本地玩家，但名下确有负坐标开拓者
Reset()
unitLists[0] = { NewUnitStub(711, 'normal', 10, 29),
	NewUnitStub(712, 'normal', -1, -1) }                     -- 本地玩家名下出现地图外开拓者
HandleGhostCityAddedToMap(0, 65539, 10, 29)
Check('本地玩家名下确有存活负坐标开拓者 ⇒ 照样归位（幽灵被归到它名下）',
	#placeCalls == 1 and placeCalls[1].id == 712, #placeCalls)

Reset()
unitLists[7] = { NewUnitStub(721, 'normal', -1, -1) }
HandleGhostCityTransfered(7, 65540)
Check('转城事件同样只看该判据', #placeCalls == 1 and placeCalls[1].id == 721, #placeCalls)

Reset()
unitLists[0] = { NewUnitStub(731, 'normal', 10, 29) }
HandleGhostCityTransfered(0, 65541)
Check('转城事件：没有这种单位就不动', #placeCalls == 0)

Section('⑧ 非开拓者单位永远不搬')
Reset()
local warrior = NewUnitStub(801, 'normal', -1, -1)
warrior.GetType = function() return 1002 end
unitLists[GHOST_ID] = { warrior }
Check('地图外的非开拓者单位不搬', RelocateOffMapSettlersIntoCity(GHOST_ID, 12, 34, '桩测试') == 0
	and #placeCalls == 0)

print('')
print('--------------------------------------------------')
print('桩测试结果：' .. pass .. ' 项通过，' .. fail .. ' 项失败')
print('--------------------------------------------------')
if fail > 0 then os.exit(1) end
