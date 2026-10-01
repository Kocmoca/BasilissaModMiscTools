-- ===========================================================================
-- Mod Misc Tool: 幽灵玩家（引擎认可的 off-map 玩家）
--
-- 参照 EXera（分封城邦）的做法：开局时把若干尚未建城的城邦玩家搬到地图外
-- （清掉地图上的单位，只在地图外 (-1,-1) 留一个开拓者），这些玩家从开局就
-- 存在于 game core，AI/外交子系统都有它们的条目。
--
-- 这样测试面板就能拿这些槽位当“新玩家”用：改文明/领袖、建城、放单位都不会
-- 像运行中 PlayerManager():AddPlayer() 那样把 AI 外交表踩空（
-- GameCore::AI::Diplomatic::GetDiplomaticStateIndex 空指针 → 闪退）。
--
-- 只在全新开局（回合 <= 1）且尚未记录过时执行一次；读档进老局不会动任何城邦。
-- ===========================================================================

-- [待验证] 幽灵化的主要文明是否顺手改成城邦（避免它继续参与外交）。
-- 若这一步在实机上引起异常，把这里改成 false 即可关掉（面板「回收成幽灵」仍可单独触发）。
local GHOST_CONVERT_MAJOR_TO_CITY_STATE = true
local GHOST_PLAYER_MAX = 64   -- 兜底上限（正常用不到：所有多余城邦都当幽灵）
local GHOST_PLAYER_PROPERTY = 'kocmoca_modmisctool_ghost_players'
local UNIT_TYPE_SETTLER = 'UNIT_SETTLER'

-- ===========================================================================
-- 幽灵玩家列表（存档内持久化）
-- ===========================================================================

function GetGhostPlayers()
	local ghosts = Game:GetProperty(GHOST_PLAYER_PROPERTY)
	if ghosts == nil then return {} end
	return ghosts
end

function IsGhostPlayer(playerID)
	if playerID == nil then return false end
	for _, ghostID in ipairs(GetGhostPlayers()) do
		if ghostID == playerID then return true end
	end
	return false
end

-- ===========================================================================
-- 查询接口（供其他 mod 调用）
-- ===========================================================================

function GetGhostPlayerCount()
	return #GetGhostPlayers()
end

-- 是否“可用”：仍是幽灵（off-map）、没有首都、也没有地图上的单位
function IsGhostPlayerAvailable(playerID)
	if not IsGhostPlayer(playerID) then return false end

	local player = Players[playerID]
	if player == nil then return false end

	local cities = player:GetCities()
	if cities ~= nil and cities:GetCapitalCity() ~= nil then return false end

	return not PlayerHasOnMapUnit(playerID)
end

function GetAvailableGhostPlayers()
	local available = {}
	for _, playerID in ipairs(GetGhostPlayers()) do
		if IsGhostPlayerAvailable(playerID) then
			table.insert(available, playerID)
		end
	end
	return available
end

function GetAvailableGhostPlayerCount()
	return #GetAvailableGhostPlayers()
end

-- 取一个可用幽灵的玩家 ID（没有则返回 nil）
function GetAvailableGhostPlayerID()
	local available = GetAvailableGhostPlayers()
	return available[1]
end

-- ---------------------------------------------------------------------------
-- 预约（claim）：多个 mod 同时取幽灵时避免抢到同一个
-- 说明：claim 只是建议性记录，不改变“可用”判定；用不到时调用 ReleaseGhostPlayer 释放，
--       幽灵被带回地图后会被自动清理。
-- ---------------------------------------------------------------------------

local GHOST_CLAIM_PROPERTY = 'kocmoca_modmisctool_ghost_claims'

function GetGhostPlayerClaims()
	local claims = Game:GetProperty(GHOST_CLAIM_PROPERTY)
	if claims == nil then return {} end
	return claims
end

function IsGhostPlayerClaimed(playerID)
	for _, claimedID in ipairs(GetGhostPlayerClaims()) do
		if claimedID == playerID then return true end
	end
	return false
end

-- 预约一个可用幽灵；返回 playerID，没有可用则返回 nil
function ClaimAvailableGhostPlayer()
	local claims = GetGhostPlayerClaims()
	for _, playerID in ipairs(GetGhostPlayers()) do
		if IsGhostPlayerAvailable(playerID) and not IsGhostPlayerClaimed(playerID) then
			table.insert(claims, playerID)
			Game:SetProperty(GHOST_CLAIM_PROPERTY, claims)
			return playerID
		end
	end
	return nil
end

