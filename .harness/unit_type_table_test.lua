-- ===========================================================================
-- 桩测试：单位类型索引（allUnitsTypeTable / WriteUnitDataToTypeTable）+
--         间谍行动查询（ModTool_Support_UI.GetSpyOperations）
--
-- 要证明的事：
--   ① 活单位按 `allUnitData[playerID][unitID].unitType` 落到
--      `allUnitsTypeTable[playerID][unitTypeText][unitID]`，且与 allUnitData 是同一张子表；
--   ② 索引只收活单位：战斗死亡 / 伤害 >= 100 / 离场（plotIndex=nil）/ 升级换 ID
--      都要把旧条目摘掉，allUnitData 里的历史记录仍然保留；
--   ③ 读档路径：Initialize() → LoadData() → InitializeAllUnitsTypeTable() 从 allUnitData
--      全量重建（跳过 removed），并且**原地重建**（ExposedMembers 拿到的是同一个表）；
--   ④ GetSpyOperations 与基座 UnitPanel 的 Espionage 段取数一致；非间谍 / 没在执行行动
--      一律返回 nil,nil,nil；间谍判定走 `GameInfo.Units[type].Spy == true`
--      （自定义间谍单位也认，不写死 'UNIT_SPY'）。
--
-- 跑法（工作目录 = 本项目根）：lua .harness/unit_type_table_test.lua
-- ===========================================================================
local GAMEPLAY_MODULE = "ModTool.lua"
local UI_SUPPORT_MODULE = "ModTool_Support_UI.lua"

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
local SPY_ROW     = { UnitType = 'UNIT_SPY', Index = 10, Spy = true,  PromotionClass = 'PROMOTION_CLASS_SPY' }
local WARRIOR_ROW = { UnitType = 'UNIT_WARRIOR', Index = 11, Spy = false, PromotionClass = 'PROMOTION_CLASS_MELEE' }
local CUSTOM_SPY_ROW = { UnitType = 'UNIT_CUSTOM_SPY', Index = 12, Spy = true, PromotionClass = 'PROMOTION_CLASS_SPY' }
local unitRows = { SPY_ROW, WARRIOR_ROW, CUSTOM_SPY_ROW }

