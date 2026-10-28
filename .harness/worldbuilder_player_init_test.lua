-- ===========================================================================
-- 桩测试：WorldBuilder 玩家生命周期（2026-10-28 补的「玩家初始化」）
--
-- 要证明的事（这次改动的回归防线）：
--   ① AddPlayer 之后必须补 InitializePlayer，且调用顺序是
--      AddPlayer → SetPlayerSlotStatus → SetPlayerLeader → InitializePlayer → 探针；
--   ② AddPlayer 返回 -1 / 抛错时，后面的接口一次都不能调（无效玩家 id 会崩引擎）；
--   ③ 槽位状态用现行枚举 SS_*（不是调试面板里的旧名 HUMAN / AI）；
--   ④ 两个探针任一为真才算初始化成功；都假时 ok=false 并给出原因；
--   ⑤ MeetAllAlivePlayers 不给自己 SetHasMet、双向都设、只统计成功的对数；
--   ⑥ 无效 playerID 走到 InitializePlayer 前面就被挡住，不碰 WorldBuilder。
--
-- 跑法（工作目录 = 本项目根）：lua5.1 .harness/worldbuilder_player_init_test.lua
-- ===========================================================================
local MODULE = "ModTool_WorldBuilderAPI.lua"

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
local callLog = {}
local function ResetCalls() callLog = {} end
local function Record(name, arg1, arg2, arg3, arg4)
	callLog[#callLog + 1] = { name = name, arg1 = arg1, arg2 = arg2, arg3 = arg3, arg4 = arg4 }
end
local function CallNames()
	local names = {}
	for _, entry in ipairs(callLog) do names[#names + 1] = entry.name end
	return table.concat(names, " > ")
end
local function FindCall(name)
	for _, entry in ipairs(callLog) do
		if entry.name == name then return entry end
	end
	return nil
end

-- 行为开关
local addPlayerReturn = 7
local addPlayerThrows = false
local initializeThrows = false
local wbInitializedValue = true
local engineInitializedValue = true
local slotStatusTable = { SS_OPEN = 0, SS_COMPUTER = 1, SS_CLOSED = 2, SS_TAKEN = 3, SS_OBSERVER = 4 }

-- 外交桩：记录谁对谁 SetHasMet
local metCalls = {}
local function NewDiplomacyStub(ownerID)
	return {
		SetHasMet = function(self, otherID)
			metCalls[#metCalls + 1] = { owner = ownerID, other = otherID }
		end,
	}
end

local function BuildPlayerStubs()
	local players = {}
	for _, playerID in ipairs({ 1, 2, 7 }) do
		players[playerID] = {
			IsInitialized = function() return engineInitializedValue end,
			GetDiplomacy = function() return NewDiplomacyStub(playerID) end,
		}
	end
	return players
end

Players = BuildPlayerStubs()
SlotStatus = slotStatusTable
PlayerManager = {
	GetAliveIDs = function() return { 1, 2, 7 } end,
}

local playerManager = {}
function playerManager:AddPlayer(isAI)
	Record("AddPlayer", isAI)
	if addPlayerThrows then error("AddPlayer boom") end
	return addPlayerReturn
end
function playerManager:SetPlayerSlotStatus(playerID, status)
	Record("SetPlayerSlotStatus", playerID, status)
	return true
end
function playerManager:SetPlayerLeader(playerID, leaderType, civType, civLevel)
	Record("SetPlayerLeader", playerID, leaderType, civType, civLevel)
	return true
end
function playerManager:InitializePlayer(playerID)
	Record("InitializePlayer", playerID)
	if initializeThrows then error("InitializePlayer boom") end
	return true
end
function playerManager:IsPlayerInitialized(playerID)
	Record("IsPlayerInitialized", playerID)
	return wbInitializedValue
end

WorldBuilder = {
	PlayerManager = function() return playerManager end,
	IsActive = function() return false end,
}

local function LoadModule()
	ResetCalls()
	metCalls = {}
	WorldBuilderAPI = nil
	local chunk = assert(loadfile(MODULE))
	chunk()
	return WorldBuilderAPI
end

local function ResetScenario()
	addPlayerReturn = 7
	addPlayerThrows = false
	initializeThrows = false
	wbInitializedValue = true
	engineInitializedValue = true
end

-- ---------------------------------------------------------------------------
Section('① 正常路径：顺序正确、槽位状态用 SS_*')
ResetScenario()
local API = LoadModule()
local result = API.AddPlayerAndInitialize(true, "LEADER_TRAJAN", "CIVILIZATION_ROME", "CIVILIZATION_LEVEL_FULL_CIV", false)
Check('返回表', type(result) == 'table', type(result))
Check('playerID=7', result.playerID == 7, result.playerID)
Check('ok=true', result.ok == true, result.ok)
Check('调用顺序 = AddPlayer > SetPlayerSlotStatus > SetPlayerLeader > InitializePlayer > IsPlayerInitialized',
	CallNames() == 'AddPlayer > SetPlayerSlotStatus > SetPlayerLeader > InitializePlayer > IsPlayerInitialized',
	CallNames())
local statusEntry = FindCall('SetPlayerSlotStatus')
Check('AI 槽位状态 = SS_COMPUTER(1)', statusEntry ~= nil and statusEntry.arg2 == 1,
	statusEntry ~= nil and statusEntry.arg2)
Check('AddPlayer 收到 isAI=true', FindCall('AddPlayer').arg1 == true, FindCall('AddPlayer').arg1)
Check('InitializePlayer 拿到 playerID=7', FindCall('InitializePlayer').arg1 == 7)
Check('steps 里记录了四步以上', #result.steps >= 5, #result.steps)
Check('metCount=0（本次关掉 meetEveryone）', result.metCount == 0, result.metCount)
Check('没有发外交调用', #metCalls == 0, #metCalls)

-- ---------------------------------------------------------------------------
Section('② 人类槽位用 SS_TAKEN(3)')
ResetScenario()
API = LoadModule()
local humanResult = API.AddPlayerAndInitialize(false, "LEADER_TRAJAN", "CIVILIZATION_ROME", "CIVILIZATION_LEVEL_FULL_CIV", false)
local humanStatus = FindCall('SetPlayerSlotStatus')
Check('人类槽位状态 = SS_TAKEN(3)', humanStatus ~= nil and humanStatus.arg2 == 3,
	humanStatus ~= nil and humanStatus.arg2)
Check('AddPlayer 收到 isAI=false', FindCall('AddPlayer').arg1 == false, FindCall('AddPlayer').arg1)
Check('人类玩家的 ok=true', humanResult.ok == true, humanResult.ok)

-- ---------------------------------------------------------------------------
Section('③ AddPlayer 返回 -1：后面一次都不能调')
ResetScenario()
addPlayerReturn = -1
API = LoadModule()
local minusResult = API.AddPlayerAndInitialize(true, "LEADER_TRAJAN", "CIVILIZATION_ROME", "CIVILIZATION_LEVEL_FULL_CIV", true)
Check('ok=false', minusResult.ok == false, minusResult.ok)
Check('playerID=-1', minusResult.playerID == -1, minusResult.playerID)
Check('只调了 AddPlayer', CallNames() == 'AddPlayer', CallNames())
Check('没有 SetHasMet', #metCalls == 0, #metCalls)
Check('reason 里带 -1', string.find(tostring(minusResult.reason), '-1', 1, true) ~= nil, minusResult.reason)

-- ---------------------------------------------------------------------------
Section('④ AddPlayer 抛错：被 pcall 包住，返回失败表')
ResetScenario()
addPlayerThrows = true
API = LoadModule()
local throwResult = API.AddPlayerAndInitialize(true, "LEADER_TRAJAN", "CIVILIZATION_ROME", "CIVILIZATION_LEVEL_FULL_CIV", true)
Check('ok=false', throwResult.ok == false, throwResult.ok)
Check('reason 说明是 AddPlayer 抛错',
	string.find(tostring(throwResult.reason), 'AddPlayer', 1, true) ~= nil, throwResult.reason)
Check('后续接口没被调', CallNames() == 'AddPlayer', CallNames())

-- ---------------------------------------------------------------------------
Section('⑤ 探针全假：ok=false 且给原因')
ResetScenario()
wbInitializedValue = false
engineInitializedValue = false
API = LoadModule()
local probeResult = API.AddPlayerAndInitialize(true, "LEADER_TRAJAN", "CIVILIZATION_ROME", "CIVILIZATION_LEVEL_FULL_CIV", false)
Check('ok=false', probeResult.ok == false, probeResult.ok)
Check('wbInitialized=false', probeResult.wbInitialized == false, probeResult.wbInitialized)
Check('engineInitialized=false', probeResult.engineInitialized == false, probeResult.engineInitialized)
Check('reason 非空', probeResult.reason ~= nil, probeResult.reason)
Check('InitializePlayer 仍然被调过', FindCall('InitializePlayer') ~= nil, CallNames())

-- ---------------------------------------------------------------------------
Section('⑥ 引擎侧为真也算成功（编辑器侧假）')
ResetScenario()
wbInitializedValue = false
engineInitializedValue = 1
API = LoadModule()
local engineOnlyResult = API.AddPlayerAndInitialize(true, "LEADER_TRAJAN", "CIVILIZATION_ROME", "CIVILIZATION_LEVEL_FULL_CIV", false)
Check('ok=true（引擎侧返回 1 也归一化成真）', engineOnlyResult.ok == true, engineOnlyResult.ok)

-- ---------------------------------------------------------------------------
Section('⑦ 互相见面：不给自己、双向、只数成功')
ResetScenario()
API = LoadModule()
local pairCount = API.MeetAllAlivePlayers(7)
Check('成功对数 = 2（1 与 2，跳过自己）', pairCount == 2, pairCount)
Check('共 4 次 SetHasMet', #metCalls == 4, #metCalls)
local selfMet = false
for _, callEntry in ipairs(metCalls) do
	if callEntry.owner == 7 and callEntry.other == 7 then selfMet = true end
end
Check('没有给自己 SetHasMet', selfMet == false)
local toOther, toSelf = false, false
for _, callEntry in ipairs(metCalls) do
	if callEntry.owner == 7 and callEntry.other == 1 then toOther = true end
	if callEntry.owner == 1 and callEntry.other == 7 then toSelf = true end
end
Check('7 → 1 有设', toOther)
Check('1 → 7 有设', toSelf)

-- ---------------------------------------------------------------------------
Section('⑧ 无效 playerID 在 InitializePlayer 之前被挡住')
ResetScenario()
API = LoadModule()
Check('InitializePlayer(nil) = false', API.InitializePlayer(nil) == false)
Check('InitializePlayer(-1) = false', API.InitializePlayer(-1) == false)
Check('SetPlayerSlotStatus(nil) = false', API.SetPlayerSlotStatus(nil, 1) == false)
Check('SetPlayerSlotStatus(nil 状态) = false', API.SetPlayerSlotStatus(7, nil) == false)
Check('一次引擎调用都没有', CallNames() == '', CallNames())

print('')
print('--------------------------------------------------')
print('桩测试结果：' .. pass .. ' 项通过，' .. fail .. ' 项失败')
print('--------------------------------------------------')
if fail > 0 then os.exit(1) end