function ReleaseGhostPlayer(playerID)
	local claims = GetGhostPlayerClaims()
	for index = #claims, 1, -1 do
		if claims[index] == playerID then
			table.remove(claims, index)
		end
	end
	Game:SetProperty(GHOST_CLAIM_PROPERTY, claims)
end

-- ===========================================================================
-- 上/下地图
-- ===========================================================================

function PlayerHasOnMapUnit(playerID)
	local player = Players[playerID]
	if player == nil then return false end
	local units = player:GetUnits()
	if units == nil then return false end
	for _, unit in units:Members() do
		if unit:GetX() >= 0 and unit:GetY() >= 0 then
			return true
		end
	end
	return false
end

-- 把玩家搬到地图外。
--
-- 关键顺序：**先保证地图外有一个开拓者，再处理地图上的单位**——否则玩家会出现
-- “零单位”的瞬间，被引擎判定为灭亡（幽灵玩家就死了）。
-- 地图上的开拓者优先用 UnitManager.PlaceUnit 直接挪到地图外（基座 AustraliaScenario
-- 有用例），挪不动才退化为 UnitManager.Kill。
-- 能否把该玩家回收成幽灵。返回 nil 表示可以，否则返回原因字符串。
-- 【硬规则·授权者实机验证】已经建城的玩家一律不能回收：
--   引擎在“全部城市被移除”时会直接判定玩家死亡，手里有开拓者也救不回来，
--   所以这里连碰都不碰（既不拆城、也不清单位），只回报原因。
function GetGhostifyBlockReason(playerID)
	local player = Players[playerID]
	if player == nil then
		return "no engine player"
	end
	-- 注意：本函数在文件前段（CallOrNil 还没声明），所以直接用 pcall，别用 CallOrNil
	local ok, cities = pcall(function() return player:GetCities() end)
	if not ok then
		cities = nil
	end
	if cities ~= nil then
		local cityCount = 0
		for _ in cities:Members() do
			cityCount = cityCount + 1
		end
		if cityCount > 0 then
			return "player has " .. tostring(cityCount) .. " city/cities"
		end
	end
	return nil
end

function MovePlayerOffMap(playerID)
	local player = Players[playerID]
	if player == nil then return false end

	-- 有城市的玩家不动：移除全部城市 = 玩家死亡（开拓者也救不回来）
	local blockReason = GetGhostifyBlockReason(playerID)
	if blockReason ~= nil then
		print("[ModMiscTool][Ghost] refuse to ghost player " .. tostring(playerID)
			.. ": " .. blockReason .. "（已有城市，回收会致死）")
		return false
	end

	-- 收集地图上的单位，并记录是否已经有地图外单位
	local onMapUnits = {}
	local hasOffMapUnit = false
	local units = player:GetUnits()
	if units ~= nil then
		for _, unit in units:Members() do
			if unit:GetX() >= 0 and unit:GetY() >= 0 then
				table.insert(onMapUnits, unit)
			else
				hasOffMapUnit = true
			end
		end
	end

	-- 1) 先在地图外放好开拓者：玩家全程都有单位，不会被引擎判定为灭亡
	--    （EXera 的 DeleteUnitsOnMap 就是这个手法：地图外有单位后，这些城邦的单位
	--      就不会出现在地图上）
	if not hasOffMapUnit then
		UnitManager.InitUnit(playerID, UNIT_TYPE_SETTLER, -1, -1)
	end

	-- 2) 再清掉地图上的单位。
	--    [已验证失败] UnitManager.PlaceUnit(unit, -1, -1)：调用不报错，但引擎会把单位拉回地图，
	--    幽灵重新落地建城（表现为“所有玩家都不是幽灵”）。搬离地图只能用 InitUnit + Kill。
	--    [已验证失败] 反过来先 Kill 再 InitUnit：中间有“零单位”瞬间，玩家被判灭亡直接死掉。
	local killedCount = 0
	for _, unit in ipairs(onMapUnits) do
		UnitManager.Kill(unit, false)
		killedCount = killedCount + 1
	end

	print("[ModMiscTool][Ghost] player " .. tostring(playerID) .. " moved off-map"
		.. " onMapUnits=" .. tostring(#onMapUnits)
		.. " killed=" .. tostring(killedCount)
		.. " offMapSettlerCreated=" .. tostring(not hasOffMapUnit))
	return true
end

-- ===========================================================================
-- 运行时补建幽灵槽位（EXera 分封城邦 CreateCityStatePlayer 的做法）
--
-- 引擎自己创建的城邦玩家数量受“数据库里城邦文明条数”限制（请求 62 只出 36）。
-- 但“不能重复文明”的拦截很可能只在 UI 层，引擎层未必禁止，所以这里尝试另一种途径：
--   取一个空玩家槽位 → 直接给 PlayerConfigurations 设城邦文明（可复用已有类型）
--   → StartCityState() 初始化 → 立刻搬到地图外 → 登记进幽灵池。
-- 全程不复制数据库，得到的仍是“引擎认可的玩家”。
-- ===========================================================================

-- 数据库里所有城邦文明类型（gameplay 端可直接读 GameInfo）
local function GetCityStateCivTypes()
	local civTypes = {}
	for civRow in GameInfo.Civilizations() do
		if civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE' then
			table.insert(civTypes, civRow.CivilizationType)
		end
	end
	return civTypes
end

-- 数据库里所有主要文明类型
local function GetMajorCivTypes()
	local civTypes = {}
	for civRow in GameInfo.Civilizations() do
		if civRow.StartingCivilizationLevelType ~= 'CIVILIZATION_LEVEL_CITY_STATE' then
			table.insert(civTypes, civRow.CivilizationType)
		end
	end
	return civTypes
end

-- 取某文明的默认领袖（CivilizationLeaders）
local function GetDefaultLeaderType(civType)
	for civLeaderRow in GameInfo.CivilizationLeaders() do
		if civLeaderRow.CivilizationType == civType then
			return civLeaderRow.LeaderType
		end
	end
	return nil
end

-- 空槽位：玩家配置里没有文明类型（EXera 的 FindEmptyPlayerSlot）
local function FindEmptyPlayerSlot()
	for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
		local playerConfig = PlayerConfigurations[playerID]
		if playerConfig ~= nil then
			local civType = playerConfig:GetCivilizationTypeName()
			if civType == nil or civType == '' then
				return playerID
			end
		end
	end
	return nil
end

-- ===========================================================================
-- 诊断：补建失败时定位“卡在哪一步”
--   1) DumpPlayerSlots —— 槽位全貌：引擎实际建了几个玩家、还剩几个空槽位
--   2) DescribeSlot    —— 单个槽位的“配置侧 + 引擎侧”状态
--   3) SetConfigEx     —— 每个 setter 单独 pcall 并回读，区分“没这个 API”和“设了没生效”
-- ===========================================================================
local m_LastCreateDiagnostics = nil