local function NewInfoTable(list)
	local byKey, ordered, idx = {}, {}, 0
	for _, row in ipairs(list) do
		ordered[#ordered + 1] = row
		if row.UnitType ~= nil then byKey[row.UnitType] = row end
		if row.Index ~= nil then byKey[row.Index] = row end
	end
	setmetatable(byKey, { __call = function()
		idx = 0
		return function() idx = idx + 1; return ordered[idx] end
	end })
	return byKey
end

GameInfo = {
	Units = NewInfoTable(unitRows),
	UnitCommands = { UNITCOMMAND_UPGRADE = { Hash = 9001 } },
	Buildings = function() return function() return nil end end,
	Districts = {}, Projects = {}, UnitOperations = { [105] = { Index = 105, OperationType = 'OP_STEAL_TECH' } },
}

local props = {}
Game = {
	GetLocalPlayer = function() return 0 end,
	GetCurrentGameTurn = function() return 33 end,
	GetProperty = function(_, key) return props[key] end,
	SetProperty = function(_, key, value) props[key] = value end,
}

-- 事件表：本测试不跑事件，但 ModTool.lua 载入 / Initialize 会注册，全部给个空壳
local function NewEventTable()
	return setmetatable({}, { __index = function(t, key)
		local ev = { Add = function() return true end, Remove = function() end, Call = function() end }
		rawset(t, key, ev)
		return ev
	end })
end
Events = NewEventTable()
LuaEvents = NewEventTable()

-- 地图：plotIndex >= 0 时算"在地图上"，负数 ⇒ 离场（GetUnitPlotIndexAndCoordinate 返回 nil）
Map = {
	GetPlot = function(x, y)
		if x == nil or y == nil or x < 0 or y < 0 then return nil end
		return { GetX = function() return x end, GetY = function() return y end,
			GetIndex = function() return y * 100 + x end }
	end,
	GetPlotByIndex = function() return nil end,
}

-- 单位桩：typeRow 决定类型，damage 决定血量，offMap=true 模拟"读不到坐标"（幽灵/离场单位）
local function NewUnitStub(id, typeRow, damage, offMap)
	local unit = { id = id, typeRow = typeRow, damage = damage or 0, offMap = offMap == true }
	function unit.GetID() return id end
	function unit.GetType() return typeRow.Index end
	function unit.GetDamage() return unit.damage end
	function unit.GetMilitaryFormation() return 0 end
	return unit
end

local unitsByPlayer = {}
local function NewPlayerStub(playerID)
	return {
		GetUnits = function()
			return {
				FindID = function(_, unitID)
					local units = unitsByPlayer[playerID]
					return units ~= nil and units[unitID] or nil
				end,
			}
		end,
	}
end
Players = setmetatable({}, { __index = function(t, key)
	local p = NewPlayerStub(key); rawset(t, key, p); return p
end })

ExposedMembers = { ModMiscToolScript = {}, ModMiscToolUI = {} }

-- 被测代码依赖 Support_Functions 里的这个转换；索引不关心坐标，桩掉即可
function GetUnitPlotIndexAndCoordinate(unit)
	if unit.offMap then return nil, nil, nil end
	return 100 + unit.id, 4, 5
end

include = function() end   -- Civ6 的 include() 在这里不加载别的文件

-- ---------------------------------------------------------------------------
-- 载入被测模块（真实 ModTool.lua）
-- ---------------------------------------------------------------------------
local chunk = assert(loadfile(GAMEPLAY_MODULE))
chunk()

Section('载入与接口')
Check('WriteUnitDataToTypeTable 已定义', type(WriteUnitDataToTypeTable) == 'function')
Check('RemoveUnitFromTypeTable 已定义', type(RemoveUnitFromTypeTable) == 'function')
Check('InitializeAllUnitsTypeTable 已定义', type(InitializeAllUnitsTypeTable) == 'function')

-- 先跑一次真实的 Initialize()：验证索引表确实被暴露出去（后面的用例都从 ExposedMembers 读，
-- 与外部 mod 看到的一样），同时顺带验证 Initialize → LoadData → 重建 这条链不抛错。
Initialize()
Check('allUnitsTypeTable 已暴露到 ExposedMembers.ModMiscToolScript',
	type(ExposedMembers.ModMiscToolScript.allUnitsTypeTable) == 'table')

local function IndexOf(playerID, unitTypeText)
	local playerTypeTable = ExposedMembers.ModMiscToolScript.allUnitsTypeTable[playerID]
	if playerTypeTable == nil then return nil end
	return playerTypeTable[unitTypeText]
end
local function CountIndex(playerID, unitTypeText)
	local bucket = IndexOf(playerID, unitTypeText)
	if bucket == nil then return 0 end
	local n = 0
	for _ in pairs(bucket) do n = n + 1 end
	return n
end

local function Reset()
	unitsByPlayer = {}
	props = {}
	-- 清掉上一组用例留下的数据（allUnitData 是模块级 local，只能通过公开函数/整体重建清）
	local script = ExposedMembers.ModMiscToolScript
	for playerID in pairs(script.allUnitData or {}) do script.allUnitData[playerID] = nil end
	for playerID in pairs(script.allUnitsTypeTable or {}) do script.allUnitsTypeTable[playerID] = nil end
	if InitializeAllUnitsTypeTable ~= nil then InitializeAllUnitsTypeTable() end
end

-- ---------------------------------------------------------------------------
Section('① 活单位按类型进索引（与 allUnitData 同一张子表）')
Reset()
unitsByPlayer[0] = {
	[1] = NewUnitStub(1, SPY_ROW),
	[2] = NewUnitStub(2, SPY_ROW),
	[3] = NewUnitStub(3, WARRIOR_ROW),
}
RefreshUnitData(0, 1)
RefreshUnitData(0, 2)
RefreshUnitData(0, 3)
Check('两个 UNIT_SPY 都进了索引', CountIndex(0, 'UNIT_SPY') == 2, CountIndex(0, 'UNIT_SPY'))
Check('UNIT_WARRIOR 也进了索引', CountIndex(0, 'UNIT_WARRIOR') == 1)
Check('unitData 与 allUnitData 是同一张子表（引用一致）',
	IndexOf(0, 'UNIT_SPY')[1] == ExposedMembers.ModMiscToolScript.allUnitData[0][1])
Check('活单位显式带 removed=false（外部 `== false` 判定可用）',
	ExposedMembers.ModMiscToolScript.allUnitData[0][1].removed == false)
Check('重复刷新不会产生重复条目', (function()
	RefreshUnitData(0, 1)
	RefreshUnitData(0, 1)
	return CountIndex(0, 'UNIT_SPY') == 2
end)())

-- ---------------------------------------------------------------------------
Section('② 死单位/离场单位从索引摘掉（allUnitData 保留历史）')
Reset()
unitsByPlayer[0] = { [1] = NewUnitStub(1, SPY_ROW) }
RefreshUnitData(0, 1)
Check('先确认在索引里', CountIndex(0, 'UNIT_SPY') == 1)
UnitDeathHandler(0, 1)
Check('UnitDeathHandler 之后不在索引里', CountIndex(0, 'UNIT_SPY') == 0)
Check('allUnitData 里仍留着 removed=true 的历史记录',
	ExposedMembers.ModMiscToolScript.allUnitData[0][1].removed == true)

Reset()
unitsByPlayer[0] = { [2] = NewUnitStub(2, SPY_ROW) }
RefreshUnitData(0, 2)
unitsByPlayer[0][2].damage = 100
RefreshUnitData(0, 2)
Check('伤害 >= 100 的刷新 ⇒ 出索引', CountIndex(0, 'UNIT_SPY') == 0)
Check('allUnitData 标记 removed=true', ExposedMembers.ModMiscToolScript.allUnitData[0][2].removed == true)

Reset()
unitsByPlayer[0] = { [3] = NewUnitStub(3, SPY_ROW) }
RefreshUnitData(0, 3)
unitsByPlayer[0][3].offMap = true          -- 读不到坐标（幽灵玩家 / 已离场）
RefreshUnitData(0, 3)
Check('plotIndex 为 nil 的单位 ⇒ 出索引', CountIndex(0, 'UNIT_SPY') == 0)

-- ---------------------------------------------------------------------------
Section('③ 升级换 ID：旧条目摘掉，新条目进新类型')
Reset()
unitsByPlayer[0] = { [4] = NewUnitStub(4, WARRIOR_ROW) }
RefreshUnitData(0, 4)
-- 升级事件顺序：UnitRemovedFromMap(old) → UnitAddedToMap(new)
unitsByPlayer[0][4] = nil
UnitDeathHandler(0, 4)
unitsByPlayer[0][5] = NewUnitStub(5, SPY_ROW)
RefreshUnitData(0, 5)
Check('旧单位从 UNIT_WARRIOR 桶里消失', CountIndex(0, 'UNIT_WARRIOR') == 0)
Check('新单位进 UNIT_SPY 桶', CountIndex(0, 'UNIT_SPY') == 1 and IndexOf(0, 'UNIT_SPY')[5] ~= nil)

-- ---------------------------------------------------------------------------
Section('④ 读档路径：Initialize() 从 allUnitData 原地重建')
Reset()
local loadData = {
	[0] = {
		[10] = { unitType = 'UNIT_SPY',     unitID = 10, removed = false, iX = 1, iY = 2, plotIndex = 201 },
		[11] = { unitType = 'UNIT_SPY',     unitID = 11, removed = true,  iX = 3, iY = 4, plotIndex = 203 },
		[12] = { unitType = 'UNIT_WARRIOR', unitID = 12, removed = false, iX = 5, iY = 6, plotIndex = 205 },
	},
	[1] = {
		[20] = { unitType = 'UNIT_SPY', unitID = 20, removed = false, iX = 7, iY = 8, plotIndex = 207 },
	},
	-- 坏档防御：存档里混进非表数据时，重建不能炸（本项目有“救档”需求）
	[2] = "garbage",
	[3] = { [30] = 42 },
}
props['kocmoca_modtool_all_units_table_prop'] = loadData
local before = ExposedMembers.ModMiscToolScript.allUnitsTypeTable
Initialize()
Check('索引表引用未被替换（原地重建，外部引用仍然有效）',
	ExposedMembers.ModMiscToolScript.allUnitsTypeTable == before)
Check('玩家 0：活间谍 1 个（removed 的那条被跳过）', CountIndex(0, 'UNIT_SPY') == 1, CountIndex(0, 'UNIT_SPY'))
Check('玩家 0：活战士 1 个', CountIndex(0, 'UNIT_WARRIOR') == 1)
Check('玩家 1：活间谍 1 个', CountIndex(1, 'UNIT_SPY') == 1)
Check('坏档数据（非表 / 非表 unitData）被跳过且不抛错',
	ExposedMembers.ModMiscToolScript.allUnitsTypeTable[2] == nil
	and ExposedMembers.ModMiscToolScript.allUnitsTypeTable[3] == nil)
Check('重建后可正常按类型取到 unitData', (function()
	local bucket = IndexOf(0, 'UNIT_SPY')
	return bucket ~= nil and bucket[10] ~= nil and bucket[10].plotIndex == 201
end)())

-- 二次重建幂等
InitializeAllUnitsTypeTable()
Check('重复重建结果不变（幂等）',
	CountIndex(0, 'UNIT_SPY') == 1 and CountIndex(0, 'UNIT_WARRIOR') == 1 and CountIndex(1, 'UNIT_SPY') == 1)

-- ---------------------------------------------------------------------------
-- 间谍行动查询（UI 支持层）
-- ---------------------------------------------------------------------------
local uiChunk = assert(loadfile(UI_SUPPORT_MODULE))
uiChunk()

Section('⑤ GetSpyOperations：取数与基座 UnitPanel Espionage 段一致')
Check('GetSpyOperations 已定义', type(GetSpyOperations) == 'function')

local spyUnits = {}
ActivityTypes = { ACTIVITY_OPERATION = 5, ACTIVITY_SLEEP = 2 }
UnitManager = {
	GetUnit = function(playerID, unitID)
		local u = spyUnits[playerID]
		return u ~= nil and u[unitID] or nil
	end,
	GetActivityType = function(unit) return unit.activityType end,
	GetTimeToComplete = function(operationIndex, unit)
		if operationIndex == 105 then return 12 end
		return 3
	end,
}

local function NewSpyStub(id, typeRow, activityType, operationIndex, endTurn)
	local unit = NewUnitStub(id, typeRow)
	unit.activityType = activityType
	unit.operationIndex = operationIndex
	unit.endTurn = endTurn
	function unit.GetSpyOperation() return unit.operationIndex end
	function unit.GetSpyOperationEndTurn() return unit.endTurn end
	return unit
end

-- 非间谍
spyUnits[0] = { [1] = NewSpyStub(1, WARRIOR_ROW, ActivityTypes.ACTIVITY_OPERATION, 105, 40) }
local op, remain, total = GetSpyOperations(0, 1)
Check('非间谍单位 ⇒ nil,nil,nil', op == nil and remain == nil and total == nil, tostring(op))

-- 间谍但没在执行行动
spyUnits[0] = { [2] = NewSpyStub(2, SPY_ROW, ActivityTypes.ACTIVITY_SLEEP, 105, 40) }
op, remain, total = GetSpyOperations(0, 2)
Check('间谍在睡觉（非 ACTIVITY_OPERATION）⇒ nil', op == nil and remain == nil and total == nil)

-- 间谍、行动类型对，但 GetSpyOperation() = -1（站着没事干）
spyUnits[0] = { [3] = NewSpyStub(3, SPY_ROW, ActivityTypes.ACTIVITY_OPERATION, -1, 40) }
op, remain, total = GetSpyOperations(0, 3)
Check('GetSpyOperation() = -1 ⇒ nil', op == nil or op == -1)

-- 正常执行任务：第 33 回合，行动第 40 回合结束，总时长 12
spyUnits[0] = { [4] = NewSpyStub(4, SPY_ROW, ActivityTypes.ACTIVITY_OPERATION, 105, 40) }
op, remain, total = GetSpyOperations(0, 4)
Check('行动 index 取到 UnitOperations 的那一条（105）', op == 105, op)
Check('剩余回合 = 40 - 33 = 7', remain == 7, remain)
Check('总回合 = GetTimeToComplete = 12', total == 12, total)
Check('行动能反查 GameInfo.UnitOperations（调用方拼图标用）',
	GameInfo.UnitOperations[op] ~= nil and GameInfo.UnitOperations[op].OperationType == 'OP_STEAL_TECH')

-- 自定义间谍单位（Spy=true 但不是 UNIT_SPY）也要认
spyUnits[0] = { [5] = NewSpyStub(5, CUSTOM_SPY_ROW, ActivityTypes.ACTIVITY_OPERATION, 105, 40) }
op, remain, total = GetSpyOperations(0, 5)
Check('自定义间谍单位（Units.Spy=true）也能取到', op == 105 and remain == 7 and total == 12)

-- 单位不存在
spyUnits[0] = {}
op, remain, total = GetSpyOperations(0, 99)
Check('单位不存在 ⇒ nil,nil,nil', op == nil and remain == nil and total == nil)

-- 类型行不在数据库里（防御）
local weirdRow = { Index = 77, UnitType = 'UNIT_WEIRD' }
spyUnits[0] = { [6] = NewSpyStub(6, weirdRow, ActivityTypes.ACTIVITY_OPERATION, 105, 40) }
op, remain, total = GetSpyOperations(0, 6)
Check('GameInfo.Units[type] 查不到 ⇒ nil,nil,nil（不抛错）',
	op == nil and remain == nil and total == nil)

-- ---------------------------------------------------------------------------
print(string.format("\n== 结果：%d 项通过，%d 项失败", pass, fail))
if fail > 0 then os.exit(1) end