local SLOT_STATUS_NAMES = {}
if SlotStatus ~= nil then
	if SlotStatus.SS_OPEN ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_OPEN] = 'SS_OPEN' end
	if SlotStatus.SS_COMPUTER ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_COMPUTER] = 'SS_COMPUTER' end
	if SlotStatus.SS_TAKEN ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_TAKEN] = 'SS_TAKEN' end
	if SlotStatus.SS_CLOSED ~= nil then SLOT_STATUS_NAMES[SlotStatus.SS_CLOSED] = 'SS_CLOSED' end
end

local function SlotStatusName(status)
	if status == nil then
		return 'nil'
	end
	return SLOT_STATUS_NAMES[status] or ('#' .. tostring(status))
end

-- pcall 包一层：取值失败时返回 nil，别把脚本打断
local function CallOrNil(fn)
	local ok, value = pcall(fn)
	if not ok then
		return nil
	end
	return value
end

local function MaxPlayerSlots()
	local maxSlots = CallOrNil(function() return GameDefines.MAX_PLAYERS end)
	if type(maxSlots) ~= 'number' or maxSlots <= 0 then
		return 64
	end
	return maxSlots
end

-- CityStates 表里该城邦文明对应的城邦类型（EXera 会额外设这一个字段）
local function GetCityStateTypeFor(civType)
	if GameInfo.CityStates == nil then
		print("[ModMiscTool][Ghost] GameInfo.CityStates is nil（本版本没有城邦类型表）")
		return nil
	end
	for cityStateRow in GameInfo.CityStates() do
		if cityStateRow.CivilizationType == civType then
			return cityStateRow.CityStateType
		end
	end
	return nil
end

local function DescribeSlot(playerID)
	local playerConfig = PlayerConfigurations[playerID]
	if playerConfig == nil then
		return "slot " .. tostring(playerID) .. " config=nil"
	end
	local civType = CallOrNil(function() return playerConfig:GetCivilizationTypeName() end)
	local leaderType = CallOrNil(function() return playerConfig:GetLeaderTypeName() end)
	local cityStateType = CallOrNil(function() return playerConfig:GetCityStateType() end)
	local isMinorCiv = CallOrNil(function() return playerConfig:IsMinorCiv() end)
	local slotStatus = CallOrNil(function() return playerConfig:GetSlotStatus() end)

	local player = Players[playerID]
	local engineState = 'enginePlayer=nil'
	if player ~= nil then
		local alive = CallOrNil(function() return player:IsAlive() end)
		local unitCount = nil
		local units = CallOrNil(function() return player:GetUnits() end)
		if units ~= nil then
			unitCount = 0
			for _ in units:Members() do
				unitCount = unitCount + 1
			end
		end
		local capital = CallOrNil(function() return player:GetCapitalCity() end)
		engineState = 'enginePlayer=yes alive=' .. tostring(alive)
			.. ' units=' .. tostring(unitCount)
			.. ' capital=' .. tostring(capital ~= nil)
	end
	return "slot " .. tostring(playerID)
		.. " civ=" .. tostring(civType)
		.. " leader=" .. tostring(leaderType)
		.. " csType=" .. tostring(cityStateType)
		.. " isMinor=" .. tostring(isMinorCiv)
		.. " status=" .. SlotStatusName(slotStatus)
		.. " " .. engineState
end

local function DumpPlayerSlots(tag)
	local emptySlots = {}
	local enginePlayerCount = 0
	local majorCount, minorCount, otherCount = 0, 0, 0
	for playerID = 0, MaxPlayerSlots() - 1 do
		local playerConfig = PlayerConfigurations[playerID]
		if playerConfig == nil then
			table.insert(emptySlots, tostring(playerID) .. '(noConfig)')
		else
			local civType = CallOrNil(function() return playerConfig:GetCivilizationTypeName() end)
			if civType == nil or civType == '' then
				table.insert(emptySlots, tostring(playerID))
			else
				local civRow = GameInfo.Civilizations[civType]
				if civRow ~= nil and civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE' then
					minorCount = minorCount + 1
				elseif string.find(civType, 'BARBARIAN') ~= nil or string.find(civType, 'FREE_CITIES') ~= nil then
					otherCount = otherCount + 1
				else
					majorCount = majorCount + 1
				end
			end
		end
		if Players[playerID] ~= nil then
			enginePlayerCount = enginePlayerCount + 1
		end
	end
	print("[ModMiscTool][Ghost] slotdump(" .. tag .. ") MAX_PLAYERS=" .. tostring(MaxPlayerSlots())
		.. " enginePlayers=" .. tostring(enginePlayerCount)
		.. " major=" .. tostring(majorCount) .. " minor=" .. tostring(minorCount)
		.. " barbOrFree=" .. tostring(otherCount)
		.. " emptySlots=" .. tostring(#emptySlots))
	print("[ModMiscTool][Ghost] slotdump(" .. tag .. ") empty slot ids: "
		.. (#emptySlots > 0 and table.concat(emptySlots, ',') or 'none'))
	return {
		emptySlots = emptySlots,
		enginePlayers = enginePlayerCount,
		major = majorCount,
		minor = minorCount,
		barbOrFree = otherCount,
	}
end

-- 每个 setter 单独 pcall + 回读
local function SetConfigEx(playerConfig, label, setter, reader)
	local ok, err = pcall(setter)
	local readBack = nil
	if reader ~= nil then
		readBack = CallOrNil(reader)
	end
	print("[ModMiscTool][Ghost]   set " .. label
		.. " ok=" .. tostring(ok)
		.. (ok and '' or (' err=' .. tostring(err)))
		.. (reader ~= nil and (' -> read ' .. tostring(readBack)) or ''))
	return ok
end

-- [已验证失败] 运行时补建玩家对象：引擎不兑现。
--   设备实测（2026-10）：PlayerConfigurations 改得动、回读也对，但 Players[slot] 恒为 nil，
--   日志 `slot N configured but not created by engine`；城邦与主要文明两条路结论一致。
--   且 EXera 的 CreateCityStatePlayer 在其工程里零调用点（死代码），此路从未被真正走通。
--   本函数因此只保留作“验证引擎限制”的诊断入口（面板两个「补建幽灵槽位」按钮），
--   正常扩容请走 InitializeGhostPlayers / InitializeGhostMajorPlayers（抬上限路线）。
-- 运行时补建一个槽位；成功返回 playerID，失败返回 nil + 原因（同时打到日志）。
--   civType 省略：轮流用一个城邦文明（EXera 路径）
--   civType 给定：用指定文明；主要文明走同样的配置流程（isMinor=false、SS_TAKEN）
-- 用途：验证“不能重复文明 / 玩家数量上限”是否只在 UI 层。
function CreateGhostPlayerFromEmptySlot(civType)
	local civRow = nil
	local isMinor = true

	local cityStateCivTypes = GetCityStateCivTypes()
	local majorCivTypes = GetMajorCivTypes()

	if civType == nil then
		if #cityStateCivTypes == 0 then
			print("[ModMiscTool][Ghost] no city state civ type in database")
			m_LastCreateDiagnostics = 'db has no city-state civ'
			return nil, m_LastCreateDiagnostics
		end
		civType = cityStateCivTypes[(#GetGhostPlayers() % #cityStateCivTypes) + 1]
		civRow = GameInfo.Civilizations[civType]
	else
		civRow = GameInfo.Civilizations[civType]
		if civRow == nil then
			print("[ModMiscTool][Ghost] unknown civ type " .. tostring(civType))
			m_LastCreateDiagnostics = 'unknown civ ' .. tostring(civType)
			return nil, m_LastCreateDiagnostics
		end
		isMinor = civRow.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_CITY_STATE'
	end

	print("[ModMiscTool][Ghost] create request: civ=" .. tostring(civType)
		.. " minor=" .. tostring(isMinor)
		.. " db cityStates=" .. tostring(#cityStateCivTypes)
		.. " db majors=" .. tostring(#majorCivTypes))

	local slotStats = DumpPlayerSlots('before-create')
	local slot = FindEmptyPlayerSlot()
	if slot == nil then
		print("[ModMiscTool][Ghost] no empty player slot")
		print("[ModMiscTool][Ghost] 结论：引擎已把 " .. tostring(MaxPlayerSlots())
			.. " 个槽位全部占满，没有可补建的槽位")
		m_LastCreateDiagnostics = 'no empty slot'
		return nil, m_LastCreateDiagnostics
	end
	print("[ModMiscTool][Ghost] picked empty slot " .. tostring(slot)
		.. " (empty slots: " .. table.concat(slotStats.emptySlots, ',') .. ")")

	-- 城邦走 EXera 的完整路径：除文明类型外还要给 CityStates 表里的城邦类型
	local cityStateType = nil
	if isMinor then
		cityStateType = GetCityStateTypeFor(civType)
		print("[ModMiscTool][Ghost] city state type for " .. tostring(civType)
			.. " = " .. tostring(cityStateType))
	end

	local leaderType = GetDefaultLeaderType(civType)
	print("[ModMiscTool][Ghost] creating player at slot " .. tostring(slot)
		.. " civ=" .. tostring(civType) .. " leader=" .. tostring(leaderType)
		.. " csType=" .. tostring(cityStateType) .. " minor=" .. tostring(isMinor))
	print("[ModMiscTool][Ghost]   before config: " .. DescribeSlot(slot))

	local playerConfig = PlayerConfigurations[slot]
	if playerConfig == nil then
		print("[ModMiscTool][Ghost] PlayerConfigurations[" .. tostring(slot) .. "]=nil")
		m_LastCreateDiagnostics = 'no player config for slot ' .. tostring(slot)
		return nil, m_LastCreateDiagnostics
	end

	SetConfigEx(playerConfig, 'civType=' .. tostring(civType),
		function() playerConfig:SetCivilizationTypeName(civType) end,
		function() return playerConfig:GetCivilizationTypeName() end)
	if cityStateType ~= nil then
		SetConfigEx(playerConfig, 'cityStateType=' .. tostring(cityStateType),
			function() playerConfig:SetCityStateType(cityStateType) end,
			function() return playerConfig:GetCityStateType() end)
	end
	if leaderType ~= nil then
		SetConfigEx(playerConfig, 'leaderType=' .. tostring(leaderType),
			function() playerConfig:SetLeaderTypeName(leaderType) end,
			function() return playerConfig:GetLeaderTypeName() end)
	end
	SetConfigEx(playerConfig, 'isMinorCiv=' .. tostring(isMinor),
		function() playerConfig:SetIsMinorCiv(isMinor) end)
	SetConfigEx(playerConfig, 'slotStatus=' .. SlotStatusName(isMinor and SlotStatus.SS_COMPUTER or SlotStatus.SS_TAKEN),
		function() playerConfig:SetSlotStatus(isMinor and SlotStatus.SS_COMPUTER or SlotStatus.SS_TAKEN) end,
		function() return playerConfig:GetSlotStatus() end)

	local player = Players[slot]
	if player == nil then
		print("[ModMiscTool][Ghost] Players[" .. tostring(slot) .. "]=nil"
			.. "（配置写进去了，但引擎没在运行时生成玩家对象）")
	else
		local started, startErr = pcall(function() player:StartCityState() end)
		print("[ModMiscTool][Ghost]   StartCityState ok=" .. tostring(started)
			.. (started and '' or (' err=' .. tostring(startErr))))
	end

	-- 引擎没有把玩家建出来的话，这里如实返回 nil，别把空槽位当幽灵记进池子
	if Players[slot] == nil then
		print("[ModMiscTool][Ghost] slot " .. tostring(slot) .. " configured but not created by engine")
		print("[ModMiscTool][Ghost] 结论：运行时补建玩家对象不被引擎支持"
			.. "（PlayerConfigurations 改得动、回读也对，但 Players[] 不会多出玩家；"
			.. "EXera 的 CreateCityStatePlayer 也没有任何调用点，属死代码）")
		DumpPlayerSlots('after-create-failed')
		m_LastCreateDiagnostics = 'engine did not create player at slot ' .. tostring(slot)
		return nil, m_LastCreateDiagnostics
	end

	print("[ModMiscTool][Ghost]   after config: " .. DescribeSlot(slot))
	MovePlayerOffMap(slot)
	local ghosts = GetGhostPlayers()
	table.insert(ghosts, slot)
	Game:SetProperty(GHOST_PLAYER_PROPERTY, ghosts)
	DumpPlayerSlots('after-create-ok')

	print("[ModMiscTool][Ghost] created ghost player " .. tostring(slot)
		.. " as " .. tostring(civType) .. " pool total=" .. tostring(#ghosts))
	m_LastCreateDiagnostics = nil
	return slot
end

-- 最近一次补建失败的原因（面板直接显示，省得每次拉日志）
function GetLastGhostCreateDiagnostics()
	return m_LastCreateDiagnostics
end

-- [已验证失败] 同 CreateGhostPlayerFromEmptySlot：主要文明也补建不出来（引擎不生成玩家对象）。
-- 保留仅为诊断对比用。
function CreateGhostPlayerFromMajorCiv(civType)
	if civType == nil then
		local majorCivTypes = GetMajorCivTypes()
		if #majorCivTypes == 0 then
			print("[ModMiscTool][Ghost] no major civ type in database")
			return nil
		end
		civType = majorCivTypes[(#GetGhostPlayers() % #majorCivTypes) + 1]
	end
	return CreateGhostPlayerFromEmptySlot(civType)
end

-- ===========================================================================
-- 开局建立幽灵玩家池
-- ===========================================================================

-- [已验证失败] player:IsMinor() 在 gameplay 层不可用（报 function expected instead of nil），
-- 只有 UI 端有。
-- 因此城邦候选列表由 UI 端算好，这里通过 ExposedMembers 取；万一 UI 端还没暴露，
-- 退回 gameplay 端可用的 IsMajor/IsBarbarian 判断（基座 VikingScenario 等即用此法）。
local function GetUnsettledCityStatePlayerIDs()
	local uiMembers = ExposedMembers.ModMiscToolUI
	if uiMembers ~= nil and uiMembers.GetUnsettledCityStatePlayerIDsUI ~= nil then
		return uiMembers.GetUnsettledCityStatePlayerIDsUI()
	end

	print("[ModMiscTool][Ghost] UI helper missing, falling back to IsMajor check")
	local playerIDs = {}
	for playerID = 0, GameDefines.MAX_PLAYERS - 1 do
		local player = Players[playerID]
		if player ~= nil and not player:IsMajor() and not player:IsBarbarian() then
			local cities = player:GetCities()
			if cities == nil or cities:GetCapitalCity() == nil then
				table.insert(playerIDs, playerID)
			end
		end
	end
	return playerIDs
end

-- 把候选里“超出 keepOnMap”的部分搬到地图外并入池子。
-- 从末尾往前取：引擎给玩家原本配置的槽位 id 更小，留在地图上的就是玩家自己选的那批。
-- beforeMove：可选钩子，在“搬离地图”之前对该玩家做一次加工（主要文明用它做城邦化）
local function AddGhostsFromCandidates(candidates, keepOnMap, tag, skipPlayerID, beforeMove)
	local ghosts = GetGhostPlayers()
	local knownGhosts = {}
	for _, ghostID in ipairs(ghosts) do
		knownGhosts[ghostID] = true
	end

	local ghostCount = math.min(#candidates - keepOnMap, GHOST_PLAYER_MAX)
	if ghostCount <= 0 then
		print("[ModMiscTool][Ghost] " .. tag .. ": nothing to move (candidates="
			.. tostring(#candidates) .. " keep=" .. tostring(keepOnMap) .. ")")
		return 0, #ghosts, 0
	end

	local added = 0
	local processed = 0
	for index = #candidates, #candidates - ghostCount + 1, -1 do
		local playerID = candidates[index]
		if playerID ~= skipPlayerID and not knownGhosts[playerID] then
			-- 先加工再搬：主要文明城邦化后如果生成了单位，会被紧接着的 MovePlayerOffMap 清掉
			if beforeMove ~= nil and beforeMove(playerID) then
				processed = processed + 1
			end
			if MovePlayerOffMap(playerID) then
				table.insert(ghosts, playerID)
				knownGhosts[playerID] = true
				added = added + 1
			end
		end
	end

	Game:SetProperty(GHOST_PLAYER_PROPERTY, ghosts)
	return added, #ghosts, processed
end

-- originalCount：玩家在创建游戏时原本设置的城邦数量（UI 层从 CustomData 读出后传入）
-- 比它多出来的城邦会被搬到地图外，作为幽灵玩家池；没传值或不是新开局则不处理。
function InitializeGhostPlayers(originalCount)
	if originalCount == nil then return end

	-- 只搬“还没建城”的城邦：读老档时城邦都已建城 → 候选为空 → 什么都不会动
	local candidates = GetUnsettledCityStatePlayerIDs()
	if #candidates == 0 then return end

	local keepOnMap = math.max(0, math.floor(originalCount))
	local added, poolTotal = AddGhostsFromCandidates(candidates, keepOnMap, 'city states')

	print("[ModMiscTool][Ghost] unsettled city states=" .. tostring(#candidates)
		.. " player choice=" .. tostring(keepOnMap)
		.. " newly off-map=" .. tostring(added)
		.. " pool total=" .. tostring(poolTotal))
end

-- ===========================================================================
-- [待验证] 把幽灵化的“主要文明”改造成城邦
--
-- 问题：主要文明即使被搬离地图，仍然是 IsMajor()==true 的完整文明，会参与外交
--       （AI 来交涉、出现在外交界面）。
-- 思路：搬离地图之前，先把它按城邦重新初始化，让它以城邦身份存在。
--
-- 与 CreateGhostPlayerFromEmptySlot 的关键区别【已验证失败】：那条路是给**空槽位**造玩家，
-- 引擎根本不会生成玩家对象（Players[slot] 恒为 nil）；而这里是给**已经存在的玩家**
-- 换身份，Players[playerID] 是有效对象，所以 StartCityState() 有机会真正生效。
--
-- 判定标准：转换后 player:IsMajor() 是否变成 false（gameplay 层可用，可直接验）。
-- 注意 player:IsMinor() 在 gameplay 层不可用【已验证失败】，不要用它做判定。
-- ===========================================================================
function ConvertGhostPlayerToCityState(playerID)
	local player = Players[playerID]
	local playerConfig = PlayerConfigurations[playerID]
	if player == nil or playerConfig == nil then
		print("[ModMiscTool][Ghost] convert-to-city-state: player " .. tostring(playerID)
			.. " has no engine player/config")
		return false
	end

	local isMajorBefore = CallOrNil(function() return player:IsMajor() end)
	if isMajorBefore == false then
		-- 本来就是城邦，不需要转换
		return false
	end

	-- 【硬保护】已经有城市的玩家绝不能动：引擎里“移除全部城市”会直接判玩家死亡，
	-- 手里有开拓者也救不回来（授权者实机验证）。所以这里连城邦化都不做。
	local cities = CallOrNil(function() return player:GetCities() end)
	local capital = nil
	if cities ~= nil then
		capital = CallOrNil(function() return cities:GetCapitalCity() end)
	end
	if capital ~= nil then
		print("[ModMiscTool][Ghost] convert-to-city-state: player " .. tostring(playerID)
			.. " 已有城市 —— 拒绝处理（移除全部城市会让玩家死亡，开拓者也救不回来）")
		return false
	end

	local cityStateCivTypes = GetCityStateCivTypes()
	if #cityStateCivTypes == 0 then
		print("[ModMiscTool][Ghost] convert-to-city-state: no city state civ in database")
		return false
	end
	local civType = cityStateCivTypes[(playerID % #cityStateCivTypes) + 1]
	local leaderType = GetDefaultLeaderType(civType)
	local cityStateType = GetCityStateTypeFor(civType)

	print("[ModMiscTool][Ghost] convert-to-city-state: player " .. tostring(playerID)
		.. " civ=" .. tostring(civType) .. " leader=" .. tostring(leaderType)
		.. " csType=" .. tostring(cityStateType))
	print("[ModMiscTool][Ghost]   before: " .. DescribeSlot(playerID))

	SetConfigEx(playerConfig, 'isMinorCiv=true',
		function() playerConfig:SetIsMinorCiv(true) end,
		function() return playerConfig:IsMinorCiv() end)
	SetConfigEx(playerConfig, 'civType=' .. tostring(civType),
		function() playerConfig:SetCivilizationTypeName(civType) end,
		function() return playerConfig:GetCivilizationTypeName() end)
	if cityStateType ~= nil then
		SetConfigEx(playerConfig, 'cityStateType=' .. tostring(cityStateType),
			function() playerConfig:SetCityStateType(cityStateType) end,
			function() return playerConfig:GetCityStateType() end)
	end
	if leaderType ~= nil then
		SetConfigEx(playerConfig, 'leaderType=' .. tostring(leaderType),
			function() playerConfig:SetLeaderTypeName(leaderType) end,
			function() return playerConfig:GetLeaderTypeName() end)
	end

	local started, startErr = pcall(function() player:StartCityState() end)
	local isMajorAfter = CallOrNil(function() return player:IsMajor() end)
	print("[ModMiscTool][Ghost]   StartCityState ok=" .. tostring(started)
		.. (started and '' or (' err=' .. tostring(startErr)))
		.. " -> IsMajor " .. tostring(isMajorBefore) .. " => " .. tostring(isMajorAfter))
	print("[ModMiscTool][Ghost]   after: " .. DescribeSlot(playerID))

	if isMajorAfter == false then
		print("[ModMiscTool][Ghost] 城邦化成功：player " .. tostring(playerID)
			.. " 已不再是主要文明（不会再参与主要文明外交）")
		return true
	end
	print("[ModMiscTool][Ghost] 城邦化未生效：player " .. tostring(playerID)
		.. " 仍是主要文明（配置能改、回读也对，但引擎的玩家身份没变）")
	return false
end

-- 主要文明候选：还没建城的主要文明，排除本机玩家（不能把自己搬到地图外）
local function GetUnsettledMajorPlayerIDs()
	local localPlayer = Game.GetLocalPlayer()
	local playerIDs = {}
	for playerID = 0, MaxPlayerSlots() - 1 do
		local player = Players[playerID]
		if player ~= nil and playerID ~= localPlayer then
			local isMajor = CallOrNil(function() return player:IsMajor() end)
			local isBarbarian = CallOrNil(function() return player:IsBarbarian() end)
			if isMajor == true and isBarbarian ~= true then
				local cities = CallOrNil(function() return player:GetCities() end)
				local capital = nil
				if cities ~= nil then
					capital = CallOrNil(function() return cities:GetCapitalCity() end)
				end
				if capital == nil then
					table.insert(playerIDs, playerID)
				end
			end
		end
	end
	return playerIDs
end

-- originalCount：玩家原本设置的主要文明玩家数（含本机玩家）。
-- 前端 hook 把参与玩家数抬到槽位预算允许的上限后，引擎会在开局多建一批主要文明；
-- 这里把超出的部分搬到地图外当幽灵，玩家自己的对手数量保持不变。
-- 只搬“还没建城”的：本机玩家与已经落地的对手一律不动。
function InitializeGhostMajorPlayers(originalCount)
	if originalCount == nil then return end

	local candidates = GetUnsettledMajorPlayerIDs()
	if #candidates == 0 then return end

	local keepOnMap = math.max(0, math.floor(originalCount) - 1)
	-- 搬离之前先城邦化：避免幽灵化的主要文明继续参与外交（可用开关关掉）
	local beforeMove = nil
	if GHOST_CONVERT_MAJOR_TO_CITY_STATE then
		beforeMove = ConvertGhostPlayerToCityState
	else
		print("[ModMiscTool][Ghost] major ghost conversion disabled by switch")
	end
	local added, poolTotal, converted = AddGhostsFromCandidates(candidates, keepOnMap,
		'major players', Game.GetLocalPlayer(), beforeMove)

	print("[ModMiscTool][Ghost] unsettled major players=" .. tostring(#candidates)
		.. " player choice=" .. tostring(keepOnMap + 1)
		.. " newly off-map=" .. tostring(added)
		.. " converted-to-city-state=" .. tostring(converted)
		.. " pool total=" .. tostring(poolTotal))
end

-- 面板用：一行统计，直接看引擎到底建了多少玩家、幽灵池还剩多少可用
function GetPlayerSlotSummary()
	local stats = DumpPlayerSlots('panel')
	return "major=" .. tostring(stats.major)
		.. " minor=" .. tostring(stats.minor)
		.. " engine=" .. tostring(stats.enginePlayers)
		.. " empty=" .. tostring(#stats.emptySlots)
		.. " pool=" .. tostring(GetGhostPlayerCount())
		.. " free=" .. tostring(GetAvailableGhostPlayerCount())
end
